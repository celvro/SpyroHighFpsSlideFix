using System.Globalization;
using System.Text;

namespace AssetDump;

// Prints UE 4.19 tagged properties (FPropertyTag streams) as indented text.
sealed class PropertyDumper
{
    readonly Package _pkg;
    readonly Reader _r;
    readonly StringBuilder _out;

    public PropertyDumper(Package pkg, Reader r, StringBuilder output) { _pkg = pkg; _r = r; _out = output; }

    static string F(float v) => v.ToString("R", CultureInfo.InvariantCulture);

    void Line(int indent, string text) => _out.Append(' ', indent * 2).AppendLine(text);

    sealed class Tag
    {
        public string Name = "", Type = "", StructName = "", EnumName = "", InnerType = "", ValueType = "";
        public int Size, ArrayIndex;
        public bool BoolVal;
    }

    Tag? ReadTag()
    {
        var t = new Tag { Name = _r.FName() };
        if (t.Name == "None") return null;
        t.Type = _r.FName();
        t.Size = _r.I32();
        t.ArrayIndex = _r.I32();
        switch (t.Type)
        {
            case "StructProperty": t.StructName = _r.FName(); _r.Guid(); break;
            case "BoolProperty": t.BoolVal = _r.U8() != 0; break;
            case "ByteProperty": case "EnumProperty": t.EnumName = _r.FName(); break;
            case "ArrayProperty": case "SetProperty": t.InnerType = _r.FName(); break;
            case "MapProperty": t.InnerType = _r.FName(); t.ValueType = _r.FName(); break;
        }
        if (_r.U8() != 0) _r.Guid();
        return t;
    }

    // Reads tagged properties until "None". Returns false if the stream did not parse cleanly.
    public void ReadProperties(int indent, int end)
    {
        while (_r.Pos < end)
        {
            var tag = ReadTag();
            if (tag == null) return;
            int start = _r.Pos;
            string label = tag.ArrayIndex > 0 ? $"{tag.Name}[{tag.ArrayIndex}]" : tag.Name;
            try
            {
                ReadValue(tag, label, indent, start + tag.Size);
            }
            catch (Exception ex)
            {
                Line(indent, $"{label} ({tag.Type}) <parse error: {ex.Message}> raw={Hex(start, tag.Size)}");
            }
            _r.Pos = start + tag.Size;
        }
    }

    string Hex(int start, int size)
    {
        int saved = _r.Pos;
        _r.Pos = start;
        var bytes = _r.Bytes(Math.Min(size, 64));
        _r.Pos = saved;
        return Convert.ToHexString(bytes) + (size > 64 ? "..." : "");
    }

    void ReadValue(Tag tag, string label, int indent, int end)
    {
        switch (tag.Type)
        {
            case "BoolProperty": Line(indent, $"{label} = {tag.BoolVal}"); return;
            case "StructProperty":
                ReadStruct(tag.StructName, $"{label} ({tag.StructName})", indent, end);
                return;
            case "ArrayProperty": ReadArray(tag, label, indent, end); return;
            case "SetProperty": ReadSet(tag, label, indent, end); return;
            case "MapProperty": ReadMap(tag, label, indent, end); return;
            case "ByteProperty" when tag.Size == 1:
                Line(indent, $"{label} = {_r.U8()}" + (tag.EnumName != "None" ? $" ({tag.EnumName})" : "")); return;
            default:
                Line(indent, $"{label} = {Scalar(tag.Type, tag.Size)}"); return;
        }
    }

    string Scalar(string type, int size) => type switch
    {
        "IntProperty" => _r.I32().ToString(),
        "UInt32Property" => _r.U32().ToString(),
        "Int64Property" => _r.I64().ToString(),
        "UInt64Property" => _r.U64().ToString(),
        "Int16Property" => _r.I16().ToString(),
        "UInt16Property" => _r.U16().ToString(),
        "Int8Property" => ((sbyte)_r.U8()).ToString(),
        "FloatProperty" => F(_r.F32()),
        "DoubleProperty" => _r.F64().ToString("R", CultureInfo.InvariantCulture),
        "NameProperty" or "EnumProperty" or "ByteProperty" => _r.FName(),
        "StrProperty" => $"\"{_r.FString()}\"",
        "ObjectProperty" or "ClassProperty" or "InterfaceProperty" or "WeakObjectProperty" or "LazyObjectProperty"
            => ObjectRef(_r.I32()),
        "SoftObjectProperty" or "SoftClassProperty" or "AssetObjectProperty" => SoftPath(),
        "TextProperty" => Text(),
        "DelegateProperty" => $"{ObjectRef(_r.I32())}.{_r.FName()}",
        _ => $"<{type} size={size}> {Hex(_r.Pos, size)}",
    };

    string ObjectRef(int index) => index == 0 ? "null" : $"{_pkg.ResolveIndex(index)} (#{index})";

    string SoftPath()
    {
        var path = _r.FName();
        var sub = _r.FString();
        return sub.Length > 0 ? $"{path}:{sub}" : path;
    }

