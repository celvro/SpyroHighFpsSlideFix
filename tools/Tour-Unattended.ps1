<#
.SYNOPSIS
    Runs the probe's world tour to the end with nobody watching, then compares the framerate passes.

.DESCRIPTION
    The tour plays every recorded stop at every framerate in -Caps, and a full route is 1843 stops, so
    a run is a night's work and it has to survive whatever happens to the game in that time. This
    script starts the game, drops an autotest.txt trigger, follows UE4SS.log, and when the game dies or
    stops making progress it restarts and drops the trigger again *without* "restart", so
    autotest_progress.txt picks the run up at the stop it had reached.

    Three things it does that matter for reading the results afterwards:

      * UE4SS.log is started over on every launch, so the tracker lines of each launch would be lost at
        the next restart. Each launch's log is copied into the run folder before the game is started
        again.
      * The tour's CSVs are named after the launch (lib/paths.lua stamps them), so a run that restarted
        eight times leaves nine CSVs. They have one header shape, so they are concatenated into one
        autotest.csv and one autotest_anims.csv -- which is what Compare-Autotest.ps1 and
        Compare-Anims.ps1 need, since each takes a single file.
      * Both comparisons are run at the end and their reports saved next to the CSVs, worst stop first.
        Read those, not the log.

    Everything lands in build\tour\<stamp>\. Nothing here needs the game to be in any particular state
    to begin with.

.PARAMETER Caps
    The framerate caps to compare, as a comma list, lowest first; the first is the baseline every other
    pass is measured against. Default "30,30,60,160" -- 30 twice on purpose: two passes at the same cap
    measure how much a stop differs from itself, which is the noise floor that tells a real 60/160 FPS
    difference from a stop that never repeats. Each stop is played once per cap, so the caps multiply
    the hours.

