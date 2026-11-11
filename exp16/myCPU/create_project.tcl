# 【实践16修改】兼容myCPU目录入口，与教材run_vivado入口使用同一套工程配置。
set exp16_cpu_entry_dir [file normalize [file dirname [info script]]]
source $exp16_cpu_entry_dir/../soc_verify/soc_axi/run_vivado/create_project.tcl
