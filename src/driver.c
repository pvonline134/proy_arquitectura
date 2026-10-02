#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "stats.h"

#define VEC_ALIGN 32 /* bytes: alineacion requerida por AVX2 (256 bits) */

static double elapsed_ms(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) * 1000.0 +
           (end.tv_nsec - start.tv_nsec) / 1e6;
}

/* Lee el contador de marcas de tiempo (TSC) del procesador.
 * lfence impide que el CPU adelante rdtsc (ejecucion fuera de orden)
 * antes de que terminen las instrucciones anteriores. */
static inline uint64_t read_tsc(void) {
    uint32_t lo, hi;
    __asm__ volatile ("lfence\n\trdtsc" : "=a"(lo), "=d"(hi) : : "memory");
    return ((uint64_t)hi << 32) | lo;
}

/* Promedio y desviacion estandar muestral (divide entre k-1) de k valores. */
static void mean_std(const double *v, int k, double *mean, double *std) {
    double s = 0.0;
    for (int i = 0; i < k; i++) s += v[i];
    *mean = s / k;

    double sq = 0.0;
    for (int i = 0; i < k; i++) sq += (v[i] - *mean) * (v[i] - *mean);
    *std = (k > 1) ? sqrt(sq / (k - 1)) : 0.0;
}

/* Reserva 'count' floats alineados a VEC_ALIGN bytes (aligned_alloc
 * exige que el tamano solicitado sea multiplo del alineamiento, por
 * eso se redondea hacia arriba). */
static float *alloc_aligned_floats(size_t count) {
    size_t bytes = count * sizeof(float);
    size_t padded = ((bytes + VEC_ALIGN - 1) / VEC_ALIGN) * VEC_ALIGN;
    if (padded == 0) padded = VEC_ALIGN;

    float *p = aligned_alloc(VEC_ALIGN, padded);
    if (!p) {
        fprintf(stderr, "Error: no se pudo reservar memoria alineada.\n");
        exit(EXIT_FAILURE);
    }
    memset(p, 0, padded);
    return p;
}

/*
 * Formato de input.dat (little endian):
 *   int32_t n
 *   float   arr[n]
 */
static float *read_input(const char *path, int *out_n) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: no se pudo abrir '%s'\n", path);
        exit(EXIT_FAILURE);
    }

    int32_t n = 0;
    if (fread(&n, sizeof(int32_t), 1, f) != 1) {
        fprintf(stderr, "Error: archivo de entrada invalido (falta N)\n");
        fclose(f);
        exit(EXIT_FAILURE);
    }
    if (n < 0) {
        fprintf(stderr, "Error: N invalido (%d)\n", n);
        fclose(f);
        exit(EXIT_FAILURE);
    }

    float *arr = alloc_aligned_floats((size_t)(n > 0 ? n : 1));
    if (n > 0 && fread(arr, sizeof(float), (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "Error: archivo de entrada truncado\n");
        fclose(f);
        exit(EXIT_FAILURE);
    }

    fclose(f);
    *out_n = n;
    return arr;
}

static void write_output(const char *path, const float *arr, int n) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "Error: no se pudo crear '%s'\n", path);
        exit(EXIT_FAILURE);
    }
    fwrite(&n, sizeof(int32_t), 1, f);
    if (n > 0) fwrite(arr, sizeof(float), (size_t)n, f);
    fclose(f);
}

/* Resumen en texto plano (para que tools/verify_reference.py no
 * tenga que parsear el binario de salida). */
static void write_stats_summary(const char *path, int n, float sum,
                                 float mean, float var, float stddev,
                                 float min, float max, double ms) {
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "Aviso: no se pudo crear el resumen '%s'\n", path);
        return;
    }
    fprintf(f, "n=%d\n", n);
    fprintf(f, "sum=%.9g\n", sum);
    fprintf(f, "mean=%.9g\n", mean);
    fprintf(f, "var=%.9g\n", var);
    fprintf(f, "stddev=%.9g\n", stddev);
    fprintf(f, "min=%.9g\n", min);
    fprintf(f, "max=%.9g\n", max);
    fprintf(f, "kernel_ms=%.6f\n", ms);
    fclose(f);
}

/* Resumen de tiempos en un archivo aparte, para no alterar el formato
 * de .stats.txt que lee tools/verify_reference.py. */
