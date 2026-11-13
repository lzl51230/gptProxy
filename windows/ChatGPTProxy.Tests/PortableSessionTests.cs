using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using ChatGPTProxy.Core;
using Xunit;

public sealed class PortableSessionTests : IDisposable
{
    private readonly string path=Path.Combine(Path.GetTempPath(),Guid.NewGuid().ToString());
    public void Dispose()=>File.Delete(path);
    private JsonObject Config()
    {
        File.WriteAllText(path,"original launcher");
        using var process=Process.GetCurrentProcess();
        return new JsonObject {
            ["launcherPath"]=path,["launcherPid"]=process.Id,
            ["launcherStartTicks"]=process.StartTime.ToUniversalTime().Ticks,
            ["launcherHash"]=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)))
        };
    }
    [Fact]
    public void LiveOwnerIsRecognizedButReusedPidIsNot()
    {
        var config=Config();Assert.True(new PortableSession(config).OwnerAlive);
        config["launcherStartTicks"]=1L;Assert.False(new PortableSession(config).OwnerAlive);
    }
    [Fact]
    public void MissingOwnerDoesNotPreventRecovery()
    {
        var config=Config();config["launcherPid"]=int.MaxValue;
        Assert.False(new PortableSession(config).OwnerAlive);
    }
    [Fact]
    public void OnlyOriginalLauncherPathAndBytesAreAccepted()
    {
        var session=new PortableSession(Config());
        Assert.True(session.MatchesLauncher(path));
        Assert.False(session.MatchesLauncher(path+"-other"));
        File.WriteAllText(path,"replaced launcher");Assert.False(session.MatchesLauncher(path));
    }
}
