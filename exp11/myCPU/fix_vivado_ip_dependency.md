# Vivado exp11 乘除法 IP 缺失问题修复方案

## 任务目标

修复 `exp11` Vivado 仿真在 `elaborate` 阶段失败的问题，并将 `exp10` 中已有的乘除法 IP 整理为可被后续实验复用的公共 IP 资源。

当前已确认缺失的模块为：

- `exp10_mul33`
- `exp10_div_signed`
- `exp10_div_unsigned`

对应报错位置：

- `mul_unit.v:15`：实例 `u_multiplier`
- `div_unit.v:52`：实例 `u_signed`
- `div_unit.v:64`：实例 `u_unsigned`

Vivado 报错核心信息：

```text
[VRFC 10-2063] Module <exp10_mul33> not found
[VRFC 10-2063] Module <exp10_div_signed> not found
[VRFC 10-2063] Module <exp10_div_unsigned> not found
[XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library work failed.
```

问题本质是：`mul_unit.v` 和 `div_unit.v` 已经实例化了上述 IP，但当前 `exp11` Vivado 工程没有加载对应的 `.xci` IP 配置文件。

---

## 约束

执行过程中必须遵守以下约束：

1. 不修改 `mul_unit.v`、`div_unit.v` 中现有乘除法逻辑。
2. 不修改下列模块名：
   - `exp10_mul33`
   - `exp10_div_signed`
   - `exp10_div_unsigned`
3. 不创建 `exp11_mul33`、`exp11_div_signed`、`exp11_div_unsigned` 等重复 IP。
4. 不重新配置新的乘法器或除法器 IP，除非确认仓库和 Git 历史中完全不存在原 `.xci`。
5. 不擅自修改 IP 的位宽、signed/unsigned、latency、pipeline stage 或接口配置。
6. 不删除或重建现有 Vivado 工程。
7. 优先复用 `exp10` 中已经存在并验证过的 `.xci`。
8. 所有自动化脚本应尽量使用相对仓库路径，避免写死 `D:/calab`。
9. 修改前先检查仓库现状，避免覆盖用户已有的同名公共 IP 或 Tcl 脚本。

---

## 第一步：搜索已有 IP

在整个仓库中搜索：

```text
exp10_mul33.xci
exp10_div_signed.xci
exp10_div_unsigned.xci
```

同时检查 Git 历史中是否曾存在这些文件。

可使用等价命令：

```bash
find . -type f \( \
  -name "exp10_mul33.xci" -o \
  -name "exp10_div_signed.xci" -o \
  -name "exp10_div_unsigned.xci" \
\)
```

如果当前工作树中未找到，再检查 Git：

```bash
git log --all --name-only -- "*.xci"
```

以及：

```bash
git log --all --name-status -- "**/exp10_mul33.xci" "**/exp10_div_signed.xci" "**/exp10_div_unsigned.xci"
```

如果文件只存在于 Git 历史，优先从原提交恢复，不要重新生成 IP。

---

## 第二步：检查原 IP 是否与当前代码匹配

找到 `.xci` 后，检查它们对应的 IP module name 是否确实为：

```text
exp10_mul33
exp10_div_signed
exp10_div_unsigned
```

同时检查：

- `mul_unit.v`
- `div_unit.v`

确认实例化名称没有变化。

不要修改 Verilog 以迁就错误的 `.xci`；应选择与当前实例化名称一致的原始 IP。

---

## 第三步：建立公共 IP 目录

在仓库根目录建立：

```text
common_ip/
```

目标结构：

```text
common_ip/
├── exp10_mul33/
│   └── exp10_mul33.xci
├── exp10_div_signed/
│   └── exp10_div_signed.xci
└── exp10_div_unsigned/
    └── exp10_div_unsigned.xci
```

将找到的三个原始 `.xci` 复制到上述位置。

不要复制整个 Vivado 自动生成工程目录。

如果 `.xci` 依赖额外的、无法由 Vivado 根据 `.xci` 自动重新生成的用户文件，则只复制实际必需的依赖，并在最终汇报中明确列出。

---

## 第四步：创建通用 Tcl 导入脚本

创建：

```text
scripts/add_common_ip.tcl
```

要求：

- 自动定位脚本所在目录；
- 从脚本目录推导仓库根目录；
- 检查三个 `.xci` 是否存在；
- 已经加入工程的 IP 不重复添加；
- 添加缺失 IP；
- 更新 compile order；
- 为三个 IP 生成 output products；
- 脚本重复执行不能因为重复添加而失败；
- 任何关键文件缺失时给出明确错误。

建议实现如下，可根据当前 Vivado 版本做必要的小幅兼容调整：

```tcl
# Common Vivado IP loader

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]

set ip_entries [list \
    [list "exp10_mul33" \
        [file join $repo_root "common_ip" "exp10_mul33" "exp10_mul33.xci"]] \
    [list "exp10_div_signed" \
        [file join $repo_root "common_ip" "exp10_div_signed" "exp10_div_signed.xci"]] \
    [list "exp10_div_unsigned" \
        [file join $repo_root "common_ip" "exp10_div_unsigned" "exp10_div_unsigned.xci"]] \
]

puts "============================================================"
puts "Loading common CPU IPs"
puts "Repository root: $repo_root"
puts "============================================================"

foreach entry $ip_entries {
    set ip_name [lindex $entry 0]
    set ip_file [file normalize [lindex $entry 1]]

    if {![file exists $ip_file]} {
        error "Required IP file does not exist: $ip_file"
    }

    set existing_ip [get_ips -quiet $ip_name]

    if {[llength $existing_ip] == 0} {
        puts "Adding IP: $ip_name"
        add_files -norecurse $ip_file
    } else {
        puts "IP already exists in project: $ip_name"
    }
}

update_compile_order -fileset sources_1

foreach entry $ip_entries {
    set ip_name [lindex $entry 0]
    set ip_obj [get_ips -quiet $ip_name]

    if {[llength $ip_obj] == 0} {
        error "Vivado cannot resolve IP object after adding XCI: $ip_name"
    }

    puts "Generating output products for: $ip_name"
    generate_target all $ip_obj
}

update_compile_order -fileset sources_1

puts "============================================================"
puts "Common CPU IP loading completed."
puts "============================================================"
```

