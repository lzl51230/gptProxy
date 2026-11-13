using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace ChatGPTProxy.App;
internal sealed partial class MainWindow
{
    internal void VerifyVisuals(string directory)
    {
        timer.Stop();Directory.CreateDirectory(directory);
        for(int legacy=0;legacy<3;legacy++)if(AppTheme.ReadIndex(new JsonObject{["theme"]=legacy})!=legacy)throw new InvalidOperationException("Legacy theme migration failed");
        if(AppTheme.ReadIndex(new JsonObject{["themeId"]="monokai",["theme"]=1})!=3)throw new InvalidOperationException("Stable theme ID must take precedence");
        if(AppTheme.ReadIndex(new JsonObject{["themeId"]="unknown"})!=0)throw new InvalidOperationException("Unknown theme fallback failed");
        var sample=new JsonObject{["status"]="Codex 长连接正常",["currentNode"]=string.Concat(Enumerable.Repeat("日本东京 · 流媒体节点 / ",20)),["latency"]=127,["connectionSeconds"]=8.0,["consecutiveFailures"]=1,["phase"]="validating",["disconnectReason"]="网络连接中断，正在验证备用候选",["lastSwitch"]="香港 → 日本"};
        foreach(var index in Enumerable.Range(0,5)){
            theme.SelectedIndex=index;ApplyTheme();UpdateMonitor(null);Capture((FrameworkElement)Content,directory,$"{AppTheme.Ids[index]}-idle",620,740,1);
            UpdateMonitor(sample);Capture((FrameworkElement)Content,directory,$"{AppTheme.Ids[index]}-monitor",620,740,1);
            ShowSettings();Capture((FrameworkElement)settingsWindow!.Content,directory,$"{AppTheme.Ids[index]}-settings",480,680,1);settingsWindow.Close();
            ShowSetup();Capture((FrameworkElement)setupWindow!.Content,directory,$"{AppTheme.Ids[index]}-setup",500,400,1);setupWindow.Close();
            ShowTrayPanel();var panel=(FrameworkElement)trayWindow!.Content;Capture(panel,directory,$"{AppTheme.Ids[index]}-tray",440,380,1);
            var buttons=((Panel)panel).Children.OfType<Button>().ToArray();var before=buttons.Select(b=>b.TranslatePoint(new Point(),panel)).ToArray();UpdateMonitor(null);panel.UpdateLayout();if(!before.SequenceEqual(buttons.Select(b=>b.TranslatePoint(new Point(),panel))))throw new InvalidOperationException("Tray actions moved after status update");trayWindow.Close();
        }
        theme.SelectedIndex=2;UpdateMonitor(sample);foreach(var scale in new[]{1.5,2.0})Capture((FrameworkElement)Content,directory,$"darkModern-scale-{scale}",560,480,scale);
        busy=true;UpdateBusy();if(activate.IsEnabled||restore.IsEnabled||port.IsEnabled)throw new InvalidOperationException("Conflicting controls remain enabled");
        busy=false;UpdateBusy();File.WriteAllText(Path.Combine(directory,"result.txt"),"PASS: theme migration, 5 themes × 5 surfaces/states, 150%/200% render, tray layout stability, busy controls");tray.Dispose();File.Delete(settingsPath);
    }
    private static void Capture(FrameworkElement content,string directory,string name,double width,double height,double scale)
    {
        content.Measure(new Size(width,height));content.Arrange(new Rect(0,0,width,height));content.UpdateLayout();
        var image=new RenderTargetBitmap((int)(width*scale),(int)(height*scale),96*scale,96*scale,PixelFormats.Pbgra32);var backdrop=new DrawingVisual();using(var drawing=backdrop.RenderOpen()){drawing.DrawRectangle((Brush)Application.Current.Resources["Surface"],null,new Rect(0,0,width,height));}image.Render(backdrop);image.Render(content);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(image));using var file=File.Create(Path.Combine(directory,name+".png"));png.Save(file);
    }
}