    string Text()
    {
        _r.U32(); // flags
        sbyte history = (sbyte)_r.U8();
        switch (history)
        {
            case -1:
                return _r.I32() != 0 ? $"\"{_r.FString()}\"" : "\"\"";
            case 0:
                var ns = _r.FString();
                var key = _r.FString();
                var src = _r.FString();
                return $"\"{src}\" [{ns}:{key}]";
            default:
                return $"<text history {history}>";
        }
    }

    // Native (non-tagged) struct serializers used by the engine in 4.19.
    bool TryNativeStruct(string structName, out string value)
    {
        value = structName switch
        {
            "Vector" => $"({F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())})",
            "Rotator" => $"(P={F(_r.F32())}, Y={F(_r.F32())}, R={F(_r.F32())})",
            "Vector2D" => $"({F(_r.F32())}, {F(_r.F32())})",
            "Vector4" or "Quat" or "Plane" => $"({F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())})",
            "LinearColor" => $"(R={F(_r.F32())}, G={F(_r.F32())}, B={F(_r.F32())}, A={F(_r.F32())})",
            "Color" => ColorValue(),
            "IntPoint" => $"({_r.I32()}, {_r.I32()})",
            "IntVector" => $"({_r.I32()}, {_r.I32()}, {_r.I32()})",
            "Guid" => _r.Guid().ToString(),
            "DateTime" or "Timespan" => _r.I64().ToString(),
            "Box" => $"Min=({F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())}) Max=({F(_r.F32())}, {F(_r.F32())}, {F(_r.F32())}) Valid={_r.U8()}",
            "GameplayTagContainer" => TagContainer(),
            "SoftObjectPath" or "SoftClassPath" or "StringAssetReference" or "StringClassReference" => SoftPath(),
            "PerPlatformFloat" => $"cooked={_r.I32() != 0} {F(_r.F32())}",
            "PerPlatformInt" => $"cooked={_r.I32() != 0} {_r.I32()}",
            _ => "",
        };
        return value.Length > 0;
    }

    string ColorValue()
    {
        byte b = _r.U8(), g = _r.U8(), rr = _r.U8(), a = _r.U8();
        return $"(R={rr}, G={g}, B={b}, A={a})";
    }

    string TagContainer()
    {
        int n = _r.I32();
        var tags = new List<string>();
        for (int i = 0; i < n; i++) tags.Add(_r.FName());
        return "[" + string.Join(", ", tags) + "]";
    }

    void ReadStruct(string structName, string label, int indent, int end)
    {
        if (TryNativeStruct(structName, out var value))
        {
            Line(indent, $"{label} = {value}");
            return;
        }
        Line(indent, $"{label}:");
        ReadProperties(indent + 1, end);
    }

    void ReadArray(Tag tag, string label, int indent, int end)
    {
        int count = _r.I32();
        if (tag.InnerType == "StructProperty")
        {
            var inner = ReadTag() ?? throw new InvalidDataException("Missing inner struct tag");
            Line(indent, $"{label} (Array<{inner.StructName}>, {count}):");
            for (int i = 0; i < count; i++)
                ReadStruct(inner.StructName, $"[{i}]", indent + 1, end);
            return;
        }
        Line(indent, $"{label} (Array<{tag.InnerType}>, {count}):");
        int payload = end - _r.Pos;
        for (int i = 0; i < count; i++)
            Line(indent + 1, $"[{i}] = {Element(tag.InnerType, count, payload)}");
    }

    void ReadSet(Tag tag, string label, int indent, int end)
    {
        _r.I32(); // elements to remove
        int count = _r.I32();
        Line(indent, $"{label} (Set<{tag.InnerType}>, {count}):");
        int payload = end - _r.Pos;
        for (int i = 0; i < count; i++)
        {
            if (tag.InnerType == "StructProperty") { Line(indent + 1, $"[{i}]:"); ReadProperties(indent + 2, end); }
            else Line(indent + 1, $"[{i}] = {Element(tag.InnerType, count, payload)}");
        }
    }

    void ReadMap(Tag tag, string label, int indent, int end)
    {
        int removed = _r.I32();
        for (int i = 0; i < removed; i++) Element(tag.InnerType, 0, 0);
        int count = _r.I32();
        Line(indent, $"{label} (Map<{tag.InnerType}, {tag.ValueType}>, {count}):");
        for (int i = 0; i < count; i++)
        {
            string key = tag.InnerType == "StructProperty" ? "<struct key>" : Element(tag.InnerType, 0, 0);
            if (tag.InnerType == "StructProperty") ReadProperties(indent + 2, end);
            if (tag.ValueType == "StructProperty")
            {
                Line(indent + 1, $"[{key}]:");
                ReadProperties(indent + 2, end);
            }
            else Line(indent + 1, $"[{key}] = {Element(tag.ValueType, 0, 0)}");
        }
    }

    string Element(string type, int count, int payload) => type switch
    {
        "BoolProperty" => (_r.U8() != 0).ToString(),
        // Byte arrays hold raw bytes unless they are enum-backed (then FNames).
        "ByteProperty" when count > 0 && payload == count => _r.U8().ToString(),
        _ => Scalar(type, 0),
    };
}
