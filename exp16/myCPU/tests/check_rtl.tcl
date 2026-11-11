# 【实践16新增】展开CPU顶层和实际乘除法IP；完整SoC功能由XSim回归验证。
set root [file normalize [file join [file dirname [info script]] ..]]
open_project $root/../soc_verify/soc_axi/run_vivado/project/loongson.xpr
file mkdir $root/.work/rtl_check
cd $root/.work/rtl_check
file mkdir .Xil
set_property generate_synth_checkpoint false [get_files *exp10_*.xci]
generate_target synthesis [get_ips exp10_*]
update_compile_order -fileset sources_1
synth_design -rtl -rtl_skip_constraints -top mycpu_top -part xc7a200tfbg676-1
puts "EXP16_CPU_RTL_ELABORATION_PASS"
close_project
