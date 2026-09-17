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
    vortex_override_instructions.json in the zip root switches Vortex to the "dinput" mod type.
    Vortex's game-spyroreignitedtrilogy extension registers no mod types of its own and its
    default path is Falcon\Content\Paks\~mods (its .pak installer skips us, so the fallback
    installer copies every entry at its archive-relative path). The core "dinput" type
    (extensions/modtype-dinput, shown as "Engine Injector") deploys to the game directory
    instead, which is what these paths are relative to. The name is the type id, not the
    loader dll: it is not tied to dinput8.dll, and its own installer (which does look for
    that file) is bypassed. gameSupported() allows it for this game.

.EXAMPLE
    .\tools\Package-Release.ps1
#>
param(
    [string] $ModName = 'HighFpsSlidingAndJumpFix',
    [string] $ReleaseName = 'HighFpsGameplayFixes'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\Zip.ps1"

$modDir = Join-Path $RepoRoot "ue4ss\Mods\$ModName"
$mainLua = Join-Path $modDir 'Scripts\main.lua'
if (-not (Test-Path $mainLua)) { throw "Mod not found: $mainLua" }

$versionMatch = Select-String -Path $mainLua -Pattern '^local VERSION = "([^"]+)"' | Select-Object -First 1
if (-not $versionMatch) { throw "No 'local VERSION = ""x.y.z""' line in $mainLua" }
$version = $versionMatch.Matches[0].Groups[1].Value

$vortexOverrides = @'
[
  {
    "type": "setmodtype",
    "value": "dinput"
  }
]
'@

$prefix = "Falcon/Binaries/Win64/ue4ss/Mods/$ModName"
# Values: a file path to copy in, or a string of literal text; $null makes an empty entry.
$entries = [ordered]@{}
foreach ($file in Get-ChildItem $modDir -Recurse -File) {
    $relative = $file.FullName.Substring($modDir.Length + 1).Replace('\', '/')
    $entries["$prefix/$relative"] = $file.FullName
}
$entries["$prefix/enabled.txt"] = $null
$entries['vortex_override_instructions.json'] = $vortexOverrides

New-ZipFromEntries -Path (Join-Path $BuildDir "release\$ReleaseName-$version.zip") -Entries $entries
