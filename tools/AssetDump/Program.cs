using System.Text;
using AssetDump;

// Usage: AssetDump <file.uasset> [--export <name-substring>] [--no-props] [--code]
if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: AssetDump <file.uasset> [--export <name-substring>] [--no-props] [--code]");
    return 1;
}

string path = args[0];
string? exportFilter = null;
bool props = true, code = false, hex = false;
for (int i = 1; i < args.Length; i++)
{
    if (args[i] == "--export" && i + 1 < args.Length) exportFilter = args[++i];
    else if (args[i] == "--no-props") props = false;
    else if (args[i] == "--code") code = true;
    else if (args[i] == "--hex") hex = true;
}

var pkg = Package.Load(path);
var sb = new StringBuilder();
sb.AppendLine($"# {Path.GetFileName(path)}  (UE4 file version {pkg.FileVersionUE4})");

sb.AppendLine($"## Imports ({pkg.Imports.Count})");
for (int i = 0; i < pkg.Imports.Count; i++)
{
    var im = pkg.Imports[i];
    sb.AppendLine($"  #{-(i + 1)} {im.ClassName} {im.ObjectName} (outer {pkg.ResolveIndex(im.OuterIndex)})");
}

sb.AppendLine($"## Exports ({pkg.Exports.Count})");
for (int i = 0; i < pkg.Exports.Count; i++)
{
    var e = pkg.Exports[i];
    sb.AppendLine($"  #{i + 1} {pkg.ClassOf(e)} {e.ObjectName} (outer {pkg.ResolveIndex(e.OuterIndex)}, super {pkg.ResolveIndex(e.SuperIndex)}, {e.SerialSize} bytes)");
    if (hex && (exportFilter == null || e.ObjectName.Contains(exportFilter, StringComparison.OrdinalIgnoreCase)))
        sb.AppendLine("    " + Convert.ToHexString(pkg.Data, (int)e.SerialOffset, (int)Math.Min(e.SerialSize, 160)));
}

if (props)
{
    for (int i = 0; i < pkg.Exports.Count; i++)
    {
        var e = pkg.Exports[i];
        if (exportFilter != null && !e.ObjectName.Contains(exportFilter, StringComparison.OrdinalIgnoreCase)) continue;
        string cls = pkg.ClassOf(e);
        // Class/function exports start with UStruct data rather than tagged properties.
        if (cls is "BlueprintGeneratedClass" or "Function" or "WidgetBlueprintGeneratedClass" or "AnimBlueprintGeneratedClass"
            or "UserDefinedStruct" or "UserDefinedEnum" || cls.EndsWith("Property")) continue;

        sb.AppendLine();
        sb.AppendLine($"## Export #{i + 1} {e.ObjectName} ({cls})");
        int start = (int)e.SerialOffset, end = (int)(e.SerialOffset + e.SerialSize);
        var r = new Reader(pkg.Data, pkg, start);
        var dumper = new PropertyDumper(pkg, r, sb);
        try
        {
            dumper.ReadProperties(1, end);
            // UObject::Serialize writes an optional object GUID for non-CDO objects.
            const uint RF_ClassDefaultObject = 0x10;
            if ((e.ObjectFlags & RF_ClassDefaultObject) == 0 && r.Pos + 4 <= end && r.I32() != 0) r.Guid();
            if (cls == "DataTable")
            {
                int rows = r.I32();
                sb.AppendLine($"  Rows ({rows}):");
                for (int row = 0; row < rows; row++)
                {
                    sb.AppendLine($"    [{r.FName()}]");
                    dumper.ReadProperties(3, end);
                }
            }
        }
        catch (Exception ex)
        {
            sb.AppendLine($"  <parse error at offset {r.Pos - start}: {ex.Message}>");
        }
        if (r.Pos < end) sb.AppendLine($"  ({end - r.Pos} bytes of native data after properties)");
    }
}

if (code)
{
    foreach (var e in pkg.Exports)
    {
        if (pkg.ClassOf(e) != "Function") continue;
        if (exportFilter != null && !e.ObjectName.Contains(exportFilter, StringComparison.OrdinalIgnoreCase)) continue;
        try { Kismet.DumpFunction(pkg, e, sb); }
        catch (Exception ex) { sb.AppendLine($"## Function {e.ObjectName} <error: {ex.Message}>"); }
    }
}

Console.Out.Write(sb.ToString());
return 0;
