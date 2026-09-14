using System.Text;

// Usage: DumpInfo <file.dmp> [maxFrames]
// Prints the exception from a Windows minidump, the module it happened in, and a heuristic stack:
// every value on the crashing thread's captured stack that points into a loaded module.
if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: DumpInfo <file.dmp> [maxFrames]");
    return 1;
}

var data = File.ReadAllBytes(args[0]);
int maxFrames = args.Length > 1 ? int.Parse(args[1]) : 40;

uint U32(long o) => BitConverter.ToUInt32(data, (int)o);
ulong U64(long o) => BitConverter.ToUInt64(data, (int)o);

if (U32(0) != 0x504D444D) { Console.Error.WriteLine("Not a minidump"); return 1; }
uint streamCount = U32(8), dirRva = U32(12);

var modules = new List<(ulong Base, ulong Size, string Name)>();
var memory = new List<(ulong Start, ulong Size, long Rva)>();
long exceptionRva = -1, threadListRva = -1;

for (uint i = 0; i < streamCount; i++)
{
    long e = dirRva + i * 12;
    uint type = U32(e), rva = U32(e + 8);
    switch (type)
    {
        case 3: threadListRva = rva; break;
        case 4: // ModuleListStream
            uint n = U32(rva);
            for (uint m = 0; m < n; m++)
            {
                long mo = rva + 4 + m * 108;
                uint nameRva = U32(mo + 20);
                int len = (int)U32(nameRva);
                modules.Add((U64(mo), U32(mo + 8), Path.GetFileName(Encoding.Unicode.GetString(data, (int)nameRva + 4, len))));
            }
            break;
        case 5: // MemoryListStream
            uint mn = U32(rva);
            for (uint m = 0; m < mn; m++)
            {
                long mo = rva + 4 + m * 16;
                memory.Add((U64(mo), U32(mo + 8), U32(mo + 12)));
            }
            break;
        case 6: exceptionRva = rva; break;
    }
}

string Symbolize(ulong addr)
{
    foreach (var m in modules)
        if (addr >= m.Base && addr < m.Base + m.Size) return $"{m.Name}+0x{addr - m.Base:X}";
    return $"0x{addr:X}";
}

if (exceptionRva < 0) { Console.WriteLine("No exception stream"); return 0; }

uint threadId = U32(exceptionRva);
long rec = exceptionRva + 8;
uint code = U32(rec);
ulong address = U64(rec + 16);
uint paramCount = U32(rec + 24);
Console.WriteLine($"Thread {threadId}: exception 0x{code:X8} at {Symbolize(address)}");
if (code == 0xC0000005 && paramCount >= 2)
{
    ulong kind = U64(rec + 32), target = U64(rec + 40);
    Console.WriteLine($"  access violation {(kind == 0 ? "reading" : kind == 1 ? "writing" : "executing")} 0x{target:X}");
}

uint ctxRva = U32(exceptionRva + 8 + 152 + 4);
ulong rsp = U64(ctxRva + 0x98), rip = U64(ctxRva + 0xF8);
Console.WriteLine($"  RIP {Symbolize(rip)}  RSP 0x{rsp:X}");

// Find the crashing thread's stack memory: from the thread list, or any range containing RSP.
var stack = memory.FirstOrDefault(r => rsp >= r.Start && rsp < r.Start + r.Size);
if (stack.Size == 0) { Console.WriteLine("  (stack memory not captured)"); return 0; }

Console.WriteLine("Stack values pointing into modules (heuristic, innermost first):");
int frames = 0;
for (ulong a = rsp & ~7UL; a + 8 <= stack.Start + stack.Size && frames < maxFrames; a += 8)
{
    ulong v = U64(stack.Rva + (long)(a - stack.Start));
    var s = Symbolize(v);
    if (s.StartsWith("0x")) continue;
    Console.WriteLine($"  [rsp+0x{a - rsp:X4}] {s}");
    frames++;
}

Console.WriteLine("Modules of interest:");
foreach (var m in modules.Where(m => !m.Name.StartsWith("api-ms", StringComparison.OrdinalIgnoreCase)).Take(12))
    Console.WriteLine($"  {m.Name} 0x{m.Base:X} size 0x{m.Size:X}");
return 0;
