using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using ChatGPTProxy.Core;

namespace ChatGPTProxy.Service;
internal sealed class Coordinator : IAsyncDisposable
{
    private readonly NativeCore core=new();
    private readonly NativeCore monitor=new();
    private readonly SemaphoreSlim mutation=new(1,1);
    private readonly string ownerSid;
    private readonly string stateDirectory;
    private readonly string journalPath;
    private ClashAdapter? clash;
    private ProxyBridgeAdapter? bridge;
    private CancellationTokenSource? monitoring;
    private Task? monitorTask;
    private int ownerPid;
    private long ownerStart;
    private int port;
    private volatile bool confirmed;
    private volatile bool exitRequested;
    private bool heartbeatOpen;
    private string? recoveryBlocked;
    private JsonNode preferences=new JsonArray();
    private JsonNode monitorState=new JsonObject();
    private string detail="保护已关闭";
    private string phase="disabled";
    private string sourceGeneration="";
    private string selectionSignature="";
    public Coordinator(string ownerSid)
    {
        this.ownerSid=ownerSid;
        stateDirectory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"ChatGPT Proxy");
        var directory = new DirectoryInfo(stateDirectory);
        if (!directory.Exists) throw new IOException("请先通过安装程序创建受保护的恢复目录");
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("恢复目录身份无效");
        var acl = System.IO.FileSystemAclExtensions.GetAccessControl(directory);
        var owner = acl.GetOwner(typeof(System.Security.Principal.SecurityIdentifier))?.Value;
        if (owner is not ("S-1-5-18" or "S-1-5-32-544") || !acl.AreAccessRulesProtected)
            throw new IOException("恢复目录权限无效，请修复安装");
        foreach (System.Security.AccessControl.FileSystemAccessRule rule in acl.GetAccessRules(true,true,typeof(System.Security.Principal.SecurityIdentifier)))
            if (rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow && rule.IdentityReference.Value is not ("S-1-5-18" or "S-1-5-32-544"))
                throw new IOException("恢复目录允许非管理员访问");
        // Directory is provisioned by installer with SYSTEM/Administrators-only access.
        journalPath=Path.Combine(stateDirectory,"recovery-v1.json");
    }
    private static double Now=>Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency;
    private JsonNode Call(object request)=>JsonNode.Parse(core.Call(request).GetRawText())!;
    public async Task Initialize()
    {
        JsonNode? journal=null;
        try {
            if(File.Exists(journalPath)) {
                if(new FileInfo(journalPath).Length>8*1024*1024)throw new IOException("Recovery journal too large; retained");
                journal=JsonNode.Parse(await File.ReadAllTextAsync(journalPath)) ?? throw new IOException("Empty recovery journal; retained");
            }
            Call(new{op="protection",action="load",journal});
        } catch(Exception e){recoveryBlocked=e.Message;phase="failed";detail=e.Message;return;}
        if(journal!=null){try{await Transaction(new{op="protection",action="restore"});}catch(Exception e){phase="failed";detail=e.Message;}}
    }
    private JsonNode MonitorStatus() {
        var value=monitorState.DeepClone();
        if(value["candidates"] is JsonObject catalog) {
            var counts=new JsonObject();foreach(var (region,nodes) in catalog)counts[region]=(nodes as JsonArray)?.Count??0;
            value["candidates"]=counts;
        }
        return value;
    }
    public JsonObject Status()=>new(){["exitRequested"]=exitRequested,["phase"]=phase,["ready"]=confirmed&&bridge?.Ready==true&&phase=="enabled",["detail"]=detail,["bridge"]=bridge?.Snapshot,["monitor"]=MonitorStatus(),["port"]=port};
    public void Heartbeat(int pid)
    {
        if(pid==ownerPid&&OwnerAlive())Call(new{op="protection",action="heartbeat",now=Now});
    }
    private bool OwnerAlive(){try{return Process.GetProcessById(ownerPid).StartTime.ToUniversalTime().Ticks==ownerStart;}catch{return false;}}
    public async Task<JsonObject> Command(JsonNode request,int pid)
    {
        var command=request["command"]?.GetValue<string>();
        if(command=="status")return Status();
        if(command=="heartbeat"){Heartbeat(pid);return Status();}
        await mutation.WaitAsync();
        try {
            switch(command) {
                case "enable":
                    if(exitRequested)throw new IOException("安装程序正在关闭启动器");
                    await Stop();
                    port=core.Call(new{op="validatePort",value=request["port"]?.ToString()??"7890"}).GetInt32();
                    ownerPid=pid;ownerStart=Process.GetProcessById(pid).StartTime.ToUniversalTime().Ticks;
                    preferences=request["regions"]?.DeepClone()??new JsonArray();
                    detail="正在检查 Clash Party 与 ProxyBridge";phase="preparing";
                    clash=await ClashAdapter.Discover(port,ownerSid,core);
                    core.Call(new{op="probeUDP",port});
                    core.Call(new{op="relayStart",listenPort=17890,upstreamPort=port});
                    bridge=new ProxyBridgeAdapter(core);await bridge.Start(stateDirectory);
                    await Transaction(new{op="protection",action="enable",now=Now});
                    if(phase!="enabled")throw new IOException(detail);
                    detail="保护已就绪，等待 ChatGPT 正常重启";
                    break;
                case "confirm":
                    if(pid!=ownerPid||phase!="enabled"||bridge?.Ready!=true)throw new IOException("保护尚未就绪");
                    var gptPid=request["pid"]?.GetValue<int>()??0;
                    using(var process=Process.GetProcessById(gptPid)) {
                        if(ProcessIdentity.OwnerSid(gptPid)!=ownerSid||!ProcessIdentity.IsChatGPTPackage(ProcessIdentity.PackageFullName(gptPid)))throw new IOException("ChatGPT 应用包身份无效");
                        if(process.SessionId!=Process.GetProcessById(pid).SessionId)throw new IOException("ChatGPT 不属于当前用户会话");
                        var path=process.MainModule?.FileName??"";
                        if(!path.StartsWith(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"WindowsApps","OpenAI.Codex_"),StringComparison.OrdinalIgnoreCase)||!Path.GetFileName(path).Equals("ChatGPT.exe",StringComparison.OrdinalIgnoreCase))throw new IOException("无法确认 ChatGPT 启动身份");
                    }
                    confirmed=true;detail="ChatGPT 已通过受保护代理启动";StartMonitor();break;
                case "restore": await Stop();break;
                case "shutdown": await Stop();exitRequested=true;break;
                case "preferences":
                    if(phase=="enabled"&&ownerPid!=pid)throw new IOException("启动器会话不匹配");
                    preferences=request["regions"]?.DeepClone()??new JsonArray();await StopMonitor();
                    if(request["paused"]?.GetValue<bool>()!=true&&confirmed)StartMonitor();
                    else if(request["paused"]?.GetValue<bool>()==true)monitorState=new JsonObject{["phase"]="paused",["status"]="节点自动切换已暂停"};break;
                default: throw new IOException("不支持的服务命令");
            }
            return Status();
        }catch(Exception e){var failure=e.Message;try{await Stop();}catch(Exception restore){failure+="；恢复未完成："+restore.Message;}phase="failed";detail=failure;throw new IOException(detail,e);}
        finally{mutation.Release();}
    }
    public async Task Watchdog()
    {
        if(!await mutation.WaitAsync(0))return;
        try {
            if(phase is "enabled" or "failed") {
                var alive=OwnerAlive();var ready=bridge?.Ready==true;
                if(!alive)detail="启动器已退出或失去响应，正在恢复 DNS";
                else if(!ready)detail="ProxyBridge 不再就绪："+bridge?.Snapshot.ToJsonString();
                await Transaction(new{op="protection",action="watchdog",now=Now,ownerAlive=alive&&ready});
                if(phase!="enabled"){confirmed=false;await StopMonitor();await StopBridge();core.Call(new{op="relayStop"});}
            }
        }catch(Exception e){confirmed=false;phase="failed";detail="恢复未完成："+e.Message;}
        finally{mutation.Release();}
    }
    private async Task Transaction(object request)
    {
        if(recoveryBlocked!=null)throw new IOException(recoveryBlocked);
        var state=Call(request);
        while(state["done"]?.GetValue<bool>()!=true) {
            var effect=state["effect"]!;var id=effect["id"]!.GetValue<ulong>();
            try {var value=await Effect(effect);state=Call(new{op="protection",action="complete",id,now=Now,value});}
            catch(Exception e){state=Call(new{op="protection",action="complete",id,now=Now,error=e.Message});}
        }
        phase=state["phase"]?.GetValue<string>()??"failed";
        var errors=state["errors"]?.AsArray();
        if(errors?.Count>0)detail=string.Join("；",errors.Select(v=>v!.GetValue<string>()));
        if(phase=="disabled"&&errors?.Count==0)detail="保护已关闭，原 DNS 配置已恢复";
        if(phase=="failed")throw new IOException(detail);
    }
    private async Task<JsonNode?> Effect(JsonNode effect)
    {
        var journal=effect["journal"];
        switch(effect["op"]!.GetValue<string>()) {
            case "preflight":
                var adapter=clash??throw new IOException("Clash unavailable");
                var general=await adapter.Command("configs");sourceGeneration=adapter.Generation();
                return new JsonObject{["platform"]="windows",["ownerSid"]=ownerSid,["pipe"]=adapter.Pipe,["root"]=adapter.Root,["corePID"]=adapter.Pid,["coreStartTicks"]=adapter.StartTicks,["sourceGeneration"]=sourceGeneration,["source"]=adapter.Source(),["general"]=general!.ToJsonString(),["snapshot"]=await adapter.Snapshot(),["selection"]=await adapter.Selections(),["services"]=await SystemAdapters.DnsSnapshot()};
            case "persist":
                var temporary=journalPath+".tmp";
                using(var stream=new FileStream(temporary,FileMode.Create,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) {var bytes=System.Text.Encoding.UTF8.GetBytes(journal!.ToJsonString());await stream.WriteAsync(bytes);stream.Flush(true);}
                File.Move(temporary,journalPath,true);return null;
            case "frontendStart": core.Call(new{op="dnsStart",listenPort=53,upstreamPort=17853});return null;
            case "frontendStop": core.Call(new{op="dnsStop"});return null;
            case "clashApply":
                await clash!.Reload(effect["protectedYAML"]!.GetValue<string>(),journal!["selection"]!.AsObject());
                await clash.Command("closeAll");return null;
            case "dnsReady":
                Exception? failure=null;
                for(int attempt=0;attempt<4;attempt++){try{core.Call(new{op="dnsProbe",port=17853,timeout=1});core.Call(new{op="dnsProbe",port=53,tcp=true,timeout=1});return null;}catch(Exception e){failure=e;await Task.Delay(250);}}
                throw failure!;
            case "systemDNSApply": await SystemAdapters.DnsApply(journal!["services"]!.AsArray(),false);return null;
            case "systemDNSRestore": await SystemAdapters.DnsApply(journal!["services"]!.AsArray(),true);return null;
            case "firewallEnable": core.Call(new{op="firewallStart"});return null;
            case "firewallDisable": core.Call(new{op="firewallStop"});return null;
            case "cacheFlush": await SystemAdapters.FlushDns();return null;
            case "verify":
                if(clash==null||!clash.SameProcess()||clash.Generation()!=sourceGeneration)throw new IOException("Clash 进程或订阅配置已变化");
                var snapshot=await clash.Snapshot();
                if(snapshot["mode"]?.GetValue<string>()!="global"||snapshot["current"]?.GetValue<string>() is null or "DIRECT" or "REJECT" or "PASS")throw new IOException("Clash 已离开全局代理模式");
                if((await clash.Command("configs"))?["ipv6"]?.GetValue<bool>()!=false)throw new IOException("Clash IPv4 策略被覆盖");
                var selection=snapshot["selection"]?.ToJsonString()??"";
                if(selection!=selectionSignature){
                    foreach(var id in await clash.ConnectionIds(dns:true))await clash.Command("close",id:id!.GetValue<string>());
                    await clash.Command("flushDNS");selectionSignature=selection;
                }
                var savedIds=journal!["services"]!.AsArray().Select(s=>s!["id"]!.GetValue<string>()).ToHashSet(StringComparer.OrdinalIgnoreCase);
                var additions=new JsonArray((await SystemAdapters.DnsSnapshot()).Where(s=>!savedIds.Contains(s!["id"]!.GetValue<string>())).Select(s=>s!.DeepClone()).ToArray());
                if(additions.Count>0)return new JsonObject{["newServices"]=additions};
                await SystemAdapters.AssertDns();core.Call(new{op="dnsProbe",port=53,ipv4Only=true,timeout=2});
                bool answered=false;try{core.Call(new{op="dnsProbe",port=53,host="1.1.1.1",timeout=1});answered=true;}catch{}
                if(answered)throw new IOException("明文 DNS 阻断验证失败");return null;
            case "clashRestorePrepare":
                if(clash==null) {
                    var pid=journal!["corePID"]!.GetValue<int>();
                    try{if(Process.GetProcessById(pid).StartTime.ToUniversalTime().Ticks!=journal["coreStartTicks"]!.GetValue<long>())return null;}catch(ArgumentException){return null;}
                    clash=new ClashAdapter(journal["pipe"]!.GetValue<string>(),journal["root"]!.GetValue<string>(),pid,core);
                }
                if(!clash.SameProcess())return null;
                return new JsonObject{["general"]=(await clash.Command("configs"))!.ToJsonString(),["sourceChanged"]=clash.Generation()!=journal!["sourceGeneration"]!.GetValue<string>(),["source"]=clash.Source(),["selection"]=await clash.Selections()};
            case "clashRestoreApply":await clash!.Reload(effect["restoreYAML"]!.GetValue<string>(),effect["restoreSelection"]!.AsObject());return null;
            case "removeJournal":File.Delete(journalPath);return null;
            case "enabled":case "finishRestore":return null;
            default:throw new IOException("Unknown protection effect");
        }
    }
    private void StartMonitor()
    {
        if(monitorTask!=null)return;
        monitoring=new CancellationTokenSource();var token=monitoring.Token;
        monitorTask=Task.Run(async ()=>{
            try {while(!token.IsCancellationRequested) {
                var response=MonitorCall(new{op="monitorWorkflow",action="begin",now=Now,regions=preferences});
                while(true) {
                    token.ThrowIfCancellationRequested();monitorState=response["state"]!.DeepClone();
                    if(response["done"]!.GetValue<bool>())break;
                    var effect=response["effect"]!;var id=effect["id"]!.GetValue<ulong>();
                    try{var value=await MonitorEffect(effect,token);token.ThrowIfCancellationRequested();response=MonitorCall(new{op="monitorWorkflow",action="complete",id,now=Now,value});}
                    catch(OperationCanceledException){throw;}
                    catch(Exception e){response=MonitorCall(new{op="monitorWorkflow",action="complete",id,now=Now,error=e.Message});}
                }
                await Task.Delay(TimeSpan.FromSeconds(monitorState["nextDelay"]?.GetValue<double>()??2),token);
            }}catch(OperationCanceledException){}catch(Exception e){monitorState=new JsonObject{["status"]=e.Message,["phase"]="retrying"};}
        });
    }
    private JsonNode MonitorCall(object request)=>JsonNode.Parse(monitor.Call(request).GetRawText())!;
    private async Task<JsonNode?> MonitorEffect(JsonNode effect,CancellationToken token)
    {
        var args=effect["args"];var adapter=clash??throw new IOException("Clash unavailable");
        switch(effect["op"]!.GetValue<string>()) {
            case "snapshot":return await adapter.Snapshot();
            case "heartbeat":
                if(!heartbeatOpen){monitor.Call(new{op="heartbeatOpen",port});heartbeatOpen=true;}
                using(var registration=token.Register(()=>{try{monitor.Call(new{op="heartbeatCancel"});}catch{}}))return await Task.Run(()=>MonitorCall(new{op="heartbeat"}),CancellationToken.None);
            case "closeConnection":monitor.Call(new{op="heartbeatClose"});heartbeatOpen=false;return null;
            case "sleep":await Task.Delay(TimeSpan.FromSeconds(args!.GetValue<double>()),token);return null;
            case "delays":
                var names=args!["names"]!.AsArray().Select(n=>n!.GetValue<string>()).ToArray();
                var results=await Task.WhenAll(names.Select(async name=>{try{var value=await adapter.Command("delay",name:name);return (name,value?["delay"]?.GetValue<int>());}catch{return (name,(int?)null);}}));
                var delays=new JsonObject();foreach(var (name,delay) in results)if(delay!=null)delays[name]=delay;return delays;
            case "select":await adapter.Command("select",name:args!["name"]!.GetValue<string>());return null;
            case "connections":
                return await adapter.ConnectionIds(node:args!["node"]!.GetValue<string>());
            case "close":await adapter.Command("close",id:args!["id"]!.GetValue<string>());return null;
            default:throw new IOException("Unknown monitor effect");
        }
    }
    private async Task StopMonitor()
    {
        monitoring?.Cancel();if(monitorTask!=null)await monitorTask;
        monitor.Call(new{op="heartbeatClose"});heartbeatOpen=false;
        monitor.Call(new{op="monitorWorkflow",action="reset"});monitorState=new JsonObject{["phase"]="stopped",["status"]="保护未启用，监控已停止"};monitorTask=null;monitoring?.Dispose();monitoring=null;
    }
    private async Task StopBridge(){if(bridge!=null){await bridge.DisposeAsync();bridge=null;}}
    public async Task Stop()
    {
        confirmed=false;await StopMonitor();
        await Transaction(new{op="protection",action="restore"});
        await StopBridge();core.Call(new{op="relayStop"});clash?.Dispose();clash=null;
        phase="disabled";detail="保护已关闭，原 DNS 配置已恢复";
    }
    public async ValueTask DisposeAsync(){await Stop();monitor.Dispose();core.Dispose();mutation.Dispose();}
}
