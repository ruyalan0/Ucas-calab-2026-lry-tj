$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$names = @('exp10_mul33', 'exp10_div_signed', 'exp10_div_unsigned')
$entries = foreach ($name in $names) {
    @{ Source = Join-Path $repoRoot "exp10/soc_verify/soc_bram/rtl/xilinx_ip/$name/$name.xci";
       Target = Join-Path $repoRoot "common_ip/$name/$name.xci" }
}
$entries += @{ Source = Join-Path $PSScriptRoot 'add_common_ip.tcl'; Target = Join-Path $repoRoot 'scripts/add_common_ip.tcl' }
foreach ($entry in $entries) {
    if (!(Test-Path -LiteralPath $entry.Source)) { throw "Missing source: $($entry.Source)" }
    if ((Test-Path -LiteralPath $entry.Target) -and
        ((Get-FileHash -LiteralPath $entry.Source).Hash -ne (Get-FileHash -LiteralPath $entry.Target).Hash)) {
        throw "Existing target differs; refusing overwrite: $($entry.Target)"
    }
}
foreach ($entry in $entries) {
    New-Item -ItemType Directory -Force -Path (Split-Path $entry.Target) | Out-Null
    if (!(Test-Path -LiteralPath $entry.Target)) { Copy-Item -LiteralPath $entry.Source -Destination $entry.Target }
}
$projectFile = Join-Path $repoRoot 'exp11/soc_verify/soc_bram/run_vivado/project/loongson.xpr'
$backupFile = Join-Path $PSScriptRoot 'loongson.before_ip_fix.xpr.bak'
if (!(Test-Path -LiteralPath $backupFile)) { Copy-Item -LiteralPath $projectFile -Destination $backupFile }
Push-Location $PSScriptRoot
try {
    & 'D:/VIVADO2019.2/Vivado/2019.2/bin/vivado.bat' -mode batch -source verify_project.tcl -log verify_project.log -journal verify_project.jou
    if ($LASTEXITCODE) { throw 'Vivado validation failed; inspect verify_project.log' }
    if (!(Select-String -Path verify_project.log -Pattern 'COMMON_IP_VALIDATION_DONE')) { throw 'Validation incomplete' }
    $points = @(Select-String -Path verify_project.log -Pattern 'Functional Test Point PASS!!!')
    if ($points.Count -ne 46 -or !(Select-String -Path verify_project.log -Pattern '^----PASS!!!') -or
        (Select-String -Path verify_project.log -Pattern '^ERROR:|Error!!!|Fail!!!|Fatal:')) {
        throw 'Functional regression did not pass all 46 points; inspect verify_project.log'
    }
} finally { Pop-Location }
