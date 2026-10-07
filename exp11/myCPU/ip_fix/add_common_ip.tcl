# Source from an open Vivado project. Install this file in <repository>/scripts.
namespace eval ::cpu_common_ip {
    variable root [file normalize [file join [file dirname [info script]] ..]]
    variable names {exp10_mul33 exp10_div_signed exp10_div_unsigned}
}
proc ::cpu_common_ip::load {} {
    variable root
    variable names
    if {[current_project -quiet] eq ""} { error "Open a Vivado project before loading common CPU IPs." }
    # Check all required sources before mutating the project.
    foreach name $names {
        set path [file join $root common_ip $name ${name}.xci]
        if {![file isfile $path]} { error "Required IP file does not exist: $path" }
    }
    foreach name $names {
        set path [file normalize [file join $root common_ip $name ${name}.xci]]
        set ip [get_ips -quiet $name]
        if {[llength $ip] == 0} {
            add_files -norecurse $path
            set ip [get_ips -quiet $name]
        } else {
            puts "Common CPU IP already loaded: $name ([get_property IP_FILE $ip])"
        }
        if {[llength $ip] != 1} { error "Expected exactly one IP object for $name, got: $ip" }
        if {[get_property IS_LOCKED $ip]} { error "IP $name is locked; use its original compatible Vivado version. No upgrade performed." }
    }
    update_compile_order -fileset sources_1
    foreach name $names {
        generate_target all [get_ips $name]
        puts "COMMON_IP_OK $name [get_property IP_FILE [get_ips $name]]"
    }
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
}
::cpu_common_ip::load
