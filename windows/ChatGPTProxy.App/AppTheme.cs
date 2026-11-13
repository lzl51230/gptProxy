using System;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
namespace ChatGPTProxy.App;
internal static class AppTheme
{
    internal static readonly string[] Ids=["system","lightModern","darkModern","monokai","solarizedDark"];
    internal static readonly string[] Titles=["跟随系统","Light Modern · 现代浅色","Dark Modern · 现代深色","Monokai","Solarized Dark · 深色"];
    internal static int ReadIndex(JsonNode? saved)
    {
        var id=saved?["themeId"]?.GetValue<string>();
        if(id!=null){var index=Array.IndexOf(Ids,id);return index<0?0:index;}
        var legacy=saved?["theme"]?.GetValue<int>()??0;return legacy is >=0 and <=2?legacy:0;
    }
    internal static void Apply(int index)
    {
        if(index==0){using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");index=key?.GetValue("AppsUseLightTheme") is int n&&n==0?2:1;}
        var colors=index switch {
            2=>new[]{"#1F1F1F","#CCCCCC","#9D9D9D","#0078D4","#303030"},
            3=>new[]{"#272822","#F8F8F2","#B5B5AB","#75715E","#3E3D32"},
            4=>new[]{"#002B36","#93A1A1","#93A1A1","#268BD2","#073642"},
            _=>new[]{"#FFFFFF","#3B3B3B","#616161","#005FB8","#F3F3F3"}};
        var resources=Application.Current.Resources;
        string[] names=["Surface","Text","Secondary","Accent","ControlSurface"];
        for(int i=0;i<names.Length;i++)resources[names[i]]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
        var window=new Style(typeof(Window));window.Setters.Add(new Setter(Control.BackgroundProperty,resources["Surface"]));window.Setters.Add(new Setter(Control.ForegroundProperty,resources["Text"]));resources[typeof(Window)]=window;
        foreach(var type in new[]{typeof(Button),typeof(TextBox),typeof(ComboBox),typeof(ComboBoxItem),typeof(CheckBox),typeof(RadioButton)}){
            var style=new Style(type);style.Setters.Add(new Setter(Control.ForegroundProperty,resources["Text"]));style.Setters.Add(new Setter(Control.BackgroundProperty,resources["ControlSurface"]));
            if(type==typeof(Button)){style.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty,HorizontalAlignment.Left));style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(10,6,10,6)));style.Setters.Add(new Setter(Control.MarginProperty,new Thickness(0,0,8,6)));}
            resources[type]=style;
        }
        resources[SystemColors.WindowBrushKey]=resources["Surface"];resources[SystemColors.WindowTextBrushKey]=resources["Text"];
        resources[SystemColors.ControlBrushKey]=resources["ControlSurface"];resources[SystemColors.ControlTextBrushKey]=resources["Text"];
        foreach(Window w in Application.Current.Windows){w.SetResourceReference(Control.BackgroundProperty,"Surface");w.SetResourceReference(Control.ForegroundProperty,"Text");}
    }
}
