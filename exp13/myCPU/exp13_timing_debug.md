# exp13 时序关键路径优化 Debug 日志

日期：2026-10-18  
更新：2026-10-20  
工程：`soc_verify/soc_bram`，器件 `xc7a200tfbg676-1`，Vivado 2019.2，CPU 时钟周期 20 ns。

当前方案：在级间寄存器入口固化异常写回资格，仅让依赖 MEM load 的条件分支和 `jirl` 等待到 WB；保留分支的 MEM 非 load 前递和 WB 前递。

## 1. 问题与优化前基线

优化前，分支遇到 EX 相关写者时暂停，MEM/WB 相关时立即前递。对应已完成布线的 exp13 报告为：

- WNS：`-0.367 ns`
- TNS：`-3.145 ns`
- setup failing endpoints：18
- 数据路径延迟：`19.538 ns`，其中 logic `5.105 ns`、route `14.433 ns`
- 逻辑级数：16

最差路径为：

```text
data RAM
  -> data_sram_rdata / bridge_1x2
  -> ws_final_result
  -> MEM/WB 到 ID 的前递
  -> ID 分支比较
  -> PC 控制
  -> instruction RAM ENARDEN
```

同一类路径在 exp12 已经存在，当时 routed WNS 为 `+0.127 ns`。exp12 的数据路径延迟为 `18.861 ns`，其中 logic `5.360 ns`、route `13.501 ns`。exp13 相比 exp12 的逻辑延迟减少 `0.255 ns`，但布线延迟增加 `0.932 ns`，说明违例主要来自网表规模、扇出和布局变化造成的物理布线退化，而不是新增了一条此前不存在的功能路径。

优化前的 exp13 控制还在 MEM/WB RAW 检测与前递资格中组合异常信号：

```verilog
ms_pending_write = ms_valid && ms_gr_we && !ms_excp_any;
ws_pending_write = ws_valid && ws_gr_we && !ws_excp_any;
ms_result_available = !ms_excp_any && !ms_res_from_csr;
```

这些条件会把异常网络扩散到 MEM/WB 前递控制。虽然异常信号不是最差路径的主要数据源，但可能影响 LUT 合并、扇出和放置结果。

## 2. 2026-10-19：异常资格提前固化

### 2.1 RTL 修改

修改文件：[mycpu_top.v](./mycpu_top.v)。

在级间寄存器入口固化异常资格：

```verilog
// EX -> MEM
ms_gr_we <= es_gr_we && !es_excp_any_with_ale;

// MEM -> WB
ws_gr_we <= ms_gr_we && !ms_excp_any;
```

MEM/WB 的 RAW 与前递判断改为仅依赖寄存后的写使能：

```verilog
assign ms_pending_write = ms_valid && ms_gr_we
                       && (ms_dest != 5'd0);
assign ws_pending_write = ws_valid && ws_gr_we
                       && (ws_dest != 5'd0);

assign ms_result_available = !ms_res_from_csr;
```

本阶段保留原分支前递行为：`es_pending_write` 和 `es_result_available` 仍直接检查 `es_excp_any_with_ale`，因此 EX 相关继续暂停；MEM/WB 相关继续立即前递。异常指令进入 MEM 时 `ms_gr_we` 已为 0，进入 WB 时再次固化，因此异常指令不参与 RAW 前递，也不会写 GPR。

### 2.2 本阶段功能验证

本轮实际执行并通过：

- exp13 功能回归：58/58 PASS
- directed：`PASS directed: 593 commits, 67 stores, 1047 cycles`
- CPU 级硬件中断：`PASS cpu hw_int: 8 lanes, precise trap/ertn`

directed 为 1047 cycles。功能回归和 8 路中断测试表明，提前固化 `gr_we` 后异常指令仍不会错误写回或前递，精确 trap/ertn 行为保持正确。

### 2.3 本阶段实现结果

正式工程重新完成综合和 `place_design`，综合为 0 errors。对新 RTL 的 placed checkpoint 执行精确时序查询得到：

