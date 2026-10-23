# Code-size report: hand-written lines per language (non-blank; generated
# files — first line says "do not edit" — excluded), the Prolog share, and
# how many functions logic/core.pl defines, and the Windows exe size.
#   powershell -File scripts\metrics.ps1
$Root = Split-Path -Parent $PSScriptRoot
function Lines($glob) {
    $files = Get-ChildItem -Path $Root -Recurse -File -Include $glob |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|build)\\' -and (Get-Content $_.FullName -TotalCount 1) -notmatch 'do not edit' }
    ($files | ForEach-Object { (Get-Content $_.FullName | Where-Object { $_.Trim() }).Count } | Measure-Object -Sum).Sum
}
$swift = Lines '*.swift'; $cs = Lines @('*.cs', '*.xaml'); $pl = Lines '*.pl'
$total = $swift + $cs + $pl
$exe = Join-Path $Root 'build\windows\claude-limits.exe'
"swift    {0,6}" -f $swift
"c#/xaml  {0,6}" -f $cs
"prolog   {0,6}" -f $pl
"total    {0,6}   prolog share {1:P1}" -f $total, ($pl / $total)
"logic    {0,6} fns in logic/core.pl" -f (Select-String -Path (Join-Path $Root 'logic\core.pl') -Pattern '^:- fn ').Count
if (Test-Path $exe) { "exe      {0,6:N0} bytes" -f (Get-Item $exe).Length }
