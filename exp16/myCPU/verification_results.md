# 实践16验证记录

日期：2026-11-10。工具：Vivado / XSim 2019.2。

## 功能与协议验证

使用exp16自带的SoC AXI验证环境、func镜像和golden_trace，逐项监控功能点结果并逐条比较有效寄存器写回trace。五次仿真均正常结束，无trace错误或协议断言失败。

| 随机种子 | 延迟类别 | 功能点 | trace比对 |
|---|---|---|---|
| 5500ff | 无延迟 | 58/58 | PASS |
| 55ffff | 短延迟 | 58/58 | PASS |
| 550000 | 长延迟 | 58/58 | PASS |
| 551234 | 长延迟 | 58/58 | PASS |
| 552345 | 长延迟 | 58/58 | PASS |

独立转接桥测试：362笔事务全部通过（242读、120写）。其中AW先握手34次、W先握手46次、同拍握手40次；AR/AW/W反压分别覆盖231/103/90拍。覆盖字节、半字、字访问，延迟B响应，连续写后读，双端口同时请求和数据优先仲裁，并验证CPU端载荷改变不会影响已接受事务。

计分板检查：复位时VALID为0且READY非X；AR/AW/W反压时保持；类SRAM请求与AXI事务对应；请求不重复发送；R/B响应属于当前事务；data_ok不提前、不重复、不错发端口。

## 源码与交付范围

- exp15目录九个源文件的SHA-256与开始工作时完全一致。
- exp16保留全部10处【实践15新增】/【实践15修改】标记注释。
- exp16八个未修改的Verilog文件与exp15逐字节相同；转接桥的修改、新增代码均有实践16标记。
- 标准建工程入口已修复并实际验证：工程位于 `../soc_verify/soc_axi/run_vivado/project/loongson.xpr`，六个IP配置副本位于工程内的 `ip` 目录；独立回归输出仍在 `.work`。
- CPU顶层及实际乘除法IP的RTL展开通过：0错误、0严重警告。105条普通警告包括基线未使用端口/信号及Xilinx IP接口提示，详见 `.work/check_rtl.log`。此项检查跳过板级管脚约束。
- 本次未进行完整SoC布局布线、时序收敛、码流生成和开发板实测。

机器可读结果、源文件哈希和协议统计见 `.work/regression_results.json`；基线核对见 `.work/baseline_audit.json`。运行方法见 `README_exp16.md`。

## 标准工程入口修复

已修正 `../soc_verify/soc_axi/run_vivado/create_project.tcl`，并将myCPU目录入口统一到该脚本。原脚本递归导入 `.work`、测试目录及重复IP内部HDL，导致Sources污染、综合顶层误选为 `flt_add_lat_exp`；原脚本也遗漏三个共享算术IP。

现工程包含13个CPU/SoC RTL文件、六个IP及RAM初始化数据；仿真文件与约束分别放入sim_1和constrs_1。综合顶层为soc_lite_top，仿真顶层为tb_top。已对该标准工程实际执行编译、仿真展开和100 us运行，功能点1及其trace比对通过，无缺失模块、重复定义或trace错误。

本次只修改工程配置与文档，九个CPU Verilog源文件未改变；exp15哈希再次核对通过。修复前的工程和入口脚本位于 `.work/project_backups`。工程清单见 `.work/standard_project_audit.txt`，验证日志见 `.work/repair_standard_project.log`。
