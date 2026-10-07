set task_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $task_dir ../../..]]
open_project [file join $repo_root exp11 soc_verify soc_bram run_vivado project loongson.xpr]
# The original XPR had no runtime override. Restore its Vivado default.
reset_property xsim.simulate.runtime [get_filesets sim_1]
foreach name {exp10_mul33 exp10_div_signed exp10_div_unsigned} {
    set ip [get_ips -quiet $name]
    if {[llength $ip] != 1} { error "Persisted project missing IP $name" }
    puts "PERSISTED_IP_OK $name [get_property IP_FILE $ip]"
}
close_project
