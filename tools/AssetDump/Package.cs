using System.Text;

namespace AssetDump;

// Minimal reader for cooked UE 4.19 packages split into .uasset (header) + .uexp (export data).
sealed class Package
{
    public int FileVersionUE4;
    public int TotalHeaderSize;
    public List<string> Names = new();
    public List<Import> Imports = new();
    public List<Export> Exports = new();
    public byte[] Data = Array.Empty<byte>();

    public sealed record Import(string ClassPackage, string ClassName, int OuterIndex, string ObjectName);

    public sealed class Export
    {
        public int ClassIndex, SuperIndex, TemplateIndex, OuterIndex;
        public string ObjectName = "";
        public uint ObjectFlags;
        public long SerialSize, SerialOffset;
    }

    public static Package Load(string uassetPath)
    {
        var header = File.ReadAllBytes(uassetPath);
        var uexpPath = Path.ChangeExtension(uassetPath, ".uexp");
        var body = File.Exists(uexpPath) ? File.ReadAllBytes(uexpPath) : Array.Empty<byte>();

        var pkg = new Package();
        var r = new Reader(header, pkg);

        if (r.U32() != 0x9E2A83C1) throw new InvalidDataException("Not a UE package");
        int legacy = r.I32();
        if (legacy != -4) r.I32();
        pkg.FileVersionUE4 = r.I32();
        if (pkg.FileVersionUE4 == 0) pkg.FileVersionUE4 = 517; // unversioned cook
        r.I32(); // licensee version
        if (legacy > -6) throw new NotSupportedException($"Legacy version {legacy} not supported");
        int customCount = r.I32();
        r.Skip(customCount * 20);
        pkg.TotalHeaderSize = r.I32();
        r.FString(); // folder name
        r.U32(); // package flags
        int nameCount = r.I32(), nameOffset = r.I32();
        r.I32(); r.I32(); // gatherable text data
        int exportCount = r.I32(), exportOffset = r.I32();
        int importCount = r.I32(), importOffset = r.I32();

        r.Pos = nameOffset;
        for (int i = 0; i < nameCount; i++)
        {
            pkg.Names.Add(r.FString());
            r.Skip(4); // name hashes
        }

        r.Pos = importOffset;
        for (int i = 0; i < importCount; i++)
            pkg.Imports.Add(new Import(r.FName(), r.FName(), r.I32(), r.FName()));

        r.Pos = exportOffset;
        for (int i = 0; i < exportCount; i++)
        {
            var e = new Export
            {
                ClassIndex = r.I32(), SuperIndex = r.I32(), TemplateIndex = r.I32(), OuterIndex = r.I32(),
                ObjectName = r.FName(), ObjectFlags = r.U32(), SerialSize = r.I64(), SerialOffset = r.I64(),
            };
            r.Skip(4 * 3 + 16 + 4 + 4 + 4 + 4 * 5);
            pkg.Exports.Add(e);
        }

        // Export serial offsets are relative to the concatenated .uasset + .uexp.
        pkg.Data = new byte[pkg.TotalHeaderSize + body.Length];
        Buffer.BlockCopy(header, 0, pkg.Data, 0, Math.Min(header.Length, pkg.TotalHeaderSize));
        Buffer.BlockCopy(body, 0, pkg.Data, pkg.TotalHeaderSize, body.Length);
        return pkg;
    }

    public string ResolveIndex(int index) => index switch
    {
        0 => "null",
        > 0 when index <= Exports.Count => Exports[index - 1].ObjectName,
        < 0 when -index <= Imports.Count => Imports[-index - 1].ObjectName,
        _ => $"<bad index {index}>",
    };

    public string ClassOf(Export e) => ResolveIndex(e.ClassIndex);
}

sealed class Reader
{
    readonly byte[] _b;
    readonly Package _pkg;
    public int Pos;

    public Reader(byte[] b, Package pkg, int pos = 0) { _b = b; _pkg = pkg; Pos = pos; }

    void Need(int n) { if (Pos < 0 || Pos + n > _b.Length) throw new EndOfStreamException($"Read past end at {Pos}"); }
    public void Skip(int n) { Need(n); Pos += n; }
    public byte U8() { Need(1); return _b[Pos++]; }
    public int I32() { Need(4); var v = BitConverter.ToInt32(_b, Pos); Pos += 4; return v; }
    public uint U32() { Need(4); var v = BitConverter.ToUInt32(_b, Pos); Pos += 4; return v; }
    public long I64() { Need(8); var v = BitConverter.ToInt64(_b, Pos); Pos += 8; return v; }
    public ulong U64() { Need(8); var v = BitConverter.ToUInt64(_b, Pos); Pos += 8; return v; }
    public float F32() { Need(4); var v = BitConverter.ToSingle(_b, Pos); Pos += 4; return v; }
    public double F64() { Need(8); var v = BitConverter.ToDouble(_b, Pos); Pos += 8; return v; }
    public short I16() { Need(2); var v = BitConverter.ToInt16(_b, Pos); Pos += 2; return v; }
    public ushort U16() { Need(2); var v = BitConverter.ToUInt16(_b, Pos); Pos += 2; return v; }

    public Guid Guid() { Need(16); var g = new Guid(_b.AsSpan(Pos, 16)); Pos += 16; return g; }

    public string FString()
    {
        int len = I32();
        if (len == 0) return "";
        if (len > 0)
        {
            if (len > 1 << 20) throw new InvalidDataException($"Bad string length {len}");
            Need(len);
            var s = Encoding.Latin1.GetString(_b, Pos, len - 1);
            Pos += len;
            return s;
        }
        len = -len;
        if (len > 1 << 20) throw new InvalidDataException($"Bad string length {len}");
        Need(len * 2);
        var w = Encoding.Unicode.GetString(_b, Pos, (len - 1) * 2);
        Pos += len * 2;
        return w;
    }

    public string FName()
    {
        int index = I32(), number = I32();
        if (index < 0 || index >= _pkg.Names.Count) throw new InvalidDataException($"Bad name index {index} at {Pos - 8}");
        var name = _pkg.Names[index];
        return number > 0 ? $"{name}_{number - 1}" : name;
    }

    public byte[] Bytes(int n) { Need(n); var a = _b.AsSpan(Pos, n).ToArray(); Pos += n; return a; }
}
