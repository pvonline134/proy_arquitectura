#!/usr/bin/env python3
"""
Genera archivos de entrada binarios para el proyecto de
normalizacion estadistica vectorizada.

Formato del archivo (little endian):
    int32   n
    float32 arr[n]

Uso:
    python3 gen_input.py <n> <salida.dat> [modo] [semilla]

    modo:
        random    (por defecto) valores aleatorios en [-100, 100]
        constant  todos los valores iguales a 5.0 (var = 0, caso borde)
        edge      mezcla de valores extremos, negativos y muy pequenos
"""
import struct
import random
import sys


def gen_random(n):
    return [random.uniform(-100.0, 100.0) for _ in range(n)]


def gen_constant(n):
    return [5.0 for _ in range(n)]


def gen_edge(n):
    base = [-1e6, 1e6, 0.0, -0.0001, 0.0001, -1.0, 1.0]
    return [base[i % len(base)] for i in range(n)]


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <n> <salida.dat> [random|constant|edge] [semilla]")
        sys.exit(1)

    n = int(sys.argv[1])
    out_path = sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else "random"
    if len(sys.argv) > 4:
        random.seed(int(sys.argv[4]))

    if mode == "random":
        values = gen_random(n)
    elif mode == "constant":
        values = gen_constant(n)
    elif mode == "edge":
        values = gen_edge(n)
    else:
        print(f"Modo desconocido: {mode}")
        sys.exit(1)

    with open(out_path, "wb") as f:
        f.write(struct.pack("<i", n))
        if n > 0:
            f.write(struct.pack(f"<{n}f", *values))

    print(f"Generado '{out_path}' con N={n}, modo={mode}")


if __name__ == "__main__":
    main()
