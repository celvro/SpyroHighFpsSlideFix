<#
.SYNOPSIS
    Real key presses for the probe: reads commands from stdin and posts them to Spyro's game window as
    WM_KEYDOWN / WM_KEYUP, the same messages a keyboard produces. The game does not need to be in front.

.DESCRIPTION
    lib/realkeys.lua starts this once with io.popen(..., "w") and keeps the pipe open, so a key reaches the
    game as soon as the line is written instead of after a PowerShell start-up. Commands, one per line:

        d <vk>    key down          u <vk>    key up          t <vk>    down, 60 ms, up

    <vk> is a Windows virtual-key code in decimal (32 Space, 13 Enter). When the window is found and the
    pipe is ready, keypipe.ready is written next to this script; it exits when the pipe closes (the game
    exited) or the game window is gone.

    Why: a level replay plays the take's Jump presses as real Space presses, so a press that the recording
    made into a conversation's text box (Space is Jump and UI_Confirm) reaches the box the same way.
    Calling the box's own Blueprint press function from Lua froze the game (docs/probe.md).

    The window is found by class (UnrealWindow) in the Spyro-Win64-Shipping process: the process's
    MainWindowHandle is UE4SS's console.
#>
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class SpyroKeys {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    public static IntPtr UnrealWindow(uint want) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != want) return true;
            var c = new StringBuilder(64); GetClassName(h, c, 64);
            if (c.ToString() != "UnrealWindow") return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
    // lParam as a keyboard sets it: repeat count 1, the scan code, and for an up the previous-state and
    // transition bits.
    public static bool Key(IntPtr window, uint vk, bool down) {
        long scan = MapVirtualKey(vk, 0) & 0xFF;
        long lParam = 1 | (scan << 16) | (down ? 0 : (3L << 30));
        return PostMessage(window, down ? 0x100u : 0x101u, (IntPtr)vk, (IntPtr)lParam);
    }
}
'@

$ready = Join-Path $PSScriptRoot 'keypipe.ready'
$game = Get-Process Spyro-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $game) { exit 1 }
$window = [SpyroKeys]::UnrealWindow([uint32]$game.Id)
if ($window -eq [IntPtr]::Zero) { exit 2 }
[IO.File]::WriteAllText($ready, "$($game.Id) $window")

try {
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        if ($line -notmatch '^([dut])\s+(\d+)') { continue }
        $vk = [uint32]$Matches[2]
        $ok = switch ($Matches[1]) {
            'd' { [SpyroKeys]::Key($window, $vk, $true) }
            'u' { [SpyroKeys]::Key($window, $vk, $false) }
            't' { $a = [SpyroKeys]::Key($window, $vk, $true); Start-Sleep -Milliseconds 60; $a -and [SpyroKeys]::Key($window, $vk, $false) }
        }
        if (-not $ok) { break } # the window is gone
    }
} finally {
    Remove-Item $ready -ErrorAction SilentlyContinue
}
