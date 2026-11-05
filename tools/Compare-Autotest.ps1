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
# A stop's own noise floor is what the SECOND pass at the baseline framerate did on that stop: the same
# input script, the same framerate, so whatever distance it covers is the stop failing to repeat itself.
# One number for the whole run is the wrong instrument, because the stops do not share a floor -- in the
# LS101/LS102 run of 2026-11-04 a charge in LS101 wandered 2436 units at the SAME framerate while a walk
# in LS102 repeated to within 182, so a run-wide 95th percentile of 775 called the first one normal and
# the second one quiet, and both readings were wrong. Against its own floor the LS101 charge is noise (a
# faster pass moved LESS than the floor) and the LS102 walk is a finding at six times its floor.
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

Write-Host ''
if ($floorOf.Count -eq 0) {
    # -f binds tighter than +, so the format arguments have to be applied to the whole joined string.
    Write-Host (("No per-stop noise floor: this run has only one pass at {0} FPS. Run the tour with " +
        "the baseline framerate twice (caps={0},{0},...) and the stops that cannot repeat themselves " +
        'stop looking like framerate bugs.') -f $Baseline)
} else {
    $graded = @()
    foreach ($r in $results) {
        if ($r.Cap -eq $Baseline) { continue }
        $floor = $floorOf["$($r.Stop)|$($r.Script)"]
        $moved = $baseMove["$($r.Stop)|$($r.Script)"]
        $graded += [pscustomobject] @{
            Cap = $r.Cap; Level = $r.Level; Stop = $r.Stop; Script = $r.Script; Note = $r.Note
            MaxDist = $r.MaxDist
            BaseMove = $(if ($null -eq $moved) { 0 } else { [math]::Round($moved, 1) })
            Floor = $(if ($null -eq $floor) { $null } else { $floor })
            # No floor for this stop means the repeat pass never played it (it was skipped, or the level
            # was given up on). Unmeasured, so it is not ranked as a finding.
            Ratio = $(if ($null -eq $floor) { $null }
                      elseif ($floor -lt 1) { [math]::Round($r.MaxDist, 1) }
                      else { [math]::Round($r.MaxDist / $floor, 1) })
        }
    }
    # A stop only measured something if the baseline pass actually went somewhere. A stop where the
    # baseline never moved has a floor of 0 for the dullest reason -- two passes of standing still agree
    # perfectly -- and ranking that as a finding is how "the game took the input away" gets reported as a
    # framerate bug. Those are listed separately, as what they are.
    $measured = @($graded | Where-Object { $null -ne $_.Ratio -and $_.BaseMove -ge $MIN_BASE_MOVE })
    $still = @($graded | Where-Object { $null -ne $_.Ratio -and $_.BaseMove -lt $MIN_BASE_MOVE })
    $found = @($measured | Where-Object {
        $_.MaxDist -gt $Tolerance -and $_.MaxDist -gt ($_.Floor * $FloorFactor)
    } | Sort-Object Ratio -Descending)
    Write-Host (("FINDINGS: {0} of {1} measured stop/framerate pairs move more than {2} units AND more " +
        'than {3}x their own noise floor.') -f $found.Count, $measured.Count, $Tolerance, $FloorFactor)
    if ($found.Count -gt 0) {
        $found | Select-Object -First $Top Cap, Level, Stop, Script, Note, BaseMove, MaxDist, Floor, Ratio |
            Format-Table -AutoSize
    }
    if ($still.Count -gt 0) {
        $spots = @($still | ForEach-Object { "$($_.Level)/$($_.Stop) $($_.Script)" } | Sort-Object -Unique)
        Write-Host (("{0} pair(s) measured nothing: the {1} FPS pass itself moved less than {2} units, so " +
            'the stop never played. Not findings -- look at why (the game holding the input, a spot ' +
            'against a wall, a script with no walk). {3}') -f $still.Count, $Baseline, $MIN_BASE_MOVE,
            (($spots | Select-Object -First 12) -join ', '))
    }
    $unmeasured = @($graded | Where-Object { $null -eq $_.Ratio })
    if ($unmeasured.Count -gt 0) {
        $spots = @($unmeasured | ForEach-Object { "$($_.Level)/$($_.Stop) $($_.Script)" } | Sort-Object -Unique)
        Write-Host (("{0} pair(s) have no floor (the repeat pass never played that stop) and are not " +
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
foreach ($g in $bad | Group-Object Script | Sort-Object Count -Descending) {
    Write-Host ("  {0}: {1} ({2})" -f $g.Name, $g.Count, (($g.Group | ForEach-Object { "$($_.Level)/$($_.Stop)@$($_.Cap)" }) -join ', '))
}
