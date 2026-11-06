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
        start.ArgumentList.Add("-NoProfile"); start.ArgumentList.Add("-NonInteractive"); start.ArgumentList.Add("-EncodedCommand");
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
    public static async Task<JsonArray> DnsSnapshot()
    {
        var json=await PowerShell("ConvertTo-Json -Compress -InputObject @((Get-NetAdapter -Physical | Where-Object Status -eq 'Up') | ForEach-Object { [pscustomobject]@{ id=$_.InterfaceGuid.ToString(); index=$_.ifIndex } })");
        var adapters=JsonNode.Parse(json)?.AsArray() ?? throw new IOException("Cannot enumerate network adapters");
        foreach(var adapter in adapters) {
            var id=Guid.Parse(adapter!["id"]!.GetValue<string>()).ToString("B");
            foreach(var family in new[]{"Tcpip","Tcpip6"}) {
                using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+family+@"\Parameters\Interfaces\"+id);
                adapter[family]=key?.GetValue("NameServer")?.ToString() ?? "";
            }
        }
        if(adapters.Count==0)throw new IOException("没有可接管的物理网络接口");
        return adapters;
    }
    public static async Task DnsApply(JsonArray adapters,bool restore)
    {
        foreach(var adapter in adapters) {
            var id=Guid.Parse(adapter!["id"]!.GetValue<string>()).ToString("B");
            // Re-resolve by GUID: interface indices can change across reboot and hotplug.
            var script="$a=Get-NetAdapter -IncludeHidden | Where-Object {[guid]$_.InterfaceGuid -eq [guid]'"+id+"'};if($a){";
            foreach(var (family,af,loopback) in new[]{("Tcpip","IPv4","127.0.0.1"),("Tcpip6","IPv6","::1")}) {
                using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+family+@"\Parameters\Interfaces\"+id);
                var current=key?.GetValue("NameServer")?.ToString() ?? "";
                if(restore && current!=loopback)continue; // Preserve explicit changes made after activation.
                var saved=adapter[family]?.GetValue<string>() ?? "";
                var servers=(restore?saved:loopback).Split(new[]{',',';',' '},StringSplitOptions.RemoveEmptyEntries);
                if(servers.Any(s=>!System.Net.IPAddress.TryParse(s,out _)))throw new IOException("Invalid saved DNS address");
                script+="$d=Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily "+af+";";
                script+=servers.Length==0?"$d | Set-DnsClientServerAddress -ResetServerAddresses;":"$d | Set-DnsClientServerAddress -ServerAddresses @("+string.Join(",",servers.Select(s=>"'"+s+"'"))+");";
            }
            await PowerShell(script+"}else{throw 'Saved network adapter is unavailable; recovery journal retained'}");
        }
    }
    public static async Task AssertDns()
    {
        var json=await PowerShell("ConvertTo-Json -Compress -InputObject @(Get-DnsClientServerAddress | ForEach-Object {$a=Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue;if($a.Status -eq 'Up' -and $_.ServerAddresses.Count -gt 0){[pscustomobject]@{id=$a.InterfaceGuid.ToString();family=$_.AddressFamily;servers=@($_.ServerAddresses)}}})");
        var rows=JsonNode.Parse(json)?.AsArray() ?? new JsonArray();var count=0;
        foreach(var row in rows) {
            var addresses=row!["servers"]!.AsArray().Select(v=>v!.GetValue<string>()).ToArray();
            // Windows exposes these deprecated site-local defaults on unconfigured
            // IPv6 adapters. They are not an explicit VPN resolver configuration.
            if(row["family"]!.GetValue<int>()==23 && addresses.SequenceEqual(new[]{"fec0:0:0:ffff::1","fec0:0:0:ffff::2","fec0:0:0:ffff::3"})) {
                var id=Guid.Parse(row["id"]!.GetValue<string>()).ToString("B");
                using var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\"+id);
                if(string.IsNullOrWhiteSpace(key?.GetValue("NameServer")?.ToString()))continue;
            }
            if(addresses.Any(v=>v is not ("127.0.0.1" or "::1")))throw new IOException("系统 DNS 被覆盖（"+row["id"]+"）："+string.Join(",",addresses));
            count+=addresses.Length;
        }
        if(count==0)throw new IOException("没有有效的本机 DNS 解析入口");
    }

    public static Task FlushDns()=>PowerShell("Clear-DnsClientCache | Out-Null");
}
