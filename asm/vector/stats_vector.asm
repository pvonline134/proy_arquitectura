; =============================================================================
; stats_vector.asm
; Version VECTORIZADA (AVX2) de los kernels de computo estadistico.
;
; Idea general: un registro YMM mide 256 bits = 8 floats de 32 bits. Cada
; instruccion empaquetada ("packed", sufijo ps) opera sobre los 8 carriles a
; la vez (modelo SIMD). Todos los recorridos siguen el mismo patron:
;
;   1) Bucle vectorial   : i = 0, 8, 16, ... mientras i < (n & ~7)
;   2) Reduccion         : 8 resultados parciales (un YMM) -> 1 escalar
;   3) Bucle de cierre   : los n % 8 elementos sobrantes, uno por uno
;
; Convencion de llamada: System V AMD64 ABI (igual que la version escalar)
;   enteros/punteros : rdi, rsi, rdx, rcx, r8, r9
;   flotantes        : xmm0, xmm1, ...          retorno float: xmm0
;   callee-saved     : rbx, rbp, r12-r15 (y rsp)
;   Todos los XMM/YMM son caller-saved: se pueden usar sin preservarlos.
;
; Codificacion VEX (prefijo "v"): forma de 3 operandos, destino no destructivo
;   vaddps ymm0, ymm1, ymm2   ->  ymm0 = ymm1 + ymm2
; Las instrucciones VEX de 128 bits (vaddss, vminps xmm...) ponen en cero los
; bits 255:128 del YMM destino, por eso no quedan "mitades altas sucias".
;
; Requisitos de memoria: el driver reserva los arreglos con
; aligned_alloc(32, ...). Como la base es multiplo de 32 y el indice avanza de
; 8 en 8 floats (32 bytes), cada acceso del bucle vectorial cae en una
; direccion multiplo de 32, lo que permite usar vmovaps (carga/guardado
; ALINEADO). Con un puntero no alineado, vmovaps genera #GP (segfault).
;
; Verificar soporte antes de ejecutar:  lscpu | grep -o avx2
; =============================================================================

    global sum_array
    global compute_stats
    global normalize_array

    section .text

; -----------------------------------------------------------------------------
; float sum_array(const float *arr, int n)          [codigo del profesor]
;   Entrada : rdi = arr, esi = n
;   Salida  : xmm0 = suma de los n elementos
;
; Registros: eax = i | ecx = n & ~7 | ymm0 = 8 sumas parciales | ymm1 = carga
; Nota: aqui se usa vmovups (no alineada); es valida con cualquier direccion
; y, con datos alineados, en CPUs modernas cuesta lo mismo que vmovaps.
; -----------------------------------------------------------------------------
sum_array:
    xor     eax, eax               ; eax = i = 0
    vxorps  ymm0, ymm0, ymm0       ; ymm0 = [0 x8] (acumulador, un parcial por carril)

    mov     ecx, esi
    and     ecx, ~7                ; ecx = n redondeado hacia abajo a multiplo de 8
    test    ecx, ecx               ; (~7 = ...11111000b borra los 3 bits bajos)
    jle     .sum_reduce            ; n < 8: no hay bloques completos

.sum_vec_loop:
    cmp     eax, ecx
    jge     .sum_reduce
    vmovups ymm1, [rdi + rax*4]    ; ymm1 = arr[i..i+7]  (direccion = arr + 4*i)
    vaddps  ymm0, ymm0, ymm1       ; carril k: ymm0[k] += arr[i+k]
    add     eax, 8                 ; avanza 8 floats = 32 bytes
    jmp     .sum_vec_loop

.sum_reduce:
    ; Reduccion horizontal 8 -> 1. Las operaciones "horizontales" combinan
    ; carriles del MISMO registro (las "verticales" combinan carriles iguales
    ; de registros distintos).
    vextractf128 xmm2, ymm0, 1     ; xmm2 = carriles 4-7 (mitad alta de 128 bits)
    vaddps  xmm0, xmm0, xmm2       ; xmm0 = {s0+s4, s1+s5, s2+s6, s3+s7}
    vhaddps xmm0, xmm0, xmm0       ; xmm0 = {a0+a1, a2+a3, a0+a1, a2+a3}
    vhaddps xmm0, xmm0, xmm0       ; xmm0[0] = suma total de los 8 carriles

