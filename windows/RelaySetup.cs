using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace Parley;

// "Eigenes Relais · 1 Klick" (setup step 7), 1:1 with the macOS RelaySetup.swift: Parley puts the
// relay (relay\ next to Parley.exe, shipped by Parley.Win.csproj) into Sir's own Cloudflare
// account — `wrangler login` opens the browser (he only confirms), `wrangler deploy` prints the
// worker's address, which is then checked ("parley relay ok") and saved as relayUrl. Needs
// Node.js (npx); without it the setup offers the address field instead.
public static class RelaySetup
{
    public const string Wrangler = "wrangler@4.149.0";   // as relay/package.json pins it

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private static readonly TimeSpan Patience = TimeSpan.FromMinutes(10);   // a login nobody confirms

    // cmd.exe, with the PATH as the registry has it now — Node.js installed after Parley started
    // isn't on the PATH this process inherited.
    public static async Task<(int Status, string Output)> Shell(string command, string? dir = null)
    {
        var psi = new ProcessStartInfo("cmd.exe", $"/d /s /c \"{command}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (dir is not null) psi.WorkingDirectory = dir;
        psi.Environment["Path"] = FreshPath();
        try
        {
            using var p = Process.Start(psi);
            if (p is null) return (-1, "");
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(Patience);
            try { await p.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException)
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                Log.Write($"relay setup: gave up on `{command}` after {Patience.TotalMinutes:0} min");
            }
            var output = await stdout + await stderr;
            return (p.HasExited ? p.ExitCode : -1, output);
        }
        catch (Exception e)
        {
            Log.Write($"relay setup: `{command}` failed: {e.Message}");
            return (-1, e.Message);
        }
    }

    private static string FreshPath()
    {
        string Read(EnvironmentVariableTarget t)
        {
            try { return Environment.ExpandEnvironmentVariables(Environment.GetEnvironmentVariable("Path", t) ?? ""); }
            catch { return ""; }
        }
        var parts = new[] { Read(EnvironmentVariableTarget.Machine), Read(EnvironmentVariableTarget.User), Environment.GetEnvironmentVariable("Path") ?? "" };
        return string.Join(";", parts.Where(p => p.Length > 0));
    }

    public static async Task<bool> HasNode() => (await Shell("where npx")).Status == 0;

    // The relay's source, copied out of the app folder (a folder wrangler may write into).
    public static string? WorkDir()
    {
        var src = Path.Combine(AppContext.BaseDirectory, "relay");
        if (!File.Exists(Path.Combine(src, "wrangler.jsonc"))) return null;
        var dir = Path.Combine(Config.Dir, "relay");
        try
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            Copy(src, dir);
            return dir;
        }
        catch (Exception e)
        {
            Log.Write($"relay setup: could not copy the relay: {e.Message}");
            return null;
        }
    }

    private static void Copy(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)), true);
        foreach (var sub in Directory.GetDirectories(from)) Copy(sub, Path.Combine(to, Path.GetFileName(sub)));
    }

    // Signed in to Cloudflare (asks in the browser when not yet).
    public static async Task<bool> Login(string dir)
    {
        if ((await Shell($"npx --yes {Wrangler} whoami", dir)).Output.Contains("You are logged in")) return true;
        await Shell($"npx --yes {Wrangler} login", dir);
        return (await Shell($"npx --yes {Wrangler} whoami", dir)).Output.Contains("You are logged in");
    }

    // Deployed: the worker's https address, null if it didn't work.
    public static async Task<string?> Deploy(string dir)
    {
        var (_, output) = await Shell($"npx --yes {Wrangler} deploy", dir);
        var address = Address(output);
        if (address is null) Log.Write($"relay setup: deploy printed no address: {output[^Math.Min(400, output.Length)..]}");
        return address;
    }

    public static string? Address(string output)
    {
        var m = Regex.Match(output, @"https://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev");
        return m.Success ? m.Value : null;
    }

    // The relay answers like a Parley relay.
    public static async Task<bool> Check(string url)
    {
        if (!Uri.TryCreate(RelayLink.Normalize(url), UriKind.Absolute, out var u) || u.Scheme != "https") return false;
        try
        {
            using var r = await Http.GetAsync(u);
            return (int)r.StatusCode == 200 && (await r.Content.ReadAsStringAsync()).Contains("parley relay ok");
        }
        catch { return false; }
    }
}
