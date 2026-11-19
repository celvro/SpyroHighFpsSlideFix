<#
.SYNOPSIS
    Frame time of the running game, from PresentMon: average/median/p99 frame time, CPU busy/wait and GPU busy.

.DESCRIPTION
    Uses the PresentMon 2.x that CapFrameX installs (or -PresentMon). PresentMon needs admin or membership of the
    "Performance Log Users" group. CPUBusy close to the frame time with GPUBusy well below it means the game is
    CPU-bound; frames bunching at one value with CPUWait rising means a cap outside the game (the driver's).
    docs/findings/frame-rate-ceiling.md has the method and the 2026-11-19 numbers.

.EXAMPLE
    .\tools\Measure-FrameTime.ps1 -Seconds 8 -Label probe-on
#>
param(
    [int] $Seconds = 8,
    [string] $Label = 'run',
    [string] $OutDir = (Join-Path $PSScriptRoot '..\build\frametime'),
    [string] $PresentMon = 'C:\Program Files (x86)\CapFrameX\PresentMon\PresentMon-2.2.0-x64.exe'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $PresentMon)) { throw "PresentMon not found: $PresentMon (pass -PresentMon)" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$csv = Join-Path (Resolve-Path $OutDir) ('{0}_{1}.csv' -f $Label, (Get-Date -Format yyyyMMdd_HHmmss))
$args = @('--process_name', 'Spyro-Win64-Shipping.exe', '--timed', $Seconds, '--terminate_after_timed',
          '--no_console_stats', '--stop_existing_session', '--output_file', "`"$csv`"")
$p = Start-Process -FilePath $PresentMon -ArgumentList $args -PassThru -WindowStyle Hidden
$null = $p.WaitForExit(($Seconds + 15) * 1000)
if (-not (Test-Path $csv)) { throw "PresentMon wrote no CSV (is the game running?)" }
$rows = @(Import-Csv $csv)
if ($rows.Count -lt 10) { throw "Only $($rows.Count) frames captured" }

function Get-Stat([string] $column) {
    $v = @($rows | ForEach-Object { [double]$_.$column } | Sort-Object)
    $avg = ($v | Measure-Object -Average).Average
    '{0} avg {1:N3} med {2:N3} p99 {3:N3}' -f $column, $avg, $v[[int]($v.Count / 2)], $v[[int]($v.Count * 0.99)]
}
$frame = ($rows | ForEach-Object { [double]$_.FrameTime } | Measure-Object -Average).Average
'{0}: {1} frames, {2:N1} FPS, {3}' -f $Label, $rows.Count, (1000 / $frame), (Get-Stat FrameTime)
'  {0} | {1}' -f (Get-Stat CPUBusy), (Get-Stat CPUWait)
'  {0} | {1}' -f (Get-Stat GPUBusy), (Get-Stat GPUWait)
'  present mode: {0}; csv {1}' -f (($rows | Group-Object PresentMode | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '), $csv
