using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;

namespace Donut.Launcher;

/// <summary>
/// Reads the app payload embedded in this assembly (PowerShell/XAML/images). LogicalNames
/// use '/', but the recursive portion carries '\', so lookups match the slash-normalized
/// name. Public: the hosted PowerShell runtime reads views and style dictionaries through
/// it (ViewLoader / ResourceService), so the XAML never has to exist on disk.
/// </summary>
public static class EmbeddedAssets {
    private static readonly Assembly Asm = typeof(EmbeddedAssets).Assembly;

    /// <summary>Opens an embedded resource by logical name (e.g. "assets/Images/x.png"), or null.</summary>
    public static Stream? Open(string logicalName) {
        foreach (string n in Asm.GetManifestResourceNames()) {
            if (string.Equals(n.Replace('\\', '/'), logicalName, StringComparison.OrdinalIgnoreCase))
                return Asm.GetManifestResourceStream(n);
        }
        return null;
    }

    /// <summary>Slash-normalized logical names under a prefix (e.g. "src/UI/Styles/").</summary>
    public static string[] List(string logicalPrefix) =>
        Asm.GetManifestResourceNames()
           .Select(n => n.Replace('\\', '/'))
           .Where(n => n.StartsWith(logicalPrefix, StringComparison.OrdinalIgnoreCase))
           .ToArray();

    /// <summary>Loads an embedded image, copied into a kept stream (GIF frames need it alive).</summary>
    public static Image? LoadImage(string logicalName) {
        using Stream? s = Open(logicalName);
        if (s is null) return null;
        var ms = new MemoryStream();
        s.CopyTo(ms);
        ms.Position = 0;
        return Image.FromStream(ms);
    }
}
