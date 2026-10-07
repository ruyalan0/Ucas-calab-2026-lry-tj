# exp11 实现与验证记录

日期：2026-10-07。按 `exp11_Codex执行方案.md` 修改当前 `mycpu_top.v`，保留关键路径优化说明中的独立分支操作数通路。

## 实现完成

- 新增 `blt/bge/bltu/bgeu`，使用分支专用 MEM/WB/寄存器堆操作数，显式区分有符号和无符号比较；依赖 EX 写者时继续暂停。
- 新增 `ld.b/ld.h/ld.bu/ld.hu/st.b/st.h`，统一扩展译码、真实源检测、立即数、写回与访存控制。
- 访存宽度和 unsigned 标志随 ID→EX→MEM 传递，MEM 保存本条指令地址低位，在 MEM 完成小端选通及符号/零扩展；前递取得扩展后的完整结果。
- store 复制低字节/半字，按地址产生 byte enable，保持完整字节地址；请求仍由 `es_fire` 限定。
- 保留五级握手、乘除法单元、最新写者优先、入口 PC、分支取消和 WB debug 接口。新增关键逻辑标注 `【实践11修改】`。
- 仅支持实验规定的对齐访问，未增加异常处理。

基线为 exp10 源文件，SHA-256：`7794AD1DD367482B919E8A31D6C7A50E95B7B0707D9EB6CB96D67E1C3E09910F`。修改后的 `mycpu_top.v` SHA-256：`D35C1927232E8CF8E9702190BAE372595202A303142FB49CC8D11543A0B819DA`。逐行差异见 [tests/mycpu_top_exp11.patch](tests/mycpu_top_exp11.patch)。

## 实际仿真结果

使用 Vivado/XSim 2019.2，RTL 编译和展开成功。

1. 定向测试：[tests/directed.log](tests/directed.log) 输出 `PASS directed: 593 commits, 67 stores, 1047 cycles`。
   - 四种新增分支分别遍历 0、1、ffffffff、80000000、7fffffff 的全部两两组合（100 组），包含 taken、not-taken、等值及错误路径 store。
   - 验证负偏移回跳、所有合法字节/半字通道、符号/零扩展、未选通字节保留、负地址偏移和 r0。
   - 覆盖 load→ALU/store 数据/store 地址/branch、连续同名写者，以及真实乘除法结果依赖和无关分支等待除法。
   - RAM 上升沿同步读，关闭使能时保持输出，逐字节写入。以独立生成的预期 PC/目的寄存器/值校验提交，以实际写请求数检查重复或错误路径写入。
2. 官方功能回归：[tests/func.log](tests/func.log) 中 n1～n46 全部显示 `Functional Test Point PASS!!!`，最终输出 `----PASS!!!`，结束时间 1484745 ns；未发现 trace 比较或功能点错误。
   - 使用 exp11 原始 `func/obj/inst_ram.mif`、`data_ram.mif` 和 `gettrace/golden_trace.txt`，未修改镜像或参考答案。
   - 使用原 SoC、bridge、confreg，以及官方 testbench 的本地副本。副本仅调整资源路径、关闭波形转储、检查参考文件打开和添加超时。
   - 数据及指令 RAM 使用配套同步行为模型的本地副本，修正 `wdata` 方向为输入并明确数组范围。未修改原测试环境文件。
   - 两项测试均只读引用 exp10 已生成的三个 Xilinx 算术 IP VHDL 仿真封装，以及 Vivado 自带 `mult_gen_v12_0_16`/`div_gen_v5_1_16` 库；不是自制算术替代模型。

## 复现

在 `D:/calab/exp11/myCPU` 的 PowerShell 执行：

```powershell
./tests/run_directed.ps1
./tests/run_func.ps1
```

两脚本支持 `-VivadoBin` 和 `-ArithmeticIp` 参数；默认使用本机 Vivado 2019.2 及仓库相对路径 `common_ip` 的已生成 IP。首次克隆后先在 Vivado 工程中 source 仓库的 `scripts/add_common_ip.tcl` 生成 IP 输出文件，再运行测试。生成文件与日志位于 `tests`。脚本检查最终 PASS，功能回归另外检查通过点数等于 46。Python 用于生成定向镜像、独立预期结果及适配后的测试环境。测试模块使用 `.vh` 后缀并由脚本显式编译，工程中仅作为仿真源使用，不要加入综合源。

## 尚未验证的范围

- 此次验证为 RTL 功能仿真；RAM 使用同步行为模型，未验证 exp11 BRAM IP 的生成与初始化接入。
- 初次 RTL 验证时仿真复用了 exp10 的现有算术 IP。后续已按 `fix_vivado_ip_dependency.md` 将原始 XCI 整理至仓库 `common_ip`，加入现有 exp11 工程并使用官方 RAM IP 再次通过 n1～n46。参见 [IP 修复记录](ip_fix/修复记录.md)；后续工程使用 `scripts/add_common_ip.tcl` 复用原 IP。
- 未运行综合、布局布线、DRC、时序或 bitstream 生成；此次任务以顶层 RTL 修改与功能验证为范围。旧文档中的 WNS/TNS 不能作为此版的时序结论。
- 未做上板验证。
