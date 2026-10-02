#!/usr/bin/env python3
"""
bench.py - Mide el rendimiento de la version escalar vs la vectorial.

Para cada tamano N:
  1. Genera el archivo de entrada con tools/gen_input.py (si no existe).
  2. Ejecuta cada binario UNA vez con REPS repeticiones del kernel.
     El driver mide cada repeticion y escribe en <salida>.timing.txt
     el promedio y la desviacion estandar (en ms y en ciclos TSC).
  3. Calcula el speedup = t_escalar / t_vectorial.

Salidas:
  - Tabla en consola
  - data/bench/resultados.csv
  - data/bench/speedup.png (si matplotlib esta instalado)

Uso:  python3 tools/bench.py
"""
import csv
import os
import subprocess

TAMANOS  = [1_000, 100_000, 1_000_000, 50_000_000]
REPS     = 30
BINARIOS = {"escalar": "./bin/norm_scalar", "vectorial": "./bin/norm_vector"}
CARPETA  = "data/bench"


def generar_entrada(n):
    ruta = f"{CARPETA}/in_{n}.dat"
    if not os.path.exists(ruta):
        print(f"Generando {ruta} ...")
        subprocess.run(["python3", "tools/gen_input.py", str(n), ruta, "random"],
                       check=True, stdout=subprocess.DEVNULL)
    return ruta


def medir(binario, entrada, salida):
    """Ejecuta el programa con REPS repeticiones y devuelve el resumen de tiempos."""
    subprocess.run([binario, entrada, salida, str(REPS)], check=True,
                   stdout=subprocess.DEVNULL)
    datos = {}
    with open(salida + ".timing.txt") as f:
        for linea in f:
            clave, valor = linea.strip().split("=")
            datos[clave] = float(valor)
    return datos


def main():
    os.makedirs(CARPETA, exist_ok=True)
    filas = []

    for n in TAMANOS:
        entrada = generar_entrada(n)
        r = {nombre: medir(binario, entrada, f"{CARPETA}/out_{nombre}_{n}.dat")
             for nombre, binario in BINARIOS.items()}
        esc, vec = r["escalar"], r["vectorial"]
        speedup = esc["ms_mean"] / vec["ms_mean"]
        filas.append([n,
                      esc["ms_mean"], esc["ms_std"], esc["cycles_mean"],
                      vec["ms_mean"], vec["ms_std"], vec["cycles_mean"],
                      speedup])
        print(f"N={n:>10}  "
              f"escalar={esc['ms_mean']:10.4f} ± {esc['ms_std']:8.4f} ms "
              f"({esc['cycles_mean']:.0f} ciclos)   "
              f"vectorial={vec['ms_mean']:10.4f} ± {vec['ms_std']:8.4f} ms "
              f"({vec['cycles_mean']:.0f} ciclos)   speedup={speedup:5.2f}x")

    with open(f"{CARPETA}/resultados.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["N", "escalar_ms", "escalar_std_ms", "escalar_ciclos",
                    "vectorial_ms", "vectorial_std_ms", "vectorial_ciclos",
                    "speedup"])
        w.writerows(filas)
    print(f"\nTabla guardada en {CARPETA}/resultados.csv")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib no esta instalado: no se genera el grafico.")
        return

    ns = [fila[0] for fila in filas]
    sp = [fila[7] for fila in filas]
    plt.figure(figsize=(7, 4.5))
    plt.plot(ns, sp, "o-", label="Speedup medido")
    plt.axhline(8, linestyle="--", color="gray", label="Maximo teorico AVX2 (8x)")
    plt.xscale("log")
    plt.xlabel("N (cantidad de elementos, escala logaritmica)")
    plt.ylabel("Speedup = t_escalar / t_vectorial")
    plt.title("Speedup AVX2 vs escalar")
    plt.grid(True, which="both", alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(f"{CARPETA}/speedup.png", dpi=150)
    print(f"Grafico guardado en {CARPETA}/speedup.png")


if __name__ == "__main__":
    main()
