<#
.SYNOPSIS
    Builds the release zip for "UE4SS for Spyro Reignited Trilogy" into build\release\.

.DESCRIPTION
    Repackages the UE4SS experimental build in tools\bin\ue4ss-dist\ as a standalone mod page
    download: the files are laid out relative to the game root, so players extract the zip into
    "Spyro Reignited Trilogy\" and get dwmapi.dll plus ue4ss\ in Falcon\Binaries\Win64.

    The only change to UE4SS itself is the engine version override (4.19) in UE4SS-settings.ini;
    the source dist is left untouched. UE4SS is MIT licensed, so its LICENSE ships both in place
    (ue4ss\LICENSE, as released) and as LICENSE.txt in the zip root, and README-ue4ss.txt
    carries the credits and the list of changes. Do not strip those: the licence requires the
    copyright and permission notice to travel with the files.

    The version comes from tools\bin\ue4ss-dist\VERSION.txt (written by whoever extracted the
    dist) and names the zip, e.g. UE4SS-for-Spyro-v3.0.1-1133-gb4cefa18.zip.
    vortex_override_instructions.json in the zip root switches Vortex to the "dinput" mod type,
    which deploys into the game directory; see Package-Release.ps1 for why that is the right one.

.EXAMPLE
    .\tools\Package-UE4SS-Release.ps1
    .\tools\Package-UE4SS-Release.ps1 -Version v3.0.1-1133-gb4cefa18
#>
param(
    [string] $Version,
    [string] $ReleaseName = 'UE4SS-for-Spyro'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\Zip.ps1"

$dist = Join-Path $PSScriptRoot 'bin\ue4ss-dist'
$distUe4ss = Join-Path $dist 'ue4ss'
if (-not (Test-Path (Join-Path $dist 'dwmapi.dll'))) {
    throw "UE4SS not found in $dist. Extract a UE4SS experimental release zip there (https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)."
}

if (-not $Version) {
    $versionFile = Join-Path $dist 'VERSION.txt'
    if (-not (Test-Path $versionFile)) { throw "No $versionFile and no -Version. Write the UE4SS build name into VERSION.txt, e.g. 'UE4SS_v3.0.1-1133-gb4cefa18'." }
    $versionMatch = Select-String -Path $versionFile -Pattern 'UE4SS_(v[\w.\-]+)' | Select-Object -First 1
    if (-not $versionMatch) { throw "No 'UE4SS_v...' build name in $versionFile. Pass -Version instead." }
    $Version = $versionMatch.Matches[0].Groups[1].Value
}

# The engine version UE4SS has to run as for this game. Everything else stays as released.
$settingsPath = Join-Path $distUe4ss 'UE4SS-settings.ini'
$settings = Get-Content $settingsPath -Raw
foreach ($setting in @{ MajorVersion = 4; MinorVersion = 19 }.GetEnumerator()) {
    $pattern = "(?m)^$($setting.Key)\s*=.*$"
    if ($settings -notmatch $pattern) { throw "No '$($setting.Key) =' line in $settingsPath; UE4SS's settings layout changed." }
    $settings = $settings -replace $pattern, "$($setting.Key) = $($setting.Value)"
}

$license = Join-Path $distUe4ss 'LICENSE'
if (-not (Test-Path $license)) { throw "UE4SS's LICENSE is missing from $distUe4ss. It has to ship with the files." }

$readme = (Get-Content (Join-Path $RepoRoot 'README-ue4ss.txt') -Raw).Replace('{{UE4SS_VERSION}}', $Version)

$vortexOverrides = @'
[
  {
    "type": "setmodtype",
    "value": "dinput"
  }
]
'@

$prefix = 'Falcon/Binaries/Win64'
# Values: a file path to copy in, or a string of literal text; $null makes an empty entry.
$entries = [ordered]@{
    'README.txt' = $readme
    'LICENSE.txt' = $license
    'vortex_override_instructions.json' = $vortexOverrides
}
foreach ($file in Get-ChildItem $dist -Recurse -File) {
    $relative = $file.FullName.Substring($dist.Length + 1).Replace('\', '/')
    if ($relative -eq 'VERSION.txt') { continue }  # our own note about the dist, not part of UE4SS
    $entries["$prefix/$relative"] = if ($relative -eq 'ue4ss/UE4SS-settings.ini') { $settings } else { $file.FullName }
}

New-ZipFromEntries -Path (Join-Path $BuildDir "release\$ReleaseName-$Version.zip") -Entries $entries

# The mod page text carries the same build name, so fill it in from the same place.
$descriptionOut = Join-Path $BuildDir 'release\nexus-description-ue4ss.bbcode'
$description = (Get-Content (Join-Path $RepoRoot 'nexus-description-ue4ss.bbcode') -Raw).Replace('{{UE4SS_VERSION}}', $Version)
Set-Content $descriptionOut $description -NoNewline
Write-Host "Wrote $descriptionOut (paste into the mod page description)"
