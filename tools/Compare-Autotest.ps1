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
    [int] $Top = 40
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
$caps = $rows | ForEach-Object { [int] $_.cap } | Sort-Object -Unique
if ($caps -notcontains $Baseline) { throw "No $Baseline FPS pass in this run (passes: $($caps -join ', '))." }
Write-Host "Passes: $($caps -join ', ') FPS; baseline $Baseline"

# Key every baseline sample by stop and time, so the other passes can look their own sample up.
$base = @{}
foreach ($r in $rows) {
    if ([int] $r.cap -ne $Baseline) { continue }
    $base["$($r.stop)|$($r.t)"] = $r
}

$results = @()
foreach ($group in $rows | Where-Object { [int] $_.cap -ne $Baseline } | Group-Object cap, stop) {
    $sorted = $group.Group | Sort-Object { [double] $_.t }
    $first = $sorted[0]
    $maxDist = 0.0; $maxYaw = 0.0; $maxPitch = 0.0; $endDist = $null; $matched = 0
    foreach ($r in $sorted) {
        $b = $base["$($r.stop)|$($r.t)"]
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

$bad = $results | Where-Object { $_.MaxDist -gt $Tolerance }
Write-Host ""
Write-Host ("{0} of {1} stop/framerate pairs drift more than {2} units from the {3} FPS run." -f `
    $bad.Count, $results.Count, $Tolerance, $Baseline)
foreach ($g in $bad | Group-Object Script | Sort-Object Count -Descending) {
    Write-Host ("  {0}: {1} ({2})" -f $g.Name, $g.Count, (($g.Group | ForEach-Object { "$($_.Level)/$($_.Stop)@$($_.Cap)" }) -join ', '))
}
