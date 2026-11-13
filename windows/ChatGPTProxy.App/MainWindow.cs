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
internal sealed partial class MainWindow : Window
{
    private readonly TextBox port=new(){Text="7890",Width=120,Height=32,VerticalContentAlignment=VerticalAlignment.Center};
    private readonly TextBlock status=new(){Text="正在连接本机服务…",TextWrapping=TextWrapping.Wrap,FontSize=15};
    private readonly TextBlock monitor=new(){TextWrapping=TextWrapping.Wrap,Foreground=Brushes.Gray,Margin=new Thickness(0,12,0,16)};
    private readonly Button activate=new(){Content="保护并启动 ChatGPT",Padding=new Thickness(18,8,18,8)};
    private readonly Button restore=new(){Content="关闭保护并恢复 DNS",Padding=new Thickness(18,8,18,8),Margin=new Thickness(8,0,0,0)};
    private readonly CheckBox paused=new(){Content="暂停节点自动切换",Margin=new Thickness(0,16,0,8)};
    private readonly CheckBox startup=new(){Content="登录 Windows 时打开启动器",Margin=new Thickness(0,8,0,8)};
    private readonly StackPanel regions=new();
    private readonly ComboBox theme=new(){Width=280,ItemsSource=AppTheme.Titles,SelectedIndex=0};
    private readonly Forms.NotifyIcon tray=new();
    private readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromSeconds(2)};
    private JsonArray preferences=new();
    private bool busy,exiting,polling;
    private readonly string settingsPath=Program.UiTesting?Path.Combine(Path.GetTempPath(),"ChatGPTProxy-ui-tests",Environment.ProcessId+".json"):PortableRuntime.SettingsPath;
    public MainWindow()
    {
        BuildInterface();
        repair.Click+=async (_,_)=>{if(busy)return;stickyError=false;busy=true;UpdateBusy();try{
            if(!PortableRuntime.IsPortable||await PortableRuntime.HasSession())await ServiceClient.Call(new JsonObject{["command"]="restore"});
            using var core=new NativeCore();var validated=core.Call(new{op="validatePort",value=port.Text}).GetInt32();
            var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")){UseShellExecute=true,Verb="runas",Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(AppContext.BaseDirectory,"install-proxybridge-windows.ps1")+"\" -ProxyPort "+validated};
            using var process=Process.Start(start)??throw new IOException("无法启动组件修复");await process.WaitForExitAsync();
            status.Text=process.ExitCode==0?"ProxyBridge 已安装并校验，可以启用保护":"组件修复失败，请检查 Clash 代理端口";
        }catch(Exception e){ShowError(e.Message);}finally{busy=false;UpdateBusy();}};
        LoadSettings();RebuildRegions();ApplyTheme();
        activate.Click+=async (_,_)=>await ActivateProtection();restore.Click+=async (_,_)=>await Restore();
        paused.Click+=async (_,_)=>await SavePreferences();startup.Click+=(_,_)=>{try{SetStartup();SaveSettings();}catch(Exception e){startup.IsChecked=startup.IsChecked!=true;ShowError(e.Message);}};theme.SelectionChanged+=(_,_)=>{ApplyTheme();SaveSettings();};
        tray.Icon=System.Drawing.SystemIcons.Shield;tray.Text="ChatGPT Proxy";tray.Visible=true;
        var menu=new Forms.ContextMenuStrip();menu.Items.Add("设置…",null,(_,_)=>Dispatcher.Invoke(ShowSettings));menu.Items.Add("暂停 / 恢复监控",null,async (_,_)=>await Dispatcher.InvokeAsync(ToggleMonitor));menu.Items.Add("打开",null,(_,_)=>Dispatcher.Invoke(()=>{Show();ActivateWindow();}));menu.Items.Add("恢复 DNS 并退出",null,async (_,_)=>await Dispatcher.InvokeAsync(Exit));tray.ContextMenuStrip=menu;
        tray.MouseClick+=(_,e)=>{if(e.Button==Forms.MouseButtons.Left)Dispatcher.Invoke(ShowTrayPanel);};
        tray.DoubleClick+=(_,_)=>{Show();ActivateWindow();};Closing+=(_,e)=>{if(!exiting){e.Cancel=true;Hide();}};
        timer.Tick+=async (_,_)=>{UpdateBusy();await Poll();};timer.Start();Loaded+=async (_,_)=>{await RefreshDiagnostics();await Poll();};
        SystemEvents.UserPreferenceChanged+=SystemThemeChanged;Closed+=(_,_)=>SystemEvents.UserPreferenceChanged-=SystemThemeChanged;
    }
    private string RegionLabel(string code){var name=code switch {"JP"=>"日本","US"=>"美国","SG"=>"新加坡","HK"=>"香港","TW"=>"台湾","KR"=>"韩国",_=>code};return name+" · "+(regionCounts[code]?.ToString() is string count?count+" 个节点":"未确认节点");}
    private void ActivateWindow(){WindowState=WindowState.Normal;Activate();}
    private async Task ActivateProtection()
    {
        if(busy)return;stickyError=false;busy=true;UpdateBusy();activate.IsEnabled=false;restore.IsEnabled=false;
        try {
            status.Text="正在准备代理与 DNS 保护…";
            await PortableRuntime.EnsureService();
            await ServiceClient.Call(new JsonObject{["command"]="enable",["port"]=port.Text,["regions"]=preferences.DeepClone()});
            status.Text="等待 ChatGPT 正常退出并重新启动（最多 15 秒）…";
            var process=await ChatGPTLifecycle.Restart();
            await ServiceClient.Call(new JsonObject{["command"]="confirm",["pid"]=process.Id});
            SaveSettings();await SavePreferences();await Poll();
        }catch(Exception e){try{await ServiceClient.Call(new JsonObject{["command"]="restore"});ShowError(e.Message);}catch(Exception recovery){ShowError(e.Message+"；恢复未完成："+recovery.Message);}}
        finally{busy=false;UpdateBusy();}
    }
    private async Task Restore(){if(busy)return;stickyError=false;busy=true;UpdateBusy();try{await ServiceClient.Call(new JsonObject{["command"]="restore"});await Poll();}catch(Exception e){ShowError(e.Message);}finally{busy=false;UpdateBusy();}}
    private async void Exit()
    {
        if(busy)return;
        if(!PortableRuntime.IsPortable||await PortableRuntime.HasSession()) {
            await Restore();
            try {
                var state=await ServiceClient.Call(new JsonObject{["command"]="status"});
                if(state["phase"]?.GetValue<string>()!="disabled"){Show();ActivateWindow();return;}
                await PortableRuntime.Shutdown();
            }catch(Exception e){ShowError(e.Message);Show();return;}
        }
        exiting=true;timer.Stop();tray.Dispose();System.Windows.Application.Current.Shutdown();
    }
    private async Task Poll()
    {
        if(polling)return;polling=true;
        try {
            var state=await ServiceClient.Call(new JsonObject{["command"]="heartbeat"});
            if(PortableRuntime.IsPortable&&state["portableOwnerPid"]?.GetValue<int>()!=Environment.ProcessId){if(!busy&&!stickyError)status.Text="后台组件属于另一启动器会话，请先退出该启动器。";UpdateStatus(null);UpdateMonitor(null);return;}
            if(!busy&&!stickyError)status.Text=state["detail"]?.GetValue<string>()??"";
            if(state["exitRequested"]?.GetValue<bool>()==true&&!busy){exiting=true;timer.Stop();tray.Dispose();System.Windows.Application.Current.Shutdown();return;}
            var ready=state["ready"]?.GetValue<bool>()==true;tray.Text=ready?"ChatGPT Proxy · 保护已启用":"ChatGPT Proxy · 未启用";
            UpdateStatus(state);
            var observation=state["monitor"];
            monitor.Text=observation?["status"]?.GetValue<string>()??"等待启动监控";
            if(observation?["currentNode"]!=null)monitor.Text+="\n节点："+observation["currentNode"]+"    连接："+observation["connectionSeconds"]+" 秒";
            UpdateMonitor(observation);
            if(observation?["candidates"] is JsonObject catalog){bool changed=!JsonNode.DeepEquals(regionCounts,catalog);regionCounts=(JsonObject)catalog.DeepClone();foreach(var (code,_) in catalog)if(!preferences.Any(p=>p?["code"]?.GetValue<string>()==code)){preferences.Add(new JsonObject{["code"]=code,["isEnabled"]=false});changed=true;}if(changed){RebuildRegions();SaveSettings();}}
        }catch(Exception e){if(!busy&&!stickyError){using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\ChatGPTProxy");status.Text=PortableRuntime.IsPortable&&key==null?"保护未启用 · 启用时授权后台恢复组件":"本机服务连接失败："+e.Message;}UpdateStatus(null);UpdateMonitor(null);}
        finally{polling=false;}
    }
    private void RebuildRegions()
    {
        regions.Children.Clear();if(preferences.Count==0)regions.Children.Add(new TextBlock{Text="尚未发现地区，请连接 Clash Party 后刷新。",TextWrapping=TextWrapping.Wrap});for(int index=0;index<preferences.Count;index++) {
            var preference=preferences[index]!;var row=new StackPanel{Orientation=Orientation.Horizontal};var box=new CheckBox{Content=RegionLabel(preference["code"]!.GetValue<string>()),IsChecked=preference["isEnabled"]?.GetValue<bool>(),Width=160,VerticalAlignment=VerticalAlignment.Center};
            box.Click+=async (_,_)=>{preference["isEnabled"]=box.IsChecked==true;await SavePreferences();};row.Children.Add(box);
            foreach(var offset in new[]{-1,1}){var button=new Button{Content=offset<0?"↑":"↓",Width=30,Margin=new Thickness(4)};var position=index;button.IsEnabled=position+offset>=0&&position+offset<preferences.Count;button.Click+=async (_,_)=>{var item=preferences[position]!.DeepClone();preferences.RemoveAt(position);preferences.Insert(position+offset,item);RebuildRegions();await SavePreferences();};row.Children.Add(button);}regions.Children.Add(row);
        }
    }
    private async Task SavePreferences(){SaveSettings();if(PortableRuntime.IsPortable&&!await PortableRuntime.HasSession())return;try{await ServiceClient.Call(new JsonObject{["command"]="preferences",["paused"]=paused.IsChecked==true,["regions"]=preferences.DeepClone()});}catch(Exception e){if(!busy)ShowError(e.Message);}}
    private void LoadSettings(){try{var saved=JsonNode.Parse(File.ReadAllText(settingsPath));port.Text=saved?["port"]?.GetValue<string>()??"7890";paused.IsChecked=saved?["paused"]?.GetValue<bool>()??false;preferences=saved?["regions"]?.DeepClone().AsArray()??new JsonArray();theme.SelectedIndex=AppTheme.ReadIndex(saved);}catch{}using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");startup.IsChecked=key?.GetValue("ChatGPT Proxy")!=null;}
    private void SaveSettings(){try{Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);File.WriteAllText(settingsPath,new JsonObject{["port"]=port.Text,["paused"]=paused.IsChecked==true,["regions"]=preferences.DeepClone(),["theme"]=theme.SelectedIndex,["themeId"]=AppTheme.Ids[theme.SelectedIndex]}.ToJsonString());}catch(Exception e){ShowError(e.Message);}}
    private void SetStartup(){using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(startup.IsChecked==true)key.SetValue("ChatGPT Proxy","\""+Environment.ProcessPath+"\" --background");else key.DeleteValue("ChatGPT Proxy",false);}
    private void ApplyTheme()=>AppTheme.Apply(theme.SelectedIndex);
}
