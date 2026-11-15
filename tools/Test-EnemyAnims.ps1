<#
.SYNOPSIS
    Spawns one enemy in the probe's empty test room and compares all of its animations at 30 and 320 FPS:
    its montages played in place, then the enemy let loose while Spyro acts on it (with powerups if asked).

.DESCRIPTION
    Drives the montage sweep's "spawn=" option (ue4ss/DevMods/SpyroFpsProbe/Scripts/tools/animtest.lua
    and tools/testroom.lua) from outside the game and waits for it:

      1. makes sure the game is running with the repo's probe scripts (deploys and starts it if it is
         not running; refuses to touch a running game whose scripts are stale unless -Restart is given),
      2. writes animtest.txt: Spyro is put on a flat floor in the empty sky above the level he is in,
         the enemy is spawned in the middle of it, and every montage its skeleton can play is played at
         each cap in turn, from the same spot,
         then the free phase (tools/freetest.lua): a fresh copy of the enemy per trial, let loose, with
         Spyro doing each of -Acts to it (and given -Power first), at each cap,
      3. follows UE4SS.log until the run says it is done (or failed, or the game died),
      4. copies this run's rows to build\animtest\<stamp>_<enemy>\ (animtest.csv for the montages,
         animtest_free.csv and animtest_freesamples.csv for the free phase) and writes compare.txt
         (Compare-Animtest.ps1) and compare-free.txt (Compare-AnimFree.ps1) next to them.

    A flagged montage means "measure it again" (-Montage <name>), not "a bug": see
    docs/findings/animations.md.

.PARAMETER Enemy
    A class from tools/spawnlist.lua by name or by the one entry containing it (Cowlek, CES1015_Ram,
    BP_CES1015_Ram_C), or a full class path (/CES1015_Ram/Blueprints/BP_CES1015_Ram.BP_CES1015_Ram_C)
    for a character the list does not hold.

.PARAMETER Caps
    Framerate caps to measure, in order. The first is the baseline of the comparison.

.PARAMETER Level
    Travel to this level first (LS101). Without it the room is built over the level Spyro is in.

.PARAMETER Montage
    Only montages whose name contains this.

.PARAMETER Acts
    What Spyro does in the free phase, one trial per act per cap: idle, approach, flame, charge,
    superflame, supercharge, icebreath, superjump. Default idle, approach, flame, charge.

.PARAMETER Power
    Powerups given to Spyro before every act, on top of the act's own (superflame, supercharge, superfly,
    invincible, icebreath, superjump, iface:<IForceAbility function>, or a gameplay effect class path).

.PARAMETER Tries
    Trials per act per cap (default 1). Gameplay varies between tries; use 3 before trusting a difference.

.PARAMETER FreeSeconds
    Seconds per free trial (default 8); 0 skips the free phase.

.PARAMETER NoMontages
    Skip the montage phase.

.PARAMETER Arena
    sky (default): the floor in the sky. level: the level ground in front of Spyro, for an enemy that finds
    its way by navmesh (there is none on the sky floor). Stand Spyro on open flat ground first.

.PARAMETER Restart
    Allow closing a running game to deploy changed probe scripts.

.PARAMETER Timeout
    Seconds to wait for the run to finish (default 1800).

.EXAMPLE
    .\tools\Test-EnemyAnims.ps1 -Enemy Cowlek
    .\tools\Test-EnemyAnims.ps1 -Enemy CES1015_Ram -Montage Attack -Caps 30,320,160
    .\tools\Test-EnemyAnims.ps1 -Enemy Cowlek -Acts superflame,flame -Tries 3 -NoMontages
    .\tools\Test-EnemyAnims.ps1 -Enemy CES1019_ArmyGnorc -Acts supercharge -Arena level
