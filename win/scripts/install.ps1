# Build, install to %LOCALAPPDATA%\Programs\claude-limits, register autostart +
# the claude-limits:// URL scheme, start it, and refresh repo snapshots.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Name = 'claude-limits'
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$Name"
$Exe = Join-Path $InstallDir "$Name.exe"
$Built = Join-Path $Root "build\win\$Name.exe"

& (Join-Path $PSScriptRoot 'build.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '→ Stopping any running instance…'
if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
    # Ask politely first (removes the tray icon cleanly), then force.
    & $Built "${Name}://quit"
    for ($i = 0; $i -lt 10 -and (Get-Process -Name $Name -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
}

Write-Host "→ Installing → $Exe"
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item $Built $Exe -Force

Write-Host '→ Registering autostart (HKCU Run) + URL scheme…'
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $Name -Value "`"$Exe`""
$cls = "HKCU:\Software\Classes\$Name"
New-Item -Force "$cls\shell\open\command" | Out-Null
Set-ItemProperty $cls -Name '(default)' -Value "URL:$Name"
Set-ItemProperty $cls -Name 'URL Protocol' -Value ''
Set-ItemProperty "$cls\shell\open\command" -Name '(default)' -Value "`"$Exe`" `"%1`""

Write-Host '→ Starting…'
Start-Process $Exe
Start-Sleep -Seconds 2
$n = @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count
if ($n -eq 1) {
    Write-Host "'$Name' is running. Look for it in your system tray."
    Write-Host "Logs: Get-Content -Wait $env:TEMP\$Name.log"
} elseif ($n -gt 1) {
    Write-Warning "multiple instances detected ($n). Check Get-Process $Name."
    exit 0
} else {
    Write-Warning "process didn't start — check $env:TEMP\$Name.log"
    exit 0
}

# Refresh repo snapshots so the working tree always reflects the just-built UI.
# Snapshot capture failure ≠ install failure — log and continue.
Write-Host '→ Refreshing snapshots\win\…'
try { & (Join-Path $PSScriptRoot 'snapshot.ps1') }
catch { Write-Host '  (snapshot capture failed; install itself succeeded)' }
