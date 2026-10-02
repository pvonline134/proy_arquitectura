# Normalizador estadístico vectorizado (NASM + C)

Proyecto del curso: **Programación vectorial en ensamblador x86-64 (NASM/Linux)**.
Comparación de rendimiento entre una versión escalar (SSE escalar) y una versión
vectorizada (AVX2) de un mismo kernel de cómputo.

**Autores:** _[Yohel Alas Gómez]_ y _[Brayan Pan Valenciano]_

Dado un arreglo de N números `float32`, el programa calcula suma, media,
varianza (poblacional), desviación estándar, mínimo y máximo, y produce el
arreglo normalizado.

---

## Resultados en breve

Medido en un Intel Core i5-1135G7 (Tiger Lake), 30 repeticiones por celda:

| N | Escalar (ms) | Vectorial AVX2 (ms) | Speedup |
|---|---|---|---|
| 10³ | 0.003775 ± 0.000031 | 0.000588 ± 0.000018 | 6.42× |
| 10⁵ | 0.3996 ± 0.0049 | 0.0565 ± 0.0013 | **7.08×** |
| 10⁶ | 3.735 ± 0.183 | 0.673 ± 0.100 | 5.55× |
| 5×10⁷ | 184.66 ± 2.25 | 59.27 ± 1.22 | 3.12× |

- La versión AVX2 ejecuta **7.74× menos instrucciones** (medido con `perf`).
- Con datos en caché (N = 10⁵) el speedup llega a 7.08×; con datos en RAM
  (N = 5×10⁷) baja a 3.12× porque la versión vectorial queda limitada por el
  ancho de banda de memoria (IPC 1.75 → 0.81).

El análisis completo está en el informe (`informe/`) y los diagramas en `diagramas/`.

---

## Requisitos

- Linux x86-64 con CPU compatible con **AVX2**. Para verificarlo:
  ```bash
  grep -o -w -m1 avx2 /proc/cpuinfo
  ```
- `nasm` ≥ 2.15, `gcc`, `make`, `python3`
- `gdb` ≥ 10 (sesiones de depuración)
- Opcionales: `perf` (paquete `linux-tools`) para contadores de hardware,
  `python3-matplotlib` para el gráfico de speedup, `graphviz` para regenerar los diagramas

En Ubuntu:

```bash
sudo apt install nasm gcc make python3 gdb python3-matplotlib graphviz
sudo apt install linux-tools-common linux-tools-$(uname -r)
```

---

## Compilar

```bash
make
```

Genera dos ejecutables que comparten el mismo driver en C y enlazan con kernels distintos:

| Ejecutable | Kernel |
|---|---|
| `bin/norm_scalar` | `asm/scalar/stats_scalar.asm` (instrucciones escalares SSE) |
| `bin/norm_vector` | `asm/vector/stats_vector.asm` (AVX2, 8 floats por instrucción) |

Los kernels se ensamblan con símbolos de depuración (`nasm -f elf64 -g -F dwarf`).
La optimización `-O2` solo afecta al driver en C; no se usan intrínsecos ni
auto-vectorización en los kernels.

---

## Ejecutar

```bash
python3 tools/gen_input.py 1000000 data/input.dat random
./bin/norm_scalar data/input.dat data/output_scalar.dat 30
./bin/norm_vector data/input.dat data/output_vector.dat 30
```

Argumentos: `<entrada.dat> <salida.dat> [repeticiones]`. El kernel se repite
`repeticiones` veces (por defecto 1) para medir su tiempo.

**Formato de los archivos `.dat`** (little endian): `int32 N` seguido de `N` valores `float32`.

Cada ejecución produce:

| Archivo | Contenido |
|---|---|
| `salida.dat` | arreglo normalizado (mismo formato binario) |
| `salida.dat.stats.txt` | estadísticos en texto plano (lo lee `verify_reference.py`) |
| `salida.dat.timing.txt` | tiempo promedio ± desviación estándar (ms) y ciclos TSC |

Por consola se imprimen N, suma, media, varianza, desviación, mínimo, máximo,
el tiempo promedio del kernel, su desviación estándar y los ciclos TSC.
Con N = 0 se imprime un aviso por `stderr` y los estadísticos se reportan como 0.

---

## Verificar la correctud

**Contra la referencia del profesor** (estadísticos, tolerancia relativa 10⁻⁴):

```bash
python3 tools/verify_reference.py data/input.dat data/output_vector.dat.stats.txt
```

**Batería completa y reproducible** (12 casos con semilla fija; compara estadísticos
y arreglo normalizado contra la referencia, y escalar contra vectorial):

```bash
python3 tools/correctud.py
```

Genera `data/correctud/resultados.md` y `resultados.csv`.

**Pruebas en C** enlazadas directamente con cada kernel:

```bash
# Cambiar stats_vector.o por stats_scalar.o para probar la version escalar
gcc -g -Iinclude tests/test_stats.c obj/stats_vector.o -lm -o /tmp/test_stats && /tmp/test_stats
gcc -g -Iinclude tests/test_norm.c  obj/stats_vector.o -lm -o /tmp/test_norm  && /tmp/test_norm
gcc -O2 -Iinclude tests/fuzz.c      obj/stats_vector.o -lm -o /tmp/fuzz       && /tmp/fuzz
```