如果发现 `get_ips` 在目标 Vivado 版本下对刚加入的 XCI 不能立即解析，可采用该版本兼容的工程刷新方式，但不要通过修改 IP 配置规避问题。

---

## 第五步：检查 `.gitignore`

检查仓库现有 `.gitignore`。

确保下列关键源文件不会被忽略：

```text
common_ip/**/*.xci
scripts/*.tcl
```

如果 `.gitignore` 当前会忽略 `.xci`，进行最小修改，使公共 IP 的 `.xci` 能被 Git 跟踪。

不要为了本任务大规模重写 `.gitignore`。

Vivado 自动生成内容如：

```text
*.cache
*.sim
*.runs
*.gen
*.ip_user_files
```

如果项目已经忽略它们，则保持现状即可。

---

## 第六步：静态校验

检查：

```text
mul_unit.v
div_unit.v
```

确认仍然实例化：

```text
exp10_mul33
exp10_div_signed
exp10_div_unsigned
```

检查：

```text
common_ip/exp10_mul33/exp10_mul33.xci
common_ip/exp10_div_signed/exp10_div_signed.xci
common_ip/exp10_div_unsigned/exp10_div_unsigned.xci
scripts/add_common_ip.tcl
```

均存在。

检查 Tcl 脚本引用路径与实际目录完全一致。

---

## 第七步：如果本机可调用 Vivado，则自动验证

先判断当前环境是否能够调用 Vivado，例如检查：

```bash
which vivado
```

或 Windows 环境中的等价命令。

如果 Vivado CLI 可用，则尽量使用 batch/Tcl 方式自动完成以下验证：

1. 打开当前 exp11 的 `.xpr`；
2. source `scripts/add_common_ip.tcl`；
3. 检查：
   ```tcl
   get_ips exp10_mul33
   get_ips exp10_div_signed
   get_ips exp10_div_unsigned
   ```
4. 确认三个 IP 均可解析；
5. 如果适合在当前环境中执行 Behavioral Simulation，则运行仿真；
6. 检查原来的三条 `VRFC 10-2063 Module not found` 是否消失。

不要因为环境缺失 GUI 而修改工程逻辑。

如果本机无法调用 Vivado，只完成文件和脚本层面的修复，并明确说明未进行实际 Vivado 验证。

---

## 第八步：如果找不到原 `.xci`

如果工作树和 Git 历史中都找不到三个 `.xci`，停止创建公共 IP 的动作，不要猜测 IP 参数。

此时执行以下调查：

1. 读取 `mul_unit.v` 中 `exp10_mul33` 的完整实例化接口；
2. 读取 `div_unit.v` 中 `exp10_div_signed` 和 `exp10_div_unsigned` 的完整实例化接口；
3. 搜索仓库中：
   - IP stub；
   - `.veo`；
   - `.vho`；
   - `.xml`；
   - `.xci`；
   - Tcl 创建脚本；
   - Vivado journal/log；
   - 旧实验工程；
4. 搜索是否有 `create_ip`、`set_property -dict`、`CONFIG.*` 等 Vivado Tcl 配置记录；
5. 根据实际证据整理出原 IP 参数，但不要自行重建。

若无法确定原 IP 配置，在最终结果中明确标记为阻塞项。

---

## 最终验收标准

至少应满足：

```text
common_ip/
├── exp10_mul33/
│   └── exp10_mul33.xci
├── exp10_div_signed/
│   └── exp10_div_signed.xci
└── exp10_div_unsigned/
    └── exp10_div_unsigned.xci

scripts/
└── add_common_ip.tcl
```

并且：

- `mul_unit.v` 未被无必要修改；
- `div_unit.v` 未被无必要修改；
- 三个原始 IP module name 未改变；
- Tcl 脚本不依赖固定的 `D:/calab`；
- Tcl 脚本可以重复执行；
- Tcl 脚本会检查缺失文件；
- Tcl 脚本会生成 IP output products；
- Git 能跟踪 `.xci` 和 `.tcl`；
- 如果实际运行 Vivado，则三个 `Module not found` 报错应消失。

---

## 最终汇报格式

完成后只汇报实际执行结果，至少包含：

1. 找到的三个原始 `.xci` 的原路径；
2. 新增的文件和目录；
3. 修改过的已有文件；
4. 是否修改过 `mul_unit.v` 或 `div_unit.v`；
5. 是否找到并保留了原 IP 参数；
6. Tcl 脚本采用的路径解析和重复执行策略；
7. 是否实际调用 Vivado；
8. 如果调用了 Vivado，`get_ips` 是否能找到三个 IP；
9. 如果运行了仿真，原来的三条 `Module not found` 是否消失；
10. 如果仍存在错误，给出新的第一条真实错误，不要只给最终的 `elaborate failed` 汇总信息。

禁止把“静态上看应该可以”写成“已经验证通过”。
