#!/usr/bin/env bash
# =============================================================================
# regenerar_evidencia.sh - Regenera TODA la evidencia del informe con el
# codigo final. Ejecutar desde la raiz del proyecto (donde esta el Makefile):
#
#     bash tools/regenerar_evidencia.sh
#
# Opcional:  SIN_BENCH=1 bash tools/regenerar_evidencia.sh
#            (omite bench.py y los casos de N = 5e7, que tardan varios minutos)
#
# Resultado: carpeta evidencia/ con un archivo por cada prueba. Si ya existia
# una carpeta evidencia/, se renombra a evidencia_anterior_<fecha>/.
# =============================================================================

if [ ! -f Makefile ]; then
    echo "Error: ejecute este script desde la raiz del proyecto (donde esta el Makefile)."
    exit 1
fi

E=evidencia
paso() { echo; echo "==> $*"; }

# Busca un archivo en la raiz, tests/ o tools/ y devuelve su ruta.
buscar() {
    for d in . tests tools; do
        if [ -f "$d/$1" ]; then echo "$d/$1"; return 0; fi
    done
    return 1
}

# Genera un .dat (int32 N + N float32) con Python, solo si no existe.
gen_py() {   # gen_py <archivo> <expresion python que produce la lista v>
    [ -f "$1" ] && return
    python3 -c "import struct,random; random.seed(1); $2; open('$1','wb').write(struct.pack('<i',len(v))+struct.pack('<%df'%len(v),*v))"
}

# ---------------------------------------------------------------------------
paso "0. Preparando carpeta $E/"
if [ -d "$E" ]; then
    viejo="${E}_anterior_$(date +%Y%m%d_%H%M%S)"
    mv "$E" "$viejo"
    echo "   La evidencia anterior quedo en $viejo/"
fi
mkdir -p "$E" data

# ---------------------------------------------------------------------------
paso "1. Compilando desde cero (salida en $E/compilacion.txt)"
make clean > /dev/null 2>&1 || rm -rf obj bin
make > "$E/compilacion.txt" 2>&1
if [ ! -x bin/norm_scalar ] || [ ! -x bin/norm_vector ]; then
    echo "   Error: la compilacion fallo. Revise $E/compilacion.txt"
    exit 1
fi
if grep -qi "warning" "$E/compilacion.txt"; then
    echo "   Aviso: hay warnings en la compilacion (ver $E/compilacion.txt)"
else
    echo "   OK, sin warnings"
fi

# ---------------------------------------------------------------------------
paso "2. Pruebas unitarias (test_stats.c, test_norm.c)"
for t in test_stats test_norm; do
    src=$(buscar "$t.c") || { echo "   (no se encontro $t.c, se omite)"; continue; }
    for v in scalar vector; do
        gcc -g -Iinclude "$src" "obj/stats_$v.o" -lm -o "/tmp/${t}_$v" 2>> "$E/compilacion_tests.txt" \
            && "/tmp/${t}_$v" > "$E/${t}_$v.txt" 2>&1
        echo "   $t ($v): $(tail -1 "$E/${t}_$v.txt")"
    done
done

# ---------------------------------------------------------------------------
paso "3. fuzz.c (1505 casos por version)"
if src=$(buscar fuzz.c); then
    for v in scalar vector; do
        gcc -O2 -Iinclude "$src" "obj/stats_$v.o" -lm -o "/tmp/fuzz_$v" 2>> "$E/compilacion_tests.txt" \
            && "/tmp/fuzz_$v" > "$E/fuzz_$v.txt" 2>&1
        echo "   fuzz ($v): $(tail -1 "$E/fuzz_$v.txt")"
    done
else
    echo "   (no se encontro fuzz.c, se omite)"
fi

# ---------------------------------------------------------------------------
paso "4. correctud.py (12 casos, estadisticos + arreglo normalizado)"
if [ -f tools/correctud.py ]; then
    python3 tools/correctud.py > "$E/correctud.txt" 2>&1
    cp data/correctud/resultados.md  "$E/correctud_tabla.md"  2>/dev/null
    cp data/correctud/resultados.csv "$E/correctud_tabla.csv" 2>/dev/null
    echo "   $(grep 'RESULTADO GENERAL' "$E/correctud.txt")"
else
    echo "   (no se encontro tools/correctud.py, se omite)"
fi

# ---------------------------------------------------------------------------
paso "5. verify_reference.py sobre los casos borde (ambas versiones)"
for n in 0 1 7 8 15 16 1000; do
    [ -f "data/in_$n.dat" ] || python3 tools/gen_input.py "$n" "data/in_$n.dat" random > /dev/null
done
[ -f data/in_const.dat ] || python3 tools/gen_input.py 1000 data/in_const.dat constant > /dev/null
gen_py data/in_const01.dat "v=[0.1]*1001"
gen_py data/in_neg.dat     "v=[-random.uniform(1,1000) for _ in range(1001)]"
gen_py data/in_ext.dat     "v=[random.choice([-1,1])*random.uniform(1e15,1e16) for _ in range(1001)]"
gen_py data/in_ext18.dat   "v=[random.choice([-1,1])*random.uniform(1e17,1e18) for _ in range(1001)]"
gen_py data/in_gdb16.dat   "v=[float(i+1) for i in range(16)]"

CASOS="0 1 7 8 15 16 1000 const const01 neg ext"
for v in scalar vector; do
    for f in $CASOS; do
        echo "===== $v | caso $f ====="
        "./bin/norm_$v" "data/in_$f.dat" "data/out_${v}_$f.dat" 1
        python3 tools/verify_reference.py "data/in_$f.dat" "data/out_${v}_$f.dat.stats.txt"
    done
