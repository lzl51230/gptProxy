using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using ChatGPTProxy.Core;
namespace ChatGPTProxy.App;
internal sealed partial class MainWindow
{
    private readonly Button monitorToggle=new(){Content="暂停监控"};
    private readonly Button repair=new(){Content="检查并修复 ProxyBridge"};
    private readonly Dictionary<string,TextBlock> checks=new();
    private readonly List<UIElement> mutations=new();
    private readonly TextBlock monitorDetails=new(){TextWrapping=TextWrapping.NoWrap,TextTrimming=TextTrimming.CharacterEllipsis};
    private readonly ProgressBar validation=new(){Minimum=0,Maximum=10,Height=4,Visibility=Visibility.Collapsed};
    private readonly TextBlock[] trayRows=Enumerable.Range(0,7).Select(_=>new TextBlock{Height=22,TextTrimming=TextTrimming.CharacterEllipsis}).ToArray();
    private Window? settingsWindow,setupWindow,trayWindow,logsWindow;
    private bool stickyError,diagnosing,protectionReady;
    private JsonObject regionCounts=new();
    private static TextBlock Label(string text,double size=13)=>new(){Text=text,FontSize=size,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,8)};
    private static Button Action(string title,Action action){var b=new Button{Content=title};b.Click+=(_,_)=>action();return b;}
    private static void Section(Panel panel,string title){if(panel.Children.Count>0)panel.Children.Add(new Separator{Margin=new Thickness(0,14,0,14)});panel.Children.Add(new TextBlock{Text=title,FontWeight=FontWeights.SemiBold,FontSize=14,Margin=new Thickness(0,0,0,10)});}
    private void BuildInterface()
    {
        Title="ChatGPT Proxy";Width=640;Height=780;MinWidth=560;MinHeight=480;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        var root=new StackPanel{Margin=new Thickness(28)};
        var header=new DockPanel{Margin=new Thickness(0,0,0,22)};
        var refresh=Action("↻",async ()=>{stickyError=false;await RefreshDiagnostics();await Poll();});refresh.ToolTip="重新检测";DockPanel.SetDock(refresh,Dock.Right);header.Children.Add(refresh);mutations.Add(refresh);
        var settings=Action("⚙",ShowSettings);settings.ToolTip="设置";DockPanel.SetDock(settings,Dock.Right);header.Children.Add(settings);
        var titles=new StackPanel();titles.Children.Add(Label("◉  ChatGPT Proxy",22));titles.Children.Add(status);header.Children.Add(titles);root.Children.Add(header);
        foreach(var name in new[]{"ChatGPT","ProxyBridge","后台保护组件","专用配置","本地代理","Clash DNS","系统 DNS"}){
            var row=new Grid{Margin=new Thickness(0,0,0,10)};row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(125)});row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(new TextBlock{Text=name,FontWeight=FontWeights.Medium});var detail=Label("○ 尚未检测");detail.Margin=new Thickness(0);detail.SetResourceReference(TextBlock.ForegroundProperty,"Secondary");Grid.SetColumn(detail,1);row.Children.Add(detail);checks[name]=detail;root.Children.Add(row);
        }
        Section(root,"后台监控");monitor.Margin=new Thickness(0,0,0,8);monitor.SetResourceReference(TextBlock.ForegroundProperty,"Text");root.Children.Add(monitor);root.Children.Add(monitorDetails);root.Children.Add(validation);
        monitorToggle.Click+=(_,_)=>ToggleMonitor();mutations.Add(monitorToggle);root.Children.Add(monitorToggle);var note=Label("无凭据检测仅验证网络与连接保持情况");note.SetResourceReference(TextBlock.ForegroundProperty,"Secondary");root.Children.Add(note);
        root.Children.Add(new Separator{Margin=new Thickness(0,12,0,12)});var primary=new WrapPanel();activate.SetResourceReference(Control.BackgroundProperty,"Accent");activate.Foreground=Brushes.White;primary.Children.Add(activate);primary.Children.Add(Action("打开 .codex",()=>{var path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".codex");if(Directory.Exists(path))Process.Start(new ProcessStartInfo(path){UseShellExecute=true});else ShowError("尚未找到 .codex 目录");}));root.Children.Add(primary);
        var secondary=new WrapPanel();secondary.Children.Add(restore);secondary.Children.Add(Action("首次配置",ShowSetup));secondary.Children.Add(Action("查看代理日志",ShowLogs));root.Children.Add(secondary);
        root.Children.Add(CreateUpdatePanel());
        mutations.AddRange(new UIElement[]{activate,restore,repair,port,regions,paused});Content=new ScrollViewer{Content=root,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
    }
    private Window Dialog(string title,object content,double width=480,double height=680)
    {
        var window=new Window{Title=title,Width=width,Height=height,MinWidth=380,MinHeight=300,Content=content,WindowStartupLocation=WindowStartupLocation.CenterScreen};
        if(IsLoaded){window.Owner=this;window.WindowStartupLocation=WindowStartupLocation.CenterOwner;}
        window.SetResourceReference(Control.BackgroundProperty,"Surface");window.SetResourceReference(Control.ForegroundProperty,"Text");return window;
    }
    private void ShowSettings()
    {
        if(settingsWindow!=null){settingsWindow.Activate();return;}
        var body=new StackPanel{Margin=new Thickness(20)};Section(body,"外观");foreach(var i in new[]{0,2,1,3,4}){var choice=new RadioButton{Content=AppTheme.Titles[i],IsChecked=theme.SelectedIndex==i,Margin=new Thickness(0,0,0,8),GroupName="Appearance"};var selected=i;choice.Checked+=(_,_)=>theme.SelectedIndex=selected;body.Children.Add(choice);}body.Children.Add(Label("配色参考 VS Code，立即应用并在下次启动时保留。"));
        Section(body,"启动");startup.Content="开机自启动";body.Children.Add(startup);body.Children.Add(Label("登录 Windows 后驻留托盘，不自动打开主窗口。"));
        Section(body,"Clash 备用地区");body.Children.Add(Label("当前地区优先；备用地区按从上到下的顺序测试，候选长连接保持 10 秒后接受。"));body.Children.Add(regions);body.Children.Add(Action("刷新地区",async ()=>await RefreshRegions()));
        Section(body,"应用更新");body.Children.Add(CreateUpdatePanel());
        Section(body,"代理");body.Children.Add(Label("本地代理端口"));body.Children.Add(port);body.Children.Add(Action("保存并重新检测",async ()=>{try{using var core=new NativeCore();core.Call(new{op="validatePort",value=port.Text});SaveSettings();await RefreshDiagnostics();}catch(Exception e){ShowError(e.Message);}}));
        settingsWindow=Dialog("设置",new ScrollViewer{Content=body,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});settingsWindow.Closed+=(_,_)=>{body.Children.Clear();settingsWindow=null;};settingsWindow.Show();
    }
    private void ShowSetup()
    {
        if(setupWindow!=null){setupWindow.Activate();return;}
        var body=new StackPanel{Margin=new Thickness(24)};body.Children.Add(Label("首次配置",20));body.Children.Add(Label("1  检查并修复 ProxyBridge"));body.Children.Add(repair);body.Children.Add(Label("2  启动 Clash Party 并确认代理端口"));body.Children.Add(Action("检查本地代理",async ()=>await RefreshDiagnostics()));body.Children.Add(Label("3  授权后台保护组件并启动 ChatGPT"));var start=Action("保护并启动 ChatGPT",async ()=>await ActivateProtection());mutations.Add(start);body.Children.Add(start);
        setupWindow=Dialog("首次配置",body,500,400);setupWindow.Closed+=(_,_)=>{body.Children.Clear();mutations.Remove(start);setupWindow=null;};setupWindow.Show();
    }
    private void ShowTrayPanel()
    {
        if(trayWindow!=null){trayWindow.Close();return;}
        var body=new StackPanel{Margin=new Thickness(12)};foreach(var row in trayRows)body.Children.Add(row);body.Children.Add(new Separator());
        body.Children.Add(Action("打开主窗口",()=>{trayWindow?.Close();Show();ActivateWindow();}));body.Children.Add(Action("设置…",()=>{trayWindow?.Close();ShowSettings();}));body.Children.Add(Action(paused.IsChecked==true?"恢复监控":"暂停监控",()=>{trayWindow?.Close();ToggleMonitor();}));body.Children.Add(Action("恢复 DNS 并退出",Exit));
        trayWindow=Dialog("ChatGPT Proxy",body,440,380);trayWindow.ShowInTaskbar=false;trayWindow.ResizeMode=ResizeMode.NoResize;trayWindow.Left=Math.Max(0,SystemParameters.WorkArea.Right-450);trayWindow.Top=Math.Max(0,SystemParameters.WorkArea.Bottom-390);var panel=trayWindow;var closing=false;
        panel.Closing+=(_,_)=>closing=true;
        panel.Deactivated+=(_,_)=>{if(!closing)panel.Close();};
        panel.Closed+=(_,_)=>{body.Children.Clear();if(ReferenceEquals(trayWindow,panel))trayWindow=null;};panel.Show();
    }
    private async void ToggleMonitor(){if(busy)return;paused.IsChecked=paused.IsChecked!=true;await SavePreferences();await Poll();}
    private void UpdateBusy(){foreach(var control in mutations)control.IsEnabled=!busy;activate.IsEnabled=!busy&&!protectionReady;}
    private void ShowError(string message){stickyError=true;status.Text=message;status.ToolTip=message;}
    private void SystemThemeChanged(object sender,UserPreferenceChangedEventArgs e)=>Dispatcher.InvokeAsync(ApplyTheme);
    private void SetCheck(string key,string value){checks[key].Text=value;checks[key].ToolTip=value;}
    private void UpdateStatus(JsonNode? state)
    {
        var active=state?["phase"]?.ToString()=="enabled";var ready=state?["ready"]?.GetValue<bool>()==true;
        SetCheck("后台保护组件",state==null?"○ 启用保护时授权":active?"✓ 已启用":"○ "+(state["detail"]?.ToString()??"未启用"));
        SetCheck("专用配置",state?["bridge"]?["ready"]?.GetValue<bool>()==true?"✓ 已应用":"○ 启用保护时应用");
        SetCheck("Clash DNS",active?"✓ 保护期间已应用加密 DNS":"○ 启用保护时检查并应用");SetCheck("系统 DNS",active?"✓ DNS / IPv4 保护已启用":"○ "+(state?["detail"]?.ToString()??"未启用"));
        protectionReady=ready;activate.Content=ready?"ChatGPT 已通过保护启动":"保护并启动 / 重启 ChatGPT";activate.IsEnabled=!busy&&!ready;
    }
    private void UpdateMonitor(JsonNode? value)
    {
        string Get(string key,string fallback="—")=>value?[key]?.ToString()??fallback;
        string[] rows=[Get("status","等待启动监控"),Get("currentNode","未知节点"),"Codex 心跳："+Get("latency")+" ms","已验证 "+Get("connectionSeconds","0")+" 秒 · 未满 60 秒失败 "+Get("consecutiveFailures","0")+"/2","候选长连接验收："+(Get("phase")=="validating"?Get("connectionSeconds")+"/10 秒":"—"),"上次断线："+Get("disconnectReason","无"),"上次切换："+Get("lastSwitch","尚未切换")];
        monitorToggle.Content=paused.IsChecked==true?"恢复监控":"暂停监控";
        monitor.Text=rows[0];monitorDetails.Text=string.Join("\n",rows.Skip(1));monitorDetails.ToolTip=monitorDetails.Text;validation.Visibility=Get("phase")=="validating"?Visibility.Visible:Visibility.Collapsed;validation.Value=Math.Min(10,value?["connectionSeconds"]?.GetValue<double>()??0);
        for(int i=0;i<rows.Length;i++){trayRows[i].Text=rows[i];trayRows[i].ToolTip=rows[i];}
    }
    private async void ShowLogs()
    {
        if(logsWindow!=null){logsWindow.Activate();return;}
        var text=new TextBox{IsReadOnly=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Margin=new Thickness(16)};
        logsWindow=Dialog("代理日志",text,640,480);logsWindow.Closed+=(_,_)=>logsWindow=null;logsWindow.Show();
        try{text.Text=(await ServiceClient.Call(new JsonObject{["command"]="logs"}))["text"]?.ToString()??"暂无日志";}catch(Exception e){text.Text="无法读取代理日志："+e.Message;}
    }
    private async Task RefreshDiagnostics()
    {
        if(diagnosing)return;diagnosing=true;
        try{
            var result=await DesktopDiagnostics.Check(port.Text);foreach(var pair in result)SetCheck(pair.Key,pair.Value);
        }catch(Exception e){ShowError(e.Message);}finally{diagnosing=false;}
    }
    private async Task RefreshRegions()
    {
        try{var catalog=await DesktopDiagnostics.Regions(port.Text);foreach(var (code,_) in catalog)if(!preferences.Any(p=>p?["code"]?.ToString()==code))preferences.Add(new JsonObject{["code"]=code,["isEnabled"]=false});regionCounts=new JsonObject();foreach(var (code,nodes) in catalog)regionCounts[code]=(nodes as JsonArray)?.Count??0;RebuildRegions();SaveSettings();}catch(Exception e){ShowError(e.Message);}
    }
}
