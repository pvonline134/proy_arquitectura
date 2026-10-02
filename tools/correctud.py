#!/usr/bin/env python3
"""
correctud.py - Bateria de correctud completa y reproducible.

Para cada caso de prueba:
  1. Genera la entrada con semilla fija (mismos datos en cualquier maquina).
  2. Ejecuta ./bin/norm_scalar y ./bin/norm_vector (1 repeticion).
  3. Compara los estadisticos de cada version contra la referencia en
     double (misma logica que tools/verify_reference.py, tolerancia 1e-4).
  4. Compara el ARREGLO NORMALIZADO de cada version contra la referencia
     y escalar contra vectorial (verify_reference.py no revisa el arreglo).

Metrica para el arreglo normalizado: |obtenido - esperado| / max(1, |esperado|).
Los z-scores son de orden 1 y muchos valen casi 0; el error relativo puro
explota cerca de 0 aunque el resultado sea correcto.

Salidas: tabla en consola, data/correctud/resultados.csv y resultados.md
Uso:     python3 tools/correctud.py
"""
import csv
import math
import os
import random
import struct
import subprocess
import sys

# Trabaja siempre desde la raiz del repo (la carpeta que contiene tools/),
# sin importar desde donde se ejecute el script.
RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(RAIZ)
sys.path.insert(0, os.path.join(RAIZ, "tools"))
try:
    from verify_reference import read_summary, reference_stats, rel_error  # noqa: E402
except ImportError as e:
    sys.exit(f"Error: no se pudo importar tools/verify_reference.py ({e}).\n"
             "Copie correctud.py en la MISMA carpeta tools/ que verify_reference.py.")

CARPETA = "data/correctud"
TOL = 1e-4
BIN = {"escalar": "./bin/norm_scalar", "vectorial": "./bin/norm_vector"}