.PARAMETER Scripts
    Only stops with these scripts (the tour's script= option), e.g. walk,enterPlay. Default: all of
    them.

.PARAMETER Levels
    Only these levels (the tour's level= option). For trying the driver out without a night of running.

.PARAMETER StartLevel
    The level the game is pointed at before the first launch. Default LS101 (Spyro 1's first), so a
    full run starts in the first game and swaps forward through the title screen as it goes.

.PARAMETER MaxRestarts
    Restarts allowed before giving up. Default 40: a long run is expected to need some, and each one
    costs under a minute.

.PARAMETER StallMinutes
    Minutes without a stop being played before the run is treated as stuck and restarted. Default 15:
    a first visit to a level plays an intro cutscene, and the travel timeout alone is 90 s.

.PARAMETER Resume
    Carry on from autotest_progress.txt instead of starting the route over. Without it the first
    trigger says "restart".

.PARAMETER AllowTrace
    Run even though the probe's per-frame trace CSV is switched on. It writes a row per frame per
    character: at 160 FPS over a night that is tens of gigabytes, and it is not what the comparisons
    read, so by default this script refuses and tells you to turn TRACE off in the deployed
    config.lua.

.EXAMPLE
    .\tools\Tour-Unattended.ps1
    .\tools\Tour-Unattended.ps1 -Caps 30,30,60,160
    .\tools\Tour-Unattended.ps1 -Levels LS101,LS102 -Caps 30,60
    .\tools\Tour-Unattended.ps1 -Resume
#>
param(
    [string[]] $Caps = @('30', '30', '60', '160'),
    [string[]] $Scripts,
    [string[]] $Levels,
    [string] $StartLevel = 'LS101',
    [int] $MaxRestarts = 40,
    [int] $StallMinutes = 15,
    [switch] $Resume,
    [switch] $AllowTrace
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

$log = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\UE4SS.log'
$stopFile = Join-Path $ProbeDir 'tourall.stop'
$processNames = @('Spyro-Win64-Shipping', 'Spyro')
$started = Get-Date
$runStamp = $started.ToString('yyyyMMdd_HHmmss')
$runDir = Join-Path $PSScriptRoot "..\build\tour\$runStamp"
$capList = ($Caps -join ',')
$baseline = [int] ($Caps | ForEach-Object { [int] $_ } | Sort-Object | Select-Object -First 1)

if (-not (Test-Path $ProbeDir)) {
    throw "The probe is not deployed: $ProbeDir (run tools\Install-UE4SS.ps1 -ModsOnly -Probe)."
}

# The per-frame CSV is the one thing that turns an overnight run into a disk-full crash, so it is
# checked before anything is started rather than discovered in the morning.
$deployedConfig = Join-Path $ProbeDir 'Scripts\config.lua'
if (-not $AllowTrace -and (Test-Path $deployedConfig)) {
    $traceOn = Select-String -Path $deployedConfig -Pattern '^\s*TRACE\s*=\s*true' -Quiet
    if ($traceOn) {
        throw ("The probe's per-frame trace CSV is on (TRACE = true in $deployedConfig). " +
               "A night at 160 FPS writes tens of GB of it and the comparisons do not read it. " +
               'Set TRACE = false there, or pass -AllowTrace.')
    }
}

$null = New-Item -ItemType Directory -Force $runDir
$runDir = (Resolve-Path $runDir).Path
# Both stop files: tourall.stop ends this script, autotest.stop ends the tour inside the game, and one
# left behind by a previous run would stop this one before it played a single stop.
Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $ProbeDir 'autotest.stop') -Force -ErrorAction SilentlyContinue

function Write-Step($text) {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $text
    Write-Host $line
    Add-Content -Path (Join-Path $runDir 'driver.log') -Value $line -Encoding ascii
}

function Stop-Game {
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    foreach ($p in $running) { $null = $p.CloseMainWindow() }
    foreach ($p in $running) {
        if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    while (Get-Process -Name $processNames -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
    # The crash reporter holds the Steam session open and would block the relaunch.
    Get-Process -Name 'CrashReportClient' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# resume.txt is "<level> <game index> <save slot>". The probe rewrites it every few seconds while the
# game runs, so it can only be set with the game closed -- Stop-Game first, always. Only the first
# launch is pointed anywhere: after a crash the probe's own resume.txt is where the run had got to,
# which is a better place to come back to than the route's beginning.
function Set-Resume([string] $level) {
    $game = [int] ($level -replace '^LS(\d).*$', '$1') - 1
    Set-Content -Path (Join-Path $ProbeDir 'resume.txt') -Value "$level $game 0" -Encoding ascii
}

# Not Set-Content -Encoding utf8: in Windows PowerShell 5.1 that writes a BOM, and those three bytes
# stick to the first option in the file, which is then silently dropped (docs/probe.md). tools/
# worldtour.lua does not strip one either.
function Write-Trigger([string] $options) {
    [IO.File]::WriteAllText((Join-Path $ProbeDir 'autotest.txt'), $options, [Text.UTF8Encoding]::new($false))
}

# UE4SS truncates its log on every launch, so each launch's lines are saved before the next one starts.
# These hold the trackers' own findings (seg / rise / charge / turn / camlock / stall lines), which are
# nowhere else.
function Save-Log([int] $attempt) {
    if (-not (Test-Path $log)) { return }
    $name = 'UE4SS_launch{0:d2}.log' -f $attempt
    Copy-Item $log (Join-Path $runDir $name) -Force -ErrorAction SilentlyContinue
}

function Start-Game {
    # Restart-Game.ps1 reports with Write-Host, which does not reach the success stream, so capturing
    # its output and matching on it finds nothing however well the restart went. Let it print, and ask
    # the log instead: UE4SS starts UE4SS.log over on every launch, so a resume line in it now belongs
    # to this launch.
    & (Join-Path $PSScriptRoot 'Restart-Game.ps1') -Wait 300
    if (-not (Get-Process -Name 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue)) {
        Write-Step '  the game is not running after the restart'
        return $false
    }
    $arrived = @(Select-String -Path $log -Pattern 'resume: (back in|arrived)' -ErrorAction SilentlyContinue)
    if ($arrived.Count -gt 0) {
        Write-Step "  in a level: $(($arrived[-1].Line -split 'SpyroFpsProbe\] ')[-1])"
        return $true
    }
    Write-Step '  the game never reached a level'
    return $false
}

# Follows the log until the tour ends, the game dies or it stops making progress. Returns
# done / crash / stall / stopped.
function Watch-Run {
    $seen = 0                       # UE4SS starts the log over each launch, so count from zero
    $lastProgress = Get-Date
    $stops = 0
    while ($true) {
        Start-Sleep -Seconds 10
        if (Test-Path $stopFile) {
            Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
            # Tell the tour to stop too, so it is not mid-stop when the game is closed.
            [IO.File]::WriteAllText((Join-Path $ProbeDir 'autotest.stop'), '', [Text.UTF8Encoding]::new($false))
            Start-Sleep -Seconds 3
            return 'stopped'
        }
        if (-not (Get-Process -Name 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue)) { return 'crash' }
        if (-not (Test-Path $log)) { continue }
        $all = @(Get-Content $log -ErrorAction SilentlyContinue)
        if ($all.Count -lt $seen) { $seen = 0 }
        $new = @($all | Select-Object -Skip $seen)
        $seen = $all.Count
        foreach ($line in $new) {
            if ($line -notmatch 'autotest|igc: \d+ cinematic') { continue }
            $text = ($line -split 'SpyroFpsProbe\] ')[-1]
            # One line per stop is already a lot over a night; the level/cap headers and anything odd
            # are printed, the per-stop lines only counted.
            if ($text -match '^autotest \d+ FPS ') {
                $stops++
                $lastProgress = Get-Date
                if ($text -notmatch ': played') { Write-Host "    $text" }
                continue
            }
            Write-Host "    $text"
            if ($text -match '^autotest: LS\d+ at \d+ FPS') { $lastProgress = Get-Date }
            if ($text -match '^autotest: done') { return 'done' }
            if ($text -match '^autotest: stopped') { return 'stopped' }
            # A run that has nothing to play will never have anything to play, and restarting into the
            # stall timeout three times to find that out cost 21 minutes once. Stop at the first one.
            if ($text -match '^autotest: (no stops to run|none of the)') { return 'nothing' }
        }
        if (((Get-Date) - $lastProgress).TotalMinutes -ge $StallMinutes) {
            Write-Step "  $stops stop(s) this launch, then nothing for $StallMinutes min"
            return 'stall'
        }
    }
}

# --- the run --------------------------------------------------------------------------------------

Write-Step "Tour: caps $capList (baseline $baseline FPS), output in $runDir"
if ($Scripts) { Write-Step "  scripts: $($Scripts -join ',')" }
if ($Levels)  { Write-Step "  levels: $($Levels -join ',')" }

# The CSVs this run produces: anything the probe writes from now on. Taken by time, because each
# launch stamps its own name.
$csvCutoff = (Get-Date).AddSeconds(-5)

$attempt = 0
$fresh = -not $Resume
$outcome = 'gave up'
while ($attempt -le $MaxRestarts) {
    if ($attempt -gt 0) { Write-Step "restart $attempt of $MaxRestarts" }
    Stop-Game
    Save-Log $attempt
    if ($attempt -eq 0) { Set-Resume $StartLevel }
    if (-not (Start-Game)) { $attempt++; continue }

    $options = @()
    if ($fresh) { $options += 'restart' }
    $options += "caps=$capList"
    if ($Levels)  { $options += "level=$($Levels -join ',')" }
    if ($Scripts) { $options += "script=$($Scripts -join ',')" }
    Write-Trigger ($options -join ' ')
    Write-Step "  trigger: $($options -join ' ')"

    $result = Watch-Run
    $fresh = $false                # anything after the first attempt resumes from the progress file
    switch ($result) {
        'done'    { $outcome = 'done' }
        'crash'   { Write-Step '  the game died; restarting and resuming from the progress file' }
        'stall'   { Write-Step '  no progress; restarting' }
        'stopped' { $outcome = 'stopped' }
        'nothing' { $outcome = 'nothing to run'; Write-Step '  the filters matched no stops; not restarting' }
    }
    if ($outcome -ne 'gave up') { break }
    $attempt++
}

Save-Log ($attempt + 1)
Stop-Game
Write-Step "$outcome after $([int]((Get-Date) - $started).TotalMinutes) min and $attempt restart(s)"

# --- the results ----------------------------------------------------------------------------------

# One CSV per launch, same header shape: concatenated into one file each, which is what the
# comparisons take.
function Join-Csvs([string] $pattern, [string] $into) {
    $files = @(Get-ChildItem (Join-Path $ProbeDir $pattern) -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $csvCutoff -and $_.Length -gt 0 } |
        Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return $null }
    $out = Join-Path $runDir $into
    $first = $true
    foreach ($f in $files) {
        $lines = Get-Content $f.FullName
        if ($lines.Count -eq 0) { continue }
        if ($first) { Set-Content -Path $out -Value $lines -Encoding ascii; $first = $false }
        else { Add-Content -Path $out -Value ($lines | Select-Object -Skip 1) -Encoding ascii }
    }
    if ($first) { return $null }
    Write-Step ("  {0}: {1} row(s) from {2} launch(es)" -f $into,
        (@(Get-Content $out).Count - 1), $files.Count)
    return $out
}

$tourCsv = Join-Csvs 'autotest_2*.csv' 'autotest.csv'
$animCsv = Join-Csvs 'autotest_anims_*.csv' 'autotest_anims.csv'
foreach ($extra in 'autotest_deaths.txt', 'autotest_progress.txt') {
    Copy-Item (Join-Path $ProbeDir $extra) $runDir -Force -ErrorAction SilentlyContinue
}

if ($tourCsv) {
    Write-Step 'comparing positions and camera (Compare-Autotest.ps1)'
    & (Join-Path $PSScriptRoot 'Compare-Autotest.ps1') -Path $tourCsv -Baseline $baseline |
        Tee-Object -FilePath (Join-Path $runDir 'compare-autotest.txt')
}
if ($animCsv) {
    Write-Step 'comparing animations (Compare-Anims.ps1)'
    & (Join-Path $PSScriptRoot 'Compare-Anims.ps1') -Path $animCsv -Baseline $baseline |
        Tee-Object -FilePath (Join-Path $runDir 'compare-anims.txt')
}

Write-Host ''
Write-Host "Tour $outcome in $([int]((Get-Date) - $started).TotalMinutes) min. Everything is in:"
Write-Host "  $runDir"
Write-Host '    compare-autotest.txt   stops worst first: how far each pass ends up from the baseline'
Write-Host '    compare-anims.txt      the same for what the characters were animating'
Write-Host '    autotest.csv           every sample of every pass, joined'
Write-Host '    UE4SS_launch*.log      each launch, for the trackers own lines'
# Only a run that could not be driven is a failure: one stopped on purpose with tourall.stop is not.
if ($outcome -eq 'gave up' -or $outcome -eq 'nothing to run') { exit 1 }
