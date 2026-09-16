# Reads a running game's memory (read-only) for disassembly work:
#  - prints the PE section table of the loaded exe,
#  - reads the vtables of the given objects (name -> object address, e.g. class default objects the probe
#    logs) and prints every slot where they differ, as exe RVAs (virtual address = 0x140000000 + RVA),
#  - with -OutExe, copies the exe and writes the decrypted .text (SteamStub encrypts it on disk) into the copy,
#    so dumpbin /DISASM /RANGE can read it.
# Example: tools/Read-GameVtables.ps1 -ProcessId (Get-Process Spyro-Win64-Shipping).Id -OutExe build/exe/decrypted.exe -Cdos @{ Base = 0x19AF6A82440; Attractor = 0x19AF69E2300 }
param([int]$ProcessId, [string]$OutExe, [hashtable]$Cdos, [int]$Slots = 110)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Mem {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    public static byte[] Read(IntPtr h, long addr, int size) {
        var b = new byte[size]; IntPtr r;
        if (!ReadProcessMemory(h, new IntPtr(addr), b, new IntPtr(size), out r)) throw new Exception("read failed at 0x" + addr.ToString("X"));
        return b;
    }
}
"@
$h = [Mem]::OpenProcess(0x0410, $false, $ProcessId) # PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
$proc = Get-Process -Id $ProcessId
$base = $proc.MainModule.BaseAddress.ToInt64()
"base 0x{0:X}" -f $base

# Section table from the in-memory PE header.
$hdr = [Mem]::Read($h, $base, 0x1000)
$pe = [BitConverter]::ToInt32($hdr, 0x3C)
$nsec = [BitConverter]::ToUInt16($hdr, $pe + 6)
$optSize = [BitConverter]::ToUInt16($hdr, $pe + 20)
$secTable = $pe + 24 + $optSize
$text = $null
for ($i = 0; $i -lt $nsec; $i++) {
    $o = $secTable + 40 * $i
    $name = [Text.Encoding]::ASCII.GetString($hdr, $o, 8).TrimEnd([char]0)
    $vsize = [BitConverter]::ToUInt32($hdr, $o + 8); $va = [BitConverter]::ToUInt32($hdr, $o + 12)
    $rawSize = [BitConverter]::ToUInt32($hdr, $o + 16); $raw = [BitConverter]::ToUInt32($hdr, $o + 20)
    "{0,-8} va 0x{1:X} vsize 0x{2:X} raw 0x{3:X} rawsize 0x{4:X}" -f $name, $va, $vsize, $raw, $rawSize
    if ($name -eq '.text') { $text = @{ va = $va; raw = $raw; size = $rawSize } }
}

$vt = @{}
foreach ($k in $Cdos.Keys) {
    $obj = [BitConverter]::ToInt64([Mem]::Read($h, $Cdos[$k], 8), 0)
    $bytes = [Mem]::Read($h, $obj, 8 * $Slots)
    $vt[$k] = 0..($Slots - 1) | % { [BitConverter]::ToInt64($bytes, 8 * $_) }
    "{0} vtable 0x{1:X} (rva 0x{2:X})" -f $k, $obj, ($obj - $base)
}
$names = @($Cdos.Keys | Sort-Object)
for ($s = 0; $s -lt $Slots; $s++) {
    $vals = $names | % { $vt[$_][$s] }
    if (($vals | Sort-Object -Unique).Count -gt 1) {
        "slot {0,3}: " -f $s + (($names | % { "{0}=0x{1:X}" -f $_, ($vt[$_][$s] - $base) }) -join '  ')
    }
}

if ($OutExe) {
    $src = $proc.MainModule.FileName
    Copy-Item $src $OutExe -Force
    $data = [Mem]::Read($h, $base + $text.va, $text.size)
    $fs = [IO.File]::Open($OutExe, 'Open', 'ReadWrite')
    $fs.Seek($text.raw, 'Begin') | Out-Null
    $fs.Write($data, 0, $data.Length); $fs.Close()
    "wrote decrypted .text to $OutExe"
}

