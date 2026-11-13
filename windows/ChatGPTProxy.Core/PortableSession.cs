using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace ChatGPTProxy.Core;
public sealed class PortableSession(JsonNode config)
{
    public string LauncherPath { get; } = Path.GetFullPath(config["launcherPath"]!.GetValue<string>());
    public int LauncherPid { get; } = config["launcherPid"]!.GetValue<int>();
    private long StartTicks { get; } = config["launcherStartTicks"]!.GetValue<long>();
    private string Hash { get; } = config["launcherHash"]!.GetValue<string>();
    public bool OwnerAlive
    {
        get {try {using var process=Process.GetProcessById(LauncherPid);return process.StartTime.ToUniversalTime().Ticks==StartTicks&&!process.HasExited;}catch{return false;}}
    }
    public bool MatchesLauncher(string? path)
    {
        if(path==null||!string.Equals(Path.GetFullPath(path),LauncherPath,StringComparison.OrdinalIgnoreCase))return false;
        using var stream=File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).Equals(Hash,StringComparison.OrdinalIgnoreCase);
    }
}
