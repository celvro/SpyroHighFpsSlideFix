<#
.SYNOPSIS
    Compares what the characters were animating in each framerate pass of a scripted tour
    (the probe's autotest_anims_<stamp>.csv).

.DESCRIPTION
    Every pass plays the same input script from the same teleport, so at each sample time the played
    character and the character the stop was recorded in front of should be in the same animation, the
    same distance into it, and in the same enemy state as they were at 30 FPS. This joins the passes on
    (stop, t, who) and reports, per stop and character, how often that is not the case.

    Columns: Differ is the share of samples playing an animation the baseline was not playing at that
    sample or either side of it; Shift is the share that played the baseline's animation one sample early
    or late, which is a timing difference rather than a different animation; State is the share of samples
    in a different enemy state; Drift is the largest difference in how far into the montage they were
    while both played the same one, over the largest distance between where that character had moved to.
    Stop is the level and the route stop number, and stops are listed worst first.

    A live level is not a controlled test: enemies wander, Spyro is knocked about, and a target that
    strolled off gives a large move distance with nothing wrong. Read this as a screen for stops worth
    looking at (and re-running), not as a verdict; tools/Compare-Animtest.ps1 is the controlled measurement.

.PARAMETER Path
    The CSVs, wildcards allowed. Without it, the newest autotest_anims_*.csv in the deployed probe
    folder. A whole run is several files, one per game segment: pass them all.

.EXAMPLE
    .\tools\Compare-Anims.ps1 -Who target

.EXAMPLE
    .\tools\Compare-Anims.ps1 -Path "...\SpyroFpsProbe\autotest_anims_*.csv"
#>
param(
    [string[]] $Path,
    [ValidateSet('both', 'player', 'target')]
    [string] $Who = 'both',
    [double] $PosTolerance = 0.05,
    [double] $MoveTolerance = 10,
    [int] $Baseline = 30,
    [int] $Top = 40
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

# A run is split across files: each restart stamps a new CSV (and runs before 2026-09-22 split at each game,
# when a restart was the only way from one game into the next; tools/worldtour/). Stop numbers are the
# route's own in every segment, so several files join into one comparison.
if (-not $Path) {
    $probeDir = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\Mods\SpyroFpsProbe'
    $newest = Get-ChildItem (Join-Path $probeDir 'autotest_anims_*.csv') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No autotest_anims_*.csv in $probeDir; pass -Path." }
    $Path = @($newest.FullName)
}
$files = @($Path | ForEach-Object { Get-ChildItem $_ -ErrorAction Stop } | Select-Object -ExpandProperty FullName -Unique)
Write-Host "Reading $($files.Count) file(s):"
foreach ($f in $files) { Write-Host "  $f" }

$rows = @($files | ForEach-Object { Import-Csv $_ })
if ($Who -ne 'both') { $rows = $rows | Where-Object { $_.who -eq $Who } }
$caps = $rows | ForEach-Object { [int] $_.cap } | Sort-Object -Unique
if ($caps -notcontains $Baseline) { throw "No $Baseline FPS pass in this run (caps: $($caps -join ', '))." }
Write-Host "Caps: $($caps -join ', '); baseline $Baseline; characters: $Who"

# A stop that is retried writes its samples twice: the recovery for a conversation that will not close
# loads the level and plays the stop again, and the abandoned attempt is already in the CSV. Keep the
# last of each (cap, stop, t, who), which is the attempt that ran to the end. Mixing two separate runs
# of the same stops collapses the same way, so pass one file per stop range if that is what you have.
$byKey = [ordered] @{}
$dupes = 0
foreach ($r in $rows) {
    $key = "$($r.cap)|$($r.stop)|$($r.t)|$($r.who)"
    if ($byKey.Contains($key)) { $dupes++ }
    $byKey[$key] = $r
}
if ($dupes -gt 0) {
    Write-Host ("Dropped {0} samples of abandoned attempts (a stop retried after a level reload writes twice)." -f $dupes)
    $rows = @($byKey.Values)
}
# A montage played through a slot rather than from an asset is a runtime object named AnimMontage_<n>,
# where n is a counter that keeps climbing for as long as the game is running. The 30 FPS pass got
# AnimMontage_0..9 and the 320 pass AnimMontage_33..41 for the same NPC dialogue, so comparing the names
# marked every one of those samples as a different animation. The counter is not an identity: all of them
# compare as one token, and how far into it they were still tells them apart.
function Get-MontageKey($name) {
    if ($name -match '^AnimMontage_\d+$') { return '(dynamic)' }
    return $name
}
foreach ($r in $rows) { $r.montage = Get-MontageKey $r.montage }

# A looping montage is at a different point in its loop in each pass, because the character started
# looping at a different moment: 484 of 1398 montage runs in the Spyro 2 segment wrapped, and comparing
# their positions said a box turtle idle was 10 seconds apart when nothing was wrong. What is worth
# comparing for those is how fast the position advances, so each run keeps the median step it made
# between samples, and runs that wrapped are timed by that instead of by where they happened to be.
$runs = @{}
foreach ($r in $rows) {
    if ($r.montage -eq '' -or $r.montage -eq '(dynamic)') { continue }
    $k = "$($r.cap)|$($r.stop)|$($r.who)|$($r.montage)"
    if (-not $runs.ContainsKey($k)) { $runs[$k] = [pscustomobject]@{ Last = $null; Steps = [System.Collections.Generic.List[double]]::new(); Looped = $false } }
    $run = $runs[$k]
    $pos = [double] $r.montagePos
    if ($null -ne $run.Last) {
        $step = $pos - $run.Last
        if ($step -lt -0.001) { $run.Looped = $true } elseif ($step -ge 0) { $run.Steps.Add($step) }
    }
    $run.Last = $pos
}
function Get-Advance($key) {
    $run = $runs[$key]
    if (-not $run -or $run.Steps.Count -lt 5) { return $null }
    # The mean, not the median: at 30 FPS the montage moves in 33 ms chunks, so a single step between
    # two samples is quantised and a median lands either side of the truth for no reason (a sheep walk
    # read 0.09 against 0.1004 on that alone). Averaging the run cancels it, and a montage genuinely
    # running at a different speed still shows.
    $sum = 0.0
    foreach ($s in $run.Steps) { $sum += $s }
    return $sum / $run.Steps.Count
}
function Test-Looped($key) { $run = $runs[$key]; return ($null -ne $run -and $run.Looped) }

$base = @{}
foreach ($r in $rows) {
    if ([int] $r.cap -ne $Baseline) { continue }
    $base["$($r.stop)|$($r.t)|$($r.who)"] = $r
}

$results = @()
foreach ($group in $rows | Where-Object { [int] $_.cap -ne $Baseline } | Group-Object cap, stop, who) {
    $sorted = $group.Group | Sort-Object { [double] $_.t }
    $first = $sorted[0]
    $matched = 0; $differ = 0; $shifted = 0; $stateDiffer = 0; $looped = @{}
    $maxPos = 0.0; $maxMove = 0.0
    $firstDiffer = $null
    foreach ($r in $sorted) {
        $b = $base["$($r.stop)|$($r.t)|$($r.who)"]
        if (-not $b) { continue }
        $matched++
        if ($r.montage -ne $b.montage) {
            # The baseline one sample earlier or later: the same animation, started at a slightly
            # different moment, which is what a 0.1 s sample grid does to a montage that begins between
            # two samples. Counted apart from playing something else entirely.
            $t = [double] $r.t
            $before = $base["$($r.stop)|$(('{0:0.000}' -f ($t - 0.1)))|$($r.who)"]
            $after = $base["$($r.stop)|$(('{0:0.000}' -f ($t + 0.1)))|$($r.who)"]
            if (($before -and $before.montage -eq $r.montage) -or ($after -and $after.montage -eq $r.montage)) {
                $shifted++
            } else {
                $differ++
                if ($null -eq $firstDiffer) { $firstDiffer = "$($t)s $($b.montage)->$($r.montage)" }
            }
        } else {
            # Only a montage that played straight through can be compared by where it had got to. One
            # that wrapped is compared by how fast it advances instead, after the loop.
            $rk = "$($r.cap)|$($r.stop)|$($r.who)|$($r.montage)"
            $bk = "$($b.cap)|$($b.stop)|$($b.who)|$($b.montage)"
            if ((Test-Looped $rk) -or (Test-Looped $bk)) {
                $looped[$rk] = $bk
            } else {
                $dPos = [math]::Abs([double] $r.montagePos - [double] $b.montagePos)
                if ($dPos -gt $maxPos) { $maxPos = $dPos }
            }
        }
        if ($r.state -ne $b.state) { $stateDiffer++ }
        $d = [math]::Sqrt([math]::Pow([double] $r.x - [double] $b.x, 2) +
                          [math]::Pow([double] $r.y - [double] $b.y, 2) +
                          [math]::Pow([double] $r.z - [double] $b.z, 2))
        if ($d -gt $maxMove) { $maxMove = $d }
    }
    if ($matched -eq 0) { continue }
    $results += [pscustomobject] @{
        Cap     = [int] $first.cap
        Level   = $first.level
        Stop    = "$($first.level)#$($first.stop)"
        Number  = [int] $first.stop
        Script  = $first.script
        Who     = $first.who
        Class   = $first.class
        Samples = $matched
        Differ  = [math]::Round(100 * $differ / $matched, 0)
        Shift   = [math]::Round(100 * $shifted / $matched, 0)
        dPos    = [math]::Round($maxPos, 3)
        dMove   = [math]::Round($maxMove, 1)
        State   = [math]::Round(100 * $stateDiffer / $matched, 0)
        Drift   = "{0:0.00}/{1:0.0}" -f $maxPos, $maxMove
        First   = $firstDiffer
    }
}

$shown = $results | Sort-Object Differ, dMove -Descending | Select-Object -First $Top
$shown |
    Select-Object Cap, Stop, Script, Who, Class, Samples, Differ, Shift, State, Drift |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$bad = @($results | Where-Object { $_.Differ -gt 0 -or $_.dPos -gt $PosTolerance -or $_.dMove -gt $MoveTolerance })
Write-Host ""
Write-Host ("{0} of {1} stop/character/framerate groups differ from the {2} FPS pass (a different
animation, a different distance into it, or somewhere else by the end)." -f `
    $bad.Count, $results.Count, $Baseline)
foreach ($g in $bad | Group-Object Script | Sort-Object Count -Descending) {
    Write-Host ("  {0}: {1} ({2})" -f $g.Name, $g.Count,
        (($g.Group | ForEach-Object { "$($_.Class)@$($_.Cap)" } | Select-Object -Unique -First 6) -join ', '))
}

# Where each flagged group first played something the baseline was not playing: the sample time and the
# swap, which is the one line worth reading before deciding whether a stop is worth re-running.
$firsts = @($shown | Where-Object { $_.First })
if ($firsts) {
    Write-Host ""
    Write-Host "First animation that differs:"
    foreach ($r in $firsts) {
        Write-Host ("  {0} {1} {2} {3}: {4}" -f $r.Stop, $r.Script, $r.Who, $r.Class, $r.First)
    }
}

# Looping montages, compared by how fast they advance rather than by where they were. A montage that
# runs at a different speed at a high framerate is the thing this whole investigation is looking for,
# and a loop is the one case where the position alone cannot show it.
$rates = @()
foreach ($k in $runs.Keys) {
    $parts = $k -split '\|'
    if ([int] $parts[0] -eq $Baseline) { continue }
    $bk = "$Baseline|$($parts[1])|$($parts[2])|$($parts[3])"
    if (-not $runs.ContainsKey($bk)) { continue }
    $a = Get-Advance $k
    $b = Get-Advance $bk
    # Only montages that are actually running, and with enough samples to average: a Damage_Flatten that
    # creeps along at 0.01 a sample is barely advancing at all, and the ratio of two numbers that small
    # says nothing. Half real time is the bar, over at least ten steps.
    if ($null -eq $a -or $null -eq $b -or $b -lt 0.05) { continue }
    if ($runs[$k].Steps.Count -lt 10 -or $runs[$bk].Steps.Count -lt 10) { continue }
    $rates += [pscustomobject] @{
        Cap     = [int] $parts[0]
        Stop    = $parts[1]
        Who     = $parts[2]
        Montage = $parts[3]
        Base    = [math]::Round($b, 4)
        This    = [math]::Round($a, 4)
        Ratio   = [math]::Round($a / $b, 3)
    }
}
if ($rates.Count -gt 0) {
    $off = @($rates | Where-Object { $_.Ratio -lt 0.95 -or $_.Ratio -gt 1.05 })
    Write-Host ""
    Write-Host ("Montage advance per sample, {0} runs compared against {1} FPS: {2} differ by more than 5%." -f
        $rates.Count, $Baseline, $off.Count)
    if ($off.Count -gt 0) {
        $off | Sort-Object { [math]::Abs($_.Ratio - 1) } -Descending |
            Select-Object -First 15 Cap, Stop, Who, Montage, Base, This, Ratio |
            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
}