- placed WNS：`-1.266 ns`
- 数据路径延迟：`20.235 ns`
- logic：`5.377 ns`
- route：`14.858 ns`
- 逻辑级数：17

该 placed 最差路径仍为 `data RAM -> MEM/WB 前递 -> ID 分支比较 -> instruction RAM ENARDEN`，但路径中已经没有 `ms_excp_any` 或 `ws_excp_any`，说明异常资格固化确实切断了异常信号到 MEM/WB 前递控制的直接组合扩散。

随后默认实现流程进入 `phys_opt_design`，日志中的暂态估算从 `WNS=-1.266 ns` 改善到 `WNS=-0.827 ns`、`TNS=-31.245 ns`。

## 3. 2026-10-20：仅 MEM load 相关分支等待 WB

### 3.1 目标与排查

按用户指定方案修改 [mycpu_top.v](./mycpu_top.v)。修改前，寄存器型分支仅等待 EX 写者，随后由分支专用选择器直接前递 `ms_final_result` 或 `ws_writeback_result`。由于 `ms_final_result` 包含尚未跨过 MEM/WB 寄存器的 RAM 读数据，MEM load 可直接进入 ID 分支比较及 `jirl` 目标计算。

本轮仅新增 MEM load 相关分支的等待。预期行为为：

| ID 消费者与最新相关写者 | 本轮行为 |
| --- | --- |
| 条件分支或 `jirl`，写者在 EX | 沿用已有 EX 相关暂停 |
| 条件分支或 `jirl`，写者是 MEM load | 暂停，等 load 进入 WB |
| 条件分支或 `jirl`，写者是 MEM 非 load、非 CSR | 继续立即前递执行结果 |
| 条件分支或 `jirl`，写者在 WB | 立即前递，无需再等寄存器堆写入 |
| 普通运算或 store，写者是 MEM load | 保留通用 MEM load 前递 |
| MEM load 与分支真实源无关 | 不新增暂停 |

CSR 返回值的既有等待、异常资格提前固化、无效槽和 r0 的 RAW 过滤均保留。

### 3.2 修改过程

1. 新增 `ds_branch_ms_load_stall` 并汇入 `ds_raw_stall`。仅在 ID 为条件分支或 `jirl`、MEM 为 load，且至少一个真实源依赖该 MEM 写者时暂停。逐源排除同名的更新 EX 写者，继续遵循最新写者优先级。

   ```verilog
   assign ds_branch_ms_load_stall = ds_is_reg_branch && ms_res_from_mem
                                  && ((ds_rj_raw_ms && !ds_rj_raw_es)
                                   || (ds_rkd_raw_ms && !ds_rkd_raw_es));
   ```

2. 新增 `ds_br_rj_fwd_ms` 和 `ds_br_rkd_fwd_ms`，在原 MEM 前递资格上排除 load。分支专用 MEM 数据源由 `ms_final_result` 改为寄存后的 `ms_alu_result`，从 RTL 数据连接上去掉 RAM 读数据到分支操作数的直接路径；该寄存器同样保存乘法、除法及计数器等非 load 执行结果。

   ```verilog
   assign ds_br_rj_fwd_ms = ds_rj_fwd_ms && !ms_res_from_mem;
   assign ds_br_rkd_fwd_ms = ds_rkd_fwd_ms && !ms_res_from_mem;
   assign ds_br_rj_value = ds_br_rj_fwd_ms ? ms_alu_result :
                           ds_rj_fwd_ws ? ws_writeback_result : rf_rdata1;
   assign ds_br_rkd_value = ds_br_rkd_fwd_ms ? ms_alu_result :
                            ds_rkd_fwd_ws ? ws_writeback_result : rf_rdata2;
   ```

3. 通用 `rj_value/rkd_value` 继续使用 `ms_final_result`，保证普通 load-use 和 store 数据前递不增加等待。WB 前递继续屏蔽 EX/MEM 的同名旧值，避免分支在 MEM load 尚未就绪时误用更早的 WB 值。

