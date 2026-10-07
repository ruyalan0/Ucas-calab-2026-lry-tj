# Source in an open Vivado 2019.2 project. The RTL wrappers require these
# exact configurations. Set exp10_ip_root before sourcing to override output.
set exp10_cpu_dir [file dirname [file normalize [info script]]]
if {![info exists exp10_ip_root]} {
    set exp10_ip_root [file normalize [file join $exp10_cpu_dir ../soc_verify/soc_bram/rtl/xilinx_ip]]
}
file mkdir $exp10_ip_root

proc exp10_ensure_ip {name type version config} {
    global exp10_ip_root
    set ip [get_ips -quiet $name]
    set xci [file join $exp10_ip_root $name $name.xci]
    if {[llength $ip] == 0 && [file exists $xci]} {
        read_ip $xci
        set ip [get_ips $name]
    }
    if {[llength $ip] == 0} {
        create_ip -name $type -vendor xilinx.com -library ip -version $version \
            -module_name $name -dir $exp10_ip_root
        set ip [get_ips $name]
        set_property -dict $config $ip
    }
    foreach {key expected} $config {
        set actual [get_property $key $ip]
        if {![string equal -nocase $actual $expected]} {
            error "$name $key=$actual; required $expected. Existing IP was not overwritten."
        }
    }
    puts "EXP10_IP $name: [get_property IPDEF $ip]"
    foreach key {CONFIG.PipeStages CONFIG.PortAWidth CONFIG.PortBWidth CONFIG.latency CONFIG.operand_sign} {
        if {[lsearch -exact [list_property $ip] $key] >= 0} {
            puts "  $key=[get_property $key $ip]"
        }
    }
}

exp10_ensure_ip exp10_mul33 mult_gen 12.0 [list \
    CONFIG.MultType Parallel_Multiplier \
    CONFIG.PortAType Signed CONFIG.PortAWidth 33 \
    CONFIG.PortBType Signed CONFIG.PortBWidth 33 \
    CONFIG.Multiplier_Construction Use_Mults \
    CONFIG.OptGoal Speed CONFIG.PipeStages 0 \
    CONFIG.Use_Custom_Output_Width false \
    CONFIG.ClockEnable false CONFIG.SyncClear false CONFIG.UseRounding false]

foreach {name sign} {exp10_div_signed Signed exp10_div_unsigned Unsigned} {
    exp10_ensure_ip $name div_gen 5.1 [list \
        CONFIG.algorithm_type Radix2 \
        CONFIG.dividend_and_quotient_width 32 CONFIG.divisor_width 32 \
        CONFIG.operand_sign $sign CONFIG.remainder_type Remainder \
        CONFIG.fractional_width 32 CONFIG.clocks_per_division 8 \
        CONFIG.FlowControl NonBlocking CONFIG.latency_configuration Automatic \
        CONFIG.OutTready false CONFIG.ACLKEN false CONFIG.ARESETN true \
        CONFIG.dividend_has_tlast false CONFIG.divisor_has_tlast false \
        CONFIG.dividend_has_tuser false CONFIG.divisor_has_tuser false \
        CONFIG.divide_by_zero_detect false]
}
generate_target all [get_ips {exp10_mul33 exp10_div_signed exp10_div_unsigned}]
foreach name {mycpu_top mul_unit div_unit alu regfile tools} {
    add_files -norecurse [file join $exp10_cpu_dir $name.v]
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