.sum_scalar_tail:
    ; Remanente: los n % 8 elementos que no completan un YMM. Se procesan en
    ; el carril 0, que es justamente donde la reduccion dejo el resultado.
    cmp     eax, esi
    jge     .sum_done
    vmovss  xmm1, [rdi + rax*4]    ; xmm1[0] = arr[i]
    vaddss  xmm0, xmm0, xmm1       ; suma += arr[i]
    inc     eax
    jmp     .sum_scalar_tail

.sum_done:
    vzeroupper                     ; limpia bits 255:128 de todos los YMM para
    ret                            ; evitar penalizacion AVX->SSE en el llamador

; -----------------------------------------------------------------------------
; void compute_stats(const float *arr, int n,
;                    float *mean, float *var, float *min, float *max)
;   Entrada : rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
;   Salida  : *mean, *var (varianza POBLACIONAL = sum((x-mean)^2)/n), *min, *max
;   Caso borde: n <= 0 -> los cuatro resultados valen 0.0
;
; Algoritmo de DOS pasadas:
;   Pasada 1 (A): suma, minimo y maximo con una sola lectura del arreglo.
;   Pasada 2 (B): suma de (x - mean)^2. Se evita la formula de una pasada
;                 E[x^2] - mean^2 porque en float32 sufre cancelacion
;                 catastrofica cuando mean^2 >> var.
;
; Asignacion de registros:
;   eax  = i (indice)              r10d = n & ~7 (limite del bucle vectorial)
;   ymm0 = 8 sumas parciales       -> xmm0[0] = suma -> mean
;   ymm1 = 8 minimos parciales     -> xmm1[0] = min
;   ymm2 = 8 maximos parciales     -> xmm2[0] = max
;   ymm3 = datos cargados / temporal de las reducciones
;   xmm4 = (float) n
;   ymm5 = [mean x8]  ymm6 = 8 sumas parciales de (x-mean)^2  ymm7 = temporal
;
; Se usa r10d y NO ecx como limite porque rcx trae el puntero var*.
; No se llama a sum_array: evita una pasada extra sobre la memoria y evita
; tener que salvar rdi/rsi/rdx/rcx/r8/r9 (caller-saved) antes del call.
; Los push/pop de rbx, r12-r15 vienen del esqueleto; no son necesarios porque
; esta funcion no usa esos registros, pero son inofensivos.
; -----------------------------------------------------------------------------
compute_stats:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; --- A1) Caso borde: n <= 0 -> escribir 0.0 en todo (sin dividir por 0)
    test    esi, esi               ; ZF/SF segun n
    jle     .cs_empty

    ; --- A2) Preparacion de la pasada 1
    xor     eax, eax               ; i = 0
    mov     r10d, esi
    and     r10d, ~7               ; r10d = n & ~7
    vxorps  ymm0, ymm0, ymm0       ; ymm0 = [0 x8]
    vbroadcastss ymm1, [rdi]       ; ymm1 = [arr[0] x8]  (min inicial)
    vbroadcastss ymm2, [rdi]       ; ymm2 = [arr[0] x8]  (max inicial)
    ; Iniciar con arr[0] es seguro porque A1 garantiza n >= 1, y evita
    ; necesitar constantes +inf/-inf en memoria.

    ; --- A3) Bucle vectorial: suma, min y max con UNA sola carga
.cs_p1_loop:
    cmp     eax, r10d
    jge     .cs_p1_reduce
    vmovaps ymm3, [rdi + rax*4]    ; ymm3 = arr[i..i+7]  (carga ALINEADA a 32 B)
    vaddps  ymm0, ymm0, ymm3       ; 8 sumas parciales
    vminps  ymm1, ymm1, ymm3       ; 8 minimos parciales (uno por carril)
    vmaxps  ymm2, ymm2, ymm3       ; 8 maximos parciales
    add     eax, 8
    jmp     .cs_p1_loop

    ; --- A4) Reducciones horizontales 8 -> 1
.cs_p1_reduce:
    ; Suma: mismo esquema que sum_array
    vextractf128 xmm3, ymm0, 1
    vaddps  xmm0, xmm0, xmm3
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0       ; xmm0[0] = suma de los bloques completos

    ; Minimo: no existe un "vhminps", asi que se parte a la mitad: 8 -> 4 -> 2 -> 1
    vextractf128 xmm3, ymm1, 1     ; xmm3 = carriles 4-7
    vminps  xmm1, xmm1, xmm3       ; 4 candidatos
    vmovhlps xmm3, xmm3, xmm1      ; xmm3[0..1] = xmm1[2..3]
    vminps  xmm1, xmm1, xmm3       ; 2 candidatos (carriles 0 y 1)
    vshufps xmm3, xmm1, xmm1, 0x55 ; 0x55 = 01 01 01 01b -> todos = xmm1[1]
    vminss  xmm1, xmm1, xmm3       ; xmm1[0] = minimo

    ; Maximo: mismo esquema con vmaxps/vmaxss
    vextractf128 xmm3, ymm2, 1
    vmaxps  xmm2, xmm2, xmm3
    vmovhlps xmm3, xmm3, xmm2
    vmaxps  xmm2, xmm2, xmm3
    vshufps xmm3, xmm2, xmm2, 0x55
    vmaxss  xmm2, xmm2, xmm3       ; xmm2[0] = maximo

    ; --- A5) Remanente (n % 8): va DESPUES de la reduccion porque trabaja en
    ;         el carril 0, donde quedaron suma, min y max.
