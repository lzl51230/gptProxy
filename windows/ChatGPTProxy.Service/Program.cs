using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json.Nodes;
using ChatGPTProxy.Core;
using ChatGPTProxy.Service;
using Microsoft.Win32.SafeHandles;

var builder=Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options=>options.ServiceName="ChatGPTProxy");
builder.Services.AddHostedService<ProxyWorker>();
await builder.Build().RunAsync();

internal sealed partial class ProxyWorker(ILogger<ProxyWorker> logger,IHostApplicationLifetime lifetime) : BackgroundService
{
    private PortableSession? portable;
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var config=JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory,"owner.json"),stoppingToken))!;
        var owner=new SecurityIdentifier(config["sid"]!.GetValue<string>());
        portable=config["portable"]?.GetValue<bool>()==true?new PortableSession(config):null;
        await using var coordinator=new Coordinator(owner.Value);
        await coordinator.Initialize();
        var cleanup=false;
        DateTime? exitRequestedAt=null;
        var watchdog=Task.Run(async ()=>{while(!stoppingToken.IsCancellationRequested){try{
            await Task.Delay(1000,stoppingToken);await coordinator.Watchdog();
            if(coordinator.ExitRequested)exitRequestedAt??=DateTime.UtcNow;
            if(portable!=null&&(!portable.OwnerAlive||(exitRequestedAt is {} requested&&DateTime.UtcNow-requested>TimeSpan.FromSeconds(5)))) {
                await coordinator.EndPortableSession();cleanup=true;lifetime.StopApplication();break;
            }
        }catch(OperationCanceledException){break;}catch(Exception e){logger.LogError("Watchdog: {Message}",e.Message);}}},stoppingToken);
        var clients=new List<Task>();
        try {while(!stoppingToken.IsCancellationRequested) {
            // Bound idle clients; each connection has a deadline and exactly one command.
            clients.RemoveAll(t=>t.IsCompleted);
            if(clients.Count>=16){await Task.WhenAny(clients);continue;}
            var security=new PipeSecurity();security.SetAccessRuleProtection(true,false);
            foreach(var sid in new[]{owner,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)})security.AddAccessRule(new PipeAccessRule(sid,sid.IsWellKnown(WellKnownSidType.LocalSystemSid)?PipeAccessRights.FullControl:PipeAccessRights.ReadWrite,AccessControlType.Allow));
            var pipe=LocalPipe.Open(ServiceClient.PipeName,security);
            try{await pipe.WaitForConnectionAsync(stoppingToken);}catch{pipe.Dispose();throw;}
            clients.Add(Serve(pipe,owner,coordinator,stoppingToken));
        }}catch(OperationCanceledException){}
        finally{await Task.WhenAll(clients);await watchdog;if(cleanup)PortableCleanup.Schedule();}
    }
    private async Task Serve(NamedPipeServerStream pipe,SecurityIdentifier owner,Coordinator coordinator,CancellationToken stopping)
    {
        using(pipe)using(var deadline=CancellationTokenSource.CreateLinkedTokenSource(stopping)) {
            deadline.CancelAfter(TimeSpan.FromSeconds(90));
            try {
                if(!GetNamedPipeClientProcessId(pipe.SafePipeHandle,out var pid))throw new IOException("Cannot authenticate client PID");
                var request=await ServiceClient.Read(pipe,deadline.Token);
                SecurityIdentifier? client=null;bool admin=false;
                pipe.RunAsClient(()=>{using var identity=WindowsIdentity.GetCurrent();client=identity.User;admin=new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);});
                var command=request["command"]?.GetValue<string>();
                if(client!=owner) {
                    // An elevated installer may only restore/query, never take over a user session.
                    if(!admin||command is not ("restore" or "status" or "shutdown"))throw new UnauthorizedAccessException("Unexpected client identity");
                } else {
                    using var process=Process.GetProcessById((int)pid);
                    var expected=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"..","ChatGPTProxy.App.exe"));
                    var valid=portable!=null?portable.MatchesLauncher(process.MainModule?.FileName):string.Equals(process.MainModule?.FileName,expected,StringComparison.OrdinalIgnoreCase);
                    if(!valid)throw new UnauthorizedAccessException("Unexpected launcher executable");
                }
                var value=await coordinator.Command(request,(int)pid);
                if(portable!=null)value["portableOwnerPid"]=portable.LauncherPid;
                await ServiceClient.Write(pipe,new JsonObject{["ok"]=true,["value"]=value},deadline.Token);
            }catch(Exception e){logger.LogWarning(e,"Control request failed");try{await ServiceClient.Write(pipe,new JsonObject{["ok"]=false,["error"]=e.Message},deadline.Token);}catch{}}
        }
    }
    [LibraryImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientProcessId(SafePipeHandle pipe,out uint pid);
}
