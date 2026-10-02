set debuginfod enabled off
set pagination off
set trace-commands on
set logging file evidencia/sesion_gdb_escalar.txt
set logging overwrite on
set logging enabled on
break sum_array.sum_loop
break compute_stats.cs_mean
break normalize_array.norm_done
run
info registers rdi rsi rax
stepi 4
x/i $pc
p $xmm1.v4_float
p $xmm0.v4_float
continue
stepi 4
p $xmm0.v4_float
p $rax
delete 1
continue
p $rax
p $xmm0.v4_float
p $xmm1.v4_float
p $xmm2.v4_float
continue
p $xmm0.v4_float[0]
p $xmm1.v4_float[0]
p/x $rsi
x/8fw $rsi
x/16fw $rsi
continue
set logging enabled off
