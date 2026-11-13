using System.Diagnostics;
using System.Text;

namespace ChatGPTProxy.Service;
internal static class PortableCleanup
{
    // A system-owned child waits for this service to exit before removing its locked binaries.
    // Failed restoration keeps both the service and journal available for the next recovery attempt.
    public static void Schedule()
    {
        var executable=Environment.ProcessPath!;
        var cache=Directory.GetParent(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar))!.FullName;
        var state=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"ChatGPT Proxy");
        var portableRoot=Path.Combine(state,"portable")+Path.DirectorySeparatorChar;
        if(!cache.StartsWith(portableRoot,StringComparison.OrdinalIgnoreCase))throw new IOException("Unexpected portable cache directory");
        static string Quote(string value)=>"'"+value.Replace("'","''")+"'";
        var script="$ErrorActionPreference='Stop'; $p=Get-Process -Id "+Environment.ProcessId+" -ErrorAction SilentlyContinue; if($p){$p.WaitForExit()}; "+
            "if(Test-Path "+Quote(Path.Combine(state,"recovery-v1.json"))+"){exit 1}; "+
            "$service=Get-CimInstance Win32_Service -Filter \"Name='ChatGPTProxy'\"; "+
            "if($service -and $service.PathName.Trim('\"') -eq "+Quote(executable)+"){ & sc.exe delete ChatGPTProxy | Out-Null; if($LASTEXITCODE){exit 1} }; "+
            "for($i=0;$i -lt 30;$i++){try{Remove-Item -LiteralPath "+Quote(cache)+" -Recurse -Force; break}catch{Start-Sleep -Milliseconds 500}}";
        Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe")) {
            UseShellExecute=false,CreateNoWindow=true,
            Arguments="-NoProfile -NonInteractive -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(script))
        })?.Dispose();
    }
}
