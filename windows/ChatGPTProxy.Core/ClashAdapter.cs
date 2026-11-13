using System.Diagnostics;
using System.IO.Pipes;
using System.Management;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ChatGPTProxy.Core;

namespace ChatGPTProxy.Core;
[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public sealed class ClashAdapter : IDisposable
{
    public string Pipe {get;}
    public string Root {get;}
    public int Pid {get;}
    public long StartTicks {get;}
    private readonly HttpClient client;
    private readonly NativeCore core;
    public ClashAdapter(string pipe,string root,int pid,NativeCore core)
    {
        Pipe=pipe;Root=root;Pid=pid;StartTicks=Process.GetProcessById(pid).StartTime.ToUniversalTime().Ticks;this.core=core;
        var handler=new SocketsHttpHandler {UseProxy=false,AllowAutoRedirect=false,ConnectCallback=async (_,ct)=>{
            var stream=new NamedPipeClientStream(".",Pipe,PipeDirection.InOut,PipeOptions.Asynchronous);
            try{await stream.ConnectAsync(ct);return stream;}catch{stream.Dispose();throw;}
        }};
        client=new HttpClient(handler){BaseAddress=new Uri("http://localhost"),Timeout=TimeSpan.FromSeconds(12)};
    }
    public static async Task<ClashAdapter> Discover(int port,string ownerSid,NativeCore core)
    {
        var matches=new List<ClashAdapter>();
        using var search=new ManagementObjectSearcher("SELECT ProcessId,CommandLine,ExecutablePath FROM Win32_Process WHERE Name='mihomo.exe'");
        foreach(ManagementObject process in search.Get()) {
            using(process) {
                if(ProcessIdentity.OwnerSid(Convert.ToInt32(process["ProcessId"]))!=ownerSid)continue;
                var command=process["CommandLine"]?.ToString()??"";
                var pipe=Regex.Match(command,@"-ext-ctl-pipe\s+(?:""([^""]+)""|(\S+))");
                var directory=Regex.Match(command,@"(?:^|\s)-d\s+(?:""([^""]+)""|(\S+))");
                var endpoint=pipe.Groups[1].Success?pipe.Groups[1].Value:pipe.Groups[2].Value;
                var work=directory.Groups[1].Success?directory.Groups[1].Value:directory.Groups[2].Value;
                if(!endpoint.StartsWith(@"\\.\pipe\MihomoParty\",StringComparison.OrdinalIgnoreCase)||!Path.IsPathFullyQualified(work)||!Path.GetFileName(work).Equals("work",StringComparison.OrdinalIgnoreCase))continue;
                var adapter=new ClashAdapter(endpoint[9..],Path.GetDirectoryName(work)!,Convert.ToInt32(process["ProcessId"]),core);
                try {
                    var version=await adapter.Command("version");var general=await adapter.Command("configs");
                    if(version?["meta"]?.GetValue<bool>()==true&&(general?["mixed-port"]?.GetValue<int>()==port||general?["socks-port"]?.GetValue<int>()==port))matches.Add(adapter);else adapter.Dispose();
                }catch{adapter.Dispose();}
            }
        }
        if(matches.Count!=1){foreach(var match in matches)match.Dispose();throw new IOException(matches.Count==0?"等待 Clash Party 控制接口":"多个 Clash 控制接口匹配，已暂停切换");}
        return matches[0];
    }
    public async Task<JsonNode?> Command(string command,string? name=null,string? id=null,string? yaml=null,string? group=null)
    {
        var request=JsonNode.Parse(core.Call(new{op="clashRequest",command,name,id,yaml,group}).GetRawText())!;
        return await Request(request["method"]!.GetValue<string>(),request["path"]!.GetValue<string>(),request["body"]);
    }
    public async Task<JsonArray> ConnectionIds(string? node=null,bool dns=false)
    {
        var connections=(await Command("connections"))?["connections"];
        return JsonNode.Parse(core.Call(new{op="clashConnectionIds",connections,node,dns}).GetRawText())!.AsArray();
    }
    public bool SameProcess() {try{return Process.GetProcessById(Pid).StartTime.ToUniversalTime().Ticks==StartTicks;}catch{return false;}}
    public async Task<JsonNode?> Request(string method,string path,JsonNode? body=null)
    {
        using var request=new HttpRequestMessage(new HttpMethod(method),path);
        if(body!=null)request.Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json");
        using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        using var input=await response.Content.ReadAsStreamAsync();using var output=new MemoryStream();var bytes=new byte[16384];
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(12));int count;
        while((count=await input.ReadAsync(bytes,timeout.Token))>0){ConfigurationFiles.ValidateSize(output.Length+count,ConfigurationFiles.MaximumResponseSize,"Clash 控制接口响应");output.Write(bytes,0,count);}
        return output.Length==0?null:JsonNode.Parse(output.ToArray());
    }
    public string Source()=>ProcessIdentity.AsProcessUser(Pid,()=>ConfigurationFiles.ReadSource(Path.Combine(Root,"work","config.yaml")));
    public string Generation()=>Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(Source())));
    public async Task<JsonObject> Snapshot()
    {
        var general=await Command("configs");var proxies=(await Command("proxies"))?["proxies"]?.DeepClone() ?? throw new IOException("Missing Clash proxies");
        var resolution=JsonNode.Parse(core.Call(new{op="clashSnapshot",proxies}).GetRawText())!;
        JsonNode? origins=null;try{origins=ProcessIdentity.AsProcessUser(Pid,()=>JsonNode.Parse(core.Call(new{op="nodeOrigins",directory=Root}).GetRawText()));}catch{}
        return new JsonObject{["socket"]=Pipe,["mode"]=general?["mode"]?.DeepClone(),["current"]=resolution["current"]?.DeepClone(),["selection"]=resolution["selection"]!.DeepClone(),["proxies"]=proxies,["signature"]=origins?["signature"]?.DeepClone(),["origins"]=origins?["origins"]?.DeepClone(),["activeProfileId"]=origins?["activeProfileId"]?.DeepClone()};
    }
    public async Task<JsonObject> Selections()
    {
        var proxies=(await Command("proxies"))?["proxies"]??throw new IOException("Missing proxies");
        return JsonNode.Parse(core.Call(new{op="clashSelections",proxies}).GetRawText())!.AsObject();
    }

    public async Task Reload(string yaml,JsonObject selections)
    {
        await Command("reload",yaml:yaml);
        var elapsed=Stopwatch.StartNew();
        while(!core.Call(new{op="clashSelectionsReady",selection=selections,proxies=(await Command("proxies"))?["proxies"]}).GetBoolean()) {
            if(elapsed.Elapsed>TimeSpan.FromSeconds(12))throw new IOException("Clash 订阅节点尚未加载，无法恢复原节点选择");
            await Task.Delay(200);
        }
        foreach(var (name,value) in selections)await Command("select",name:value!.GetValue<string>(),group:name);
        await Command("flushDNS");
    }
    public void Dispose()=>client.Dispose();
}
