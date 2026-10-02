#ifndef STATS_H
#define STATS_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Firmas de los kernels de computo. Estas MISMAS firmas deben estar
 * implementadas tanto en asm/scalar/stats_scalar.asm como en
 * asm/vector/stats_vector.asm, respetando la convencion de llamada
 * System V AMD64 ABI:
 *
 *   Enteros/punteros (en orden): rdi, rsi, rdx, rcx, r8, r9
 *   Flotantes (en orden, aparte): xmm0, xmm1, xmm2, ...
 *   Valor de retorno float: xmm0
 *
 * sum_array:
 *   rdi = arr, esi = n              -> retorna la suma en xmm0
 *
 * compute_stats:
 *   rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
 *   (var = varianza POBLACIONAL: var = sum((x - mean)^2) / n)
 *   Caso borde: si n == 0, escriba 0.0 en mean/var/min/max.
 *
 * normalize_array:
 *   rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
 *   out[i] = (in[i] - mean) / stddev
 *   Caso borde: si stddev == 0.0, copie in[i] en out[i] tal cual
 *   (evite division por cero).
 */

float sum_array(const float *arr, int n);

void compute_stats(const float *arr, int n,
                    float *mean, float *var, float *min, float *max);

void normalize_array(const float *in, float *out, int n,
                      float mean, float stddev);

#ifdef __cplusplus
}
#endif

#endif /* STATS_H */
