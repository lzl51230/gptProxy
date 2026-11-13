#if DEBUG
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using ChatGPTProxy.Core;
namespace ChatGPTProxy.App;
// Test transport is compiled out of Release. Installation and protection use production code.
internal static class UpdateQa {
    internal static string? Root => Environment.GetEnvironmentVariable("GPTPROXY_QA_UPDATE_ROOT");
    internal static bool Enabled => Root is { } path && Path.GetFileName(path).StartsWith("gptproxy-qa-",StringComparison.Ordinal) && File.Exists(Path.Combine(path,"case.json"));
    internal static JsonNode Config => JsonNode.Parse(File.ReadAllText(Path.Combine(Root!,"case.json")))!;
    internal static string Text(string key)=>Config[key]?.GetValue<string>()??"";
    internal static string Scenario=>Text("scenario");
    internal sealed class Handler:HttpMessageHandler {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct) {
            ct.ThrowIfCancellationRequested();
            var zip=Text("zip");var name="ChatGPT-Proxy-2.4.0-Windows-x64-Portable.zip";
            var url="https://github.com/lzl51230/gptProxy/releases/download/v2.4.0/"+name;
            HttpResponseMessage response;
            if(request.RequestUri!.AbsoluteUri==AppUpdates.Repository) {
                using var input=File.OpenRead(zip);var digest=Scenario=="corrupt"?new string('0',64):Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
                var release=new JsonObject{["tag_name"]="v2.4.0",["draft"]=false,["prerelease"]=false,["assets"]=new JsonArray(new JsonObject{["name"]=name,["browser_download_url"]=url,["size"]=new FileInfo(zip).Length,["digest"]="sha256:"+digest})};
                response=new(HttpStatusCode.OK){Content=new StringContent(release.ToJsonString(),Encoding.UTF8,"application/json")};
            }else if(request.RequestUri.AbsoluteUri==url){response=new(HttpStatusCode.Found);response.Headers.Location=new Uri("https://release-assets.githubusercontent.com/qa.zip");}
            else if(request.RequestUri.AbsoluteUri=="https://release-assets.githubusercontent.com/qa.zip")response=new(HttpStatusCode.OK){Content=new StreamContent(File.OpenRead(zip))};
            else throw new IOException("Unexpected QA network URL");
            return Task.FromResult(response);
        }
    }
    internal static JsonArray Processes()=>new(Process.GetProcessesByName("ChatGPT").Select(p=>{using(p)return (JsonNode)new JsonObject{["pid"]=p.Id,["start"]=p.StartTime.ToUniversalTime().Ticks};}).OrderBy(p=>p["pid"]!.GetValue<int>()).ToArray());
}
internal sealed partial class MainWindow {
    private Button? qaInstallButton;
    private async Task RunUpdateQa(UpdateTransaction? context,string? transaction) {
        var output=UpdateQa.Root!;Directory.CreateDirectory(output);
        try {
            using var identity=WindowsIdentity.GetCurrent();bool administrator=new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            if(administrator)throw new IOException("QA GUI must run without administrator privileges");
            if(context==null) {
                if(UpdateQa.Scenario=="success-running") {
                    if(UpdateQa.Processes().Count==0)throw new IOException("Open ChatGPT before the running-state case");
                    await PortableRuntime.EnsureService();
                    await ServiceClient.Call(new JsonObject{["command"]="resumeAfterUpdate",["port"]=port.Text,["regions"]=preferences.DeepClone(),["paused"]=paused.IsChecked==true});
                    await WaitForProtectionQa();
                }
                File.WriteAllText(Path.Combine(output,"before.json"),new JsonObject{["processes"]=UpdateQa.Processes(),["settings"]=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(settingsPath))),["protected"]=protectionReady}.ToJsonString());
                await updates.CheckAsync();if(updates.Available==null)throw new IOException(updates.Status);
                Capture((FrameworkElement)Content,output,"before",620,920,1);
                qaInstallButton!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                while(updates.Busy)await Task.Delay(200);
                if(UpdateQa.Scenario is not ("corrupt" or "cancel-authorization")) {
                    // The idle-priority shutdown queued by the production handler runs after this await.
                    await Task.Delay(3000);throw new IOException("Update did not restart: "+updates.Status);
                }
                if(UpdateQa.Scenario=="corrupt"&&!updates.Status.Contains("SHA-256"))throw new IOException("Expected a hash failure: "+updates.Status);
                if(!updates.Status.Contains("失败")&&!updates.Status.Contains("取消"))throw new IOException("Expected update cancellation");
            } else {
                var rollback=UpdateQa.Scenario=="startup-failure";
                if(AppUpdates.CurrentVersion!=(rollback?"2.3.9":"2.4.0"))throw new IOException("Wrong version after restart");
                await Poll();
                if(UpdateQa.Scenario=="success-running") {
                    await WaitForProtectionQa();
                    var state=await ServiceClient.Call(new JsonObject{["command"]="status"});
                    if(state["monitor"]?["phase"]?.GetValue<string>()!="paused")throw new IOException("Paused monitor state was not restored");
                }
            }
            var before=JsonNode.Parse(File.ReadAllText(Path.Combine(output,"before.json")))!;
            if(!JsonNode.DeepEquals(before["processes"],UpdateQa.Processes()))throw new IOException("ChatGPT process identity changed");
            if(before["settings"]!.GetValue<string>()!=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(settingsPath))))throw new IOException("Settings changed");
            Capture((FrameworkElement)Content,output,"after",620,920,1);
            File.WriteAllText(Path.Combine(output,"result.json"),new JsonObject{["success"]=true,["version"]=AppUpdates.CurrentVersion,["administrator"]=administrator,["protected"]=protectionReady,["processes"]=UpdateQa.Processes(),["status"]=updates.Status,["transaction"]=transaction}.ToJsonString());
        } catch(Exception e){File.WriteAllText(Path.Combine(output,"result.json"),new JsonObject{["success"]=false,["error"]=e.ToString()}.ToJsonString());}
        finally {
            // On the old side of a successful update, the application exits while awaiting above.
            if(File.Exists(Path.Combine(output,"result.json"))){await Task.Delay(2000);Exit();}
        }
    }
    private async Task WaitForProtectionQa() {
        // Poll may return immediately while the timer's earlier request is still in flight.
        var deadline=DateTime.UtcNow.AddSeconds(10);
        do {
            await Poll();
            if(protectionReady)return;
            await Task.Delay(100);
        } while(DateTime.UtcNow<deadline);
        throw new IOException("Protection was not restored: "+status.Text);
    }
}
#endif
