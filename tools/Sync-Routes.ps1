<#
.SYNOPSIS
    Copies the world tour's stops between the deployed probe folder and this repo.

.DESCRIPTION
    routes.txt lives in the deployed probe folder, because that is where the game writes it: M records
    a stop, H scans the level and a scansweep.txt run scans every level (tools/scansweep.lua). It is
    hours of recording and it used to exist nowhere else, so a reinstall or a new machine lost the lot.

    -Pull (the default) copies the deployed file into the repo, to be committed. -Push copies the repo
    copy out to the game, for a machine that has no stops yet. Install-UE4SS.ps1 already seeds the file
    when the probe folder has none, so -Push is for replacing one that is there.

    Both directions refuse to overwrite a file that has more stops than the one being copied, since
    that is how a route gets thrown away; pass -Force when that is really what you want. Comment and
    blank lines are not counted. A backup of whatever was overwritten goes next to it as
    routes.backup.txt.

.PARAMETER Pull
    Deployed -> repo. The default when neither direction is given.

.PARAMETER Push
    Repo -> deployed.

.PARAMETER Force
    Overwrite even when the destination has more stops than the source.

.EXAMPLE
    .\tools\Sync-Routes.ps1
    .\tools\Sync-Routes.ps1 -Push
    .\tools\Sync-Routes.ps1 -Pull -Force
#>
param(
    [switch] $Pull,
    [switch] $Push,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if ($Pull -and $Push) { throw "Pick one direction: -Pull or -Push." }

$repoFile = Join-Path $RepoRoot 'ue4ss\DevMods\SpyroFpsProbe\routes.txt'
$gameFile = Join-Path $ProbeDir 'routes.txt'

if ($Push) {
    $source, $destination, $what = $repoFile, $gameFile, 'repo -> game'
} else {
    $source, $destination, $what = $gameFile, $repoFile, 'game -> repo'
}

# Stops, not lines: the seed copy is all comments, and a file of comments must not look like a route
# worth keeping.
function Get-StopCount($path) {
    if (-not (Test-Path $path)) { return $null }
    @(Get-Content $path | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }).Count
}

function Get-LevelSummary($path) {
    if (-not (Test-Path $path)) { return '' }
    $levels = Get-Content $path |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
        ForEach-Object { ($_ -split '\|')[0] } |
        Sort-Object -Unique
    if ($levels.Count -eq 0) { return '' }
    "$($levels.Count) level(s): $($levels -join ' ')"
}

if (-not (Test-Path $source)) {
    throw "No routes.txt at $source. Record some stops first (M or H in game, or a scansweep.txt run)."
}

$sourceStops = Get-StopCount $source
$destinationStops = Get-StopCount $destination

Write-Host "$what"
Write-Host "  from $source ($sourceStops stop(s))"
if ($null -eq $destinationStops) {
    Write-Host "  to   $destination (no file yet)"
} else {
    Write-Host "  to   $destination ($destinationStops stop(s))"
}
$summary = Get-LevelSummary $source
if ($summary) { Write-Host "  $summary" }

if ($null -ne $destinationStops -and $destinationStops -gt $sourceStops -and -not $Force) {
    throw ("$destination has $destinationStops stop(s) and the source only $sourceStops. " +
           "Copying would lose $($destinationStops - $sourceStops) of them; pass -Force if that is intended.")
}

if ($null -ne $destinationStops) {
    $backup = Join-Path (Split-Path -Parent $destination) 'routes.backup.txt'
    Copy-Item $destination $backup -Force
    Write-Host "  previous file kept as $backup"
}

New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
Copy-Item $source $destination -Force
Write-Host "Copied $sourceStops stop(s)."
if (-not $Push) { Write-Host "Commit ue4ss\DevMods\SpyroFpsProbe\routes.txt to keep them." }
