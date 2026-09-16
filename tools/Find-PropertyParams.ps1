# Static search for UE 4.19 reflected property params in an exe with decrypted .text (see tools/Read-GameVtables.ps1 -OutExe).
# For each name, finds the ASCII string (null-terminated, preceded by a null) and every absolute 64-bit pointer to it
# in .rdata/.data, then dumps the bytes that follow the pointer (the rest of the FPropertyParams struct, which
# holds the property offset).
param([string]$Exe, [string[]]$Names, [int]$Dump = 40)
Add-Type @"
using System;
using System.Collections.Generic;
public static class PScan {
    public static List<long> FindBytes(byte[] data, byte[] pattern, int start, int end) {
        var r = new List<long>();
        for (int i = start; i <= end - pattern.Length; i++) {
            int j = 0;
            while (j < pattern.Length && data[i + j] == pattern[j]) j++;
            if (j == pattern.Length) r.Add(i);
        }
        return r;
    }
    public static List<long> FindQword(byte[] data, long value, int start, int end) {
        var r = new List<long>();
        for (int i = start; i <= end - 8; i += 8)
            if (BitConverter.ToInt64(data, i) == value) r.Add(i);
        return r;
    }
}
"@
$data = [IO.File]::ReadAllBytes($Exe)
$pe = [BitConverter]::ToInt32($data, 0x3C); $n = [BitConverter]::ToUInt16($data, $pe + 6); $opt = [BitConverter]::ToUInt16($data, $pe + 20)
$secs = for ($i = 0; $i -lt $n; $i++) { $o = $pe + 24 + $opt + 40 * $i; [pscustomobject]@{ name = [Text.Encoding]::ASCII.GetString($data, $o, 8).TrimEnd([char]0); va = [BitConverter]::ToUInt32($data, $o + 12); raw = [BitConverter]::ToUInt32($data, $o + 20); size = [BitConverter]::ToUInt32($data, $o + 16) } }
function ToRva($off) { foreach ($s in $secs) { if ($off -ge $s.raw -and $off -lt $s.raw + $s.size) { return $s.va + ($off - $s.raw) } } }
$rdata = $secs | ? name -eq '.rdata'; $dataSec = $secs | ? name -eq '.data'
foreach ($name in $Names) {
    $pat = [byte[]](@(0) + [Text.Encoding]::ASCII.GetBytes($name) + @(0))
    foreach ($off in [PScan]::FindBytes($data, $pat, $rdata.raw, $rdata.raw + $rdata.size)) {
        $va = 0x140000000 + (ToRva ($off + 1))
        foreach ($sec in @($rdata, $dataSec)) {
            foreach ($p in [PScan]::FindQword($data, $va, $sec.raw, $sec.raw + $sec.size)) {
                $bytes = ($data[($p + 8)..($p + 7 + $Dump)] | % { $_.ToString('X2') }) -join ' '
                "{0,-32} params at VA 0x{1:X}: {2}" -f $name, (0x140000000 + (ToRva $p)), $bytes
            }
        }
    }
}