def f32(x):
    """Redondea un double a float32 (los datos del archivo son float32)."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def casos():
    """(nombre, descripcion, generador de valores). Semilla fija por caso."""
    def rnd(n, seed):
        r = random.Random(seed)
        return [r.uniform(-100.0, 100.0) for _ in range(n)]

    def neg(n, seed):
        r = random.Random(seed)
        return [-r.uniform(1.0, 1000.0) for _ in range(n)]

    def ext(n, seed):
        r = random.Random(seed)
        return [r.choice([-1, 1]) * r.uniform(1e15, 1e16) for _ in range(n)]

    edge = [-1e6, 1e6, 0.0, -0.0001, 0.0001, -1.0, 1.0]
    lista = [(f"N{n}", f"N = {n}, aleatorio [-100, 100]", (lambda n=n: rnd(n, 100 + n)))
             for n in (0, 1, 7, 8, 15, 16, 1000)]
    lista += [
        ("const5",  "N = 1000, todos = 5.0 (sigma = 0)",      lambda: [5.0] * 1000),
        ("const01", "N = 1001, todos = 0.1 (sigma = 0, no exacto)", lambda: [0.1] * 1001),
        ("neg",     "N = 1001, negativos [-1000, -1]",         lambda: neg(1001, 7)),
        ("ext",     "N = 1001, extremos +-[1e15, 1e16]",       lambda: ext(1001, 8)),
        ("edge",    "N = 1000, mezcla +-1e6, 0, +-1e-4, +-1",  lambda: [edge[i % 7] for i in range(1000)]),
    ]
    return lista


def escribir(ruta, valores):
    with open(ruta, "wb") as f:
        f.write(struct.pack("<i", len(valores)))
        if valores:
            f.write(struct.pack(f"<{len(valores)}f", *valores))


def leer_salida(ruta):
    with open(ruta, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        return list(struct.unpack(f"<{n}f", f.read(4 * n))) if n > 0 else []


def err_norm(a, b):
    return max((abs(x - y) / max(1.0, abs(y)) for x, y in zip(a, b)), default=0.0)


def main():
    faltan = [b for b in BIN.values() if not os.access(b, os.X_OK)]
    if faltan:
        sys.exit(f"Error: no existen {', '.join(faltan)} en {RAIZ}. Corra 'make' primero "
                 "(o ajuste BIN al nombre que usa su Makefile).")
    os.makedirs(CARPETA, exist_ok=True)
    filas, todo_ok = [], True
    for nombre, desc, gen in casos():
        vals = [f32(v) for v in gen()]
        entrada = f"{CARPETA}/in_{nombre}.dat"
        escribir(entrada, vals)
        n = len(vals)
        ref = dict(zip(["sum", "mean", "var", "stddev", "min", "max"], reference_stats(vals)))
        sd = ref["stddev"]
        ref_norm = [(x - ref["mean"]) / sd if sd > 0 else x for x in vals]

        res, salidas = {}, {}
        for ver, binario in BIN.items():
            salida = f"{CARPETA}/out_{ver}_{nombre}.dat"
            r = subprocess.run([binario, entrada, salida, "1"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            if r.returncode != 0:
                sys.exit(f"Error: {binario} fallo en el caso {nombre} "
                         f"(codigo {r.returncode}):\n{r.stderr}")
            got = read_summary(salida + ".stats.txt")
            e_stats = max(rel_error(got[k], ref[k]) for k in ref)
            out = leer_salida(salida)
            e_norm = err_norm(out, ref_norm)
            ok = got["n"] == n and e_stats <= TOL and e_norm <= TOL and len(out) == n
            res[ver] = (got, e_stats, e_norm, ok)
            salidas[ver] = out
        e_ev = err_norm(salidas["vectorial"], salidas["escalar"])
        ok_total = res["escalar"][3] and res["vectorial"][3] and e_ev <= TOL
        todo_ok &= ok_total
        filas.append([nombre, desc, n,
                      ref["mean"], ref["var"], ref["min"], ref["max"],
                      res["escalar"][0]["mean"], res["escalar"][0]["var"],
                      res["vectorial"][0]["mean"], res["vectorial"][0]["var"],
                      res["escalar"][1], res["escalar"][2],
                      res["vectorial"][1], res["vectorial"][2], e_ev,
                      "PASA" if ok_total else "FALLA"])
        print(f"{nombre:<8} n={n:<5} err_stats esc={res['escalar'][1]:.1e} "
              f"vec={res['vectorial'][1]:.1e}  err_norm esc={res['escalar'][2]:.1e} "
              f"vec={res['vectorial'][2]:.1e}  esc-vs-vec={e_ev:.1e}  "
              f"{'PASA' if ok_total else 'FALLA'}")

    cab = ["caso", "descripcion", "N", "ref_mean", "ref_var", "ref_min", "ref_max",
           "esc_mean", "esc_var", "vec_mean", "vec_var",
           "esc_err_stats", "esc_err_norm", "vec_err_stats", "vec_err_norm",
           "err_esc_vs_vec", "resultado"]
    with open(f"{CARPETA}/resultados.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cab)
        w.writerows(filas)
    with open(f"{CARPETA}/resultados.md", "w") as f:
        f.write("| Caso | Entrada | Media ref. | Var. ref. | Media esc. | Var. esc. | "
                "Media vec. | Var. vec. | Err. máx. esc. | Err. máx. vec. | Esc. vs vec. | Resultado |\n")
        f.write("|" + "---|" * 12 + "\n")
        for r in filas:
            f.write(f"| {r[0]} | {r[1]} | {r[3]:.6g} | {r[4]:.6g} | {r[7]:.6g} | {r[8]:.6g} | "
                    f"{r[9]:.6g} | {r[10]:.6g} | {max(r[11], r[12]):.1e} | "
                    f"{max(r[13], r[14]):.1e} | {r[15]:.1e} | {r[16]} |\n")
    print("\nRESULTADO GENERAL:", "PASA" if todo_ok else "FALLA")
    print(f"Tablas en {CARPETA}/resultados.csv y resultados.md")
    sys.exit(0 if todo_ok else 1)


if __name__ == "__main__":
    main()
