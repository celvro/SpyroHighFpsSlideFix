<#
.SYNOPSIS
    Copies the game's save files into a named snapshot under build/saves.
.DESCRIPTION
    The game saves progress, not position: a snapshot restores enemies, level mechanisms and cutscenes to
    how they were at the last autosave, and loading the level starts at its entrance. Take it after the
    autosave you want (the save icon), ideally from the title screen or with the game closed.
    Restore with Restore-GameSnapshot.ps1.
.EXAMPLE
    .\tools\Save-GameSnapshot.ps1 fireworks-dragons
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if ($Name -notmatch '^[\w.-]+$') { throw "Snapshot name may only use letters, digits, '_', '-' and '.'." }
$files = @(Get-ChildItem $SaveGamesDir -File -Filter '*.sav')
if (-not $files) { throw "No .sav files in $SaveGamesDir." }

$dest = Join-Path $SnapshotDir $Name
if (Test-Path $dest) {
    if (-not $Force) { throw "Snapshot '$Name' already exists. Use -Force to replace it." }
    Remove-Item $dest -Recurse -Force
}
New-Item -ItemType Directory -Force $dest | Out-Null
$files | Copy-Item -Destination $dest

if (Get-Process 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue) {
    Write-Warning 'The game is running: this copies the last save it wrote, not the current moment.'
}
foreach ($f in $files) { Write-Host ("Saved {0} ({1:N0} KB, written {2})" -f $f.Name, ($f.Length / 1KB), $f.LastWriteTime) }
Write-Host "Snapshot '$Name' -> $dest"
