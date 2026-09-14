using System.Globalization;
using System.Text;

namespace AssetDump;

// Disassembles UE 4.19 Blueprint (Kismet) bytecode as serialized in cooked packages.
// Jump targets in the bytecode are in-memory offsets, where object pointers are 8 bytes and
// FScriptNames are 12 bytes (vs 4 and 8 on disk); MemPos tracks that so labels line up.
sealed class Kismet
{
    readonly Package _pkg;
    readonly Reader _r;
    readonly int _end;
    int _memDelta;

    public Kismet(Package pkg, Reader r, int end) { _pkg = pkg; _r = r; _end = end; }

    int MemPos => _r.Pos + _memDelta;

    public static void DumpFunction(Package pkg, Package.Export e, StringBuilder sb)
    {
        int start = (int)e.SerialOffset, end = (int)(e.SerialOffset + e.SerialSize);
        var r = new Reader(pkg.Data, pkg, start);
        new PropertyDumper(pkg, r, new StringBuilder()).ReadProperties(0, end);
        r.I32(); // UField::Next
        string super = pkg.ResolveIndex(r.I32());
        r.Skip(r.I32() * 4); // Children (array of package indices)
        int memSize = r.I32();
        int diskSize = r.I32();

        sb.AppendLine();
        sb.AppendLine($"## {pkg.ClassOf(e)} {e.ObjectName}" + (super != "null" ? $" : {super}" : "") + $"  (script {diskSize} bytes on disk, {memSize} in memory)");

        var k = new Kismet(pkg, r, r.Pos + diskSize);
        int scriptStart = r.Pos;
        while (r.Pos < k._end)
        {
            int mem = k.MemPos - scriptStart;
            try
            {
                sb.AppendLine($"  {mem,6}: {k.Expr()}");
            }
            catch (Exception ex)
            {
                sb.AppendLine($"  {mem,6}: <disassembly error: {ex.Message}>");
                break;
            }
        }
        int finalMem = k.MemPos - scriptStart;
        if (finalMem != memSize) sb.AppendLine($"  (warning: computed memory size {finalMem} != {memSize}; labels may be off)");
    }

    static string F(float v) => v.ToString("R", CultureInfo.InvariantCulture);

    string Obj() { _memDelta += 4; return _pkg.ResolveIndex(_r.I32()); }
    string Name() { _memDelta += 4; return _r.FName(); }

    string Params()
    {
        var args = new List<string>();
        while (true)
        {
            if (Peek() == 0x16) { _r.U8(); break; }
            args.Add(Expr());
        }
        return string.Join(", ", args);
    }

    string Until(byte terminator)
    {
        var items = new List<string>();
        while (Peek() != terminator) items.Add(Expr());
        _r.U8();
        return string.Join(", ", items);
    }

    byte Peek()
    {
        int saved = _r.Pos;
        byte b = _r.U8();
        _r.Pos = saved;
        return b;
    }

    string AnsiString()
    {
        var sb = new StringBuilder();
        for (byte c; (c = _r.U8()) != 0;) sb.Append((char)c);
        return sb.ToString();
    }

    string UnicodeString()
    {
        var sb = new StringBuilder();
        for (ushort c; (c = _r.U16()) != 0;) sb.Append((char)c);
        return sb.ToString();
    }

    string Context(string arrow)
    {
        string target = Expr();
        _r.U32(); // skip offset
        Obj();    // r-value property
        return $"{target}{arrow}{Expr()}";
    }