done > "$E/verify.txt" 2>&1
echo "   PASA: $(grep -c 'RESULTADO GENERAL: PASA' "$E/verify.txt") de $(grep -c 'RESULTADO GENERAL' "$E/verify.txt")"

# ---------------------------------------------------------------------------
paso "6. Arreglo normalizado: escalar contra vectorial"
for f in 1 7 8 15 16 1000 const const01 neg ext; do
    python3 -c "
import struct
def lee(p):
    d=open(p,'rb').read(); n=struct.unpack('<i',d[:4])[0]
    return struct.unpack('<%df'%n,d[4:4+4*n])
a=lee('data/out_scalar_$f.dat'); b=lee('data/out_vector_$f.dat')
err=max([abs(x-y)/max(1,abs(y)) for x,y in zip(a,b)] or [0])
print('caso $f: error max escalar vs vectorial = %.2e  %s' % (err,'PASA' if err<1e-4 else 'FALLA'))
"
done > "$E/comparacion_escalar_vectorial.txt"
echo "   PASA: $(grep -c PASA "$E/comparacion_escalar_vectorial.txt") de $(wc -l < "$E/comparacion_escalar_vectorial.txt")"

# ---------------------------------------------------------------------------
paso "7. Limitacion: overflow con valores ~1e18"
for v in scalar vector; do
    echo "===== $v | extremos 1e18 ====="
    "./bin/norm_$v" data/in_ext18.dat "data/out_${v}_ext18.dat" 1
    python3 tools/verify_reference.py data/in_ext18.dat "data/out_${v}_ext18.dat.stats.txt"
done > "$E/overflow_1e18.txt" 2>&1
echo "   listo (se espera FALLA en var y stddev: limite de float32)"

# ---------------------------------------------------------------------------
paso "8. Sesion de GDB (vectorial, N = 16)"
if g=$(buscar sesion_vectorial.gdb); then
    gdb -q -batch -x "$g" --args ./bin/norm_vector data/in_gdb16.dat data/out_gdb16_vec.dat 1 > /dev/null 2>&1
    if [ -f "$E/sesion_gdb_vectorial.txt" ]; then
        echo "   listo: $E/sesion_gdb_vectorial.txt"
    else
        echo "   Aviso: GDB no genero el archivo (revise que el .gdb escriba en evidencia/)"
    fi
else
    echo "   (no se encontro sesion_vectorial.gdb, se omite)"
fi

# ---------------------------------------------------------------------------
if [ "${SIN_BENCH:-0}" = "1" ]; then
    paso "9-10. Rendimiento y precision con N = 5e7: OMITIDOS (SIN_BENCH=1)"
else
    paso "9. Rendimiento: bench.py (tarda varios minutos, no use la computadora)"
    python3 tools/bench.py > "$E/bench.txt" 2>&1
    cp data/bench/resultados.csv "$E/" 2>/dev/null
    cp data/bench/speedup.png    "$E/" 2>/dev/null
    cat "$E/bench.txt" | grep "^N="

    paso "10. Limitacion: precision con N = 5e7"
    for v in scalar vector; do
        echo "===== $v | N = 5e7 ====="
        "./bin/norm_$v" data/bench/in_50000000.dat "/tmp/o_$v.dat" 1
        python3 tools/verify_reference.py data/bench/in_50000000.dat "/tmp/o_$v.dat.stats.txt"
    done > "$E/precision_5e7.txt" 2>&1
    echo "   listo (se espera FALLA en var: limite de float32, peor en la escalar)"
fi

# ---------------------------------------------------------------------------
paso "11. perf stat (IPC y fallos de cache)"
if ! command -v perf > /dev/null; then
    echo "   (perf no esta instalado, se omite)"
elif [ ! -f data/bench/in_100000.dat ] || [ ! -f data/bench/in_50000000.dat ]; then
    echo "   (faltan las entradas de data/bench/: corra primero sin SIN_BENCH=1)"
else
    if [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 1 ]; then
        echo "   Se necesita permiso para leer contadores (pedira su contrasena):"
        sudo sysctl kernel.perf_event_paranoid=1
    fi
    for v in scalar vector; do
        perf stat -e cycles,instructions,cache-misses "./bin/norm_$v" data/bench/in_100000.dat /tmp/o.dat 3000 \
            > /dev/null 2> "$E/perf_${v}_1e5.txt"
        perf stat -e cycles,instructions,cache-misses "./bin/norm_$v" data/bench/in_50000000.dat /tmp/o.dat 30 \
            > /dev/null 2> "$E/perf_${v}_5e7.txt"
    done
    python3 - "$E" <<'PYEOF'
import re, sys
E = sys.argv[1]
def num(txt, ev):
    m = re.search(r"([\d.,\s]+?)\s+" + ev, txt)
    return float(re.sub(r"[^\d]", "", m.group(1))) if m else None
for v in ("scalar", "vector"):
    for n in ("1e5", "5e7"):
        t = open(f"{E}/perf_{v}_{n}.txt").read()
        c, i, m = num(t, "cycles"), num(t, "instructions"), num(t, "cache-misses")
        if c and i:
            print(f"   {v:7s} N={n}: IPC = {i/c:.2f}   cache-misses = {m:,.0f}")
        else:
            print(f"   {v:7s} N={n}: no se pudieron leer los contadores (ver {E}/perf_{v}_{n}.txt)")
PYEOF
fi

# ---------------------------------------------------------------------------
paso "12. Entorno"
LANG=C lscpu > "$E/lscpu.txt"
{ nasm -v; gcc --version | head -1; gdb --version | head -1;
  command -v perf > /dev/null && perf --version; echo "kernel $(uname -r)"; } > "$E/versiones.txt" 2>&1
echo "   listo"

paso "Terminado. Archivos en $E/:"
ls -1 "$E"
