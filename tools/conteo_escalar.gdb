set debuginfod enabled off
set pagination off
break sum_array.sum_loop
commands
silent
continue
end
break compute_stats.cs_p1_loop
commands
silent
continue
end
break compute_stats.cs_p2_loop
commands
silent
continue
end
break normalize_array.norm_loop
commands
silent
continue
end
run
info breakpoints
