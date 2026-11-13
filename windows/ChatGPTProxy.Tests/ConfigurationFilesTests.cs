using System.Text;
using System.Text.Json;
using ChatGPTProxy.Core;
using Xunit;

public sealed class ConfigurationFilesTests : IDisposable
{
    private readonly string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
    public void Dispose() => File.Delete(path);

    [Theory]
    [InlineData(10 * 1024 * 1024)]
    [InlineData(32 * 1024 * 1024)]
    public void ConfigurationUpTo32MiBIsReadCompletely(int size)
    {
        using (var file = File.Create(path)) file.SetLength(size);
        Assert.Equal(size, Encoding.UTF8.GetByteCount(ConfigurationFiles.ReadSource(path)));
    }

    [Fact]
    public void OversizedConfigurationReportsActualBytesAndLimit()
    {
        long size = ConfigurationFiles.MaximumConfigurationSize + 1L;
        using (var file = File.Create(path)) file.SetLength(size);
        var error = Assert.Throws<IOException>(() => ConfigurationFiles.ReadSource(path));
        Assert.Contains("32 MiB", error.Message);
        Assert.Contains(size.ToString(), error.Message);
    }

    [Fact]
    public void InvalidUtf8IsRejectedAndBomIsRemoved()
    {
        File.WriteAllBytes(path, new byte[] { 0xff });
        Assert.Throws<DecoderFallbackException>(() => ConfigurationFiles.ReadSource(path));
        File.WriteAllText(path, "mode: global", new UTF8Encoding(true));
        Assert.Equal("mode: global", ConfigurationFiles.ReadSource(path));
    }

    [Fact]
    public void OversizedRecoveryRecordIsRetained()
    {
        long size = ConfigurationFiles.MaximumRecoverySize + 1L;
        using (var file = File.Create(path)) file.SetLength(size);
        Assert.Contains("256 MiB", Assert.Throws<IOException>(() => ConfigurationFiles.ReadRecovery(path)).Message);
        Assert.Equal(size, new FileInfo(path).Length);
    }

    [Fact]
    public void LargeConfigurationTransformsAndRecoveryReloadThroughNativeCore()
    {
        var payload = new string('x', 9 * 1024 * 1024) + "中文 \"quoted\" \\ path\n";
        var source = "mode: global\ndns: {enable: true, default-nameserver: [tls://1.1.1.1], proxy-server-nameserver: [https://1.1.1.1/dns-query]}\nx-payload: " + JsonSerializer.Serialize(payload);
        File.WriteAllText(path, source, new UTF8Encoding(false));
        using var core = new NativeCore();
        var loaded = ConfigurationFiles.ReadSource(path);
        var runtime = core.Call(new { op = "runtimeYAML", source = loaded, general = "{\"ipv6\":true}" }).GetString()!;
        var protectedYaml = core.Call(new { op = "protectedYAML", source = runtime }).GetString()!;
        Assert.Contains("x-payload:", protectedYaml);
        File.WriteAllText(path, JsonSerializer.Serialize(new { version = 1, source = loaded, originalYAML = runtime }));
        Assert.True(new FileInfo(path).Length > 8 * 1024 * 1024);
        using var journal = JsonDocument.Parse(ConfigurationFiles.ReadRecovery(path));
        var result = core.Call(new { op = "protection", action = "load", journal = journal.RootElement });
        Assert.Equal("restoring", result.GetProperty("phase").GetString());
        var restored = core.Call(new { op = "restoredYAML", source = runtime, general = "{\"ipv6\":true}", originalIPv6 = true, ipv4PolicyApplied = true, sourceChanged = false }).GetString()!;
        Assert.Contains("x-payload:", restored);
    }
}
