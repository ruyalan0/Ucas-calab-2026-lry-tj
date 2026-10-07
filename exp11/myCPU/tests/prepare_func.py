"""Adapt only local testbench copies; official images and golden trace stay read-only."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
tb = (root / 'soc_verify/soc_bram/testbench/mycpu_tb.v').read_text(encoding='utf-8')
tb = tb.replace('../../../../../../../../gettrace/golden_trace.txt', (root / 'gettrace/golden_trace.txt').as_posix())
tb = tb.replace('    $dumpfile("dump.vcd");', '').replace('    $dumpvars;', '')
tb = tb.replace('    trace_ref = $fopen(`TRACE_REF_FILE, "r");', '    trace_ref = $fopen(`TRACE_REF_FILE, "r");\n    if (!trace_ref) $fatal(1,"FAIL missing reference");')
tb = tb.replace('endmodule', 'initial begin\n    #100000000;\n    $fatal(1,"FAIL timeout");\nend\nendmodule')
(out / 'func_tb.vh').write_text(tb, encoding='utf-8')
ram = (root / 'soc_verify/soc_bram/testbench/sync_ram.v').read_text(encoding='utf-8')
ram = ram.replace('output wire [DATA_WIDTH-1:0] wdata;', 'input wire [DATA_WIDTH-1:0] wdata;')
ram = ram.replace('ram[DEPTH]', 'ram[0:DEPTH-1]')
for name in ('inst_ram', 'data_ram'):
    ram = ram.replace(f'../../../../../../../../func/obj/{name}.mif', (root / f'func/obj/{name}.mif').as_posix())
(out / 'func_ram.vh').write_text(ram, encoding='utf-8')
