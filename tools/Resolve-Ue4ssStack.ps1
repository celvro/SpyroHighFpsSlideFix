<#
.SYNOPSIS
    Puts function names on the UE4SS.dll offsets that tools\DumpInfo prints for a crash dump.

.DESCRIPTION
    DumpInfo reads a minidump and prints "UE4SS.dll+0x<rva>" for every frame. This resolves those
    offsets against the linker map of a local UE4SS build (add /MAP to CMAKE_SHARED_LINKER_FLAGS; see
    tools\bin\ue4ss-dist\VERSION.txt for the build steps), so a crash inside UE4SS can be read as a
    stack of names. The map has to be from the same build as the DLL that crashed.

.EXAMPLE
    $dmp = "$env:LOCALAPPDATA\Falcon\Saved\Crashes\UE4CC-*\UE4Minidump.dmp"
    .\build\DumpInfo\DumpInfo.exe (Resolve-Path $dmp) 60 | .\tools\Resolve-Ue4ssStack.ps1
#>
param(
    [string] $Map = 'C:\ue4ss\bld\Game__Shipping__Win64\bin\UE4SS.map',
    [Parameter(ValueFromPipeline = $true)] [string[]] $Line
)
begin {
    if (-not (Test-Path $Map)) { throw "No linker map at $Map (build UE4SS with /MAP)." }
    # Every map entry is "<section>:<offset> <name> <address> ...", and the RVA is the address minus
    # the image's preferred load address. Entries below it are imports and absolutes: skip them.
    $base = 0x180000000
    $syms = New-Object System.Collections.Generic.List[object]
    foreach ($l in [System.IO.File]::ReadLines($Map)) {
        if ($l -match '^\s[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s') {
            $addr = [uint64]('0x' + $Matches[2])
            if ($addr -ge $base) { $syms.Add([pscustomobject]@{ Rva = $addr - $base; Name = $Matches[1] }) }
        }
    }
    $sorted = @($syms | Sort-Object Rva)
    $rvas = [uint64[]] @($sorted | ForEach-Object { $_.Rva })
    Write-Host "$($sorted.Count) symbols from $Map"

    function Resolve-Rva([uint64] $rva) {
        $i = [array]::BinarySearch($rvas, $rva)
        if ($i -lt 0) { $i = (-$i) - 2 }   # BinarySearch returns -(insertion point) - 1
        if ($i -lt 0) { return '<below the first symbol>' }
        '{0}+0x{1:X}' -f $sorted[$i].Name, ($rva - $sorted[$i].Rva)
    }
}
process {
    foreach ($l in $Line) {
        [regex]::Replace($l, 'UE4SS\.dll\+0x([0-9A-Fa-f]+)', {
            param($m)
            'UE4SS.dll+0x' + $m.Groups[1].Value + ' [' + (Resolve-Rva ([uint64]('0x' + $m.Groups[1].Value))) + ']'
        })
    }
}
