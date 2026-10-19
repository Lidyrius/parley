using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Parley;

// The app's icon (tray → App-Symbol), as on macOS and the iPhone: Graphit (default), Porzellan ·
// Indigo, Indigo, Petrol. The tray shows the chosen one (branding\icon-<id>.png, shared with the
// macOS app); the .exe keeps Parley.ico (Graphit).
public static class AppIcon
{
    public static readonly (string Id, string Name)[] Choices =
        { ("graphit", "Graphit"), ("porzellan", "Porzellan"), ("indigo", "Indigo"), ("petrol", "Petrol") };

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    /// The tray icon for a choice (32 px; Windows scales it down at 100 %).
    public static Icon For(string id)
    {
        try
        {
            using var src = new Bitmap(Path.Combine(AppContext.BaseDirectory, "branding", $"icon-{id}.png"));
            using var small = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(small))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, 32, 32));
            }
            var handle = small.GetHicon();
            try { return (Icon)Icon.FromHandle(handle).Clone(); }
            finally { DestroyIcon(handle); }
        }
        catch (Exception e)
        {
            Log.Write($"app icon {id}: {e.Message}");
            return SystemIcons.Application;
        }
    }
}
