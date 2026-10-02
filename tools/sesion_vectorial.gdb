set debuginfod enabled off
set pagination off
set trace-commands on
set logging file evidencia/sesion_gdb_vectorial.txt
set logging overwrite on
set logging enabled on
break sum_array.sum_vec_loop
break compute_stats.cs_p1_reduce
break normalize_array.norm_done
run
info registers rdi rsi rax rcx
stepi 4
x/i $pc
p $ymm1.v8_float
p $ymm0.v8_float
continue
stepi 4
p $ymm0.v8_float
p $rax
delete 1
continue
p $ymm0.v8_float
p $ymm1.v8_float
p $ymm2.v8_float
stepi 4
p $xmm0.v4_float
stepi 6
p $xmm1.v4_float
stepi 6
p $xmm2.v4_float
continue
p $xmm0.v4_float[0]
p $xmm1.v4_float[0]
p/x $rsi
x/8fw $rsi
x/16fw $rsi
continue
set logging enabled off
