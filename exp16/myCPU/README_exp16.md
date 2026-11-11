# 实践16：AXI随机延迟验证

以 `D:/calab/exp15/myCPU` 的九个 Verilog 文件为基线。CPU核、CSR、乘除法器、AXI顶层等保持基线代码，修改集中在 `sram_axi_bridge.v`。原有【实践15新增】【实践15修改】注释保留，实践16的修改和新增代码已分别标注。

依据教材第8章8.4.2和8.5.3节（PDF第231、237～238页，书页214、220～221）：实践16要求完善AXI接口，并用不同种子覆盖无延迟、短延迟和长延迟下的func功能验证。

## 实现

- 用五个独立握手事件驱动状态机；只有类SRAM实际握手后才启动事务。
- AR、AW、W的VALID来自寄存状态。请求载荷先锁存，READY拉低期间持续稳定。
- AW、W分别记录完成，支持任意先后和同拍接收，已完成通道不再重复发送。
- 仅当前事务对应ID的R最后一拍、B响应能结束事务；读数据先缓存，再返回一次data_ok。
- 保持单事务串行方案：写响应返回前不发后续读，不做写到读前递。CPU已有的取指返回缓存、取消后排空旧响应、MEM等待store响应机制沿用exp15。

## 验证

`tests/run_regression.py` 在 `.work` 内生成独立IP、编译并运行原始exp16 SoC的58项func和golden_trace比对。仅在仿真副本内加入种子运行参数、协议检查和超时检查，不修改exp16的func、golden_trace或原验证环境。

本次使用exp16目录已提供的func镜像和参考trace。若重新编译功能程序，应使用 `make EXP=16`，并同步更新参考trace和RAM初始化数据。

默认五个23位种子（最多三个独立XSim进程并行运行）：

| 种子 | 类型 |
|---|---|
| 5500ff | 无延迟：低16位为00ff |
| 55ffff | 短延迟：低8位为ff，低16位不是00ff |
| 550000 | 长延迟 |
| 551234 | 长延迟 |
| 552345 | 长延迟 |

协议计分板检查复位输出、AR/AW/W反压稳定、类SRAM与AXI一一对应、响应归属、重复请求和提前完成。`tests/bridge_tb.sv` 另外覆盖强制AW先到、W先到、同拍握手、延迟B响应、字节/半字/字连续写读、双端口同时请求及数据优先仲裁，共362笔事务。

在本目录运行：

```powershell
python tests/run_regression.py
python tests/run_regression.py --bridge-only
python tests/run_regression.py --seeds 5500ff 55ffff 550000 551234 552345
```

可通过 `--vivado-bin` 指定Vivado 2019.2的bin目录；`--generate-ip` 强制重新生成本地IP。编译日志保存在 `.work/soc_sim`，每个种子的运行日志保存在 `.work/runs/seed_<种子>`；定向测试日志和机器可读结果分别保存在 `.work/bridge_sim` 和 `.work/regression_results.json`。

建立可打开的完整SoC工程：

```powershell
& 'D:/VIVADO2019.2/Vivado/2019.2/bin/vivado.bat' -mode batch -source create_project.tcl
```

此入口和教材原入口 `../soc_verify/soc_axi/run_vivado/create_project.tcl` 已统一，工程位于 `../soc_verify/soc_axi/run_vivado/project/loongson.xpr`。脚本既可新建工程，也可清理并修复同一路径的已有工程；只移除错误工程引用，不删除源文件。配置由 `project_setup.tcl` 统一维护，显式加入13个CPU/SoC RTL文件、6个独立IP配置、1个仿真文件和1个约束文件，排除整个 `.work` 和 `tests`。IP配置副本位于该工程的 `project/ip` 下。综合顶层固定为 `soc_lite_top`，仿真顶层固定为 `tb_top`。六个IP为 `clk_pll`、`axi_ram`、`axi_crossbar_1x2`、`exp10_mul33`、`exp10_div_signed` 和 `exp10_div_unsigned`。打开工程后可运行仿真、综合和实现。上板时需按教材覆盖不同拨码开关初始种子；实际硬件验证结果需在开发板上确认。

完成建工程后，可用以下命令复现CPU顶层和实际乘除法IP的RTL展开检查（不等同于完整SoC综合实现和时序收敛验证）：

```powershell
& 'D:/VIVADO2019.2/Vivado/2019.2/bin/vivado.bat' -mode batch -source tests/check_rtl.tcl
```

本次实际运行的验证结果见 [verification_results.md](verification_results.md)。

若Vivado已打开旧工程，在其Tcl Console中执行以下命令，将同一修复同步到当前窗口：

```tcl
source D:/calab/exp16/soc_verify/soc_axi/run_vivado/create_project.tcl
```

Sources中Design Sources的根应为 `soc_lite_top`，Simulation Sources的根应为 `tb_top`；IP Sources页应有六个IP。修复前的工程文件保存在 `.work/project_backups`。
