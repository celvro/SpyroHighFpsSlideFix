<#
.SYNOPSIS
    Summarizes airborne segments from a SpyroFpsProbe trace CSV for side-by-side comparison.

.DESCRIPTION
    For each segment id: framerate, horizontal distance when Spyro has dropped DropHeight below
    his takeoff height, movement-mode phases with start times, and horizontal/vertical speed
    stats while gliding (MovementMode 5). The "seg N" numbers come from the probe's log lines.

.EXAMPLE
    .\tools\Compare-Segments.ps1 -Trace build\probe\glide_charge.csv -Segments 83,86,89,92,97,100
#>
param(
    [Parameter(Mandatory)] [string] $Trace,
    [Parameter(Mandatory)] [int[]] $Segments,
    [double] $DropHeight = 90
)

$ErrorActionPreference = 'Stop'

# The game keeps the live trace open; read it with shared access.
$fs = [IO.File]::Open((Resolve-Path $Trace), 'Open', 'Read', 'ReadWrite')
try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
$rows = @($text | ConvertFrom-Csv)
$groups = $rows | Group-Object air -AsHashTable -AsString
$modeNames = @{ '1' = 'Walk'; '2' = 'NavWalk'; '3' = 'Fall'; '4' = 'Swim'; '5' = 'Fly'; '6' = 'Custom' }

function HSpeed($r) { [math]::Sqrt([double]$r.vx * [double]$r.vx + [double]$r.vy * [double]$r.vy) }

foreach ($id in $Segments) {
    $s = @($groups["$id"])
    if ($s.Count -eq 0 -or -not $s[0]) { Write-Output "seg ${id}: not in trace"; continue }

    # Measure from the last grounded frame; the first airborne frame has already risen one frame.
    $first = [array]::IndexOf($rows, $s[0])
    $base = if ($first -gt 0) { $rows[$first - 1] } else { $s[0] }
    $x0 = [double]$base.x; $y0 = [double]$base.y; $z0 = [double]$base.z; $t0 = [double]$base.time
    $phases = @(); $prev = $null
    foreach ($r in $s) {
        if ($r.move_mode -ne $prev) {
            $name = $modeNames[$r.move_mode]; if (-not $name) { $name = "Mode$($r.move_mode)" }
            $phases += "$name@$([math]::Round([double]$r.time - $t0, 3))"
            $prev = $r.move_mode
        }
    }

    $drop = $s | Where-Object { [double]$_.z -le $z0 - $DropHeight } | Select-Object -First 1
    $dist = if ($drop) { [math]::Round([math]::Sqrt(([double]$drop.x - $x0) * ([double]$drop.x - $x0) + ([double]$drop.y - $y0) * ([double]$drop.y - $y0)), 1) } else { 'n/a' }
    $fps = [math]::Round(1 / (($s | ForEach-Object { [double]$_.dt } | Measure-Object -Average).Average), 0)
    $apex = [math]::Round((($s | ForEach-Object { [double]$_.z } | Measure-Object -Maximum).Maximum) - $z0, 2)

    $line = "seg $id fps=$fps apex=+$apex dist@drop$DropHeight=$dist phases=$($phases -join ',')"
    $fly = @($s | Where-Object { $_.move_mode -eq '5' })
    if ($fly.Count -gt 0) {
        $h = $fly | ForEach-Object { HSpeed $_ } | Measure-Object -Average -Minimum -Maximum
        $vz = $fly | ForEach-Object { [double]$_.vz } | Measure-Object -Average -Minimum -Maximum
        $line += " glide=$([math]::Round([double]$fly[-1].time - [double]$fly[0].time, 3))s"
        $line += " glideH avg=$([math]::Round($h.Average, 1)) [$([math]::Round($h.Minimum, 1))..$([math]::Round($h.Maximum, 1))]"
        $line += " glideVz avg=$([math]::Round($vz.Average, 1)) [$([math]::Round($vz.Minimum, 1))..$([math]::Round($vz.Maximum, 1))]"
    }
    Write-Output $line
}
