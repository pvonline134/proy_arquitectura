set debuginfod enabled off
set pagination off
break sum_array.sum_vec_loop
commands
silent
continue
end
break sum_array.sum_scalar_tail
commands
silent
continue
end
break compute_stats.cs_p1_loop
commands
silent
continue
end
break compute_stats.cs_p1_tail
commands
silent
continue
end
break compute_stats.cs_p2_loop
commands
silent
continue
end
break compute_stats.cs_p2_tail
commands
silent
continue
end
break normalize_array.norm_vec_loop
commands
silent
continue
end
break normalize_array.norm_scalar_tail
commands
silent
continue
end
run
info breakpoints
