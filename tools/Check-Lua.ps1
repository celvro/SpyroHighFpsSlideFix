<#
.SYNOPSIS
Syntax-checks the project's Lua with luac 5.4 (no UE4SS, no game).

.DESCRIPTION
Byte-compiles every .lua under the given paths (default: both mods) and
reports the files that fail to parse. Catches typos and Lua 5.3-isms
(math.pow, math.frexp) without a game restart; it cannot catch runtime
errors, since the scripts need UE4SS globals.

Install the interpreter with: winget install --id DEVCOM.Lua --exact

.EXAMPLE
tools/Check-Lua.ps1
tools/Check-Lua.ps1 ue4ss/Mods/HighFpsSlidingAndJumpFix
#>
[CmdletBinding()]
param(
    [string[]] $Path = @('ue4ss/Mods', 'ue4ss/DevMods')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$luac = (Get-Command luac -ErrorAction SilentlyContinue).Source
if (-not $luac) {
    $luac = Join-Path $env:LOCALAPPDATA 'Programs\Lua\bin\luac.exe'
}
if (-not (Test-Path $luac)) {
    throw "luac not found. Install Lua 5.4: winget install --id DEVCOM.Lua --exact"
}

$version = & (Join-Path (Split-Path $luac) 'lua.exe') -v
if ($version -notmatch 'Lua 5\.4') {
    Write-Warning "$version - UE4SS uses Lua 5.4, so results may differ."
}

$files = @()
foreach ($p in $Path) {
    $full = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $repo $p }
    if (-not (Test-Path $full)) { continue }
    $files += Get-ChildItem -Path $full -Filter '*.lua' -Recurse -File
}
if (-not $files) { throw "No .lua files found under: $($Path -join ', ')" }

$failed = 0
foreach ($f in $files) {
    # Run through cmd.exe: redirecting a native command's stderr inside Windows
    # PowerShell turns each line into a NativeCommandError instead of text.
    $out = & cmd.exe /c "`"$luac`" -p `"$($f.FullName)`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $failed++
        Write-Host (($out -join "`n").Trim()) -ForegroundColor Red
    }
}

if ($failed -eq 0) {
    Write-Host "OK: $($files.Count) file(s) parse cleanly ($version)." -ForegroundColor Green
} else {
    Write-Host "$failed of $($files.Count) file(s) failed to parse." -ForegroundColor Red
    exit 1
}
