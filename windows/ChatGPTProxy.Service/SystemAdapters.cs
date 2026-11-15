using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace ChatGPTProxy.Service;

internal static class SystemAdapters
{
    public static async Task<string> PowerShell(string script)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe")) {
            UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true,
            StandardOutputEncoding=Encoding.UTF8, StandardErrorEncoding=Encoding.UTF8 };
        start.ArgumentList.Add("-NoProfile"); start.ArgumentList.Add("-NonInteractive"); start.ArgumentList.Add("-OutputFormat"); start.ArgumentList.Add("Text"); start.ArgumentList.Add("-EncodedCommand");
        start.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.Encoding]::UTF8;"+script)));
        using var process=Process.Start(start) ?? throw new IOException("Cannot start system adapter");
        var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(20));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch {process.Kill(true);await process.WaitForExitAsync();throw;}
        var text=await output;var diagnostic=await error;
        if(process.ExitCode!=0)throw new IOException(diagnostic[..Math.Min(diagnostic.Length,1500)]);
        if(text.Length>4*1024*1024)throw new IOException("System adapter response too large");
        return text;
    }
    public static async Task RestoreLegacyDns(JsonArray adapters)
    {
        foreach(var adapter in adapters) {
            var id=Guid.Parse(adapter!["id"]!.GetValue<string>()).ToString("B");
            // Re-resolve by GUID: interface indices can change across reboot and hotplug.
            var script="$a=Get-NetAdapter -IncludeHidden | Where-Object {[guid]$_.InterfaceGuid -eq [guid]'"+id+"'};if($a){";
            foreach(var (family,af,loopback) in new[]{("Tcpip","IPv4","127.0.0.1"),("Tcpip6","IPv6","::1")}) {
                using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+family+@"\Parameters\Interfaces\"+id);
                var current=key?.GetValue("NameServer")?.ToString() ?? "";
                if(current!=loopback)continue; // Preserve explicit changes made after activation.
                var saved=adapter[family]?.GetValue<string>() ?? "";
                var servers=saved.Split(new[]{',',';',' '},StringSplitOptions.RemoveEmptyEntries);
                if(servers.Any(s=>!System.Net.IPAddress.TryParse(s,out _)))throw new IOException("Invalid saved DNS address");
                script+="$d=Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily "+af+";";
                script+=servers.Length==0?"$d | Set-DnsClientServerAddress -ResetServerAddresses;":"$d | Set-DnsClientServerAddress -ServerAddresses @("+string.Join(",",servers.Select(s=>"'"+s+"'"))+");";
            }
            await PowerShell(script+"}else{throw 'Saved network adapter is unavailable; recovery journal retained'}");
        }
    }
    private static readonly string domainPolicyScript = ReadPolicyScript();

    private static string ReadPolicyScript()
    {
        using var stream = typeof(SystemAdapters).Assembly.GetManifestResourceStream("DomainDns.ps1")
            ?? throw new IOException("Missing NRPT adapter");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static Task DomainDns(string operation, JsonNode journal)
    {
        var transaction = Guid.Parse(journal["dnsTransaction"]!.GetValue<string>());
        var domains = journal["domains"]!.AsArray();
        if (domains.Count == 0) throw new IOException("恢复记录缺少 DNS 域名");
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(domains.ToJsonString()));
        return PowerShell("& { " + domainPolicyScript +
            $" }} -operation '{operation}' -transaction '{transaction:D}' -domainData '{encoded}'");
    }

    public static Task FlushDns()=>PowerShell("Clear-DnsClientCache | Out-Null");
}
