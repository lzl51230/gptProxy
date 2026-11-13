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
    [STAThread] public static int Main(string[] args)
    {
        if(args.Length>0){try{return Command(args).GetAwaiter().GetResult();}catch(Exception e){Console.Error.WriteLine(e.ToString());return 1;}}
        using var mutex=new Mutex(true,"Local\\ChatGPTProxy.Launcher",out var first);if(!first)return 0;
        var app=new System.Windows.Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
        var window=new MainWindow();app.Run(window);return 0;
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
internal sealed class MainWindow : Window
{
    private readonly TextBox port=new(){Text="7890",Width=120,Height=32,VerticalContentAlignment=VerticalAlignment.Center};
    private readonly TextBlock status=new(){Text="正在连接本机服务…",TextWrapping=TextWrapping.Wrap,FontSize=15};
    private readonly TextBlock monitor=new(){TextWrapping=TextWrapping.Wrap,Foreground=Brushes.Gray,Margin=new Thickness(0,12,0,16)};
    private readonly Button activate=new(){Content="保护并启动 ChatGPT",Padding=new Thickness(18,8,18,8)};
    private readonly Button restore=new(){Content="关闭保护并恢复 DNS",Padding=new Thickness(18,8,18,8),Margin=new Thickness(8,0,0,0)};
    private readonly CheckBox paused=new(){Content="暂停节点自动切换",Margin=new Thickness(0,16,0,8)};
    private readonly CheckBox startup=new(){Content="登录 Windows 时打开启动器",Margin=new Thickness(0,8,0,8)};
    private readonly StackPanel regions=new();
    private readonly ComboBox theme=new(){Width=130,ItemsSource=new[]{"跟随系统","浅色","深色"},SelectedIndex=0};
    private readonly Forms.NotifyIcon tray=new();
    private readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromSeconds(2)};
    private JsonArray preferences=new();
    private bool busy,exiting,polling;
    private readonly string settingsPath=PortableRuntime.SettingsPath;
    public MainWindow()
    {
        Title="ChatGPT Proxy";Width=620;Height=640;MinWidth=560;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        var root=new StackPanel{Margin=new Thickness(28)};
        root.Children.Add(new TextBlock{Text="ChatGPT Proxy",FontSize=28,FontWeight=FontWeights.SemiBold});
        root.Children.Add(new TextBlock{Text="Clash Party · 独立代理 · DNS 保护",Margin=new Thickness(0,6,0,24),Foreground=Brushes.Gray});
        var row=new StackPanel{Orientation=Orientation.Horizontal};row.Children.Add(new TextBlock{Text="本地代理端口",VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,12,0)});row.Children.Add(port);root.Children.Add(row);
        var state=new Border{Padding=new Thickness(16),Margin=new Thickness(0,20,0,16),BorderThickness=new Thickness(1),BorderBrush=Brushes.LightGray,CornerRadius=new CornerRadius(8),Child=status};root.Children.Add(state);
        var actions=new StackPanel{Orientation=Orientation.Horizontal};actions.Children.Add(activate);actions.Children.Add(restore);root.Children.Add(actions);
        var repair=new Button{Content="安装或修复 ProxyBridge",HorizontalAlignment=HorizontalAlignment.Left,Padding=new Thickness(12,6,12,6),Margin=new Thickness(0,10,0,0)};
        repair.Click+=async (_,_)=>{if(busy)return;busy=true;try{
            if(!PortableRuntime.IsPortable||await PortableRuntime.HasSession())await ServiceClient.Call(new JsonObject{["command"]="restore"});
            using var core=new NativeCore();var validated=core.Call(new{op="validatePort",value=port.Text}).GetInt32();
            var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")){UseShellExecute=true,Verb="runas",Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(AppContext.BaseDirectory,"install-proxybridge-windows.ps1")+"\" -ProxyPort "+validated};
            using var process=Process.Start(start)??throw new IOException("无法启动组件修复");await process.WaitForExitAsync();
            status.Text=process.ExitCode==0?"ProxyBridge 已安装并校验，可以启用保护":"组件修复失败，请检查 Clash 代理端口";
        }catch(Exception e){status.Text=e.Message;}finally{busy=false;}};root.Children.Add(repair);
        root.Children.Add(monitor);root.Children.Add(paused);
        root.Children.Add(new TextBlock{Text="允许故障切换的地区（勾选并按优先级排序）",Margin=new Thickness(0,12,0,8)});root.Children.Add(regions);root.Children.Add(startup);
        var themes=new StackPanel{Orientation=Orientation.Horizontal};themes.Children.Add(new TextBlock{Text="外观",VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,12,0)});themes.Children.Add(theme);root.Children.Add(themes);
        Content=new ScrollViewer{Content=root,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        LoadSettings();RebuildRegions();ApplyTheme();
        activate.Click+=async (_,_)=>await ActivateProtection();restore.Click+=async (_,_)=>await Restore();
        paused.Click+=async (_,_)=>await SavePreferences();startup.Click+=(_,_)=>{SetStartup();SaveSettings();};theme.SelectionChanged+=(_,_)=>{ApplyTheme();SaveSettings();};
        tray.Icon=System.Drawing.SystemIcons.Shield;tray.Text="ChatGPT Proxy";tray.Visible=true;
        var menu=new Forms.ContextMenuStrip();menu.Items.Add("打开",null,(_,_)=>Dispatcher.Invoke(()=>{Show();ActivateWindow();}));menu.Items.Add("恢复 DNS 并退出",null,async (_,_)=>await Dispatcher.InvokeAsync(Exit));tray.ContextMenuStrip=menu;
        tray.DoubleClick+=(_,_)=>{Show();ActivateWindow();};Closing+=(_,e)=>{if(!exiting){e.Cancel=true;Hide();}};
        timer.Tick+=async (_,_)=>await Poll();timer.Start();Loaded+=async (_,_)=>await Poll();
    }
    private void ActivateWindow(){WindowState=WindowState.Normal;Activate();}
    private async Task ActivateProtection()
    {
        if(busy)return;busy=true;activate.IsEnabled=false;restore.IsEnabled=false;
        try {
            status.Text="正在准备代理与 DNS 保护…";
            await PortableRuntime.EnsureService();
            await ServiceClient.Call(new JsonObject{["command"]="enable",["port"]=port.Text,["regions"]=preferences.DeepClone()});
            status.Text="等待 ChatGPT 正常退出并重新启动（最多 15 秒）…";
            var process=await ChatGPTLifecycle.Restart();
            await ServiceClient.Call(new JsonObject{["command"]="confirm",["pid"]=process.Id});
            SaveSettings();await SavePreferences();await Poll();
        }catch(Exception e){try{await ServiceClient.Call(new JsonObject{["command"]="restore"});}catch{}status.Text=e.Message;}
        finally{busy=false;activate.IsEnabled=true;restore.IsEnabled=true;}
    }
    private async Task Restore(){if(busy)return;busy=true;try{await ServiceClient.Call(new JsonObject{["command"]="restore"});await Poll();}catch(Exception e){status.Text=e.Message;}finally{busy=false;}}
    private async void Exit()
    {
        if(busy)return;
        if(!PortableRuntime.IsPortable||await PortableRuntime.HasSession()) {
            await Restore();
            try {
                var state=await ServiceClient.Call(new JsonObject{["command"]="status"});
                if(state["phase"]?.GetValue<string>()!="disabled")return;
                await PortableRuntime.Shutdown();
            }catch(Exception e){status.Text=e.Message;Show();return;}
        }
        exiting=true;timer.Stop();tray.Dispose();System.Windows.Application.Current.Shutdown();
    }
    private async Task Poll()
    {
        if(polling)return;polling=true;
        try {
            var state=await ServiceClient.Call(new JsonObject{["command"]="heartbeat"});
            if(PortableRuntime.IsPortable&&state["portableOwnerPid"]?.GetValue<int>()!=Environment.ProcessId){if(!busy)status.Text="便携模式：点击「保护并启动 ChatGPT」，授权临时后台恢复组件。";return;}
            if(!busy)status.Text=state["detail"]?.GetValue<string>()??"";
            if(state["exitRequested"]?.GetValue<bool>()==true&&!busy){exiting=true;timer.Stop();tray.Dispose();System.Windows.Application.Current.Shutdown();return;}
            var ready=state["ready"]?.GetValue<bool>()==true;tray.Text=ready?"ChatGPT Proxy · 保护已启用":"ChatGPT Proxy · 未启用";
            var observation=state["monitor"];
            monitor.Text=observation?["status"]?.GetValue<string>()??"等待启动监控";
            if(observation?["currentNode"]!=null)monitor.Text+="\n节点："+observation["currentNode"]+"    连接："+observation["connectionSeconds"]+" 秒";
            if(observation?["candidates"] is JsonObject catalog){bool changed=false;foreach(var (code,_) in catalog)if(!preferences.Any(p=>p?["code"]?.GetValue<string>()==code)){preferences.Add(new JsonObject{["code"]=code,["isEnabled"]=false});changed=true;}if(changed){RebuildRegions();SaveSettings();}}
        }catch(Exception e){if(!busy)status.Text=PortableRuntime.IsPortable?"便携模式：点击「保护并启动 ChatGPT」，授权临时后台恢复组件。":"本机服务不可用："+e.Message;}
        finally{polling=false;}
    }
    private void RebuildRegions()
    {
        regions.Children.Clear();for(int index=0;index<preferences.Count;index++) {
            var preference=preferences[index]!;var row=new StackPanel{Orientation=Orientation.Horizontal};var box=new CheckBox{Content=preference["code"]!.GetValue<string>(),IsChecked=preference["isEnabled"]?.GetValue<bool>(),Width=160,VerticalAlignment=VerticalAlignment.Center};
            box.Click+=async (_,_)=>{preference["isEnabled"]=box.IsChecked==true;await SavePreferences();};row.Children.Add(box);
            foreach(var offset in new[]{-1,1}){var button=new Button{Content=offset<0?"↑":"↓",Width=30,Margin=new Thickness(4)};var position=index;button.IsEnabled=position+offset>=0&&position+offset<preferences.Count;button.Click+=async (_,_)=>{var item=preferences[position]!.DeepClone();preferences.RemoveAt(position);preferences.Insert(position+offset,item);RebuildRegions();await SavePreferences();};row.Children.Add(button);}regions.Children.Add(row);
        }
    }
    private async Task SavePreferences(){SaveSettings();try{await ServiceClient.Call(new JsonObject{["command"]="preferences",["paused"]=paused.IsChecked==true,["regions"]=preferences.DeepClone()});}catch(Exception e){if(!busy)status.Text=e.Message;}}
    private void LoadSettings(){try{var saved=JsonNode.Parse(File.ReadAllText(settingsPath));port.Text=saved?["port"]?.GetValue<string>()??"7890";paused.IsChecked=saved?["paused"]?.GetValue<bool>()??false;preferences=saved?["regions"]?.DeepClone().AsArray()??new JsonArray();theme.SelectedIndex=saved?["theme"]?.GetValue<int>()??0;}catch{}using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");startup.IsChecked=key?.GetValue("ChatGPT Proxy")!=null;}
    private void SaveSettings(){try{Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);File.WriteAllText(settingsPath,new JsonObject{["port"]=port.Text,["paused"]=paused.IsChecked==true,["regions"]=preferences.DeepClone(),["theme"]=theme.SelectedIndex}.ToJsonString());}catch(Exception e){status.Text=e.Message;}}
    private void SetStartup(){using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(startup.IsChecked==true)key.SetValue("ChatGPT Proxy","\""+Environment.ProcessPath+"\"");else key.DeleteValue("ChatGPT Proxy",false);}
    private void ApplyTheme(){bool dark=theme.SelectedIndex==2;if(theme.SelectedIndex==0){using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");dark=key?.GetValue("AppsUseLightTheme") is int light&&light==0;}Background=dark?new SolidColorBrush(Color.FromRgb(30,32,36)):Brushes.White;Foreground=dark?Brushes.WhiteSmoke:Brushes.Black;
        Resources[SystemColors.WindowBrushKey]=Background;Resources[SystemColors.WindowTextBrushKey]=Foreground;
        Resources[SystemColors.ControlBrushKey]=dark?new SolidColorBrush(Color.FromRgb(48,51,57)):Brushes.WhiteSmoke;
        Resources[SystemColors.ControlTextBrushKey]=Foreground;
        var controlStyle=new Style(typeof(Control));controlStyle.Setters.Add(new Setter(Control.ForegroundProperty,Foreground));controlStyle.Setters.Add(new Setter(Control.BackgroundProperty,Resources[SystemColors.ControlBrushKey]));
        foreach(var type in new[]{typeof(Button),typeof(TextBox)})Resources[type]=new Style(type,controlStyle);
        theme.Foreground=Brushes.Black;theme.Background=Brushes.White;
        var itemStyle=new Style(typeof(ComboBoxItem));itemStyle.Setters.Add(new Setter(Control.ForegroundProperty,Brushes.Black));itemStyle.Setters.Add(new Setter(Control.BackgroundProperty,Brushes.White));Resources[typeof(ComboBoxItem)]=itemStyle;
        monitor.Foreground=dark?Brushes.LightGray:Brushes.DimGray;}
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
