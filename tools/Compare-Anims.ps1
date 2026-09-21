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

# A run is split across files: each game is its own segment (a restart is the only way to cross from one
# game into another, see tools/autotest.lua) and each restart stamps a new CSV. Stop numbers are the
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

# Segments of one run never repeat a stop, so a key seen twice means two files hold the same stop
# measured twice (two attempts at a run, not two segments of one). Merging those silently would make
# the later attempt overwrite the baseline and compare passes that were never run against each other.
$seen = @{}
$dupes = 0
foreach ($r in $rows) {
    $key = "$($r.cap)|$($r.stop)|$($r.t)|$($r.who)"
    if ($seen.ContainsKey($key)) { $dupes++ } else { $seen[$key] = $true }
}
if ($dupes -gt 0) {
    Write-Warning ("{0} samples are measured more than once across these files: they are repeats of the same stops, not segments of one run. Pass one file per stop range." -f $dupes)
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

$base = @{}
foreach ($r in $rows) {
    if ([int] $r.cap -ne $Baseline) { continue }
    $base["$($r.stop)|$($r.t)|$($r.who)"] = $r
}

$results = @()
foreach ($group in $rows | Where-Object { [int] $_.cap -ne $Baseline } | Group-Object cap, stop, who) {
    $sorted = $group.Group | Sort-Object { [double] $_.t }
    $first = $sorted[0]
    $matched = 0; $differ = 0; $shifted = 0; $stateDiffer = 0
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
            $dPos = [math]::Abs([double] $r.montagePos - [double] $b.montagePos)
            if ($dPos -gt $maxPos) { $maxPos = $dPos }
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
