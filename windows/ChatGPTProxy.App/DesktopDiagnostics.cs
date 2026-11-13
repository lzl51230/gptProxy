using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using ChatGPTProxy.Core;
namespace ChatGPTProxy.App;
internal static class DesktopDiagnostics
{
    internal static async Task<Dictionary<string,string>> Check(string port)
    {
        var result=new Dictionary<string,string>();
        var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true};
        start.ArgumentList.Add("-NoProfile");start.ArgumentList.Add("-Command");start.ArgumentList.Add("Get-AppxPackage OpenAI.Codex | Select-Object -ExpandProperty PackageFamilyName");
        using var process=Process.Start(start)??throw new IOException("无法检测 ChatGPT");var package=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();result["ChatGPT"]=package.Trim()==ProcessIdentity.ChatGPTFamily?"✓ 已安装":"○ 未找到当前用户的 ChatGPT 应用包";
        result["ProxyBridge"]=await Task.Run(()=>{try{var manifest=JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"proxybridge-files.json")))!.AsObject();foreach(var (name,hash) in manifest){if(Path.GetFileName(name)!=name)throw new IOException("清单无效");using var file=File.OpenRead(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"ProxyBridge",name));if(!Convert.ToHexString(SHA256.HashData(file)).Equals(hash!.ToString(),StringComparison.OrdinalIgnoreCase))return "! 组件需要修复";}return "✓ 已安装并通过校验";}catch{return "! 未安装或需要修复";}});
        result["本地代理"]=await Task.Run(()=>{try{using var core=new NativeCore();var number=core.Call(new{op="validatePort",value=port}).GetInt32();core.Call(new{op="probeUDP",port=number});return "✓ SOCKS UDP 可用 · "+number;}catch(Exception e){return "! "+e.Message;}});return result;
    }
    internal static async Task<JsonObject> Regions(string port)
    {
        using var core=new NativeCore();var number=core.Call(new{op="validatePort",value=port}).GetInt32();
        using var identity=WindowsIdentity.GetCurrent();using var clash=await ClashAdapter.Discover(number,identity.User!.Value,core);var snapshot=await clash.Snapshot();
        return JsonNode.Parse(core.Call(new{op="monitorCandidates",current=snapshot["current"],origins=snapshot["origins"],activeProfileId=snapshot["activeProfileId"],names=snapshot["proxies"]?["GLOBAL"]?["all"],proxies=snapshot["proxies"]}).GetRawText())!.AsObject();
    }
}