static void write_timing_summary(const char *path, int n, int reps,
                                 double ms_mean, double ms_std,
                                 double cyc_mean, double cyc_std) {
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "Aviso: no se pudo crear el resumen '%s'\n", path);
        return;
    }
    fprintf(f, "n=%d\n", n);
    fprintf(f, "reps=%d\n", reps);
    fprintf(f, "ms_mean=%.6f\n", ms_mean);
    fprintf(f, "ms_std=%.6f\n", ms_std);
    fprintf(f, "cycles_mean=%.0f\n", cyc_mean);
    fprintf(f, "cycles_std=%.0f\n", cyc_std);
    fclose(f);
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Uso: %s <input.dat> <output.dat> [repeticiones]\n"
        "  input.dat      archivo binario de entrada (int32 N + N floats)\n"
        "  output.dat     archivo binario de salida (arreglo normalizado)\n"
        "  repeticiones   veces que se repite el kernel para promediar\n"
        "                 el tiempo medido (por defecto: 1)\n",
        prog);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    const char *input_path  = argv[1];
    const char *output_path = argv[2];
    int reps = (argc >= 4) ? atoi(argv[3]) : 1;
    if (reps < 1) reps = 1;

    int n = 0;
    float *in  = read_input(input_path, &n);
    float *out = alloc_aligned_floats((size_t)(n > 0 ? n : 1));

        /* Caso borde N = 0: se reporta como error controlado (el enunciado
     * lo exige), pero se continua para generar las salidas con ceros. */
    if (n == 0) {
        fprintf(stderr, "Aviso: N = 0, el arreglo esta vacio. "
                        "Los estadisticos se reportan como 0.\n");
    }

    float sum = 0.0f, mean = 0.0f, var = 0.0f, min = 0.0f, max = 0.0f;
    struct timespec t0, t1;

    /* Un tiempo (ms) y una cuenta de ciclos por cada repeticion. */
    double *times_ms = malloc((size_t)reps * sizeof(double));
    double *cycles   = malloc((size_t)reps * sizeof(double));
    if (!times_ms || !cycles) {
        fprintf(stderr, "Error: no se pudo reservar memoria para los tiempos.\n");
        return EXIT_FAILURE;
    }

    /* --- Seccion medida: sum_array + compute_stats + normalize_array --- */
    for (int r = 0; r < reps; r++) {
        clock_gettime(CLOCK_MONOTONIC, &t0);
        uint64_t c0 = read_tsc();

        sum = sum_array(in, n);
        compute_stats(in, n, &mean, &var, &min, &max);
        float stddev_r = sqrtf(var);
        normalize_array(in, out, n, mean, stddev_r);

        uint64_t c1 = read_tsc();
        clock_gettime(CLOCK_MONOTONIC, &t1);
        times_ms[r] = elapsed_ms(t0, t1);
        cycles[r]   = (double)(c1 - c0);
    }

    double avg_ms, std_ms, avg_cyc, std_cyc;
    mean_std(times_ms, reps, &avg_ms, &std_ms);
    mean_std(cycles,   reps, &avg_cyc, &std_cyc);
    float stddev = sqrtf(var);

    printf("N        = %d\n", n);
    printf("Suma     = %.6f\n", sum);
    printf("Media    = %.6f\n", mean);
    printf("Varianza = %.6f\n", var);
    printf("StdDev   = %.6f\n", stddev);
    printf("Minimo   = %.6f\n", min);
    printf("Maximo   = %.6f\n", max);
    printf("Tiempo promedio del kernel (%d rep.): %.6f ms\n", reps, avg_ms);
    printf("Desv. estandar del tiempo         : %.6f ms\n", std_ms);
    printf("Ciclos TSC promedio del kernel    : %.0f +- %.0f\n", avg_cyc, std_cyc);

    write_output(output_path, out, n);

    char summary_path[1024];
    snprintf(summary_path, sizeof(summary_path), "%s.stats.txt", output_path);
    write_stats_summary(summary_path, n, sum, mean, var, stddev, min, max, avg_ms);

    char timing_path[1024];
    snprintf(timing_path, sizeof(timing_path), "%s.timing.txt", output_path);
    write_timing_summary(timing_path, n, reps, avg_ms, std_ms, avg_cyc, std_cyc);

    free(times_ms);
    free(cycles);
    free(in);
    free(out);
    return EXIT_SUCCESS;
}
