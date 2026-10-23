# Render the Windows UI into snapshots\win\ from spec\fixtures\snapshot.json.
#
# Runs the built exe in fixture mode (canned response, pinned clock, no
# network, no settings/history writes), which renders menubar + dropdown +
# settings in light + dark and exits. Same images on every machine and in CI.
#
#   powershell -File win\scripts\snapshot.ps1              # uses build\win\claude-limits.exe
#   powershell -File win\scripts\snapshot.ps1 -Exe C:\path\claude-limits.exe
param([string]$Exe)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Exe) { $Exe = Join-Path $Root 'build\win\claude-limits.exe' }
# CI writes the committed PNGs; local renders go under build\ so font and
# encoder differences between machines don't churn snapshots\.
$Dest = if ($env:CI) { Join-Path $Root 'snapshots\win' } else { Join-Path $Root 'build\snapshots\win' }
$Fixture = Join-Path $Root 'spec\fixtures\snapshot.json'
New-Item -ItemType Directory -Force $Dest | Out-Null

$p = Start-Process -FilePath $Exe -ArgumentList @('--fixture', "`"$Fixture`"", '--snapshot-all', "`"$Dest`"") -PassThru
if (-not $p.WaitForExit(30000)) {
    $p.Kill()
    throw 'snapshot render timed out'
}
if ($p.ExitCode -ne 0) { throw "snapshot render failed (exit $($p.ExitCode)) — see $env:TEMP\claude-limits.log" }
foreach ($k in 'menubar', 'dropdown', 'settings') {
    if (-not (Test-Path (Join-Path $Dest "$k-dark.png"))) { throw "missing $k-dark.png — see $env:TEMP\claude-limits.log" }
}

Write-Host "Saved to $Dest. Open snapshots\index.html to view."
