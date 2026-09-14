<#
.SYNOPSIS
    Removes an installed mod pak (<Name>_P.pak) from the game's ~mods folder.
#>
param([Parameter(Mandatory)] [string] $Name)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

$pak = Join-Path $GameModsDir "${Name}_P.pak"
if (Test-Path $pak) {
    Remove-Item $pak -Force
    Write-Host "Removed $pak"
} else {
    Write-Host "Not installed: $pak"
}
