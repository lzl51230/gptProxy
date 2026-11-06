using ChatGPTProxy.Core;
using Xunit;

public class NativeCoreTests
{
    [Fact]
    public void ValidationErrorsDoNotInvalidateHandle()
    {
        using var core = new NativeCore();
        Assert.Throws<InvalidOperationException>(() => core.Call(new { op = "validatePort", value = "17890" }));
        Assert.Equal(7890, core.Call(new { op = "validatePort", value = "7890" }).GetInt32());
    }
    [Fact]
    public void EnvironmentUsesRemoteDnsAndPreservesOtherVariables()
    {
        using var core = new NativeCore();
        var result = core.Call(new { op = "launchEnvironment", environment = new Dictionary<string,string> { ["PATH"]="kept", ["NO_PROXY"]="*" } });
        Assert.Equal("kept", result.GetProperty("PATH").GetString());
        Assert.Equal("socks5h://127.0.0.1:17890",result.GetProperty("HTTPS_PROXY").GetString());
        Assert.Equal("localhost,127.0.0.1,::1,192.168.0.0/16", result.GetProperty("NO_PROXY").GetString());
    }
    [Fact]
    public void RelayCanBeStoppedAndSamePortReused()
    {
        using var core = new NativeCore();
        int port=core.Call(new { op="relayStart", listenPort=0, upstreamPort=7890 }).GetInt32();
        core.Call(new { op="relayStop" });
        Assert.Equal(port,core.Call(new { op="relayStart", listenPort=port, upstreamPort=7890 }).GetInt32());
        core.Call(new { op="relayStop" });
    }
}

public class SharedMonitorTests
{
    [Fact]
    public void RecoveryRequiresTwoShortFailuresAndUsesBoundedBackoff()
    {
        using var core = new NativeCore();
        for(int count=1; count<=2; count++)
        {
            var state=core.Call(new { op="monitor", action="observe", node="日本 A", heartbeat=new { isHealthy=false, connectionSeconds=9.0 } });
            Assert.Equal(count,state.GetProperty("failures").GetInt32());
            Assert.Equal(count==2,state.GetProperty("recovery").GetBoolean());
        }
        foreach(int delay in new[]{2,4,8,16,30,30})
            Assert.Equal(delay,core.Call(new { op="monitor", action="retry" }).GetProperty("delay").GetInt32());
        Assert.False(core.Call(new { op="monitor", action="accept" }).GetProperty("recovery").GetBoolean());
    }
    [Fact]
    public void CandidatesRemainInsideCurrentSubscription()
    {
        using var core = new NativeCore();
        var result=core.Call(new { op="monitorCandidates", current="日本 A",
            origins=new Dictionary<string,string>{{"日本 A","one"},{"美国 B","one"},{"日本 C","two"}},
            names=new[]{"美国 B","日本 C"}, proxies=new Dictionary<string,object>{{"美国 B",new { type="ss" }},{"日本 C",new { type="ss" }}} });
        Assert.Equal("美国 B",result.GetProperty("US")[0].GetString());
        Assert.False(result.TryGetProperty("JP",out _));
    }
}

public class PipeFramingTests
{
    [Theory]
    [InlineData(-1)]
    [InlineData(0)]
    [InlineData(65537)]
    public async Task InvalidLengthIsRejectedBeforeAllocatingPayload(int length)
    {
        using var input=new MemoryStream(BitConverter.GetBytes(length));
        await Assert.ThrowsAsync<IOException>(()=>ServiceClient.Read(input,CancellationToken.None));
    }
    [Fact]
    public async Task TruncatedPayloadCannotBecomeACommand()
    {
        using var input=new MemoryStream(new byte[]{10,0,0,0,123,125});
        await Assert.ThrowsAsync<EndOfStreamException>(()=>ServiceClient.Read(input,CancellationToken.None));
    }
}
