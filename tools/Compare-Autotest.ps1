<#
.SYNOPSIS
    Compares the framerate passes of a scripted tour run (the probe's autotest_<stamp>.csv).

.DESCRIPTION
    Every pass plays the same input script from the same teleport, so at each sample time the character
    should be in the same place and the camera at the same angle as at 30 FPS. This joins the passes on
    (level, stop, script, t) and reports, per stop, how far the other framerates end up from the 30 FPS
    run: the largest distance during the script, the distance at the end, and the largest camera yaw and
    pitch difference. Stops are listed worst first.

    Position is measured from the stop, so it does not matter that a level streams in at a different
    offset each load. -Tolerance only changes which rows are called out, not what is measured.

.PARAMETER Path
    The CSV. Without it, the newest autotest_*.csv in the deployed probe folder.

.EXAMPLE
    .\tools\Compare-Autotest.ps1 -Tolerance 20
#>
param(
    [string] $Path,
    [double] $Tolerance = 10,
    [int] $Baseline = 30,
    [int] $Top = 40,
    [double] $FloorFactor = 3
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if (-not $Path) {
    $probeDir = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\Mods\SpyroFpsProbe'
    $newest = Get-ChildItem (Join-Path $probeDir 'autotest_*.csv') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No autotest_*.csv in $probeDir; pass -Path." }
    $Path = $newest.FullName
}
Write-Host "Reading $Path"

$rows = Import-Csv $Path

# A run whose samples were taken before he was placed is thrown away, not compared.
#
# The teleport does not always take effect in the second play.lua spends settling: in the 2026-11-04
# trilogy run, 349 of 3733 runs (9%) spent their first second or so still standing where the last stop
# left them, 3000-odd units away, with the camera not yet placed anywhere near him (camDist in the
# hundreds of thousands, against about 150 in gameplay). The stop's origin is taken at the start of the
# script, so that whole run is offset by the distance between the two places, and the input was driven
# at the old one. Nothing in it can be repaired: the drift it reports is the teleport, and the samples
# are of the wrong place. It showed up as the loudest findings in the report (17 of the 21 stops in the
# first table), and because the number of frames the teleport takes depends on the framerate -- 11% of
# the 30 FPS runs against 7% of the 160 FPS ones -- it looked exactly like a framerate difference.
$PLACED_CAM = 1000      # units from him the camera can be before he is clearly not placed yet
$unplaced = @{}
foreach ($r in $rows) {
    if ([double] $r.camDist -gt $PLACED_CAM) { $unplaced["$($r.pass)|$($r.stop)|$($r.script)"] = $true }
}
if ($unplaced.Count -gt 0) {
    $before = $rows.Count
    $rows = @($rows | Where-Object { -not $unplaced.ContainsKey("$($_.pass)|$($_.stop)|$($_.script)") })
    $spots = @($unplaced.Keys | ForEach-Object { $p = $_ -split '\|'; "$($p[1]) $($p[2])" } | Sort-Object -Unique)
    Write-Host (("Dropped {0} run(s) of {1} stop(s) whose samples start before the teleport landed " +
        '({2} of {3} rows). Those stops are measured by their remaining passes only: {4}') -f `
        $unplaced.Count, $spots.Count, ($before - $rows.Count), $before,
        (($spots | Select-Object -First 10) -join ', '))
}

# The cap is not an identity: a run asked for caps=30,30,60,160 has two passes that both say 30, and the
# second one is the point -- it is how far a stop lands from ITSELF, the noise floor every other pass has
# to beat to be a finding. The `pass` column tells them apart; a CSV written before that column existed
# (before 2026-11-04) has one pass per cap, so the cap stands in for it.
$hasPass = $null -ne $rows[0].PSObject.Properties['pass']
if (-not $hasPass) {
    Write-Host 'This CSV has no pass column (written before 2026-11-04); treating each cap as one pass.'
    foreach ($r in $rows) { Add-Member -InputObject $r -NotePropertyName pass -NotePropertyValue $r.cap -Force }
}
$passes = @($rows | Group-Object pass | ForEach-Object {
    [pscustomobject] @{ Pass = $_.Name; Cap = [int] $_.Group[0].cap }
} | Sort-Object { [int] $_.Pass })
$basePass = @($passes | Where-Object { $_.Cap -eq $Baseline } | Select-Object -First 1)
if ($basePass.Count -eq 0) {
    throw "No $Baseline FPS pass in this run (passes: $(($passes | ForEach-Object { "$($_.Pass)=$($_.Cap)" }) -join ', '))."
}
$basePass = $basePass[0].Pass
Write-Host ("Passes: {0}; baseline is pass {1} at {2} FPS" -f `
    (($passes | ForEach-Object { "$($_.Pass)=$($_.Cap)FPS" }) -join ', '), $basePass, $Baseline)

# Key every baseline sample by stop and time, so the other passes can look their own sample up.
$base = @{}
$baseMove = @{}
foreach ($r in $rows) {
    if ($r.pass -ne $basePass) { continue }
    $base["$($r.stop)|$($r.script)|$($r.t)"] = $r
    # Positions are relative to the stop, so this is simply how far the baseline pass got.
    $d = [math]::Sqrt([math]::Pow([double] $r.x, 2) + [math]::Pow([double] $r.y, 2) + [math]::Pow([double] $r.z, 2))
    $mk = "$($r.stop)|$($r.script)"
    if (-not $baseMove.ContainsKey($mk) -or $d -gt $baseMove[$mk]) { $baseMove[$mk] = $d }
}

$results = @()
foreach ($group in $rows | Where-Object { $_.pass -ne $basePass } | Group-Object pass, stop, script) {
    $sorted = $group.Group | Sort-Object { [double] $_.t }
    $first = $sorted[0]
    $maxDist = 0.0; $maxYaw = 0.0; $maxPitch = 0.0; $endDist = $null; $matched = 0
    foreach ($r in $sorted) {
        $b = $base["$($r.stop)|$($r.script)|$($r.t)"]
        if (-not $b) { continue }
        $matched++
        $d = [math]::Sqrt([math]::Pow([double] $r.x - [double] $b.x, 2) +
                          [math]::Pow([double] $r.y - [double] $b.y, 2) +
                          [math]::Pow([double] $r.z - [double] $b.z, 2))
        # Angles wrap: 359 and 1 are two degrees apart.
        $dy = [math]::Abs((([double] $r.camYaw - [double] $b.camYaw) + 540) % 360 - 180)
        $dp = [math]::Abs((([double] $r.camPitch - [double] $b.camPitch) + 540) % 360 - 180)
        if ($d -gt $maxDist) { $maxDist = $d }
        if ($dy -gt $maxYaw) { $maxYaw = $dy }
        if ($dp -gt $maxPitch) { $maxPitch = $dp }
        $endDist = $d
    }
    if ($matched -eq 0) { continue }
    $results += [pscustomobject] @{
        Pass     = [int] $first.pass
        Cap      = [int] $first.cap
        Level    = $first.level
        Stop     = [int] $first.stop
        Script   = $first.script
        Note     = $first.note
        Samples  = $matched
        MaxDist  = [math]::Round($maxDist, 1)
        EndDist  = [math]::Round($endDist, 1)
        MaxCamYaw = [math]::Round($maxYaw, 1)
        MaxCamPitch = [math]::Round($maxPitch, 1)
    }
}

$results | Sort-Object MaxDist -Descending | Select-Object -First $Top | Format-Table -AutoSize

# The findings, and the only part of this worth reading first.
#
# A stop's own noise floor is what the SECOND pass at the baseline framerate did on it: the same input
# script at the same framerate, so whatever distance it covers is the stop failing to repeat itself. One
# number for the whole run is the wrong instrument, because the stops do not share a floor -- a charge in
# LS101 wandered 2436 units at the SAME framerate while a walk in LS102 repeated to within 182, so a
# run-wide 95th percentile of 775 called the first one normal and the second one quiet, and both readings
# were wrong.
#
# But a floor is not enough on its own, because most stops repeat EXACTLY: over the trilogy run of
# 2026-11-04 the median floor was 0. Dividing by it makes every drift over the tolerance a finding at a
# huge ratio -- 426 of 962 pairs, which is not a list anybody can work through.
#
# What separates a framerate difference from a stop that merely wandered is that the FAST PASSES AGREE
# WITH EACH OTHER. 60 and 160 are both wrong in the same way if the cause is the framerate, and wrong in
# unrelated ways if the cause is a charge compounding a small difference in facing. So a finding has to
# clear three bars: every fast pass is over the stop's own floor, the baseline pass actually went
# somewhere, and the fast passes land near one another compared with how far they are from 30 FPS. That
# is what cuts the same data to 67 findings, and it drops the loudest entry in the table above.
$floorOf = @{}
foreach ($r in $results) {
    if ($r.Cap -ne $Baseline) { continue }     # the repeat pass at the baseline framerate
    $key = "$($r.Stop)|$($r.Script)"
    if (-not $floorOf.ContainsKey($key) -or $r.MaxDist -gt $floorOf[$key]) { $floorOf[$key] = $r.MaxDist }
}
$MIN_BASE_MOVE = 10   # units the baseline pass must cover for a stop to have measured anything at all
# Low on purpose. It is there to tell a stop that never played from one that did, and a standstill is
# essentially zero -- while a hop's whole travel is only about 40 units, so a bar of 50 hid every
# jump-height difference there is. A flame, which does not move him at all, is still excluded, and
# tools/Compare-Anims.ps1 is what measures those.
$AGREE = 0.5   # the fast passes may be this much of their own drift apart and still count as agreeing

# Two frames of walking, in units, measured from this run. It is the floor under the whole method, and
# nothing smaller than it means anything: the script presses and releases the stick on a frame boundary,
# so the same walk ends up to a frame further on at 30 FPS than at 160, with no bug involved. At the
# 268 units/s the trilogy run of 2026-11-04 measured, one 30 FPS frame is 8.9 units -- and 44 of that
# run's 68 cross-checked findings sat between 10 and 50 units, clustered tightly around 16. That is this
# artefact, not 44 bugs, and it was reported as findings until the bar was raised to clear it.
$moving = @($rows | Where-Object { [double] $_.speed -gt 50 } | ForEach-Object { [double] $_.speed } | Sort-Object)
$frameUnits = $(if ($moving.Count -gt 0) { $moving[[int] ($moving.Count / 2)] / $Baseline } else { 0 })
$floorUnits = [math]::Max($Tolerance, 2 * $frameUnits)

# How far the fast passes are from EACH OTHER, per stop: every fast sample against the first fast pass's
# sample at the same time. One reference is enough -- if two fast passes both sit near it they sit near
# each other.
$firstFast = @($passes | Where-Object { $_.Cap -ne $Baseline } | Select-Object -First 1)
# Every pass at the baseline framerate, not just the one used as the baseline: the repeat pass is also
# 30 FPS, and letting it into this comparison made the spread enormous for every stop and the findings
# nil, since the repeat pass is exactly what the fast ones are supposed to differ from.
$isBaseCap = @{}
foreach ($p in $passes) { if ($p.Cap -eq $Baseline) { $isBaseCap[$p.Pass] = $true } }
$spreadOf = @{}
if ($firstFast.Count -gt 0) {
    $ref = @{}
    foreach ($r in $rows) {
        if ($r.pass -ne $firstFast[0].Pass) { continue }
        $ref["$($r.stop)|$($r.script)|$($r.t)"] = $r
    }
    foreach ($r in $rows) {
        if ($isBaseCap.ContainsKey($r.pass) -or $r.pass -eq $firstFast[0].Pass) { continue }
        $o = $ref["$($r.stop)|$($r.script)|$($r.t)"]
        if (-not $o) { continue }
        $d = [math]::Sqrt([math]::Pow([double] $r.x - [double] $o.x, 2) +
                          [math]::Pow([double] $r.y - [double] $o.y, 2) +
                          [math]::Pow([double] $r.z - [double] $o.z, 2))
        $k = "$($r.stop)|$($r.script)"
        if (-not $spreadOf.ContainsKey($k) -or $d -gt $spreadOf[$k]) { $spreadOf[$k] = $d }
    }
}

# One row per stop now, not per stop and framerate: a framerate bug is a property of the stop, and
# listing it once per cap was what made the table three times longer than the work in it.
$byStop = @{}
foreach ($r in $results) {
    if ($r.Cap -eq $Baseline) { continue }
    $k = "$($r.Stop)|$($r.Script)"
    if (-not $byStop.ContainsKey($k)) { $byStop[$k] = @() }
    $byStop[$k] += $r
}
$graded = @(); $still = @(); $unmeasured = @()
foreach ($k in $byStop.Keys) {
    $fast = $byStop[$k]
    $floor = $floorOf[$k]
    $moved = $baseMove[$k]
    $least = ($fast | Measure-Object MaxDist -Minimum).Minimum   # the least convinced fast pass
    $most = ($fast | Measure-Object MaxDist -Maximum).Maximum
    $spread = $(if ($spreadOf.ContainsKey($k)) { $spreadOf[$k] } else { 0 })
    $row = [pscustomobject] @{
        Level = $fast[0].Level; Stop = $fast[0].Stop; Script = $fast[0].Script; Note = $fast[0].Note
        Caps = ($fast | ForEach-Object { $_.Cap } | Sort-Object -Unique) -join '/'
        # One fast pass cannot be cross-checked: its spread is 0 because there is nothing to spread
        # against, so it clears the agreement bar for free and rests on the floor alone.
        Fast = @($fast | ForEach-Object { $_.Cap } | Sort-Object -Unique).Count
        BaseMove = $(if ($null -eq $moved) { 0 } else { [math]::Round($moved, 1) })
        Floor = $(if ($null -eq $floor) { $null } else { $floor })
        Least = [math]::Round($least, 1)
        Worst = [math]::Round($most, 1)
        Spread = [math]::Round($spread, 1)
        Ratio = $(if ($null -eq $floor) { $null }
                  elseif ($floor -lt 1) { [math]::Round($least, 1) }
                  else { [math]::Round($least / $floor, 1) })
    }
    # No floor means the repeat pass never played this stop (skipped, or the level was given up on).
    if ($null -eq $floor) { $unmeasured += $row; continue }
    # A stop only measured something if the baseline pass went somewhere. One where it did not has a
    # floor of 0 for the dullest reason -- two passes of standing still agree perfectly -- and ranking
    # that is how "the game took the input away" gets reported as a framerate bug.
    if ($row.BaseMove -lt $MIN_BASE_MOVE) { $still += $row; continue }
    $graded += $row
}
Write-Host ''
if ($floorOf.Count -eq 0) {
    # -f binds tighter than +, so the format arguments have to be applied to the whole joined string.
    Write-Host (("No per-stop noise floor: this run has only one pass at {0} FPS. Run the tour with " +
        "the baseline framerate twice (caps={0},{0},...) and the stops that cannot repeat themselves " +
        'stop looking like framerate bugs.') -f $Baseline)
} else {
    if ($spreadOf.Count -eq 0) {
        Write-Host (('Only one framerate above {0} FPS in this run, so there is nothing to cross-check ' +
            'it against: the findings below rest on the noise floor alone, and a stop that simply ' +
            'wandered can still reach the table. Three caps (e.g. caps={0},{0},60,160) fix that.') -f $Baseline)
    }
    $found = @($graded | Where-Object {
        $_.Least -gt $floorUnits -and $_.Least -gt ($_.Floor * $FloorFactor) -and
        $_.Spread -le ($AGREE * $_.Least)
    } | Sort-Object Worst -Descending)
    $wandered = @($graded | Where-Object {
        $_.Least -gt $floorUnits -and $_.Least -gt ($_.Floor * $FloorFactor) -and
        $_.Spread -gt ($AGREE * $_.Least)
    })
    $granular = @($graded | Where-Object {
        $_.Least -le $floorUnits -and $_.Least -gt $Tolerance -and $_.Least -gt ($_.Floor * $FloorFactor)
    })
    Write-Host ('' +
        ("One 30 FPS frame of walking is {0:0.0} units at the {1:0} units/s this run measured, so " -f `
            $frameUnits, ($frameUnits * $Baseline)) +
        ("nothing under {0:0.0} is a finding: the script presses and releases on a frame boundary." -f $floorUnits))
    # Two tiers, because they are not the same evidence. A stop played at two or more framerates above the
    # baseline has been cross-checked: the fast passes agreeing is what says the framerate caused it. A
    # stop played at only one has nothing to agree with, so all it has is its own floor, and a stop that
    # merely wandered can sit in that list. The second tier exists because a crash costs a level its
    # later passes, which is most of what games 2 and 3 lost in the run of 2026-11-04.
    $crossed = @($found | Where-Object { $_.Fast -ge 2 })
    $single = @($found | Where-Object { $_.Fast -lt 2 })
    $cols = 'Level', 'Stop', 'Script', 'Note', 'Caps', 'BaseMove', 'Floor', 'Least', 'Worst', 'Spread', 'Ratio'
    Write-Host (("FINDINGS: {0} of {1} measured stops, {2} of them cross-checked at more than one " +
        "framerate. Every pass above {3} FPS beats the stop's own noise floor by {4}x, and they agree " +
        'with each other to within {5} of that drift, so it is the framerate and not the stop ' +
        'wandering.') -f $found.Count, $graded.Count, $crossed.Count, $Baseline, $FloorFactor, $AGREE)
    if ($granular.Count -gt 0) {
        Write-Host (("{0} more stop(s) beat their floor but by less than two frames of walking, which is " +
            'the harness and not the game.') -f $granular.Count)
    }
    if ($crossed.Count -gt 0) {
        Write-Host ''
        Write-Host 'Cross-checked -- two or more framerates above the baseline agree:'
        $crossed | Select-Object -First $Top $cols | Format-Table -AutoSize
    }
    if ($single.Count -gt 0) {
        Write-Host ("Floor only -- one framerate above the baseline, nothing to cross-check it against " +
            '(weaker: a stop that just wandered can be in here):')
        $single | Select-Object -First $Top $cols | Format-Table -AutoSize
    }
    if ($wandered.Count -gt 0) {
        Write-Host (("{0} more stop(s) drift past their floor but the fast passes disagree among " +
            'themselves, so the drift is the stop and not the framerate.') -f $wandered.Count)
    }
    if ($still.Count -gt 0) {
        $spots = @($still | ForEach-Object { "$($_.Level)/$($_.Stop) $($_.Script)" } | Sort-Object -Unique)
        Write-Host (("{0} stop(s) measured nothing: the {1} FPS pass itself moved less than {2} units, so " +
            'the stop never played. Not findings -- look at why (the game holding the input, a spot ' +
            'against a wall, a script with no walk). {3}') -f $still.Count, $Baseline, $MIN_BASE_MOVE,
            (($spots | Select-Object -First 12) -join ', '))
    }
    if ($unmeasured.Count -gt 0) {
        $spots = @($unmeasured | ForEach-Object { "$($_.Level)/$($_.Stop) $($_.Script)" } | Sort-Object -Unique)
        Write-Host (("{0} stop(s) have no floor (the repeat pass never played them) and are not " +
            'ranked: {1}') -f $unmeasured.Count, (($spots | Select-Object -First 12) -join ', '))
    }
}

$bad = $results | Where-Object { $_.MaxDist -gt $Tolerance }
Write-Host ""
Write-Host ("{0} of {1} stop/pass pairs drift more than {2} units from the baseline run." -f `
    $bad.Count, $results.Count, $Tolerance)

# What the same framerate does against itself, per pass: anything a faster pass does that is inside this
# is the tour repeating itself, not a framerate difference. Read this before anything above.
$floorPasses = @($passes | Where-Object { $_.Cap -eq $Baseline -and $_.Pass -ne $basePass })
if ($floorPasses.Count -gt 0) {
    Write-Host ''
    Write-Host 'Noise floor -- the same framerate against itself:'
    foreach ($fp in $floorPasses) {
        $own = @($results | Where-Object { $_.Pass -eq [int] $fp.Pass })
        if ($own.Count -eq 0) { continue }
        $dists = @($own | ForEach-Object { $_.MaxDist } | Sort-Object)
        $median = $dists[[int] ($dists.Count / 2)]
        $p95 = $dists[[int] [math]::Floor($dists.Count * 0.95)]
        Write-Host ("  pass {0} at {1} FPS over {2} stop(s): median {3}, 95th percentile {4}, worst {5} units" -f `
            $fp.Pass, $fp.Cap, $own.Count, $median, $p95, $dists[-1])
        Write-Host ("  -> treat a drift under about {0} units as noise." -f $p95)
    }
}
# Which scripts the drift is in, counted. The ids used to be printed in full here, which ran to hundreds
# of lines of "LS103/35@60, LS103/38@60, ..." three times over and buried everything below it -- and the
# findings table above already names the stops worth opening.
foreach ($g in $bad | Group-Object Script | Sort-Object Count -Descending) {
    $spots = @($g.Group | ForEach-Object { "$($_.Level)/$($_.Stop)@$($_.Cap)" })
    Write-Host ("  {0}: {1} ({2}{3})" -f $g.Name, $g.Count,
        (($spots | Select-Object -First 8) -join ', '),
        $(if ($spots.Count -gt 8) { ", and $($spots.Count - 8) more" } else { '' }))
}