.cs_p1_tail:
    cmp     eax, esi
    jge     .cs_mean
    vmovss  xmm3, [rdi + rax*4]    ; xmm3[0] = arr[i]
    vaddss  xmm0, xmm0, xmm3
    vminss  xmm1, xmm1, xmm3       ; minss/maxss en vez de comiss + saltos:
    vmaxss  xmm2, xmm2, xmm3       ; sin ramas que el CPU tenga que predecir
    inc     eax
    jmp     .cs_p1_tail

    ; --- A6) Media y guardado de mean/min/max
.cs_mean:
    vcvtsi2ss xmm4, xmm4, esi      ; xmm4 = (float) n

    ; A6b) Arreglo constante: si min == max todos los valores son iguales y
    ; la respuesta exacta es mean = arr[0], var = 0. Sin esta prueba, el
    ; redondeo de la suma (p. ej. mil veces 0.1f) deja una varianza ~1e-13 en
    ; vez de 0, normalize_array no detecta sigma == 0 y la salida sale +-1.
    ; La comparacion min == max es EXACTA (no acumula redondeo).
    vucomiss xmm1, xmm2            ; compara min con max
    jp      .cs_general            ; PF = 1: algun NaN -> camino general
    je      .cs_const              ; ZF = 1 y ordenados: min == max

.cs_general:
    vdivss  xmm0, xmm0, xmm4       ; xmm0 = mean = suma / n
    vmovss  [rdx], xmm0            ; *mean
    vmovss  [r8], xmm1             ; *min
    vmovss  [r9], xmm2             ; *max

    ; --- B1) Preparacion de la pasada 2
    xor     eax, eax               ; i = 0 (r10d conserva n & ~7)
    vbroadcastss ymm5, xmm0        ; ymm5 = [mean x8] (forma registro: AVX2)
    vxorps  ymm6, ymm6, ymm6       ; ymm6 = [0 x8]

    ; --- B2) Bucle vectorial: acumular (x - mean)^2
.cs_p2_loop:
    cmp     eax, r10d
    jge     .cs_p2_reduce
    vmovaps ymm7, [rdi + rax*4]    ; ymm7 = arr[i..i+7]
    vsubps  ymm7, ymm7, ymm5       ; 8 restas:          x - mean
    vmulps  ymm7, ymm7, ymm7       ; 8 multiplicaciones: (x - mean)^2
    vaddps  ymm6, ymm6, ymm7       ; 8 acumuladores independientes
    add     eax, 8
    jmp     .cs_p2_loop
    ; (No se usa vfmadd231ps: FMA es una extension aparte, bandera "fma", y
    ;  cambiaria el redondeo respecto de la version escalar.)

    ; --- B3) Reduccion horizontal (igual que la suma)
.cs_p2_reduce:
    vextractf128 xmm7, ymm6, 1
    vaddps  xmm6, xmm6, xmm7
    vhaddps xmm6, xmm6, xmm6
    vhaddps xmm6, xmm6, xmm6       ; xmm6[0] = suma de cuadrados (bloques)

    ; --- B4) Remanente (n % 8)
.cs_p2_tail:
    cmp     eax, esi
    jge     .cs_var
    vmovss  xmm7, [rdi + rax*4]
    vsubss  xmm7, xmm7, xmm0       ; x - mean (mean sigue en xmm0[0])
    vmulss  xmm7, xmm7, xmm7       ; (x - mean)^2
    vaddss  xmm6, xmm6, xmm7
    inc     eax
    jmp     .cs_p2_tail

    ; --- B5) Varianza poblacional
.cs_var:
    vdivss  xmm6, xmm6, xmm4       ; var = suma / n
    vmovss  [rcx], xmm6            ; *var
    jmp     .cs_done

    ; --- A6b) Arreglo constante: resultados exactos, sin pasada 2
