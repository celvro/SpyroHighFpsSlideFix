# Samples Spyro's flame breath particles straight from game memory (read-only) while the game runs.
# Needs the SpyroFpsProbe build that logs "flame component found: ... at 0x<address>" to UE4SS.log.
#
# For every new flame ParticleSystemComponent in the log it finds the component's EmitterInstances array
# (a TArray whose first element's Component pointer, +0x18, points back at the component), then polls each
# emitter instance's particles as fast as it can and writes one CSV row per particle per poll.
#
# FParticleEmitterInstance offsets (UE 4.19, from the disassembly of ParticleModuleAttractorPoint::Update):
#   +0x18 Component, +0xF0 ParticleData, +0xF8 ParticleIndices (uint16), +0x114 ParticleStride,
#   +0x118 ActiveParticles, +0x12C EmitterTime.
# FBaseParticle: +0x00 OldLocation, +0x0C RelativeTime, +0x10 Location, +0x1C OneOverMaxLifetime,
#   +0x20 BaseVelocity, +0x30 Velocity, +0x50 Size, +0x5C Flags.
#
# Polls aren't synchronized with game frames, so a row can occasionally catch a particle mid-update.
param(
    [int]$Seconds = 180,
    [string]$OutCsv = "$PSScriptRoot\..\build\probe\flame_particles.csv"
)
. "$PSScriptRoot\Config.ps1"
$log = Join-Path $GameDir 'Falcon\Binaries\Win64\ue4ss\UE4SS.log'
$proc = Get-Process Spyro-Win64-Shipping -ErrorAction Stop

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class FlameCapture {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    static IntPtr handle;

    static byte[] Read(long addr, int size) {
        var b = new byte[size]; IntPtr r;
        if (addr == 0 || !ReadProcessMemory(handle, new IntPtr(addr), b, new IntPtr(size), out r) || r.ToInt64() != size) return null;
        return b;
    }

    // Offset of the EmitterInstances TArray inside the component, or -1.
    static int FindEmitterInstances(long component) {
        var obj = Read(component, 0x1000);
        if (obj == null) return -1;
        for (int off = 0x100; off + 16 <= obj.Length; off += 8) {
            long ptr = BitConverter.ToInt64(obj, off);
            int num = BitConverter.ToInt32(obj, off + 8), max = BitConverter.ToInt32(obj, off + 12);
            if (ptr == 0 || num < 1 || num > 64 || max < num || max > 256) continue;
            var first = Read(ptr, 8);
            if (first == null) continue;
            var inst = Read(BitConverter.ToInt64(first, 0), 0x20);
            if (inst != null && BitConverter.ToInt64(inst, 0x18) == component) return off;
        }
        return -1;
    }

    public static void Run(int pid, string logPath, string outCsv, int seconds) {
        handle = OpenProcess(0x0410, false, pid);
        var components = new Dictionary<long, int>(); // address -> EmitterInstances offset (-1 not found yet)
        var names = new Dictionary<long, int>();
        var re = new Regex(@"flame component found: .*\((\w+)\) at 0x([0-9A-Fa-f]+)");
        long logPos = new FileInfo(logPath).Length;
        var sw = Stopwatch.StartNew();
        using (var w = new StreamWriter(outCsv)) {
            w.WriteLine("t_ms,component,emitter,active,emitter_time,slot,old_x,old_y,old_z,rel_time,x,y,z,inv_life,base_vx,base_vy,base_vz,vx,vy,vz,size_x,size_y,flags");
            long polls = 0, rows = 0;
            while (sw.Elapsed.TotalSeconds < seconds) {
                // New flame components from the probe's log.
                using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    if (fs.Length < logPos) logPos = 0;
                    fs.Seek(logPos, SeekOrigin.Begin);
                    var sr = new StreamReader(fs, Encoding.UTF8);
                    string line;
                    while ((line = sr.ReadLine()) != null) {
                        var m = re.Match(line);
                        if (m.Success) {
                            long a = Convert.ToInt64(m.Groups[2].Value, 16);
                            if (!components.ContainsKey(a)) { components[a] = -1; names[a] = components.Count; Console.WriteLine("component {0} at 0x{1:X}", names[a], a); }
                        }
                    }
                    logPos = fs.Length;
                }
                double t = sw.Elapsed.TotalMilliseconds;
                foreach (var a in new List<long>(components.Keys)) {
                    if (components[a] < 0) { components[a] = FindEmitterInstances(a); if (components[a] < 0) continue; Console.WriteLine("component {0}: EmitterInstances at +0x{1:X}", names[a], components[a]); }
                    var arr = Read(a + components[a], 16);
                    if (arr == null) { components.Remove(a); continue; }
                    long data = BitConverter.ToInt64(arr, 0); int num = BitConverter.ToInt32(arr, 8);
                    if (num < 1 || num > 64) continue;
                    var ptrs = Read(data, 8 * num);
                    if (ptrs == null) continue;
                    for (int e = 0; e < num; e++) {
                        long inst = BitConverter.ToInt64(ptrs, 8 * e);
                        var ib = Read(inst, 0x130);
                        if (ib == null || BitConverter.ToInt64(ib, 0x18) != a) continue;
                        int active = BitConverter.ToInt32(ib, 0x118), stride = BitConverter.ToInt32(ib, 0x114);
                        if (active <= 0 || active > 2000 || stride < 0x60 || stride > 0x400) continue;
                        float emitterTime = BitConverter.ToSingle(ib, 0x12C);
                        var idx = Read(BitConverter.ToInt64(ib, 0xF8), 2 * active);
                        long pdata = BitConverter.ToInt64(ib, 0xF0);
                        if (idx == null) continue;
                        for (int i = 0; i < active; i++) {
                            int slot = BitConverter.ToUInt16(idx, 2 * i);
                            var p = Read(pdata + (long)stride * slot, 0x60);
                            if (p == null) continue;
                            var sb = new StringBuilder();
                            sb.AppendFormat("{0:F3},{1},{2},{3},{4:F4},{5}", t, names[a], e, active, emitterTime, slot);
                            foreach (int off in new[] { 0x0, 0x4, 0x8, 0xC, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x30, 0x34, 0x38, 0x50, 0x54 })
                                sb.Append(',').Append(BitConverter.ToSingle(p, off).ToString("R"));
                            sb.Append(',').Append(BitConverter.ToInt32(p, 0x5C));
                            w.WriteLine(sb.ToString());
                            rows++;
                        }
                    }
                }
                polls++;
                Thread.Sleep(1);
            }
            Console.WriteLine("{0} polls, {1} rows, {2} components", polls, rows, components.Count);
        }
    }
}
"@

New-Item -ItemType Directory -Force (Split-Path $OutCsv) | Out-Null
"capturing for $Seconds s to $OutCsv"
[FlameCapture]::Run($proc.Id, $log, (Resolve-Path (Split-Path $OutCsv)).Path + '\' + (Split-Path $OutCsv -Leaf), $Seconds)
