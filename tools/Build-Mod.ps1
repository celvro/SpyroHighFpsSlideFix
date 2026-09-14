<#
.SYNOPSIS
    Packs mods\<Name> into build\<Name>_P.pak and optionally installs it into the game's ~mods folder.

.DESCRIPTION
    The mod folder's contents are packed relative to the ../../../ mount point, so files must be laid
    out as they would be in the game root, e.g. mods\FpsFixes\Falcon\Config\DefaultEngine.ini.
    The _P suffix gives the pak priority over the retail paks.

.EXAMPLE
    .\tools\Build-Mod.ps1 -Name FpsFixes -Install
#>
param(
    [Parameter(Mandatory)] [string] $Name,
    [switch] $Install
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

$src = Join-Path $ModsDir $Name
if (-not (Test-Path $src)) { throw "Mod folder not found: $src" }

# Stage a copy without placeholder files so they never end up in the pak.
$stage = Join-Path $BuildDir "stage\$Name"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item "$src\*" $stage -Recurse -Force
Get-ChildItem $stage -Recurse -File -Filter '.gitkeep' | Remove-Item -Force

$files = @(Get-ChildItem $stage -Recurse -File)
if ($files.Count -eq 0) { throw "Mod '$Name' has no files to pack." }

foreach ($f in $files) {
    $rel = $f.FullName.Substring($stage.Length + 1)
    if ($rel -notmatch '^(Falcon|Engine)\\') {
        Write-Warning "$rel is not under Falcon\ or Engine\ and will not override any game file."
    }
}

$repak = Find-Repak
$pak = Join-Path $BuildDir "${Name}_P.pak"
& $repak pack --version $PakVersion --mount-point $PakMountPoint $stage $pak
if ($LASTEXITCODE -ne 0) { throw "repak failed with exit code $LASTEXITCODE" }
Write-Host "Built $pak ($($files.Count) files)"

if ($Install) {
    New-Item -ItemType Directory -Force $GameModsDir | Out-Null
    Copy-Item $pak $GameModsDir -Force
    Write-Host "Installed to $GameModsDir"
}
