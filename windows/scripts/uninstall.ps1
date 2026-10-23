# Remove the Windows install (exe, autostart entry, URL scheme).
# With -Purge, also delete settings + history.
#
# Usage:
#   powershell -File scripts\uninstall.ps1           # remove install, keep data
#   powershell -File scripts\uninstall.ps1 -Purge    # also remove %APPDATA%\claude-limits
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

$Name = 'claude-limits'
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$Name"
$Exe = Join-Path $InstallDir "$Name.exe"
$DataDir = Join-Path $env:APPDATA $Name

# ── Stop running instance(s) ─────────────────────────────────────────────────
if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
    if (Test-Path $Exe) { & $Exe "${Name}://quit" }
    for ($i = 0; $i -lt 10 -and (Get-Process -Name $Name -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force
}

# ── Remove install: autostart entry, URL scheme, exe ─────────────────────────
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $Name -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "HKCU:\Software\Classes\$Name" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue

if ($Purge) { Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host "Removed $InstallDir, the autostart entry and the ${Name}:// URL scheme."
if ($Purge) {
    Write-Host "Settings + history also removed (-Purge)."
} else {
    Write-Host ''
    Write-Host "Kept: settings + history ($DataDir) — run with -Purge to remove them too."
}