    public string Expr()
    {
        byte op = _r.U8();
        switch (op)
        {
            case 0x00: return Obj();                                   // EX_LocalVariable
            case 0x01: return $"this.{Obj()}";                         // EX_InstanceVariable
            case 0x02: return $"default.{Obj()}";                      // EX_DefaultVariable
            case 0x04: return $"return {Expr()}";                      // EX_Return
            case 0x06: return $"goto {_r.U32()}";                      // EX_Jump
            case 0x07: { uint t = _r.U32(); return $"if not ({Expr()}) goto {t}"; } // EX_JumpIfNot
            case 0x09: { _r.U16(); _r.U8(); return $"assert({Expr()})"; }
            case 0x0B: return "nop";                                   // EX_Nothing
            case 0x0F: { Obj(); string v = Expr(); return $"{v} = {Expr()}"; } // EX_Let
            case 0x12: return Context(" ::");                          // EX_ClassContext
            case 0x13: { string c = Obj(); return $"MetaCast<{c}>({Expr()})"; }
            case 0x14: { string v = Expr(); return $"{v} = {Expr()}"; } // EX_LetBool
            case 0x15: return "<EndParmValue>";
            case 0x16: return "<EndFunctionParms>";
            case 0x17: return "this";
            case 0x18: { _r.U32(); return $"skip({Expr()})"; }
            case 0x19: return Context(".");                            // EX_Context
            case 0x1A: return Context("?.");                           // EX_Context_FailSilent
            case 0x1B: { string n = Name(); return $"{n}({Params()})"; }    // EX_VirtualFunction
            case 0x1C: { string f = Obj(); return $"{f}({Params()})"; }     // EX_FinalFunction
            case 0x1D: return _r.I32().ToString();
            case 0x1E: return F(_r.F32());
            case 0x1F: return $"\"{AnsiString()}\"";
            case 0x20: return $"obj:{Obj()}";
            case 0x21: return $"name:{Name()}";
            case 0x22: return $"Rotator(P={F(_r.F32())}, Y={F(_r.F32())}, R={F(_r.F32())})";
            case 0x23: return $"Vector({F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())})";
            case 0x24: return _r.U8().ToString();
            case 0x25: return "0";
            case 0x26: return "1";
            case 0x27: return "true";
            case 0x28: return "false";
            case 0x29: return TextConst();
            case 0x2A: return "null";
            case 0x2B: { _r.Skip(40); return "Transform(...)"; }
            case 0x2C: return _r.U8().ToString();
            case 0x2D: return "null-interface";
            case 0x2E: { string c = Obj(); return $"Cast<{c}>({Expr()})"; }
            case 0x2F: { string s = Obj(); _r.I32(); return $"{s}{{{Until(0x30)}}}"; } // EX_StructConst
            case 0x31: { string a = Expr(); return $"{a} = [{Until(0x32)}]"; }         // EX_SetArray
            case 0x34: return $"\"{UnicodeString()}\"";
            case 0x35: return _r.I64().ToString();
            case 0x36: return _r.U64().ToString();
            case 0x38: { byte t = _r.U8(); return $"PrimitiveCast{t}({Expr()})"; }
            case 0x39: { string a = Expr(); _r.I32(); return $"{a} = set{{{Until(0x3A)}}}"; }
            case 0x3B: { string a = Expr(); _r.I32(); return $"{a} = map{{{Until(0x3C)}}}"; }
            case 0x3D: { Obj(); _r.I32(); return $"set{{{Until(0x3E)}}}"; }
            case 0x3F: { Obj(); Obj(); _r.I32(); return $"map{{{Until(0x40)}}}"; }
            case 0x42: { string p = Obj(); return $"{Expr()}.{p}"; }   // EX_StructMemberContext
            case 0x43: case 0x44: case 0x5F: case 0x60:
                { string v = Expr(); return $"{v} = {Expr()}"; }
            case 0x45: { string n = Name(); return $"{n}({Params()})"; }    // EX_LocalVirtualFunction
            case 0x46: { string f = Obj(); return $"{f}({Params()})"; }     // EX_LocalFinalFunction
            case 0x48: return $"out {Obj()}";                          // EX_LocalOutVariable
            case 0x4A: return "<DeprecatedOp4A>";
            case 0x4B: return $"delegate:{Name()}";                    // EX_InstanceDelegate
            case 0x4C: return $"push_flow {_r.U32()}";
            case 0x4D: return "pop_flow";
            case 0x4E: return $"goto_computed({Expr()})";
            case 0x4F: return $"pop_flow_if_not({Expr()})";
            case 0x50: return "breakpoint";
            case 0x51: return $"Interface({Expr()})";
            case 0x52: case 0x54: case 0x55: { string c = Obj(); return $"InterfaceCast<{c}>({Expr()})"; }
            case 0x53: return "end_of_script";
            case 0x5A: return "wire_tracepoint";
            case 0x5B: return $"skip_offset:{_r.U32()}";
            case 0x5C: { string d = Expr(); return $"{d} += {Expr()}"; }
            case 0x5D: return $"{Expr()}.Clear()";
            case 0x5E: return "tracepoint";
            case 0x61: { string n = Name(); string d = Expr(); return $"{d}.Bind({Expr()}, {n})"; }
            case 0x62: { string d = Expr(); return $"{d} -= {Expr()}"; }
            case 0x63: { string f = Obj(); return $"broadcast {f}({Params()})"; }
            case 0x64: { string p = Obj(); return $"frame.{p} = {Expr()}"; }
            case 0x65: { Obj(); _r.I32(); return $"[{Until(0x66)}]"; }
            case 0x67: return $"soft:{Expr()}";
            case 0x68: { string f = Obj(); return $"{f}({Params()})"; }     // EX_CallMath
            case 0x69: return SwitchValue();
            case 0x6A: { byte t = _r.U8(); if (t == 4) Name(); return $"instrumentation{t}"; }
            case 0x6B: { string a = Expr(); return $"{a}[{Expr()}]"; }
            default: throw new InvalidDataException($"Unknown opcode 0x{op:X2} at {_r.Pos - 1}");
        }
    }

    string TextConst()
    {
        byte type = _r.U8();
        switch (type)
        {
            case 0: return "text:\"\"";
            case 1: { string s = Expr(); Expr(); Expr(); return $"text:{s}"; }
            case 2: case 3: return $"text:{Expr()}";
            case 4: { Obj(); Expr(); return $"stringtable:{Expr()}"; }
            default: throw new InvalidDataException($"Unknown text literal type {type}");
        }
    }

    string SwitchValue()
    {
        ushort cases = _r.U16();
        _r.U32(); // end offset
        var sb = new StringBuilder($"switch({Expr()}) {{ ");
        for (int i = 0; i < cases; i++)
        {
            string value = Expr();
            _r.U32(); // next case offset
            sb.Append($"{value}: {Expr()}; ");
        }
        sb.Append($"default: {Expr()} }}");
        return sb.ToString();
    }
}
