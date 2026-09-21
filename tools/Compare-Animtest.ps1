<#
.SYNOPSIS
    Compares the framerate passes of a montage sweep (the probe's animtest_<stamp>.csv).

.DESCRIPTION
    tools/animtest.lua plays every character animation at each framerate cap in turn, from the same
    standstill. An animation is the same asset at every framerate, so at 320 FPS it should take the same
    time, move the character the same distance with its root motion, and fire its notifies the same
    number of times as at 30. This joins the passes on the montage's asset path and lists the ones that
    differ, worst first.

    Flags per montage and cap:
      duration   one pass through the montage took more than -TimeTolerance seconds longer or less
      move       root-motion displacement differs by more than -MoveTolerance units (the rounding bugs)
      fx         the character's notifies made a different number of particle components
      audio      the same for audio components
      result     it ended on its own at one framerate and looped, stuck or lost its character at the other

.PARAMETER Path
    The CSV. Without it, the newest animtest_*.csv in the deployed probe folder.

.EXAMPLE
    .\tools\Compare-Animtest.ps1 -MoveTolerance 5
#>
param(
    [string] $Path,
    [double] $TimeTolerance = 0.05,
    [double] $MoveTolerance = 2,
    [int] $Baseline = 30,
    [int] $Top = 60,
    [switch] $All
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if (-not $Path) {
    $probeDir = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\Mods\SpyroFpsProbe'
    $newest = Get-ChildItem (Join-Path $probeDir 'animtest_*.csv') -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'animtest_samples_*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No animtest_*.csv in $probeDir; pass -Path." }
    $Path = $newest.FullName
}
Write-Host "Reading $Path"

$rows = Import-Csv $Path
$caps = $rows | ForEach-Object { [int] $_.cap } | Sort-Object -Unique
if ($caps -notcontains $Baseline) { throw "No $Baseline FPS pass in this run (caps: $($caps -join ', '))." }
Write-Host "Caps: $($caps -join ', '); baseline $Baseline"

# One baseline row per montage asset. A montage measured in several levels is kept once: the first row.
$base = @{}
foreach ($r in $rows) {
    if ([int] $r.cap -ne $Baseline) { continue }
    if (-not $base.ContainsKey($r.path)) { $base[$r.path] = $r }
}

$results = @()
foreach ($r in $rows) {
    $cap = [int] $r.cap
    if ($cap -eq $Baseline) { continue }
    $b = $base[$r.path]
    if (-not $b) { continue }

    $dDuration = [double] $r.duration - [double] $b.duration
    $dMove = [double] $r.moveDist - [double] $b.moveDist
    $dZ = [double] $r.moveZ - [double] $b.moveZ
    $dFx = [int] $r.fx - [int] $b.fx
    $dAudio = [int] $r.audio - [int] $b.audio

    $resultText = if ($r.result -eq $b.result) { $r.result } else { "$($b.result)->$($r.result)" }
    # A montage looping faster than one frame reads as standing still at the lower framerate and as
    # wrapping at the higher one, so its duration and verdict say more about the sampling than the game.
    $subFrame = $r.result -eq 'sub-frame loop' -or $b.result -eq 'sub-frame loop'
    $looping = @('looped', 'sub-frame loop')
    $flags = @()
    if (-not $subFrame -and [math]::Abs($dDuration) -gt $TimeTolerance) { $flags += 'duration' }
    if ([math]::Abs($dMove) -gt $MoveTolerance -or [math]::Abs($dZ) -gt $MoveTolerance) { $flags += 'move' }
    if ($dFx -ne 0) { $flags += 'fx' }
    if ($dAudio -ne 0) { $flags += 'audio' }
    if ($r.result -ne $b.result -and -not ($looping -contains $r.result -and $looping -contains $b.result)) {
        $flags += 'result'
    }

    $results += [pscustomobject] @{
        Cap       = $cap
        Class     = $r.class
        Montage   = $r.montage
        Length    = [math]::Round([double] $r.length, 3)
        Base      = [math]::Round([double] $b.duration, 3)
        Duration  = [math]::Round([double] $r.duration, 3)
        dTime     = [math]::Round($dDuration, 3)
        BaseMove  = [math]::Round([double] $b.moveDist, 1)
        Move      = [math]::Round([double] $r.moveDist, 1)
        dMove     = [math]::Round($dMove, 1)
        dZ        = [math]::Round($dZ, 1)
        Fx        = "$($b.fx)->$($r.fx)"
        Audio     = "$($b.audio)->$($r.audio)"
        Result    = $resultText
        Flags     = ($flags -join '+')
        Path      = $r.path
    }
}

$flagged = @($results | Where-Object { $_.Flags })
$shown = $flagged
if ($All) { $shown = $results }
$shown |
    Sort-Object @{ Expression = { [math]::Abs($_.dMove) }; Descending = $true },
                @{ Expression = { [math]::Abs($_.dTime) }; Descending = $true } |
    Select-Object -First $Top Cap, Class, Montage, Length, Base, Duration, dTime, BaseMove, Move, dMove, dZ, Fx, Audio, Result, Flags |
    Format-Table -AutoSize

Write-Host ""
Write-Host ("{0} of {1} montage/framerate pairs differ from the {2} FPS pass ({3} montages measured)." -f `
    $flagged.Count, $results.Count, $Baseline, $base.Count)
foreach ($g in $flagged | Group-Object Flags | Sort-Object Count -Descending) {
    Write-Host ("  {0}: {1}" -f $g.Name, $g.Count)
}
$noBaseline = ($rows | Where-Object { [int] $_.cap -ne $Baseline -and -not $base.ContainsKey($_.path) }).Count
if ($noBaseline -gt 0) {
    Write-Host ("  {0} rows had no {1} FPS row to compare against (the run stopped part way)." -f $noBaseline, $Baseline)
}
