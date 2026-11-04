<#
.SYNOPSIS
    Runs a scan sweep over all three games with nobody watching, restarting the game when it dies.

.DESCRIPTION
    tools/scansweep.lua covers one game per run, because "start game" does nothing from inside a
    level: what gets into another game is the menu lib/resume.lua drives after a restart. And UE4SS
    gets unstable over a long run of level travels -- two access violations inside UE4SS.dll in the
    first trilogy sweep, neither reproducible on its own. Both of those turn an overnight sweep into
    an afternoon of restarting the game by hand, which is what this script is for.

    Per game it closes the game, points resume.txt at that game's first level, starts it with
    Restart-Game.ps1, drops a scansweep.txt trigger, and follows UE4SS.log. If the sweep finishes it
    moves on; if the game dies or stops making progress it restarts and drops the trigger again
    without "restart", so scansweep_progress.txt picks the run up at the level it had reached. Stops
    are pulled into the repo after every game, so a run that is abandoned half way still leaves
    everything it recorded (Sync-Routes.ps1).

    Nothing here needs the game to be in any particular state to begin with.

.PARAMETER Games
    Which games to sweep, in order. Default 1, 2, 3.

.PARAMETER MaxRestarts
    Restarts allowed per game before giving up on it and moving to the next. Default 6.

.PARAMETER StallMinutes
    Minutes without a level being finished before the run is treated as stuck and restarted.
    Default 12: a first visit plays an intro cutscene and the travel timeout alone is 90 s.

