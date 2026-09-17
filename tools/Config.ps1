# Shared paths for the tooling scripts. Dot-source this file: . "$PSScriptRoot\Config.ps1"
# Override the game location by setting $env:SPYRO_GAME_DIR.

$GameDir = if ($env:SPYRO_GAME_DIR) { $env:SPYRO_GAME_DIR } else {
    'C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot 'build'

# Game save files, and where Save-GameSnapshot.ps1 keeps named copies of them.
$SaveGamesDir = Join-Path $env:LOCALAPPDATA 'Falcon\Saved\SaveGames'
$SnapshotDir = Join-Path $BuildDir 'saves'
