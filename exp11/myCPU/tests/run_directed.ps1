param([string]$VivadoBin = 'D:/VIVADO2019.2/Vivado/2019.2/bin',
      [string]$ArithmeticIp = (Join-Path $PSScriptRoot '../../../common_ip'))
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    python generate_directed.py
    if ($LASTEXITCODE) { throw 'Generation failed' }
    & "$VivadoBin/xvhdl.bat" "$ArithmeticIp/exp10_mul33/sim/exp10_mul33.vhd" "$ArithmeticIp/exp10_div_signed/sim/exp10_div_signed.vhd" "$ArithmeticIp/exp10_div_unsigned/sim/exp10_div_unsigned.vhd"
    if ($LASTEXITCODE) { throw 'IP compilation failed' }
    & "$VivadoBin/xvlog.bat" ../mycpu_top.v ../alu.v ../regfile.v ../tools.v ../mul_unit.v ../div_unit.v directed_tb.vh
    if ($LASTEXITCODE) { throw 'RTL compilation failed' }
    & "$VivadoBin/xelab.bat" directed_tb -L mult_gen_v12_0_16 -L div_gen_v5_1_16 -s directed_sim
    if ($LASTEXITCODE) { throw 'Elaboration failed' }
    & "$VivadoBin/xsim.bat" directed_sim -runall -log directed.log
    if ($LASTEXITCODE -or !(Select-String -Path directed.log -Pattern 'PASS directed:') -or (Select-String -Path directed.log -Pattern 'FAIL|Fatal:')) { throw 'Simulation failed' }
} finally { Pop-Location }
