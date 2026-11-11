# 【实践16新增】统一配置标准exp16工程：精确列举源文件，六个IP各只登记一次。
namespace eval ::exp16_setup {}

proc ::exp16_setup::configure {cpu_dir} {
    set cpu_dir [file normalize $cpu_dir]
    set exp_dir [file dirname $cpu_dir]
    set repo_dir [file dirname $exp_dir]
    set rtl_dir $exp_dir/soc_verify/soc_axi/rtl
    set project_dir [get_property DIRECTORY [current_project]]

    # 先验证所需文件，避免路径错误时清空当前工程。
    set design_sources {}
    foreach name {alu csr div_unit mul_unit mycpu_core mycpu_top regfile sram_axi_bridge tools} {
        lappend design_sources $cpu_dir/$name.v
    }
    foreach relative {soc_lite_top.v axi_wrap/axi_wrap.v ram_wrap/axi_wrap_ram.v CONFREG/confreg.v} {
        lappend design_sources $rtl_dir/$relative
    }
    set tb $exp_dir/soc_verify/soc_axi/testbench/mycpu_tb.v
    set xdc $exp_dir/soc_verify/soc_axi/run_vivado/constraints/soc_lite_top.xdc
    set coe $exp_dir/func/obj/inst_ram.coe
    set ip_sources [list \
        $rtl_dir/xilinx_ip/clk_pll/clk_pll.xci \
        $rtl_dir/xilinx_ip/axi_ram/axi_ram.xci \
        $rtl_dir/xilinx_ip/axi_crossbar_1x2/axi_crossbar_1x2.xci \
        $repo_dir/common_ip/exp10_mul33/exp10_mul33.xci \
        $repo_dir/common_ip/exp10_div_signed/exp10_div_signed.xci \
        $repo_dir/common_ip/exp10_div_unsigned/exp10_div_unsigned.xci]
    foreach path [concat $design_sources $ip_sources [list $tb $xdc $coe]] {
        if {![file isfile $path]} { error "Required exp16 file missing: $path" }
    }

    file mkdir $cpu_dir/.work/project_backups
    set current_xpr $project_dir/[get_property NAME [current_project]].xpr
    if {[file isfile $current_xpr]} {
        file copy -force $current_xpr $cpu_dir/.work/project_backups/loongson_[clock format [clock seconds] -format %Y%m%d_%H%M%S].xpr
    }
    # 只移除工程引用，不删除任何Verilog、测试、IP或生成文件。
    foreach fileset {sources_1 sim_1 constrs_1} {
        set old_files [get_files -quiet -of_objects [get_filesets $fileset]]
        if {[llength $old_files]} { remove_files -fileset $fileset $old_files }
    }
    add_files -fileset sources_1 -norecurse $design_sources
    add_files -fileset sim_1 -norecurse $tb
    add_files -fileset constrs_1 -norecurse $xdc

    # 独立IP配置位于标准工程的ip目录，生成产品不会写入exp15或common_ip。
    foreach source $ip_sources {
        set name [file rootname [file tail $source]]
        set local_dir $project_dir/ip/$name
        file mkdir $local_dir
        set target $local_dir/$name.xci
        if {![file exists $target]} {
            set fd [open $source r]
            fconfigure $fd -encoding utf-8
            set xml [read $fd]
            close $fd
            if {$name eq "axi_ram"} {
                set xml [string map [list "../../../../../func/obj/inst_ram.coe" $coe] $xml]
            }
            set fd [open $target w]
            fconfigure $fd -encoding utf-8
            puts -nonewline $fd $xml
            close $fd
        }
        read_ip $target
    }

    # 禁止自动从误扫进来的IP内部模块推断综合顶层。
    set_property top soc_lite_top [get_filesets sources_1]
    set_property top_auto_set false [get_filesets sources_1]
    set_property top tb_top [get_filesets sim_1]
    set_property top_auto_set false [get_filesets sim_1]
    set_property xsim.simulate.log_all_signals 1 [get_filesets sim_1]
    generate_target all [get_ips]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

    set required_ips {axi_crossbar_1x2 axi_ram clk_pll exp10_div_signed exp10_div_unsigned exp10_mul33}
    set actual_ips [lsort [get_property NAME [get_ips]]]
    if {$actual_ips ne $required_ips} { error "Unexpected IP set: $actual_ips" }
    foreach name $required_ips {
        if {[get_property IS_LOCKED [get_ips $name]]} { error "Locked IP: $name" }
    }
    # 确保测试和.work中的任何裸HDL文件都未重新混入设计源。
    foreach source [get_files -quiet -of_objects [get_filesets sources_1]] {
        set filename [file normalize $source]
        if {[string match -nocase "$cpu_dir/.work/*" $filename] ||
            [string match -nocase "$cpu_dir/tests/*" $filename]} {
            error "Unexpected regression source in design: $filename"
        }
    }
    set fd [open $cpu_dir/.work/standard_project_audit.txt w]
    puts $fd "PROJECT=[get_property DIRECTORY [current_project]]/[get_property NAME [current_project]].xpr"
    puts $fd "DESIGN_TOP=[get_property TOP [get_filesets sources_1]]"
    puts $fd "SIM_TOP=[get_property TOP [get_filesets sim_1]]"
    puts $fd "CPU_AND_SOC_RTL=[llength $design_sources]"
    puts $fd "IPS=$actual_ips"
    puts $fd "DESIGN_FILES:"
    foreach source [get_files -quiet -of_objects [get_filesets sources_1]] { puts $fd $source }
    close $fd
    puts "EXP16_PROJECT_SETUP_PASS: soc_lite_top / tb_top / six IPs / no regression sources"
}
