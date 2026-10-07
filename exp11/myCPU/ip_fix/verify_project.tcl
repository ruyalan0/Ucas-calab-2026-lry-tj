set task_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $task_dir ../../..]]
set project_file [file join $repo_root exp11 soc_verify soc_bram run_vivado project loongson.xpr]
if {![file isfile $project_file]} { error "Existing exp11 project missing: $project_file" }
open_project $project_file
source [file join $repo_root scripts add_common_ip.tcl]
# Explicit second execution checks idempotence in the real project.
source [file join $repo_root scripts add_common_ip.tcl]
puts "COMMON_IP_REPEAT_PASS"
set saved_runtime [get_property xsim.simulate.runtime [get_filesets sim_1]]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
launch_simulation -mode behavioral
puts "COMMON_IP_ELABORATION_PASS"
run 5 ms
close_sim
set_property xsim.simulate.runtime $saved_runtime [get_filesets sim_1]
close_project
puts "COMMON_IP_VALIDATION_DONE"
