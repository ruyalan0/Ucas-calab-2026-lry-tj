# 【实践16新增】本地Vivado/XSim回归；所有生成物均在当前myCPU/.work内。
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.work'
ENV = ROOT.parent / 'soc_verify/soc_axi'
LIBS = ['blk_mem_gen_v8_4_4', 'generic_baseblocks_v2_1_0',
        'axi_infrastructure_v1_1_0', 'axi_register_slice_v2_1_20',
        'fifo_generator_v13_2_5', 'axi_data_fifo_v2_1_19', 'axi_crossbar_v2_1_21',
        'xbip_utils_v3_0_10', 'axi_utils_v2_0_6', 'xbip_pipe_v3_0_6',
        'xbip_dsp48_wrapper_v3_0_4', 'xbip_dsp48_addsub_v3_0_6',
        'xbip_bram18k_v3_0_6', 'mult_gen_v12_0_16', 'floating_point_v7_0_17',
        'xbip_dsp48_mult_v3_0_6', 'xbip_dsp48_multadd_v3_0_6',
        'div_gen_v5_1_16', 'unisims_ver', 'unimacro_ver', 'secureip', 'xpm']


def run(name, args, cwd, logfile):
    with (cwd / logfile).open('w', encoding='utf-8') as f:
        result = subprocess.run([str(BIN / (name + '.bat')), *map(str, args)],
                                cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    text = (cwd / logfile).read_text(encoding='utf-8', errors='replace')
    if result.returncode or re.search(r'^(?:ERROR|FATAL_ERROR|Fatal):', text, re.M):
        raise RuntimeError(f'{name} failed; see {cwd / logfile}\n{text[-4000:]}')
    return text


def prepare_ip():
    sources = list((ENV / 'rtl/xilinx_ip').glob('*/*.xci'))
    sources += list((ROOT.parents[1] / 'common_ip').glob('exp10_*/*.xci'))
    for source in sources:
        target = WORK / 'ip' / source.parent.name / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        text = source.read_text(encoding='utf-8')
        text = text.replace('../../../../../func/obj/inst_ram.coe',
                            (ROOT.parent / 'func/obj/inst_ram.coe').as_posix())
        target.write_text(text, encoding='utf-8')
    script = WORK / 'generate_ip.tcl'
    script.write_text('''set root [file normalize [file join [file dirname [info script]] ..]]
create_project -force exp16_sim $root/.work/ip_project -part xc7a200tfbg676-1
foreach xci [glob $root/.work/ip/*/*.xci] { read_ip $xci }
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target simulation [get_ips]
close_project
''', encoding='utf-8')
    print('Generating isolated simulation IPs...', flush=True)
    run('vivado', ['-mode', 'batch', '-source', script, '-log', 'generate_ip.log',
                   '-journal', 'generate_ip.jou'], WORK, 'generate_ip.console.log')


def compile_soc():
    sim = WORK / 'soc_sim'
    sim.mkdir(exist_ok=True)
    confreg = (ENV / 'rtl/CONFREG/confreg.v').read_text(encoding='utf-8')
    confreg = re.sub(r'`define RANDOM_SEED[^\n]*',
                     '`define RANDOM_SEED tb_top.regression_seed', confreg)
    (sim / 'confreg.v').write_text(confreg, encoding='utf-8')
    tb = (ENV / 'testbench/mycpu_tb.v').read_text(encoding='utf-8')
    trace = (ROOT.parent / 'gettrace/golden_trace.txt').as_posix()
    tb = re.sub(r'`define TRACE_REF_FILE[^\n]*', f'`define TRACE_REF_FILE "{trace}"', tb)
    tb = tb.replace('module tb_top( );', '''module tb_top( );
// 【实践16新增】只在仿真副本中用运行参数切换随机种子，不修改实验环境。
reg [22:0] regression_seed;
initial begin
    if (!$value$plusargs("SEED=%h", regression_seed)) regression_seed = 23'h5500ff;
    $display("REGRESSION_SEED=%h", regression_seed);
end
initial begin #100000000; $fatal(1,"func timeout"); end
`define CPU soc_lite.u_cpu
`define CHECK_CLK soc_clk
`define CHECK_RESETN soc_lite.cpu_resetn
`include "axi_checks.svh"
''')
    tb = tb.replace('$display ("        [%t] Test is running, debug_wb_pc = 0x%8h",$time, debug_wb_pc);', '')
    (sim / 'soc_tb.sv').write_text(tb, encoding='utf-8')
    ip = WORK / 'ip'
    verilog = [*sorted(ROOT.glob('*.v')),
               ip / 'clk_pll/clk_pll_clk_wiz.v', ip / 'clk_pll/clk_pll.v',
               ip / 'axi_ram/sim/axi_ram.v',
               ip / 'axi_crossbar_1x2/sim/axi_crossbar_1x2.v',
               ENV / 'rtl/axi_wrap/axi_wrap.v', ENV / 'rtl/ram_wrap/axi_wrap_ram.v',
               sim / 'confreg.v', ENV / 'rtl/soc_lite_top.v',
               BIN.parent / 'data/verilog/src/glbl.v']
    prj = ''.join(f'verilog xil_defaultlib "{f.as_posix()}"\n' for f in verilog)
    prj += f'sv xil_defaultlib "{(sim / "soc_tb.sv").as_posix()}"\nnosort\n'
    (sim / 'sources.prj').write_text(prj, encoding='utf-8')
    run('xvlog', ['--relax', '-i', ROOT / 'tests', '-i', ip / 'clk_pll',
                  '-i', ip / 'axi_crossbar_1x2/hdl', '-prj', 'sources.prj'], sim, 'compile.log')
    vhdl = ''.join(f'vhdl xil_defaultlib "{p.as_posix()}"\n'
                   for p in sorted(ip.glob('exp10_*/sim/*.vhd')))
    (sim / 'vhdl.prj').write_text(vhdl + 'nosort\n', encoding='utf-8')
    run('xvhdl', ['--relax', '-prj', 'vhdl.prj'], sim, 'vhdl.log')
    shutil.copyfile(ip / 'axi_ram/axi_ram.mif', sim / 'axi_ram.mif')
    libs = [item for lib in LIBS for item in ('-L', lib)]
    run('xelab', ['--relax', '--mt', '2', *libs, '-s', 'exp16_soc',
                  'xil_defaultlib.tb_top', 'xil_defaultlib.glbl'], sim, 'elaborate.log')
    return sim


def test_soc(compiled, seeds):
    # Each simulator gets its own snapshot and files; random seeds run independently.
    def test_seed(seed):
        sim = WORK / 'runs' / f'seed_{seed:06x}'
        sim.mkdir(parents=True, exist_ok=True)
        shutil.copytree(compiled / 'xsim.dir', sim / 'xsim.dir', dirs_exist_ok=True)
        shutil.copyfile(compiled / 'axi_ram.mif', sim / 'axi_ram.mif')
        print(f'Running func seed {seed:06x}...', flush=True)
        log = f'seed_{seed:06x}.log'
        (sim / 'options.txt').write_text(f'-runall\n-testplusarg SEED={seed:06x}\n-log xsim_{seed:06x}.log\n', encoding='utf-8')
        text = run('xsim', ['exp16_soc', '-f', 'options.txt'], sim, log)
        points = re.findall(r'Functional Test Point PASS!!!', text)
        if '----PASS!!!' not in text or len(points) != 58 or 'Error' in text or 'Fatal' in text:
            raise RuntimeError(f'func failed or incomplete: {sim / log}\n{text[-3000:]}')
        summary = re.search(r'AXI_CHECK[^\r\n]*', text)
        result = {'seed': f'{seed:06x}', 'points': len(points),
                        'axi': summary.group() if summary else '',
                        'log': str(sim / log)}
        print(f'PASS {seed:06x}: 58/58; {result["axi"]}', flush=True)
        return result
    with ThreadPoolExecutor(max_workers=3) as pool:
        return list(pool.map(test_seed, seeds))


def test_bridge():
    sim = WORK / 'bridge_sim'
    sim.mkdir(exist_ok=True)
    run('xvlog', ['--sv', '-i', ROOT / 'tests', ROOT / 'sram_axi_bridge.v',
                  ROOT / 'tests/bridge_tb.sv'], sim, 'compile.log')
    run('xelab', ['--relax', '-s', 'exp16_bridge', 'work.bridge_tb'], sim, 'elaborate.log')
    text = run('xsim', ['exp16_bridge', '-runall', '-log', 'xsim.log'], sim, 'run.log')
    if 'BRIDGE_PASS' not in text or 'Fatal' in text:
        raise RuntimeError(text[-3000:])
    print(text[text.find('BRIDGE_PASS'):].split('$finish')[0].strip(), flush=True)
    return {'log': str(sim / 'run.log'), 'result': 'PASS'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--vivado-bin', default='D:/VIVADO2019.2/Vivado/2019.2/bin')
    parser.add_argument('--seeds', nargs='+', default=['5500ff','55ffff','550000','551234','552345'])
    parser.add_argument('--generate-ip', action='store_true')
    parser.add_argument('--bridge-only', action='store_true')
    parser.add_argument('--reuse-snapshot', action='store_true')
    args = parser.parse_args()
    BIN = Path(args.vivado_bin)
    WORK.mkdir(exist_ok=True)
    if args.bridge_only:
        results = {'bridge': test_bridge()}
    else:
        if args.generate_ip or not (WORK / 'ip/axi_ram/sim/axi_ram.v').exists():
            prepare_ip()
        results = {'func': test_soc(WORK / 'soc_sim' if args.reuse_snapshot else compile_soc(), [int(s,16) for s in args.seeds])}
        if (ROOT / 'tests/bridge_tb.sv').exists():
            results['bridge'] = test_bridge()
    (WORK / 'regression_results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
