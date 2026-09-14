# Shared paths for the tooling scripts. Dot-source this file: . "$PSScriptRoot\Config.ps1"
# Override the game location by setting $env:SPYRO_GAME_DIR.

$GameDir = if ($env:SPYRO_GAME_DIR) { $env:SPYRO_GAME_DIR } else {
    'C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy'
}

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ModsDir     = Join-Path $RepoRoot 'mods'
$BuildDir    = Join-Path $RepoRoot 'build'
$PaksDir     = Join-Path $GameDir 'Falcon\Content\Paks'
$GameModsDir = Join-Path $PaksDir '~mods'

# Unpacked reference copies of the retail paks (read-only; never edit these).
$UnpackedChunks = @{
    chunk0 = Join-Path $PaksDir 'chunk0'   # mount ../../../        -> contains Engine/ and Falcon/
    chunk1 = Join-Path $PaksDir 'chunk1'   # mount ../../../Falcon/ -> contains Content/ and Plugins/
    chunk2 = Join-Path $PaksDir 'chunk2'   # mount ../../../Falcon/ -> contains Content/ and Plugins/
}

# Retail paks are version 4 with an unencrypted index.
$PakVersion    = 'V4'
$PakMountPoint = '../../../'

function Find-Repak {
    $local = Join-Path $PSScriptRoot 'bin\repak.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command repak -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "repak not found. Put repak.exe in tools\bin\ or on PATH (https://github.com/trumank/repak/releases)."
}
