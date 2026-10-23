# Capture current claude-limits (Windows) visual state into snapshots\windows\.
# Triggers in-app render via the claude-limits:// URL scheme — the app rebuilds
# its own views offscreen and renders them to PNG (no screen capture).
#
# Modes:
#   powershell -File scripts\snapshot.ps1                   # all (menubar + dropdown + settings)
#   powershell -File scripts\snapshot.ps1 --auto-menubar    # tray + pill only
#   powershell -File scripts\snapshot.ps1 --auto-dropdown   # flyout only
#   powershell -File scripts\snapshot.ps1 --auto-settings   # settings only
#   powershell -File scripts\snapshot.ps1 --auto-all        # alias for default
param([string]$Mode = '--auto-all')
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Dest = Join-Path $Root 'snapshots\windows'
New-Item -ItemType Directory -Force $Dest | Out-Null

function Trigger([string]$kind) {
    # Each trigger emits both light + dark; poll on the dark file.
    $watch = Join-Path $Dest "$kind-dark.png"
    $before = if (Test-Path $watch) { (Get-Item $watch).LastWriteTimeUtc } else { [DateTime]::MinValue }
    Start-Process "claude-limits://snapshot/${kind}?dest=$([uri]::EscapeDataString($Dest))"
    for ($i = 0; $i -lt 50; $i++) {
        if ((Test-Path $watch) -and (Get-Item $watch).LastWriteTimeUtc -ne $before) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "$kind capture didn't update $watch"
}

switch ($Mode) {
    '--auto-menubar'  { Trigger 'menubar' }
    '--auto-dropdown' { Trigger 'dropdown' }
    '--auto-settings' { Trigger 'settings' }
    '--auto-all'      { Trigger 'menubar'; Trigger 'dropdown'; Trigger 'settings' }
    default { Write-Host 'Usage: snapshot.ps1 [--auto-menubar|--auto-dropdown|--auto-settings|--auto-all]'; exit 2 }
}

Write-Host "Saved to $Dest. Open snapshots\index.html to view."
