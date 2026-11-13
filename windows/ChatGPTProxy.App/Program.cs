using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using ChatGPTProxy.Core;
using Microsoft.Win32;
using Forms=System.Windows.Forms;

namespace ChatGPTProxy.App;
internal static class Program
{
    internal static bool UiTesting;
    [STAThread] public static int Main(string[] args)
    {
#if DEBUG
        if(UpdateQa.Enabled && UpdateQa.Text("scenario")=="startup-failure" && AppUpdates.CurrentVersion=="2.4.0")return 19;
#endif
        if(args.Length==2&&args[0]=="--qa-ui"){UiTesting=true;var qaApp=new System.Windows.Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};try{var qaWindow=new MainWindow();qaWindow.VerifyVisuals(args[1]);qaApp.Shutdown();return 0;}catch(Exception e){Directory.CreateDirectory(args[1]);File.WriteAllText(Path.Combine(args[1],"error.txt"),e.ToString());qaApp.Shutdown();return 1;}}
        if(args.Length>0&&args[0]!="--background"&&args[0]!="--update-restart"){try{return Command(args).GetAwaiter().GetResult();}catch(Exception e){Console.Error.WriteLine(e.ToString());return 1;}}
        using var mutex=new Mutex(true,"Local\\ChatGPTProxy.Launcher",out var first);if(!first)return 0;
        var app=new System.Windows.Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
        var window=new MainWindow();if(args.Contains("--background")){app.MainWindow=window;app.Run();}else app.Run(window);return 0;
    }
    private static async Task<int> Command(string[] args)
    {
        if(args[0] is "--qa-smoke" or "--qa-protection-hold") {
            await PortableRuntime.EnsureService();
            using var cancellation=new CancellationTokenSource();
            var pulse=Task.Run(async ()=>{while(!cancellation.IsCancellationRequested){try{await ServiceClient.Call(new JsonObject{["command"]="heartbeat"});await Task.Delay(2000,cancellation.Token);}catch(OperationCanceledException){break;}catch{await Task.Delay(500);}}});
            var evidence=new JsonObject();
            try {
                var prepared=await ServiceClient.Call(new JsonObject{["command"]="enable",["port"]="7890"});
                evidence["prepared"]=prepared.DeepClone();
                if(args[0]=="--qa-protection-hold"){Console.WriteLine(evidence.ToJsonString());await Task.Delay(TimeSpan.FromMinutes(2));return 0;}
                if(prepared["ready"]?.GetValue<bool>()==true)throw new IOException("Protection claimed ready before ChatGPT restart");
                using var gpt=await ChatGPTLifecycle.Restart();
                evidence["confirmed"]=await ServiceClient.Call(new JsonObject{["command"]="confirm",["pid"]=gpt.Id});
                await Task.Delay(TimeSpan.FromSeconds(20));
                var live=await ServiceClient.Call(new JsonObject{["command"]="status"});evidence["live"]=live;
                Console.WriteLine(evidence.ToJsonString());
                if(live["ready"]?.GetValue<bool>()!=true||live["monitor"]?["phase"]?.GetValue<string>()!="maintaining")throw new IOException("Live protection or Codex observation failed");
                evidence["restored"]=await ServiceClient.Call(new JsonObject{["command"]="restore"});
                Console.WriteLine(evidence.ToJsonString());return 0;
            } finally {try{await ServiceClient.Call(new JsonObject{["command"]="restore"});}finally{cancellation.Cancel();await pulse;await PortableRuntime.Shutdown();}}
        }
        var command=args[0] switch {"--restore"=>"restore","--status"=>"status","--shutdown"=>"shutdown",_=>throw new ArgumentException("Unsupported command")};
        Console.WriteLine((await ServiceClient.Call(new JsonObject{["command"]=command})).ToJsonString());
        if(command=="shutdown") {
            var deadline=Stopwatch.StartNew();
            while(Process.GetProcessesByName("ChatGPTProxy.App").Any(p=>p.Id!=Environment.ProcessId)) {
                if(deadline.Elapsed>TimeSpan.FromSeconds(15))throw new IOException("启动器尚未退出，升级已停止");
                await Task.Delay(200);
            }
        }
        return 0;
    }
}
internal static class ChatGPTLifecycle
{
    public static async Task<Process> Restart()
    {
        var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8};
        start.ArgumentList.Add("-NoProfile");start.ArgumentList.Add("-Command");start.ArgumentList.Add("[Console]::OutputEncoding=[Text.Encoding]::UTF8;Get-AppxPackage OpenAI.Codex | Select-Object InstallLocation,PackageFamilyName,PackageFullName | ConvertTo-Json -Compress");
        using var discovery=Process.Start(start)??throw new IOException("无法查找 ChatGPT");var package=JsonNode.Parse(await discovery.StandardOutput.ReadToEndAsync())??throw new IOException("未找到 ChatGPT 应用包");var location=package["InstallLocation"]!.GetValue<string>();await discovery.WaitForExitAsync();
        if(discovery.ExitCode!=0||package["PackageFamilyName"]?.GetValue<string>()!=ProcessIdentity.ChatGPTFamily||!Directory.Exists(location)||!Path.GetFileName(location).StartsWith("OpenAI.Codex_",StringComparison.Ordinal))throw new IOException("当前用户尚未安装 ChatGPT 桌面版");
        var paths=Directory.GetFiles(location,"ChatGPT.exe",SearchOption.AllDirectories);if(paths.Length!=1)throw new IOException("ChatGPT 安装身份不明确");
        var running=Process.GetProcessesByName("ChatGPT").Where(p=>{try{return p.MainModule?.FileName?.StartsWith(location+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)==true;}catch{return false;}}).ToArray();
        if(running.Length>0) {
            var window=running.FirstOrDefault(p=>p.MainWindowHandle!=nint.Zero)?.MainWindowHandle??nint.Zero;
            if(window==nint.Zero) {
                var existingManifest=System.Xml.Linq.XDocument.Load(Path.Combine(location,"AppxManifest.xml"));
                var existingApp=existingManifest.Descendants().Single(e=>e.Name.LocalName=="Application"&&(e.Attribute("Executable")?.Value.EndsWith("ChatGPT.exe",StringComparison.OrdinalIgnoreCase)??false));
                using var existing=PackageActivation.Launch(package["PackageFamilyName"]!.GetValue<string>()+"!"+existingApp.Attribute("Id")!.Value,package["PackageFullName"]!.GetValue<string>());
                for(int attempt=0;attempt<20&&window==nint.Zero;attempt++){await Task.Delay(100);existing.Refresh();window=existing.MainWindowHandle;}
            }
            await ChatGPTQuit.Request(window);
        }
        var until=Stopwatch.StartNew();while(running.Any(p=>!p.HasExited)&&until.Elapsed<TimeSpan.FromSeconds(15))await Task.Delay(100);
        if(running.Any(p=>!p.HasExited))throw new IOException("ChatGPT 尚未正常退出，请保存任务并退出后重试；DNS 已恢复");
        foreach(var process in running)process.Dispose();
        var manifest=System.Xml.Linq.XDocument.Load(Path.Combine(location,"AppxManifest.xml"));
        var application=manifest.Descendants().Single(e=>e.Name.LocalName=="Application"&&(e.Attribute("Executable")?.Value.EndsWith("ChatGPT.exe",StringComparison.OrdinalIgnoreCase)??false));
        var appId=package["PackageFamilyName"]!.GetValue<string>()+"!"+application.Attribute("Id")!.Value;
        var child=PackageActivation.Launch(appId,package["PackageFullName"]!.GetValue<string>());
        await Task.Delay(1000);if(child.HasExited)throw new IOException("ChatGPT 启动后提前退出");return child;
    }
}
