# Build claude-limits.exe (Windows) into build\windows\
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Name = 'claude-limits'
$OutDir = Join-Path $Root 'build\windows'
$Proj = Join-Path $Root 'windows\claude-limits.csproj'

# Boundary check: windows\core\* must stay UI-free (no WPF / WinForms) — the spec
# tests (windows\tests\) compile it on its own, without WPF.
$hits = Select-String -Path (Join-Path $Root 'windows\core\*.cs') -Pattern 'System\.Windows|PresentationFramework' -List
if ($hits) {
    $hits | ForEach-Object { Write-Host $_.Path }
    Write-Error 'ERROR: WPF/WinForms references found in windows\core\ — core must stay headless.'
    exit 2
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error 'dotnet not found. Install the .NET SDK: winget install Microsoft.DotNet.SDK.10'
    exit 2
}

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
Write-Host '→ Compiling C#…'
dotnet build $Proj -c Release -o $OutDir --nologo -v quiet -clp:ErrorsOnly
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $OutDir "$Name.exe"
Write-Host "Built $exe"
Write-Host ('   size: {0:N0} bytes' -f (Get-Item $exe).Length)
