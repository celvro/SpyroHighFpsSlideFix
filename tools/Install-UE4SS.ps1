<#
.SYNOPSIS
    Installs UE4SS (from tools\bin\ue4ss-dist) into the game and deploys this repo's Lua mods.

.DESCRIPTION
    Copies dwmapi.dll + ue4ss\ next to Spyro-Win64-Shipping.exe, applies the settings this project
    needs, then copies each folder in ue4ss\Mods\ (the fixes) into the game's ue4ss\Mods\ with an
    enabled.txt. Development mods in ue4ss\DevMods\ (the probe) are only deployed with -Probe;
    without it, any previously deployed dev mod is disabled (its enabled.txt is removed, logs kept).
    Re-run after editing a Lua mod, then restart the game. Use -ModsOnly to skip reinstalling UE4SS.

.EXAMPLE
    .\tools\Install-UE4SS.ps1
    .\tools\Install-UE4SS.ps1 -ModsOnly
    .\tools\Install-UE4SS.ps1 -ModsOnly -Probe
    .\tools\Install-UE4SS.ps1 -Uninstall
#>
param(
    [switch] $ModsOnly,
    [switch] $Probe,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"

$win64 = Join-Path $GameDir 'Falcon\Binaries\Win64'
$gameUe4ss = Join-Path $win64 'ue4ss'

if ($Uninstall) {
    Remove-Item (Join-Path $win64 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
    if (Test-Path $gameUe4ss) { Remove-Item $gameUe4ss -Recurse -Force }
    Write-Host "Removed UE4SS from $win64"
    return
}

if (-not $ModsOnly) {
    $dist = Join-Path $PSScriptRoot 'bin\ue4ss-dist'
    if (-not (Test-Path (Join-Path $dist 'dwmapi.dll'))) {
        throw "UE4SS not found in $dist. Extract a UE4SS release zip there (https://github.com/UE4SS-RE/RE-UE4SS/releases)."
    }
    Copy-Item (Join-Path $dist 'dwmapi.dll') $win64 -Force
    Copy-Item (Join-Path $dist 'ue4ss') $win64 -Recurse -Force

    $settings = Join-Path $gameUe4ss 'UE4SS-settings.ini'
    $ini = Get-Content $settings -Raw
    $ini = $ini -replace '(?m)^ConsoleEnabled = .*$', 'ConsoleEnabled = 1'
    # Hot reload: Ctrl+R, and saving a file in a mod's Scripts folder reloads that mod on its own, so
    # a probe change can be tried without restarting the game. Both need the patched UE4SS.dll in
    # bin\ue4ss-dist (tools\ue4ss-patches\luamod-hot-reload-actions-mutex.patch); the stock build
    # crashes the game on a reload.
    $ini = $ini -replace '(?m)^EnableHotReloadSystem = .*$', 'EnableHotReloadSystem = 1'
    $ini = $ini -replace '(?m)^EnableAutoReloadingLuaMods = .*$', 'EnableAutoReloadingLuaMods = 1'
    $ini = $ini -replace '(?m)^MajorVersion = .*$', 'MajorVersion = 4'
    $ini = $ini -replace '(?m)^MinorVersion = .*$', 'MinorVersion = 19'
    Set-Content $settings $ini -NoNewline
    Write-Host "Installed UE4SS to $win64"
}

function Deploy-LuaMod($mod) {
    $target = Join-Path $gameUe4ss "Mods\$($mod.Name)"
    New-Item -ItemType Directory -Force $target | Out-Null
    # Only files that actually differ, because UE4SS reloads a mod as soon as anything under its
    # Scripts folder is written: copying everything every time reloads mods that didn't change, and
    # reloading is the risky moment (see docs/ue4ss.md). Sizes and contents, not timestamps: a copy
    # keeps the source's write time.
    $copied = 0
    foreach ($source in Get-ChildItem $mod.FullName -Recurse -File) {
        $relative = $source.FullName.Substring($mod.FullName.Length + 1)
        $destination = Join-Path $target $relative
        $existing = Get-Item $destination -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -eq $source.Length -and
            (Get-FileHash $destination).Hash -eq (Get-FileHash $source.FullName).Hash) {
            continue
        }
        New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
        Copy-Item $source.FullName $destination -Force
        $copied++
    }
    $enabled = Join-Path $target 'enabled.txt'
    if (-not (Test-Path $enabled)) { Set-Content $enabled '' -NoNewline }
    if ($copied) {
        Write-Host "Deployed Lua mod $($mod.Name) ($copied file(s) changed)"
    } else {
        Write-Host "Lua mod $($mod.Name) is already up to date"
    }
}

foreach ($mod in Get-ChildItem (Join-Path $RepoRoot 'ue4ss\Mods') -Directory) {
    Deploy-LuaMod $mod
}

foreach ($mod in Get-ChildItem (Join-Path $RepoRoot 'ue4ss\DevMods') -Directory) {
    if ($Probe) {
        Deploy-LuaMod $mod
        continue
    }
    $enabled = Join-Path $gameUe4ss "Mods\$($mod.Name)\enabled.txt"
    if (Test-Path $enabled) {
        Remove-Item $enabled -Force
        Write-Host "Disabled dev mod $($mod.Name) (pass -Probe to deploy it)"
    }
}
