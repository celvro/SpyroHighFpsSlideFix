<#
.SYNOPSIS
    Restarts Spyro Reignited Trilogy and puts the probe back in the level it was in.

.DESCRIPTION
    Closes the game (the window first, then the process if it doesn't go), arms the probe's resume
    (resume.go next to its resume.txt note) and starts the game again. The game only saves which level
    was loaded at an autosave or a menu quit, so closing it this way loses that; the probe writes its
    own note every few seconds instead and, with resume.go set, drives the title screen itself:
    "start game"(game index, save slot), then travel to the noted level (ue4ss/DevMods/SpyroFpsProbe/
    Scripts/lib/resume.lua).

    A test run in progress (tools/autotest.lua, tools/spawntest.lua) picks itself up from its own
    progress file once the level is back, so restarting is all that is needed to carry on.

    Needs the probe deployed: tools\Install-UE4SS.ps1 -Probe.

.PARAMETER NoResume
    Just restart: don't arm the resume, so the game sits at the title screen.

.PARAMETER ViaSteam
    Launch through the Steam store entry instead of running the shipping exe directly. The direct launch
    is the default so a restart does not wait for Steam to finish with the last run.

.PARAMETER SteamSettle
    Seconds to wait after the game is gone before starting it again (default 15). Steam keeps the game
    marked as running for a moment, and a launch in that window fails with "Game already running".

.PARAMETER Wait
    Seconds to wait for the level to come back before returning (default 180). The log line to look for
    is "resume: back in LS###" or "resume: arrived".

.EXAMPLE
    .\tools\Restart-Game.ps1
#>
param(
    [string] $ModName = 'SpyroFpsProbe',
    [int] $AppId = 996580,
    [switch] $NoResume,
    [switch] $ViaSteam,
    [int] $SteamSettle = 15,
    [int] $Wait = 180
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

# The Steam entry starts "Spyro.exe", which launches the game itself as "Spyro-Win64-Shipping.exe";
# both have to go, or Steam thinks the game is still running and the relaunch does nothing.
$processNames = @('Spyro-Win64-Shipping', 'Spyro')
$probeDir = Join-Path $GameDir "Falcon\Binaries\Win64\ue4ss\Mods\$ModName"
if (-not (Test-Path $probeDir)) { throw "Probe not deployed: $probeDir (run tools\Install-UE4SS.ps1 -Probe)" }

$running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
if ($running) {
    foreach ($p in $running) {
        Write-Host "Closing $($p.ProcessName) (pid $($p.Id))..."
        # CloseMainWindow is the same as clicking the X: the game still does not save the loaded level,
        # but it shuts down cleanly, which keeps the save file itself intact.
        $null = $p.CloseMainWindow()
    }
    foreach ($p in $running) {
        if (-not $p.WaitForExit(20000)) {
            Write-Host "$($p.ProcessName) did not close; stopping the process."
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $null = $p.WaitForExit(20000)
        }
    }
} else {
    Write-Host 'The game is not running.'
}
# The exe asks Steam to launch it, and Steam keeps the game marked as running for a while after the
# process is gone; launching in that window fails with "Game already running" and nothing starts. So wait
# for the processes to disappear and then give Steam time to let go.
while (Get-Process -Name $processNames -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
Write-Host "Waiting ${SteamSettle}s for Steam to release the game session..."
Start-Sleep -Seconds $SteamSettle

$note = Join-Path $probeDir 'resume.txt'
if ($NoResume) {
    Remove-Item (Join-Path $probeDir 'resume.go') -ErrorAction SilentlyContinue
} elseif (Test-Path $note) {
    Write-Host "Resuming: $(Get-Content $note -TotalCount 1)"
    Set-Content -Path (Join-Path $probeDir 'resume.go') -Value '' -Encoding utf8
} else {
    Write-Warning "No $note yet, so the game will stop at the title screen."
}

# The shipping exe directly, so a restart doesn't wait on Steam finishing with the last run (Steam itself
# stays running, and Steam's own overlay and cloud sync are skipped). -ViaSteam goes through the store
# entry instead, which is what a player does.
$exe = Join-Path $GameDir 'Falcon\Binaries\Win64\Spyro-Win64-Shipping.exe'
$direct = -not $ViaSteam -and (Test-Path $exe)
# The launch can still land in Steam's "Game already running" window and do nothing at all, so this checks
# that the process actually came up and tries again if it didn't.
for ($try = 1; $try -le 3; $try++) {
    if ($direct) {
        Write-Host "Starting $exe..."
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    } else {
        Write-Host "Starting the game (steam://rungameid/$AppId)..."
        Start-Process "steam://rungameid/$AppId"
    }
    $up = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $up = Get-Process -Name 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue
        if ($up) { break }
    }
    if ($up) { break }
    Write-Warning "The game did not start (attempt $try); Steam may still think it is running."
    Start-Sleep -Seconds $SteamSettle
}
if (-not (Get-Process -Name 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue)) {
    throw 'The game would not start. Close any Steam "Game already running" dialog and try again.'
}

$log = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\UE4SS.log'

# Steam's DRM wrapper is what decrypts the game's code, and a direct launch sometimes gets going before
# that has happened: every UE4SS pattern scan then fails ("[PS] Scan failed" with nothing found) and the
# game sits there with no mods and no level. Watch for the scan result and, if it never succeeds, start
# over through Steam, which always decrypts first.
if ($direct) {
    $scanDeadline = (Get-Date).AddSeconds(60)
    $scanned = $false
    while ((Get-Date) -lt $scanDeadline) {
        Start-Sleep -Seconds 3
        if (-not (Test-Path $log)) { continue }
        if (Select-String -Path $log -Pattern 'PS scan successful' -Quiet) { $scanned = $true; break }
    }
    if (-not $scanned) {
        Write-Warning 'UE4SS found none of its patterns (the game code was still encrypted); restarting through Steam.'
        Get-Process -Name $processNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        while (Get-Process -Name $processNames -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds $SteamSettle
        if (-not $NoResume -and (Test-Path $note)) {
            Set-Content -Path (Join-Path $probeDir 'resume.go') -Value '' -Encoding utf8
        }
        Write-Host "Starting the game (steam://rungameid/$AppId)..."
        Start-Process "steam://rungameid/$AppId"
    }
}

if ($NoResume -or $Wait -le 0) { return }

# Only lines written after this point count: UE4SS appends to the same log, so an older run's resume
# lines are still in there. A shorter file than before means the log was started over.
$before = if (Test-Path $log) { (Get-Content $log | Measure-Object -Line).Lines } else { 0 }
$deadline = (Get-Date).AddSeconds($Wait)
Write-Host "Waiting up to $Wait s for the level..."
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (-not (Test-Path $log)) { continue }
    $all = Get-Content $log
    $new = if ($all.Count -lt $before) { $all } else { $all | Select-Object -Skip $before }
    $line = $new | Where-Object { $_ -match 'resume: (back in|arrived|gave up|can''t travel|start game.*failed)' } | Select-Object -Last 1
    if ($line) {
        Write-Host $line
        return
    }
}
Write-Warning "No resume line in the log after $Wait s; check $log."
