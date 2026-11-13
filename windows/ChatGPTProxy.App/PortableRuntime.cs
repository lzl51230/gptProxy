using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using ChatGPTProxy.Core;

namespace ChatGPTProxy.App;
internal static class PortableRuntime
{
    public static bool IsPortable => File.Exists(Path.Combine(AppContext.BaseDirectory,"portable.json"));
    public static string SettingsPath => Path.Combine(IsPortable ? Path.Combine(AppContext.BaseDirectory,"Data") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ChatGPT Proxy"),"settings.json");
    public static async Task<bool> HasSession()
    {
        try {var status=await ServiceClient.Call(new JsonObject{["command"]="status"});return status["portableOwnerPid"]?.GetValue<int>()==Environment.ProcessId;}
        catch{return false;}
    }
    public static async Task EnsureService()
    {
        if(!IsPortable)return;
        if(await HasSession())return;
        static string Quote(string value)=>"'"+value.Replace("'","''")+"'";
        var command="& "+Quote(Path.Combine(AppContext.BaseDirectory,"start-portable-windows.ps1"))+" -LauncherPid "+Environment.ProcessId+" -LauncherStartTicks "+Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks+" -Source "+Quote(AppContext.BaseDirectory);
        var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")) {
            UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden,
            Arguments="-NoProfile -ExecutionPolicy Bypass -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(command))
        };
        using var process=Process.Start(start)??throw new IOException("无法启动便携保护组件");
        await process.WaitForExitAsync();
        if(process.ExitCode!=0)throw new IOException("便携保护组件启动失败，原恢复记录已保留");
        for(int attempt=0;attempt<30;attempt++) {
            try {var status=await ServiceClient.Call(new JsonObject{["command"]="status"});if(status["portableOwnerPid"]?.GetValue<int>()==Environment.ProcessId)return;}catch{}
            await Task.Delay(500);
        }
        throw new IOException("便携保护组件未就绪，请重试");
    }
    public static async Task Shutdown()
    {
        if(!IsPortable||!await HasSession())return;
        try {await ServiceClient.Call(new JsonObject{["command"]="shutdown"});}
        catch when(!ServiceIdentityAvailable()){}
    }
    private static bool ServiceIdentityAvailable()
    {
        using var key=Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\ChatGPTProxy");
        return key!=null;
    }
}