4. 首次编译提示 `ms_alu_result` 在声明前使用。将它的唯一声明从 MEM 段移到前部结果信号声明区，保留原有寄存更新逻辑，重新编译通过。首次回归另遇到仿真数据库写入和隔离目录创建权限限制，经自动审批重试后正常运行。

### 3.3 验证命令与结果

在 `D:/calab/exp13/myCPU` 执行：

```powershell
.\tests\run_directed.ps1
.\tests\run_func.ps1 -Mode exp13 -OutputDir D:/calab/exp13/myCPU/tests/run/mem_load_branch_func
.\tests\run_hw_int.ps1 -OutputDir D:/calab/exp13/myCPU/tests/run/mem_load_branch_hw_int
```

实际结果：

- [directed.log](./tests/directed.log)：`PASS directed: 593 commits, 67 stores, 1047 cycles`。
- [func.log](./tests/run/mem_load_branch_func/func.log)：58/58 功能点通过，最终 `----PASS!!!`，结束时间 `2122465 ns`。
- [hw_int.log](./tests/run/mem_load_branch_hw_int/hw_int.log)：`PASS cpu hw_int: 8 lanes, precise trap/ertn`。

由于现有 directed 总周期数仍为 1047，额外保留了 [专项控制测试](./tests/run/mem_load_branch_control_tb.v)，通过构造流水线状态直接检查新增策略，避免仅用总周期数判断改动是否生效。该测试检查六类条件分支与 `jirl`、条件分支两个源、MEM load 时禁止重定向及误用旧 WB、WB 前递放行、MEM 非 load 前递、无关 load、普通消费者、最新 EX 写者和原 CSR 等待。它使用固定流水线状态验证控制与选数，端到端执行正确性由上述功能回归补充。

在 `run_directed.ps1` 编译当前 RTL 后，可从 `tests` 目录复现专项测试：

```powershell
$vivadoBin = 'D:/VIVADO2019.2/Vivado/2019.2/bin'
& "$vivadoBin/xvlog.bat" run/mem_load_branch_control_tb.v
& "$vivadoBin/xelab.bat" mem_load_branch_control_tb -L mult_gen_v12_0_16 -L div_gen_v5_1_16 -s mem_load_branch_control_sim
& "$vivadoBin/xsim.bat" mem_load_branch_control_sim -runall -log mem_load_branch_control.log
```

[专项日志](./tests/mem_load_branch_control.log)结果：`PASS MEM load branch control: 55 checks`。

本轮验证 RTL 的 SHA-256：`5F608BC1329AB56CDE34685DF76DAD8C8FD610985AC1CF030FC958534E92C6B1`。

### 3.4 当前结论与时序边界

功能回归及专项测试通过：新增等待仅作用于依赖 MEM load 的寄存器型分支，load 到 WB 后即可前递；MEM 非 load 分支前递与普通消费者的 MEM load 前递均保留。

本轮代码修改与功能验证期间，代理未运行综合、布局布线或生成 bitstream。RTL 已移除分支专用选择器对 `ms_final_result` 的数据连接；后续时序结果记录如下，第 2.3 节的中间实现结果不代表本轮方案。

### 3.5 用户补充的时序结果

2026-10-20，用户反馈本方案的时序指标：

| 指标 | 结果 | 含义 |
| --- | --- | --- |
| WNS | `+0.596 ns` | 最差 setup 裕量为正 |
| WHS | `+0.021 ns` | 最差 hold 裕量为正 |

两项最差裕量均为正，说明该报告覆盖的 setup/hold 检查均无负裕量；hold 余量为 21 ps。数值来源为用户反馈，尚未核对对应报告文件、实现阶段（placed/routed）、TNS/THS、约束覆盖及 bitstream 状态，因此此处不将其扩展为已完成全部时序签核或已生成新 bitstream 的结论。
