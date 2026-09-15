<#
.SYNOPSIS
    Builds the release zip for High FPS Gameplay Fixes into build\release\.

.DESCRIPTION
    The zip is laid out relative to the game root, so players extract it into
    "Spyro Reignited Trilogy\" and the mod lands in Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix\
    with an enabled.txt (UE4SS loads it without editing mods.txt). The version comes from the
    VERSION constant in the mod's main.lua. UE4SS itself is not included.
    The zip is named after the mod page ($ReleaseName), but the folder keeps the original
    $ModName so a new version overwrites an older install instead of loading next to it.

.EXAMPLE
    .\tools\Package-Release.ps1
#>
param(
    [string] $ModName = 'HighFpsSlidingAndJumpFix',
    [string] $ReleaseName = 'HighFpsGameplayFixes'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$modDir = Join-Path $RepoRoot "ue4ss\Mods\$ModName"
$mainLua = Join-Path $modDir 'Scripts\main.lua'
if (-not (Test-Path $mainLua)) { throw "Mod not found: $mainLua" }

$versionMatch = Select-String -Path $mainLua -Pattern '^local VERSION = "([^"]+)"' | Select-Object -First 1
if (-not $versionMatch) { throw "No 'local VERSION = ""x.y.z""' line in $mainLua" }
$version = $versionMatch.Matches[0].Groups[1].Value

$releaseDir = Join-Path $BuildDir 'release'
New-Item -ItemType Directory -Force $releaseDir | Out-Null
$zipPath = Join-Path $releaseDir "$ReleaseName-$version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$prefix = "Falcon/Binaries/Win64/ue4ss/Mods/$ModName"
$entries = [ordered]@{}
foreach ($file in Get-ChildItem $modDir -Recurse -File) {
    $relative = $file.FullName.Substring($modDir.Length + 1).Replace('\', '/')
    $entries["$prefix/$relative"] = $file.FullName
}
$entries["$prefix/enabled.txt"] = $null

# Build entries by hand: Compress-Archive in Windows PowerShell writes backslash paths, which
# some extractors (and mod managers) treat as file names instead of folders.
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($name in $entries.Keys) {
        $source = $entries[$name]
        if ($source) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $name, 'Optimal') | Out-Null
        } else {
            $zip.CreateEntry($name) | Out-Null
        }
    }
} finally {
    $zip.Dispose()
}

Write-Host "Built $zipPath"
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try { $check.Entries | ForEach-Object { Write-Host "  $($_.FullName) ($($_.Length) bytes)" } } finally { $check.Dispose() }
