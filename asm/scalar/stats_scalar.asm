; =============================================================================
; stats_scalar.asm
; Version ESCALAR (referencia) de los kernels de computo estadistico.
;
; Modelo SISD: cada instruccion procesa UN float. Se usan solo instrucciones
; escalares de SSE/SSE2 (sufijo "ss" = scalar single): movss, addss, subss,
; mulss, divss, minss, maxss, comiss, ucomiss, cvtsi2ss. Operan sobre el
; carril 0 (bits 31:0) de un registro XMM; los carriles 1-3 no se usan.
; La unica instruccion "empaquetada" es xorps reg, reg, que se usa solo como
; modismo para poner un registro en 0.0.
;
; Formato SSE clasico de DOS operandos (destino destructivo):
;   subss xmm3, xmm0   ->  xmm3 = xmm3 - xmm0   (se pierde el valor previo)
;
; Convencion de llamada: System V AMD64 ABI
;   enteros/punteros : rdi, rsi, rdx, rcx, r8, r9
;   flotantes        : xmm0, xmm1, ...          retorno float: xmm0
;   callee-saved     : rbx, rbp, r12-r15 (si se usan, hay que preservarlos)
;
; Recorrido: el indice i avanza de 1 en 1; la direccion [rdi + rax*4] avanza
; 4 bytes (un float) por iteracion. No hay bucle de remanente ni reduccion
; horizontal: el mismo bucle procesa todos los elementos.
; =============================================================================

    global sum_array
    global compute_stats
    global normalize_array

    section .text

; -----------------------------------------------------------------------------
; float sum_array(const float *arr, int n)          [codigo del profesor]
;   Entrada : rdi = arr, esi = n
;   Salida  : xmm0 = suma
; -----------------------------------------------------------------------------
sum_array:
    xor     eax, eax           ; eax = i = 0 (escribir eax limpia tambien rax 63:32)
    xorps   xmm0, xmm0         ; xmm0 = acumulador = 0.0

.sum_loop:
    cmp     eax, esi           ; i < n ?  (comparacion con signo -> jge)
    jge     .sum_done
    movss   xmm1, [rdi + rax*4] ; xmm1 = arr[i]
    addss   xmm0, xmm1         ; suma += arr[i]
    inc     eax                ; i++
    jmp     .sum_loop

.sum_done:
    ret                        ; resultado ya esta en xmm0

; -----------------------------------------------------------------------------
; void compute_stats(const float *arr, int n,
;                    float *mean, float *var, float *min, float *max)
;   Entrada : rdi = arr, esi = n, rdx = mean*, rcx = var*, r8 = min*, r9 = max*
;   Salida  : *mean, *var (POBLACIONAL: sum((x-mean)^2)/n), *min, *max
;   Caso borde: n <= 0 -> los cuatro resultados valen 0.0
;
; Mismo algoritmo de dos pasadas que la version vectorial, para que el
; speedup mida SOLO el efecto de SIMD:
;   Pasada 1 (C3): suma, minimo y maximo leyendo cada elemento una vez.
;   Pasada 2 (C5): suma de (x - mean)^2 (evita E[x^2]-mean^2, inestable).
;
; Asignacion de registros:
;   eax  = i          xmm0 = suma -> mean     xmm1 = min      xmm2 = max
;   xmm3 = arr[i] / temporal                  xmm4 = (float) n
;   xmm5 = suma de (x - mean)^2 -> var
; No se llama a sum_array (una pasada menos y no hay que salvar argumentos).
; Los push/pop de rbx, r12-r15 vienen del esqueleto; no son necesarios.
; -----------------------------------------------------------------------------
compute_stats:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; --- C1) Caso borde: n <= 0
    test    esi, esi
    jle     .cs_empty

    ; --- C2) Preparacion de la pasada 1
    xor     eax, eax               ; i = 0
    xorps   xmm0, xmm0             ; suma = 0.0
    movss   xmm1, [rdi]            ; min = arr[0]  (n >= 1 garantizado por C1)
    movss   xmm2, [rdi]            ; max = arr[0]

    ; --- C3) Pasada 1: un elemento por iteracion
.cs_p1_loop:
    cmp     eax, esi
    jge     .cs_mean
    movss   xmm3, [rdi + rax*4]    ; xmm3 = arr[i]
    addss   xmm0, xmm3             ; suma += arr[i]
    minss   xmm1, xmm3             ; min = min(min, arr[i])  (sin saltos)
    maxss   xmm2, xmm3             ; max = max(max, arr[i])
    inc     eax
    jmp     .cs_p1_loop

    ; --- C4) Media y guardado de mean/min/max