.cs_const:
    vmovss  [rdx], xmm1            ; *mean = arr[0]
    vmovss  [r8], xmm1             ; *min
    vmovss  [r9], xmm2             ; *max
    vxorps  xmm0, xmm0, xmm0
    vmovss  [rcx], xmm0            ; *var = 0.0
    jmp     .cs_done

    ; --- Caso n <= 0
.cs_empty:
    vxorps  xmm0, xmm0, xmm0       ; xmm0 = 0.0
    vmovss  [rdx], xmm0
    vmovss  [rcx], xmm0
    vmovss  [r8], xmm0
    vmovss  [r9], xmm0

.cs_done:
    pop     r15                    ; orden inverso a los push
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    vzeroupper
    ret

; -----------------------------------------------------------------------------
; void normalize_array(const float *in, float *out, int n,
;                      float mean, float stddev)
;   Entrada : rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
;   Salida  : out[i] = (in[i] - mean) / stddev  (z-score)
;   Caso borde: stddev == 0.0 -> out[i] = in[i] (se evita dividir por 0)
;
; Asignacion de registros:
;   eax = i | ecx = n & ~7 | ymm2 = [mean x8] | ymm3 = [stddev x8] | ymm4 = datos
;   xmm0/xmm1 NUNCA se sobrescriben: el remanente usa mean y stddev
;   directamente de ahi, sin guardarlos en la pila.
; -----------------------------------------------------------------------------
normalize_array:
    ; --- N1) Preparacion
    xor     eax, eax               ; i = 0
    mov     ecx, edx
    and     ecx, ~7                ; ecx = n & ~7

    ; --- N2) Caso borde stddev == 0
    vxorps  xmm2, xmm2, xmm2       ; xmm2 = 0.0
    vucomiss xmm1, xmm2            ; ZF = 1 si stddev == 0 (o si es NaN)
    je      .norm_copy_vec_loop

    ; --- N3) Broadcast de los parametros a los 8 carriles
    vbroadcastss ymm2, xmm0        ; ymm2 = [mean   x8]
    vbroadcastss ymm3, xmm1        ; ymm3 = [stddev x8]
    ; La forma "vbroadcastss ymm, xmm" (fuente registro) es de AVX2;
    ; en AVX1 la fuente solo podia ser memoria.

    ; --- N4) Bucle vectorial: 8 z-scores por iteracion
.norm_vec_loop:
    cmp     eax, ecx
    jge     .norm_scalar_tail
    vmovaps ymm4, [rdi + rax*4]    ; ymm4 = in[i..i+7]   (carga alineada)
    vsubps  ymm4, ymm4, ymm2       ; 8 restas
    vdivps  ymm4, ymm4, ymm3       ; 8 divisiones
    vmovaps [rsi + rax*4], ymm4    ; out[i..i+7] = ymm4  (guardado alineado)
    add     eax, 8
    jmp     .norm_vec_loop
    ; Se divide (vdivps) en lugar de multiplicar por 1/stddev: es mas lento,
    ; pero da el MISMO redondeo que divss en la version escalar.

    ; --- N5) Remanente (n % 8)
.norm_scalar_tail:
    cmp     eax, edx
    jge     .norm_done
    vmovss  xmm4, [rdi + rax*4]    ; xmm4 = in[i]
    vsubss  xmm4, xmm4, xmm0       ; in[i] - mean
    vdivss  xmm4, xmm4, xmm1       ; (in[i] - mean) / stddev
    vmovss  [rsi + rax*4], xmm4    ; out[i]
    inc     eax
    jmp     .norm_scalar_tail

    ; --- N6) Rama de copia (stddev == 0): mismo patron vector + remanente
.norm_copy_vec_loop:
    cmp     eax, ecx
    jge     .norm_copy_tail
    vmovaps ymm4, [rdi + rax*4]
    vmovaps [rsi + rax*4], ymm4    ; copia 8 floats
    add     eax, 8
    jmp     .norm_copy_vec_loop

.norm_copy_tail:
    cmp     eax, edx
    jge     .norm_done
    vmovss  xmm4, [rdi + rax*4]
    vmovss  [rsi + rax*4], xmm4    ; copia 1 float
    inc     eax
    jmp     .norm_copy_tail

.norm_done:
    vzeroupper
    ret

; Marca la pila como NO ejecutable (evita la advertencia del enlazador
; "missing .note.GNU-stack section implies executable stack").
    section .note.GNU-stack noalloc noexec nowrite progbits
