# Build claude-limits.exe (Windows) into build\win\
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Name = 'claude-limits'
$OutDir = Join-Path $Root 'build\win'
$Proj = Join-Path $Root 'src\win\claude-limits.csproj'

# Boundary check: src\win\core\* must stay UI-free (no WPF / WinForms), the
# same rule build.sh enforces for src/core/ and AppKit.
$hits = Select-String -Path (Join-Path $Root 'src\win\core\*.cs') -Pattern 'System\.Windows|PresentationFramework' -List
if ($hits) {
    $hits | ForEach-Object { Write-Host $_.Path }
    Write-Error 'ERROR: WPF/WinForms references found in src\win\core\ — core must stay headless.'
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