`fuzz.c` prueba 1 505 casos (N = 0 a 300 con 5 tipos de datos) y verifica que no
se escriba fuera de `out[0..n-1]`.

**Casos borde cubiertos:** N = 0, N = 1, N no múltiplo de 8 (7, 15, 21, 1001),
arreglos constantes (σ = 0, incluido 0.1 repetido, que no es exacto en binario),
valores negativos y valores extremos.

---

## Medir el rendimiento

```bash
python3 tools/bench.py
```

Ejecuta ambas versiones con N = 10³, 10⁵, 10⁶ y 5×10⁷ (30 repeticiones cada una)
y genera `data/bench/resultados.csv` y `data/bench/speedup.png`. Tarda varios
minutos y necesita ~600 MB libres en disco.

**Contadores de hardware** (IPC y fallos de caché):

```bash
sudo sysctl kernel.perf_event_paranoid=1
perf stat -e cycles,instructions,cache-misses ./bin/norm_vector data/bench/in_100000.dat /tmp/o.dat 3000
```

Se usan muchas repeticiones porque `perf` mide el programa completo, incluida la
lectura del archivo.

---

## Depuración con GDB

Sesiones documentadas con N = 16 (entrada 1, 2, …, 16):

```bash
python3 -c "import struct; v=[float(i+1) for i in range(16)]; open('data/in_gdb16.dat','wb').write(struct.pack('<i',16)+struct.pack('<16f',*v))"

# Registro YMM tras vaddps, reduccion horizontal y memoria de salida
gdb -q -batch -x tools/sesion_vectorial.gdb --args ./bin/norm_vector data/in_gdb16.dat data/out_gdb16_vec.dat 1
# Sesion equivalente con la version escalar
gdb -q -batch -x tools/sesion_escalar.gdb   --args ./bin/norm_scalar data/in_gdb16.dat data/out_gdb16_esc.dat 1
# Conteo de vueltas de cada bucle (repetir con N = 21 para ver el remanente)
gdb -q -batch -x tools/conteo_vectorial.gdb --args ./bin/norm_vector data/in_gdb16.dat /tmp/o.dat 1
```

Las transcripciones quedan en `evidencia/`. Para una sesión interactiva:

```bash
gdb --args ./bin/norm_vector data/in_gdb16.dat data/out.dat 1
(gdb) break sum_array.sum_vec_loop
(gdb) run
(gdb) stepi 4
(gdb) p $ymm0.v8_float
```

Las etiquetas locales de NASM se nombran `funcion.etiqueta` en GDB.

---

## Regenerar toda la evidencia

```bash
bash tools/regenerar_evidencia.sh
```

Compila desde cero y ejecuta todas las pruebas, la verificación, las sesiones de
GDB, el benchmark y `perf`, dejando los resultados en `evidencia/` (si ya existía,
la renombra a `evidencia_anterior_<fecha>/`). Con `SIN_BENCH=1` omite las
mediciones de rendimiento.

---

## Estructura del repositorio

```
.
├── Makefile
├── README.md
├── include/
│   └── stats.h                  # firmas de los kernels (contrato para ambas versiones)
├── src/
│   └── driver.c                 # E/S, reserva alineada a 32 bytes, medición de tiempo
├── asm/
│   ├── scalar/stats_scalar.asm  # versión escalar
│   └── vector/stats_vector.asm  # versión AVX2
├── tools/
│   ├── gen_input.py             # genera archivos de entrada
│   ├── verify_reference.py      # verificación contra referencia en Python
│   ├── correctud.py             # batería de correctud reproducible
│   ├── bench.py                 # mediciones de rendimiento y gráfico de speedup
│   └── regenerar_evidencia.sh   # regenera toda la evidencia
│ 
├── tests/
│   ├── test_stats.c             # pruebas de compute_stats
│   ├── test_norm.c              # pruebas de normalize_array y sum_array
│   └── fuzz.c                   # 1 505 casos aleatorios
|
├── evidencia/                   # salidas de pruebas, GDB, perf y benchmark
├── informe/                     # informe 
└── data/                        # entradas y salidas generadas
```

---

## Diseño en breve

- **Convención de llamada:** System V AMD64 ABI. Argumentos enteros y punteros en
  `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`; floats en `xmm0`, `xmm1`; retorno float en `xmm0`.
- **Dos pasadas en `compute_stats`:** la primera calcula suma, mínimo y máximo con
  una sola lectura de cada elemento; la segunda acumula (x − media)². Se evita la
  fórmula de una pasada E[x²] − media², que en `float32` sufre cancelación catastrófica.
- **Versión vectorial:** bucle principal de 8 en 8 con `vmovaps` (memoria alineada a
  32 bytes por el driver), reducción horizontal (`vextractf128`, `vhaddps`, shuffles)
  y bucle escalar de cierre para los `n % 8` elementos restantes. `vzeroupper` antes
  de cada `ret`.
- Ambas versiones usan el mismo algoritmo, para que el speedup mida solo el efecto de SIMD.

**Limitaciones conocidas** (detalladas en el informe): pérdida de precisión de
`float32` al sumar decenas de millones de valores (menor en la versión vectorial),
y desbordamiento de la varianza cuando N · σ² supera ~3.4×10³⁸.