#>
param(
    [Parameter(Mandatory)] [string] $Enemy,
    [int[]] $Caps = @(30, 320),
    [string] $Level,
    [string] $Montage,
    [string[]] $Acts,
    [string[]] $Power,
    [int] $Tries = 1,
    [int] $FreeSeconds = -1,
    [switch] $NoMontages,
    [ValidateSet('sky', 'level')] [string] $Arena = 'sky',
    [switch] $Restart,
    [int] $Timeout = 1800
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if ($Enemy -match '\s' -or $Montage -match '\s' -or $Level -match '\s') { throw 'Options cannot contain spaces.' }
$processName = 'Spyro-Win64-Shipping'
$log = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\UE4SS.log'
$source = Join-Path $RepoRoot 'ue4ss\DevMods\SpyroFpsProbe\Scripts'
$deployed = Join-Path $ProbeDir 'Scripts'

function Test-ScriptsCurrent {
    if (-not (Test-Path (Join-Path $ProbeDir 'enabled.txt'))) { return $false }
    foreach ($file in Get-ChildItem $source -Recurse -File) {
        $other = Join-Path $deployed $file.FullName.Substring($source.Length + 1)
        if (-not (Test-Path $other)) { return $false }
        if ((Get-FileHash $other).Hash -ne (Get-FileHash $file.FullName).Hash) { return $false }
    }
    return $true
}

$running = [bool] (Get-Process -Name $processName -ErrorAction SilentlyContinue)
$current = Test-ScriptsCurrent
if (-not $current) {
    if ($running) {
        if (-not $Restart) {
            throw 'The game is running with probe scripts that differ from the repo. Close it, or pass -Restart to have it closed, deployed to and started again.'
        }
        # Deploying while the game runs reloads the mod, which can crash this UE4SS build: close it first.
        Write-Host 'Closing the game to deploy the probe...'
        foreach ($p in Get-Process -Name $processName, 'Spyro' -ErrorAction SilentlyContinue) {
            $null = $p.CloseMainWindow()
            if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
        while (Get-Process -Name $processName, 'Spyro' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
        $running = $false
    }
    & "$PSScriptRoot\Install-UE4SS.ps1" -ModsOnly -Probe
}
# A trigger or stop file left by an earlier attempt would start or end this run on its own.
Remove-Item (Join-Path $ProbeDir 'animtest.stop'), (Join-Path $ProbeDir 'animtest.txt') -ErrorAction SilentlyContinue
if (-not $running) {
    & "$PSScriptRoot\Restart-Game.ps1"
    if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { throw 'The game is not running.' }
}

# The probe writes one file of each kind per game session, named animtest[_<kind>]_<stamp>.csv.
function Get-RunCsv([string] $kind) {
    $prefix = if ($kind) { "animtest_$($kind)_" } else { 'animtest_' }
    Get-ChildItem (Join-Path $ProbeDir "$prefix*.csv") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '\d{8}_\d{6}\.csv$') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function Read-Shared([string] $path) {
    # The game holds both files open for writing.
    $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($stream)).ReadToEnd() -split "`r?`n" } finally { $stream.Dispose() }
}

# Where each file ends now, so only this run's rows are taken. Non-empty lines only: the split leaves an
# empty string after the last newline, and counting it skipped the first row of a second run in the same
# game session (one CSV per session, appended to).
$kinds = @('', 'free', 'freesamples')
$before = @{}
foreach ($kind in $kinds) {
    $file = Get-RunCsv $kind
    $before[$kind] = if ($file) { @{ Path = $file.FullName; Rows = @(Read-Shared $file.FullName | Where-Object { $_ }).Count } } else { $null }
}
$logBefore = if (Test-Path $log) { @(Read-Shared $log).Count } else { 0 }

$options = @("spawn=$Enemy", "caps=$($Caps -join ',')")
if ($Level) { $options += "level=$Level" }
if ($Montage) { $options += "montage=$Montage" }
if ($Acts) { $options += "act=$(($Acts | ForEach-Object { $_ -split ',' }) -join ',')" }
if ($Power) { $options += "power=$(($Power | ForEach-Object { $_ -split ',' }) -join ',')" }
if ($Tries -gt 1) { $options += "tries=$Tries" }
if ($FreeSeconds -ge 0) { $options += "free=$FreeSeconds" }
if ($NoMontages) { $options += 'nomontages' }
if ($Arena -ne 'sky') { $options += "arena=$Arena" }
foreach ($o in $options) { if ($o -match '\s') { throw "Option '$o' cannot contain a space." } }
# No BOM: Windows PowerShell's utf8 writes one, and it eats the first option (CLAUDE.md).
[IO.File]::WriteAllText((Join-Path $ProbeDir 'animtest.txt'), ($options -join ' '), [Text.UTF8Encoding]::new($false))
Write-Host "animtest.txt: $($options -join ' ')"

$ended = '(animtest: (done|stopped|spawn=|could not|the test room|unknown)|animtest error)'
$deadline = (Get-Date).AddSeconds($Timeout)
$seen = 0
$outcome = $null
while (-not $outcome -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $all = @(Read-Shared $log)
    $new = if ($all.Count -lt $logBefore) { $all } else { $all | Select-Object -Skip $logBefore }
    $lines = @($new | Where-Object { $_ -match 'animtest|testroom|freetest' })
    foreach ($line in $lines | Select-Object -Skip $seen) {
        Write-Host $line.Trim()
        if ($line -match $ended) { $outcome = $line.Trim() }
    }
    $seen = $lines.Count
    if (-not $outcome -and -not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        throw "The game went away during the run. Crash dumps: $env:LOCALAPPDATA\Falcon\Saved\Crashes (build\DumpInfo\DumpInfo.exe <dmp>)."
    }
    if ($seen -eq 0 -and (Test-Path (Join-Path $ProbeDir 'animtest.txt')) -and (Get-Date) -gt $deadline.AddSeconds(90 - $Timeout)) {
        throw 'animtest.txt was not picked up in 90 s: the probe only reads it while Spyro is in a level and the game is not paused.'
    }
}
if (-not $outcome) {
    [IO.File]::WriteAllText((Join-Path $ProbeDir 'animtest.stop'), '')
    throw "The run did not finish in $Timeout s; asked it to stop (animtest.stop)."
}
if ($outcome -notmatch 'animtest: done') { throw "The run did not complete: $outcome" }

$label = ($Enemy -replace '^.*[/.]', '') -replace '[^\w-]', ''
$outDir = Join-Path $BuildDir ("animtest\{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $label)
New-Item -ItemType Directory -Force $outDir | Out-Null

# This run's rows of one kind of file, written next to the comparison with its header. Returns the path,
# or nothing when the run wrote none.
function Save-RunRows([string] $kind, [string] $name) {
    $file = Get-RunCsv $kind
    if (-not $file) { return $null }
    $text = @(Read-Shared $file.FullName | Where-Object { $_ })
    $was = $before[$kind]
    $skip = if ($was -and $was.Path -eq $file.FullName) { $was.Rows } else { 1 }
    $rows = @($text | Select-Object -Skip $skip)
    if (-not $rows) { return $null }
    $out = Join-Path $outDir $name
    [IO.File]::WriteAllLines($out, @($text[0]) + $rows)
    return $out
}

$montageCsv = Save-RunRows '' 'animtest.csv'
$freeCsv = Save-RunRows 'free' 'animtest_free.csv'
$null = Save-RunRows 'freesamples' 'animtest_freesamples.csv'
if (-not $montageCsv -and -not $freeCsv) { throw 'The run wrote no rows (see the log lines above).' }

if ($montageCsv) {
    $compare = Join-Path $outDir 'compare.txt'
    & "$PSScriptRoot\Compare-Animtest.ps1" -Path $montageCsv -Baseline $Caps[0] -All -Top 1000 *>&1 |
        Out-String -Width 400 | Set-Content $compare -Encoding ascii
    Write-Host '--- montages'
    Get-Content $compare | Select-Object -Last 6
} elseif (-not $NoMontages) {
    Write-Host 'No montage rows: the character had no montages loaded for its skeleton.'
}
if ($freeCsv) {
    $compareFree = Join-Path $outDir 'compare-free.txt'
    & "$PSScriptRoot\Compare-AnimFree.ps1" -Path $freeCsv -Baseline $Caps[0] *>&1 |
        Out-String -Width 400 | Set-Content $compareFree -Encoding ascii
    Write-Host '--- free phase'
    Get-Content $compareFree | Where-Object { $_ -match '\S' } | Select-Object -Last 14
}
Write-Host "Output: $outDir"
