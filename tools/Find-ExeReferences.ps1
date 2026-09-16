# Static reference search in an exe with decrypted .text (see tools/Read-GameVtables.ps1 -OutExe):
#  -WideString finds a UTF-16 string in .rdata and reports its RVA; all -TargetRvas (and those strings)
#  get every rip-relative displacement in .text that points at them (VA = 0x140000000 + RVA).
# UE class names: IMPLEMENT_CLASS passes TEXT("AClassName") + 1, so the referenced RVA is the string's RVA - 2.
param([string]$Exe, [string]$WideString, [long[]]$TargetRvas)
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
public static class XRef {
    public static List<long> FindBytes(byte[] data, byte[] pattern, int start, int end) {
        var r = new List<long>();
        for (int i = start; i <= end - pattern.Length; i++) {
            int j = 0;
            while (j < pattern.Length && data[i + j] == pattern[j]) j++;
            if (j == pattern.Length) r.Add(i);
        }
        return r;
    }
    // rip-relative references: int32 at file offset i where (textVa + (i - textRaw) + 4 + disp) == target
    public static List<long> RipRefs(byte[] data, int textRaw, int textSize, long textVa, long target) {
        var r = new List<long>();
        for (int i = textRaw; i < textRaw + textSize - 4; i++) {
            int disp = BitConverter.ToInt32(data, i);
            long rva = textVa + (i - textRaw) + 4 + disp;
            if (rva == target) r.Add(textVa + (i - textRaw));
        }
        return r;
    }
}
"@
$data = [IO.File]::ReadAllBytes($Exe)
# section table
$pe = [BitConverter]::ToInt32($data, 0x3C); $n = [BitConverter]::ToUInt16($data, $pe + 6); $opt = [BitConverter]::ToUInt16($data, $pe + 20)
$secs = for ($i = 0; $i -lt $n; $i++) { $o = $pe + 24 + $opt + 40 * $i; [pscustomobject]@{ name = [Text.Encoding]::ASCII.GetString($data, $o, 8).TrimEnd([char]0); va = [BitConverter]::ToUInt32($data, $o + 12); raw = [BitConverter]::ToUInt32($data, $o + 20); size = [BitConverter]::ToUInt32($data, $o + 16) } }
$text = $secs | ? name -eq '.text'
function ToRva($off) { foreach ($s in $secs) { if ($off -ge $s.raw -and $off -lt $s.raw + $s.size) { return $s.va + ($off - $s.raw) } } }
$targets = @($TargetRvas)
if ($WideString) {
    $rdata = $secs | ? name -eq '.rdata'
    $pat = [Text.Encoding]::Unicode.GetBytes($WideString + [char]0)
    foreach ($off in [XRef]::FindBytes($data, $pat, $rdata.raw, $rdata.raw + $rdata.size)) {
        $rva = ToRva $off; "string at rva 0x{0:X}" -f $rva; $targets += $rva
    }
}
foreach ($t in $targets) {
    foreach ($ref in [XRef]::RipRefs($data, $text.raw, $text.size, $text.va, $t)) {
        "ref to 0x{0:X} at disp rva 0x{1:X} (VA 0x{2:X})" -f $t, $ref, (0x140000000 + $ref)
    }
}

