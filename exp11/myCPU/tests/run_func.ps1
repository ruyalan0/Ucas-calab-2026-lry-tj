param([string]$VivadoBin = 'D:/VIVADO2019.2/Vivado/2019.2/bin',
      [string]$ArithmeticIp = (Join-Path $PSScriptRoot '../../../common_ip'))
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    python prepare_func.py
    if ($LASTEXITCODE) { throw 'Preparation failed' }
    & "$VivadoBin/xvhdl.bat" "$ArithmeticIp/exp10_mul33/sim/exp10_mul33.vhd" "$ArithmeticIp/exp10_div_signed/sim/exp10_div_signed.vhd" "$ArithmeticIp/exp10_div_unsigned/sim/exp10_div_unsigned.vhd"
    if ($LASTEXITCODE) { throw 'IP compilation failed' }
    & "$VivadoBin/xvlog.bat" ../mycpu_top.v ../alu.v ../regfile.v ../tools.v ../mul_unit.v ../div_unit.v func_tb.vh func_ram.vh ../../soc_verify/soc_bram/rtl/soc_lite_top.v ../../soc_verify/soc_bram/rtl/BRIDGE/bridge_1x2.v ../../soc_verify/soc_bram/rtl/CONFREG/confreg.v
    if ($LASTEXITCODE) { throw 'RTL compilation failed' }
    & "$VivadoBin/xelab.bat" tb_top -L mult_gen_v12_0_16 -L div_gen_v5_1_16 -s func_sim
    if ($LASTEXITCODE) { throw 'Elaboration failed' }
    & "$VivadoBin/xsim.bat" func_sim -runall -log func.log
    if ($LASTEXITCODE -or !(Select-String -Path func.log -Pattern '^----PASS!!!') -or (Select-String -Path func.log -Pattern 'Error|FAIL|Fail|Fatal:')) { throw 'Functional simulation failed' }
    $points = @(Select-String -Path func.log -Pattern 'Functional Test Point PASS!!!')
    if ($points.Count -ne 46) { throw "Expected 46 passing points, got $($points.Count)" }
} finally { Pop-Location }
