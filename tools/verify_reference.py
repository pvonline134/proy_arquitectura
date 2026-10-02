#!/usr/bin/env python3
"""
Calcula estadisticos de referencia (en Python puro, sin SIMD) para un
archivo input.dat y los compara contra el resumen que el driver en C
escribe en '<output>.stats.txt'.

Uso:
    python3 verify_reference.py <input.dat> <output.stats.txt> [tolerancia]
"""
import struct
import sys
import math


def read_input(path):
    with open(path, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        values = list(struct.unpack(f"<{n}f", f.read(4 * n))) if n > 0 else []
    return n, values


def read_summary(path):
    result = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, val = line.split("=", 1)
            result[key] = float(val)
    return result


def reference_stats(values):
    n = len(values)
    if n == 0:
        return 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    total = sum(values)
    mean = total / n
    var = sum((x - mean) ** 2 for x in values) / n
    stddev = math.sqrt(var)
    return total, mean, var, stddev, min(values), max(values)


def rel_error(a, b):
    if abs(b) < 1e-12:
        return abs(a - b)
    return abs(a - b) / abs(b)


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <input.dat> <output.stats.txt> [tolerancia]")
        sys.exit(1)

    input_path = sys.argv[1]
    summary_path = sys.argv[2]
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 1e-4

    n, values = read_input(input_path)
    ref_sum, ref_mean, ref_var, ref_std, ref_min, ref_max = reference_stats(values)
    got = read_summary(summary_path)

    checks = [
        ("n", float(n), got.get("n", float("nan"))),
        ("sum", ref_sum, got.get("sum", float("nan"))),
        ("mean", ref_mean, got.get("mean", float("nan"))),
        ("var", ref_var, got.get("var", float("nan"))),
        ("stddev", ref_std, got.get("stddev", float("nan"))),
        ("min", ref_min, got.get("min", float("nan"))),
        ("max", ref_max, got.get("max", float("nan"))),
    ]

    all_ok = True
    print(f"{'campo':<10}{'referencia':>15}{'obtenido':>15}{'error rel.':>15}  resultado")
    for name, ref, val in checks:
        err = abs(val - ref) if name == "n" else rel_error(val, ref)
        ok = (err == 0) if name == "n" else (err <= tol)
        all_ok = all_ok and ok
        status = "OK" if ok else "FALLA"
        print(f"{name:<10}{ref:>15.6f}{val:>15.6f}{err:>15.6g}  {status}")

    print()
    print("RESULTADO GENERAL:", "PASA" if all_ok else "FALLA")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
