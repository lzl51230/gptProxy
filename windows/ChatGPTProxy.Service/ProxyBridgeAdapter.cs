using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using ChatGPTProxy.Core;

namespace ChatGPTProxy.Service;
internal sealed class ProxyBridgeAdapter : IAsyncDisposable
{
    private Process? process;
    private OwnedJob? job;
    private Task[] readers=[];
    private readonly NativeCore core;
    private readonly object gate=new();
    private JsonNode output=new JsonObject();
    private readonly Stopwatch clock=new();
    private JsonNode Status(){var alive=process is {HasExited:false};return JsonNode.Parse(core.Call(new{op="cliStatus",platform="windows",state=output,alive,elapsed=clock.Elapsed.TotalSeconds,timeout=10,exitCode=process is {HasExited:true}?process.ExitCode:-1}).GetRawText())!;}
    public JsonNode Snapshot {get{lock(gate)return Status();}}
    public bool Ready {get {lock(gate)return Status()["ready"]!.GetValue<bool>();}}
    public ProxyBridgeAdapter(NativeCore core)=>this.core=core;
    public async Task Start(string stateDirectory)
    {
        var directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"ProxyBridge");
        var executable=Path.Combine(directory,"ProxyBridge_CLI.exe");
        var manifestPath=Path.Combine(AppContext.BaseDirectory,"proxybridge-files.json");
        if(!File.Exists(executable)||!File.Exists(manifestPath))throw new IOException("请先安装已校验的 ProxyBridge 4.1.1 Windows 组件");
        var manifest=JsonNode.Parse(await File.ReadAllTextAsync(manifestPath))!.AsObject();
        foreach(var (name,hash) in manifest) {
            if(Path.GetFileName(name)!=name)throw new IOException("Invalid ProxyBridge manifest");
            using var file=File.OpenRead(Path.Combine(directory,name));
            if(!Convert.ToHexString(SHA256.HashData(file)).Equals(hash!.GetValue<string>(),StringComparison.OrdinalIgnoreCase))throw new IOException("ProxyBridge 文件版本不匹配，请修复安装");
        }
        if(Process.GetProcessesByName("ProxyBridge_CLI").Length>0||Process.GetProcessesByName("ProxyBridge").Length>0)throw new IOException("请先退出已有的 ProxyBridge 实例");
        var profile=Path.Combine(stateDirectory,"ChatGPT-Only.pbprofile");
        await File.WriteAllTextAsync(profile,core.Call(new{op="proxyProfile",platform="windows"}).GetRawText());
        var start=new ProcessStartInfo(executable){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=directory};
        start.ArgumentList.Add("--profile");start.ArgumentList.Add(profile);start.ArgumentList.Add("--verbose");start.ArgumentList.Add("1");
        clock.Restart();
        process=Process.Start(start)??throw new IOException("无法启动 ProxyBridge");
        try { job=new OwnedJob(process); } catch { process.Kill(true); throw; }
        readers=[Read(process.StandardOutput.BaseStream),Read(process.StandardError.BaseStream)];
        while(true) {
            lock(gate){var status=Status();if(status["ready"]!.GetValue<bool>())return;if(status["failure"]!=null)throw new IOException(status["failure"]!.GetValue<string>());}
            await Task.Delay(100);
        }
    }

    private async Task Read(Stream stream)
    {
        using var decoder=new NativeCore();var bytes=new byte[16384];
        try {while(true) {
            var count=await stream.ReadAsync(bytes);var result=decoder.Call(new{op="lineChunk",bytes=bytes.Take(count).Select(b=>(int)b).ToArray(),finish=count==0});
            lock(gate){foreach(var line in result.GetProperty("lines").EnumerateArray())output=JsonNode.Parse(core.Call(new{op="cliConsume",platform="windows",state=output,line=line.GetString()}).GetRawText())!;}
            if(count==0)break;
        }}catch(Exception e){lock(gate)output["failure"]="CLI 输出读取失败: "+e.Message;}
    }
    public async ValueTask DisposeAsync()
    {
        if(process!=null){if(!process.HasExited)process.Kill(true);await process.WaitForExitAsync();await Task.WhenAll(readers);process.Dispose();process=null;job?.Dispose();job=null;}
    }
}
