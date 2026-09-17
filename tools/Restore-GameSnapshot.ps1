<#
.SYNOPSIS
    Restores a snapshot from Save-GameSnapshot.ps1 over the game's save files. Without -Name, lists snapshots.
.DESCRIPTION
    The game must be closed, since it keeps its save state in memory and would overwrite the files.
    The current saves are first copied to the snapshot '_before-restore' (replaced each time), so an
    accidental restore can be undone with: Restore-GameSnapshot.ps1 _before-restore
.EXAMPLE
    .\tools\Restore-GameSnapshot.ps1 fireworks-dragons
#>
param([string]$Name)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

if (-not $Name) {
    $snapshots = @(Get-ChildItem $SnapshotDir -Directory -ErrorAction SilentlyContinue)
    if (-not $snapshots) { Write-Host "No snapshots in $SnapshotDir."; return }
    $snapshots | Sort-Object Name | ForEach-Object {
        $save = Get-ChildItem $_.FullName -File -Filter '*.sav' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        [pscustomobject]@{ Name = $_.Name; SaveWritten = $save.LastWriteTime }
    } | Format-Table -AutoSize
    return
}

$src = Join-Path $SnapshotDir $Name
$files = @(Get-ChildItem $src -File -Filter '*.sav' -ErrorAction SilentlyContinue)
if (-not $files) { throw "Snapshot '$Name' not found (or empty) in $SnapshotDir." }
if (Get-Process 'Spyro-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close the game first: it would overwrite the restored save with its in-memory state.'
}

if ($Name -ne '_before-restore') {
    $backup = Join-Path $SnapshotDir '_before-restore'
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    New-Item -ItemType Directory -Force $backup | Out-Null
    Get-ChildItem $SaveGamesDir -File -Filter '*.sav' | Copy-Item -Destination $backup
}

# Remove saves the snapshot doesn't have, so a slot created after the snapshot doesn't linger.
Get-ChildItem $SaveGamesDir -File -Filter '*.sav' | Where-Object { $files.Name -notcontains $_.Name } | Remove-Item
$files | Copy-Item -Destination $SaveGamesDir -Force
# Mark the restored files as new so Steam Cloud treats them as the latest local change and uploads them.
Get-ChildItem $SaveGamesDir -File -Filter '*.sav' | ForEach-Object { $_.LastWriteTime = Get-Date }

foreach ($f in $files) { Write-Host ("Restored {0} ({1:N0} KB, originally written {2})" -f $f.Name, ($f.Length / 1KB), $f.LastWriteTime) }
Write-Host "Snapshot '$Name' restored. Previous saves are in '_before-restore'."