.PARAMETER Settle
    Seconds in each level before it is scanned (the sweep's settle= option). Default 8.

.PARAMETER Range
    How far from the checkpoint characters are taken from (the sweep's range= option). 0 leaves the
    sweep's own default (30000). Levels sit on a 300000 grid, so up to about 150000 is still this
    level.

.PARAMETER Levels
    Only these levels, as a comma list (the sweep's level= option), for topping a route up or for
    trying the driver out without an hour of sweeping. A named level is swept even if it is one of
    the flight levels the sweep normally leaves out.

.PARAMETER Resume
    Carry on from scansweep_progress.txt for the first game as well, instead of starting it over.

.EXAMPLE
    .\tools\Sweep-AllGames.ps1
    .\tools\Sweep-AllGames.ps1 -Games 2,3 -Range 120000
    .\tools\Sweep-AllGames.ps1 -Resume
    .\tools\Sweep-AllGames.ps1 -Games 1 -Levels LS104,LS106
#>
param(
    [int[]] $Games = @(1, 2, 3),
    [int] $MaxRestarts = 6,
    [int] $StallMinutes = 12,
    [int] $Settle = 8,
    [int] $Range = 0,
    [string[]] $Levels,
    [switch] $Resume
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

$log = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\UE4SS.log'
$stopFile = Join-Path $ProbeDir 'sweepall.stop'
$processNames = @('Spyro-Win64-Shipping', 'Spyro')
$started = Get-Date

if (-not (Test-Path $ProbeDir)) {
    throw "The probe is not deployed: $ProbeDir (run tools\Install-UE4SS.ps1 -ModsOnly -Probe)."
}
Remove-Item $stopFile -Force -ErrorAction SilentlyContinue

function Write-Step($text) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $text)
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
# game runs, so it can only be set with the game closed -- Stop-Game first, always.
function Set-Resume([string] $level, [int] $gameIndex) {
    Set-Content -Path (Join-Path $ProbeDir 'resume.txt') -Value "$level $gameIndex 0" -Encoding ascii
}

# Not Set-Content -Encoding utf8: in Windows PowerShell 5.1 that writes a BOM, and those three bytes
# stick to the first option in the file, which is then silently dropped (docs/probe.md).
function Write-Trigger([string] $options) {
    [IO.File]::WriteAllText((Join-Path $ProbeDir 'scansweep.txt'), $options, [Text.UTF8Encoding]::new($false))
}

function Start-Game {
    # Restart-Game.ps1 reports with Write-Host, which does not go to the success stream, so capturing
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

# Follows the log until the sweep ends, the game dies or it stops making progress. Returns
# done / crash / stall / stopped.
function Watch-Run {
    $seen = 0                       # UE4SS starts the log over each launch, so count from zero
    $lastProgress = Get-Date
    while ($true) {
        Start-Sleep -Seconds 10
        if (Test-Path $stopFile) {
            Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
            return 'stopped'
        }
        if (-not (Get-Process -Name 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue)) { return 'crash' }
        if (-not (Test-Path $log)) { continue }
        $all = @(Get-Content $log -ErrorAction SilentlyContinue)
        if ($all.Count -lt $seen) { $seen = 0 }
        $new = @($all | Select-Object -Skip $seen)
        $seen = $all.Count
        foreach ($line in $new) {
            if ($line -notmatch 'scansweep') { continue }
            $text = ($line -split 'SpyroFpsProbe\] ')[-1]
            Write-Host "    $text"
            if ($line -match 'LS\d+ (done|skipped)') { $lastProgress = Get-Date }
            if ($line -match 'scansweep: (every level done|stopped|no levels)') { return 'done' }
        }
        if (((Get-Date) - $lastProgress).TotalMinutes -ge $StallMinutes) { return 'stall' }
    }
}

function Get-StopCount {
    $file = Join-Path $ProbeDir 'routes.txt'
    if (-not (Test-Path $file)) { return 0 }
    @(Get-Content $file | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }).Count
}

$summary = @()
foreach ($game in $Games) {
    $firstLevel = "LS${game}01"
    $before = Get-StopCount
    $attempt = 0
    $fresh = -not $Resume          # only the first attempt of the first game may start over
    $outcome = 'gave up'

    Write-Step "Spyro ${game}: sweeping, starting at $firstLevel ($before stop(s) recorded so far)"
    while ($attempt -le $MaxRestarts) {
        if ($attempt -gt 0) { Write-Step "Spyro ${game}: restart $attempt of $MaxRestarts" }
        Stop-Game
        Set-Resume $firstLevel ($game - 1)
        if (-not (Start-Game)) { $attempt++; continue }

        $options = @()
        if ($fresh) { $options += 'restart' }
        $options += "game=$game"
        $options += "settle=$Settle"
        if ($Range -gt 0) { $options += "range=$Range" }
        if ($Levels)      { $options += "level=$($Levels -join ',')" }
        Write-Trigger ($options -join ' ')
        Write-Step "  trigger: $($options -join ' ')"

        $result = Watch-Run
        $fresh = $false            # anything after the first attempt resumes from the progress file
        switch ($result) {
            'done'    { $outcome = 'done' }
            'crash'   { Write-Step '  the game died; restarting and resuming from the progress file' }
            'stall'   { Write-Step "  no level finished in $StallMinutes min; restarting" }
            'stopped' { $outcome = 'stopped' }
        }
        if ($outcome -ne 'gave up') { break }
        $attempt++
    }

    $after = Get-StopCount
    $summary += [pscustomobject]@{
        Game     = $game
        Outcome  = $outcome
        Stops    = $after - $before
        Restarts = $attempt
    }
    Write-Step "Spyro ${game}: $outcome, $($after - $before) new stop(s)"

    # After every game, not just at the end: a run abandoned half way still leaves its stops in the repo.
    & (Join-Path $PSScriptRoot 'Sync-Routes.ps1') | Out-Null
    Write-Step "  stops pulled into the repo ($after in all)"

    if ($outcome -eq 'stopped') {
        Write-Step 'sweepall.stop was set; stopping here'
        break
    }
}

Stop-Game
Write-Host ''
Write-Host "Swept in $([int]((Get-Date) - $started).TotalMinutes) min:"
$summary | Format-Table -AutoSize
Write-Host "routes.txt now holds $(Get-StopCount) stop(s). Commit ue4ss\DevMods\SpyroFpsProbe\routes.txt to keep them."
