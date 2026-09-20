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
    Files that a tagged release shipped but this version no longer has are added as a one-line comment,
    because extracting a zip over an older install cannot delete anything (Nexus and Vortex both just
    extract). Only tagged releases count, so files that came and went between releases are ignored.
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

# Extracting a zip over an older install cannot delete anything, so a file dropped since the last
# release would stay in the player's mod folder (and a stale Scripts file still loads). Every file any
# released version shipped but this one doesn't gets an entry that overwrites it with a comment saying
# it is gone. Only tagged releases count: files that came and went between them never reached anyone.
$released = @{}
$tags = @(& git -C $RepoRoot tag 2>$null)
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'git tag failed: cannot check for files retired since the last release.'
} elseif (-not $tags) {
    Write-Warning 'No release tags: cannot check for files retired since the last release.'
}
foreach ($tag in $tags) {
    foreach ($path in @(& git -C $RepoRoot ls-tree -r --name-only $tag -- "ue4ss/Mods/$ModName")) {
        if ($path) { $released[$path.Substring("ue4ss/Mods/$ModName/".Length)] = $tag }
    }
}
$retired = @($released.Keys | Where-Object { -not (Test-Path (Join-Path $modDir ($_ -replace '/', '\'))) } | Sort-Object)
foreach ($relative in $retired) {
    $lastTag = $released[$relative]
    $note = "Removed in $version (was last shipped in $lastTag). Kept as an empty file because extracting a release zip cannot delete files."
    # A leftover .lua must parse and do nothing if anything still requires it; other files just say why.
    $entries["$prefix/$relative"] = if ($relative -like '*.lua') { "-- $note`n" } else { "$note`n" }
    Write-Host "Retired: $relative (last in $lastTag)"
}

$entries['vortex_override_instructions.json'] = $vortexOverrides

New-ZipFromEntries -Path (Join-Path $BuildDir "release\$ReleaseName-$version.zip") -Entries $entries
