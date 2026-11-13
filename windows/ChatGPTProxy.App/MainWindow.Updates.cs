using System;
using System.IO;
using System.Threading;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using ChatGPTProxy.Core;

namespace ChatGPTProxy.App;
internal sealed partial class MainWindow
{
    private AppUpdates updates = null!;
    private readonly CancellationTokenSource updateLifetime = new();
    private void InitializeUpdates()
    {
#if DEBUG
        updates = new AppUpdates(() => int.Parse(port.Text), UpdateQa.Enabled ? ()=>new UpdateQa.Handler() : null);
#else
        updates = new AppUpdates(() => int.Parse(port.Text));
#endif
        async void StartUpdates() {
            if(Program.UiTesting)return;
            UpdateTransaction? context;string? transaction;
            try {context=UpdateInstaller.RestartContext(out transaction);}
            catch(Exception e){ShowError("更新恢复记录无效："+e.Message);return;}
            if(context!=null) {
                updates.ReportRestart(File.Exists(transaction+".phase")&&File.ReadAllText(transaction+".phase")=="rolled-back");
                File.WriteAllText(transaction+".healthy","");
                if(context.Running) {
                    try {await PortableRuntime.EnsureService();await ServiceClient.Call(new JsonObject{["command"]="resumeAfterUpdate",["port"]=port.Text,["regions"]=preferences.DeepClone(),["paused"]=paused.IsChecked==true});await Poll();}
                    catch(Exception e){ShowError("更新完成，保护恢复待处理："+e.Message);}
                }
            }
#if DEBUG
            if(UpdateQa.Enabled){await RunUpdateQa(context,transaction);return;}
#endif
            await updates.RecoverPendingAsync(()=>protectionReady,PrepareUpdateExit);
            _=updates.RunAsync(updateLifetime.Token);
        }
        if(!Program.UiTesting)_ = Dispatcher.BeginInvoke(new Action(StartUpdates));
        Closed += (_,_)=>{updateLifetime.Cancel();updates.Dispose();};
        port.TextChanged += (_,_)=>updates.Cancel();
    }
    private async System.Threading.Tasks.Task PrepareUpdateExit()
    {
                if(!PortableRuntime.IsPortable)throw new IOException("请先迁移至便携版");
                if(await PortableRuntime.HasSession()) {
                    await ServiceClient.Call(new JsonObject{["command"]="restore"});
                    var state=await ServiceClient.Call(new JsonObject{["command"]="status"});
                    if(state["phase"]?.GetValue<string>()!="disabled")throw new IOException("DNS 恢复未完成，已停止更新");
                    await PortableRuntime.Shutdown();
                }
                _ = Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{exiting=true;timer.Stop();tray.Dispose();System.Windows.Application.Current.Shutdown();}));
    }
    private StackPanel CreateUpdatePanel()
    {
        var panel=new StackPanel();var label=new TextBlock{TextWrapping=TextWrapping.Wrap};
        var check=new Button{Content="检查更新"};var install=new Button{Content="更新并重启"};var cancel=new Button{Content="取消下载"};
        void Refresh(){label.Text="版本 "+AppUpdates.CurrentVersion+" · "+updates.Status;check.IsEnabled=!updates.Busy;install.Visibility=updates.Available==null?Visibility.Collapsed:Visibility.Visible;install.IsEnabled=!busy&&!updates.Busy;cancel.Visibility=updates.Busy&&!updates.Installing?Visibility.Visible:Visibility.Collapsed;}
#if DEBUG
        if(UpdateQa.Enabled)qaInstallButton ??= install;
#endif
        panel.Children.Add(label);panel.Children.Add(check);panel.Children.Add(install);panel.Children.Add(cancel);
        check.Click+=async (_,_)=>await updates.CheckAsync();cancel.Click+=(_,_)=>updates.Cancel();
        install.Click+=async (_,_)=>{
            if(busy)return;
            bool running=protectionReady;busy=true;UpdateBusy();
            try {await updates.InstallAsync(()=>running,async ()=>{
                await PrepareUpdateExit();
            });}finally{busy=false;UpdateBusy();}
        };
        panel.Loaded+=(_,_)=>{updates.Changed+=Refresh;Refresh();};panel.Unloaded+=(_,_)=>updates.Changed-=Refresh;
        var notes=new Button{Content="发布说明"};notes.Click+=(_,_)=>System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://github.com/lzl51230/gptProxy/releases/latest"){UseShellExecute=true});panel.Children.Add(notes);
        return panel;
    }
}