.cs_mean:
    cvtsi2ss xmm4, esi             ; xmm4 = (float) n  (entero -> float)

    ; C4b) Arreglo constante: si min == max, mean = arr[0] y var = 0 exactos.
    ; Evita que el redondeo de la suma deje una varianza ~1e-13 que impida
    ; detectar stddev == 0 en normalize_array.
    ucomiss xmm1, xmm2             ; compara min con max
    jp      .cs_general            ; algun NaN -> camino general
    je      .cs_const              ; min == max

.cs_general:
    divss   xmm0, xmm4             ; xmm0 = mean = suma / n
    movss   [rdx], xmm0            ; *mean
    movss   [r8], xmm1             ; *min
    movss   [r9], xmm2             ; *max

    ; --- C5) Pasada 2: acumular (x - mean)^2
    xor     eax, eax               ; i = 0
    xorps   xmm5, xmm5             ; acumulador = 0.0
.cs_p2_loop:
    cmp     eax, esi
    jge     .cs_var
    movss   xmm3, [rdi + rax*4]    ; xmm3 = arr[i]
    subss   xmm3, xmm0             ; xmm3 = arr[i] - mean  (xmm0 no se toca)
    mulss   xmm3, xmm3             ; xmm3 = (arr[i] - mean)^2
    addss   xmm5, xmm3             ; acumula
    inc     eax
    jmp     .cs_p2_loop

    ; --- C6) Varianza poblacional
.cs_var:
    divss   xmm5, xmm4             ; var = suma / n
    movss   [rcx], xmm5            ; *var
    jmp     .cs_done

    ; --- C4b) Arreglo constante
.cs_const:
    movss   [rdx], xmm1            ; *mean = arr[0]
    movss   [r8], xmm1             ; *min
    movss   [r9], xmm2             ; *max
    xorps   xmm0, xmm0
    movss   [rcx], xmm0            ; *var = 0.0
    jmp     .cs_done

    ; --- C7) Caso n <= 0
.cs_empty:
    xorps   xmm0, xmm0
    movss   [rdx], xmm0
    movss   [rcx], xmm0
    movss   [r8], xmm0
    movss   [r9], xmm0

.cs_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret                            ; sin vzeroupper: no se usaron registros YMM

; -----------------------------------------------------------------------------
; void normalize_array(const float *in, float *out, int n,
;                      float mean, float stddev)
;   Entrada : rdi = in, rsi = out, edx = n, xmm0 = mean, xmm1 = stddev
;   Salida  : out[i] = (in[i] - mean) / stddev
;   Caso borde: stddev == 0.0 -> out[i] = in[i]
;
; Registros: eax = i | xmm2 = temporal. mean y stddev se quedan en xmm0/xmm1
; todo el tiempo (nunca son destino), asi que no hace falta copiarlos.
; -----------------------------------------------------------------------------
normalize_array:
    ; --- N1) Preparacion y caso borde stddev == 0
    xor     eax, eax               ; i = 0
    xorps   xmm2, xmm2             ; xmm2 = 0.0
    comiss  xmm1, xmm2             ; ZF = 1 si stddev == 0 (o NaN)
    je      .norm_copy_loop

    ; --- N2) Bucle principal: un z-score por iteracion
.norm_loop:
    cmp     eax, edx               ; i < n ?
    jge     .norm_done
    movss   xmm2, [rdi + rax*4]    ; xmm2 = in[i]
    subss   xmm2, xmm0             ; xmm2 = in[i] - mean
    divss   xmm2, xmm1             ; xmm2 = (in[i] - mean) / stddev
    movss   [rsi + rax*4], xmm2    ; out[i] = xmm2
    inc     eax
    jmp     .norm_loop

    ; --- N3) Rama de copia (stddev == 0)
.norm_copy_loop:
    cmp     eax, edx
    jge     .norm_done
    movss   xmm2, [rdi + rax*4]    ; xmm2 = in[i]
    movss   [rsi + rax*4], xmm2    ; out[i] = in[i]
    inc     eax
    jmp     .norm_copy_loop

.norm_done:
    ret

; Pila no ejecutable (evita la advertencia del enlazador).
    section .note.GNU-stack noalloc noexec nowrite progbits
