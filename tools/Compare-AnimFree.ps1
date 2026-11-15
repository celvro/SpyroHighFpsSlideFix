<#
.SYNOPSIS
    Compares the framerate caps of a test room free phase (the probe's animtest_free_<stamp>.csv).

.DESCRIPTION
    tools/freetest.lua lets one character loose in the test room and has Spyro do one act to it (stand
    still, walk up, flame, charge, the same with a powerup) at each framerate cap. This groups the trials
    by act and powerups and compares each cap against the baseline: how far the character went, how fast,
    how high it was launched and for how long it was in the air, how long it took to react, and which
    states and montages it went through.

    With several tries per act the numbers are medians, and the spread between tries at the BASELINE cap
    is printed next to them: a framerate difference smaller than that spread is not one. Gameplay is not a
    controlled test (an AI picks its path, a launch depends on where the flame lands), so a flag here is a
    reason to run more tries, not a result.

.PARAMETER Path
    The CSV. Without it, the newest animtest_free_*.csv in the deployed probe folder.

.EXAMPLE
    .\tools\Compare-AnimFree.ps1 -Path build\animtest\20261114_160000_Cowlek\animtest_free.csv
#>
param(
    [string] $Path,
    [int] $Baseline = 30
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if (-not $Path) {
    $newest = Get-ChildItem (Join-Path $ProbeDir 'animtest_free_*.csv') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No animtest_free_*.csv in $ProbeDir; pass -Path." }
    $Path = $newest.FullName
}
Write-Host "Reading $Path"
$rows = @(Import-Csv $Path)
if (-not $rows) { throw 'No trials in the file.' }

function Median([double[]] $values) {
    $v = @($values | Sort-Object)
    if ($v.Count -eq 0) { return [double]::NaN }
    if ($v.Count % 2) { return $v[[int][math]::Floor($v.Count / 2)] }
    return ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2
}
function Spread([double[]] $values) {
    if ($values.Count -lt 2) { return 0 }
    return ($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum
}
function StateNames([string] $states) {
    (($states -split '>') | ForEach-Object { ($_ -split ':')[0] }) -join '>'
}
function Summary($trials) {
    $num = { param($name) @($trials | ForEach-Object { [double] $_.$name }) }
    $react = @($trials | Where-Object { $_.react } | ForEach-Object { [double] $_.react })
    [pscustomobject] @{
        Tries     = $trials.Count
        Result    = (($trials | Group-Object result | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' ')
        Path      = Median (& $num 'path');  PathSpread = Spread (& $num 'path')
        Net       = Median (& $num 'net')
        Vmax      = Median (& $num 'vmax');  VmaxSpread = Spread (& $num 'vmax')
        ZMax      = Median (& $num 'zMax');  ZSpread = Spread (& $num 'zMax')
        Air       = Median (& $num 'air');   AirSpread = Spread (& $num 'air')
        React     = if ($react) { Median $react } else { [double]::NaN }
        AvgFps    = Median (& $num 'avgFps')
        States    = (($trials | ForEach-Object { StateNames $_.states } | Sort-Object -Unique) -join ' | ')
        Montages  = (($trials | ForEach-Object { $_.montages -split '>' } | Where-Object { $_ } | Sort-Object -Unique) -join ',')
        NaN       = [bool] ($trials | Where-Object { $_.animSpeedNaN -eq 'true' })
    }
}

$caps = @($rows | ForEach-Object { [int] $_.cap } | Sort-Object -Unique)
if ($caps -notcontains $Baseline) { throw "No $Baseline FPS trials (caps: $($caps -join ', '))." }
$out = @()
$flagged = 0
foreach ($group in $rows | Group-Object { "$($_.act)|$($_.powers)" }) {
    $act, $powers = $group.Name -split '\|', 2
    $base = Summary @($group.Group | Where-Object { [int] $_.cap -eq $Baseline })
    $label = if ($powers) { "$act (+$powers)" } else { $act }
    Write-Host ""
    Write-Host ("== {0}: {1} FPS baseline, {2} tries, {3}" -f $label, $Baseline, $base.Tries, $base.Result)
    if ($base.Result -match '^stillx\d+$' -and $act -eq 'idle') {
        Write-Host '   it never moved on its own: with arena=sky a character that paths by navmesh has none; try arena=level'
    }
    foreach ($cap in $caps | Where-Object { $_ -ne $Baseline }) {
        $trials = @($group.Group | Where-Object { [int] $_.cap -eq $cap })
        if (-not $trials) { continue }
        $s = Summary $trials
        $flags = @()
        $check = {
            param($name, $a, $b, $abs, $rel, $spread)
            if ([double]::IsNaN($a) -or [double]::IsNaN($b)) { return }
            $limit = [math]::Max([math]::Max($abs, $rel * [math]::Abs($a)), $spread)
            if ([math]::Abs($b - $a) -gt $limit) { $script:flags += $name }
        }
        & $check 'path' $base.Path $s.Path 25 0.15 $base.PathSpread
        & $check 'vmax' $base.Vmax $s.Vmax 15 0.05 $base.VmaxSpread
        & $check 'height' $base.ZMax $s.ZMax 15 0.10 $base.ZSpread
        & $check 'air' $base.Air $s.Air 0.1 0 $base.AirSpread
        & $check 'react' $base.React $s.React 0.1 0 0
        if ($s.Result -ne $base.Result -and $base.Tries -eq $s.Tries) { $flags += 'result' }
        if ($s.States -ne $base.States) { $flags += 'states' }
        if ($s.Montages -ne $base.Montages) { $flags += 'montages' }
        if ($s.NaN -and -not $base.NaN) { $flags += 'NaN speed' }
        if ($flags) { $flagged++ }
        $out += [pscustomobject] @{
            Act = $label; Cap = $cap; Result = $s.Result
            Path = '{0:N0} / {1:N0}' -f $base.Path, $s.Path
            Vmax = '{0:N0} / {1:N0}' -f $base.Vmax, $s.Vmax
            Height = '{0:N0} / {1:N0}' -f $base.ZMax, $s.ZMax
            Air = '{0:N2} / {1:N2}' -f $base.Air, $s.Air
            React = '{0:N2} / {1:N2}' -f $base.React, $s.React
            Fps = '{0:N0}' -f $s.AvgFps
            Flags = $flags -join '+'
        }
        Write-Host ("   states  {0,4}: {1}" -f $Baseline, $base.States)
        Write-Host ("           {0,4}: {1}" -f $cap, $s.States)
        Write-Host ("   montages{0,4}: {1}" -f $Baseline, $base.Montages)
        Write-Host ("           {0,4}: {1}" -f $cap, $s.Montages)
        if ($base.Tries -gt 1) {
            Write-Host ("   spread over the {0} FPS tries: path {1:N0}, vmax {2:N0}, height {3:N0}, air {4:N2} s" -f
                $Baseline, $base.PathSpread, $base.VmaxSpread, $base.ZSpread, $base.AirSpread)
        }
    }
}
Write-Host ""
Write-Host "Baseline / cap (medians):"
$out | Format-Table Act, Cap, Result, Path, Vmax, Height, Air, React, Fps, Flags -AutoSize | Out-String -Width 300 | Write-Host
Write-Host ("{0} of {1} act/framerate pairs differ from the {2} FPS trials." -f $flagged, $out.Count, $Baseline)
