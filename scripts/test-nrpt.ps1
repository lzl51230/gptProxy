# Exercise the production policy adapter without requiring elevation or changing DNS.
$ErrorActionPreference = 'Stop'
$domains = @('chatgpt.com', 'challenges.cloudflare.com')
$domainData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject $domains)))
$transaction = [guid]::NewGuid().ToString()
$adapter = Join-Path $PSScriptRoot '../windows/ChatGPTProxy.Service/DomainDns.ps1'
$fixture = @{ rules = @(); external = @() }
function Get-DnsClientNrptRule { $fixture.rules }
function Get-DnsClientNrptPolicy { param([switch]$Effective) $fixture.rules; $fixture.external }
function Add-DnsClientNrptRule {
    param($Namespace, $NameServers, $Comment, $DisplayName)
    $fixture.rules += [pscustomobject]@{Name='fixture'; Namespace=$Namespace; NameServers=$NameServers; Comment=$Comment; DisplayName=$DisplayName}
}
function Remove-DnsClientNrptRule { param($Name, [switch]$Force) $fixture.rules = @($fixture.rules | Where-Object Name -ne $Name) }
function Run-Policy($operation) { & $adapter -operation $operation -domainData $domainData -transaction $transaction }
function Expect-Failure($op, $fragment) {
    try { Run-Policy $op } catch { if ($_.Exception.Message -like "*$fragment*") { return }; throw }
    throw "$op did not report $fragment"
}
$foreign = [pscustomobject]@{Namespace=@('.internal.example', 'chatgpt.com.example.org', 'www.cloudflare.com');NameServers='192.0.2.1'}
$fixture.external = @($foreign)
Run-Policy domainDNSCheck
Run-Policy domainDNSApply
Run-Policy verify
if ($fixture.rules.Count -ne 1 -or $fixture.rules[0].Namespace.Count -ne 4) { throw 'Missing apex or suffix' }
Run-Policy domainDNSApply
if ($fixture.rules.Count -ne 1) { throw 'Retry duplicated policy' }
$fixture.external += [pscustomobject]@{Namespace='.CloudFlare.com';NameServers='192.0.2.2'}
Expect-Failure verify 'challenges.cloudflare.com'
Run-Policy domainDNSRestore
Run-Policy domainDNSRestore
if ($fixture.rules.Count) { throw 'Owned policy survived restore' }
Expect-Failure domainDNSCheck 'challenges.cloudflare.com'
$fixture.external = @($foreign)
Run-Policy domainDNSApply
$fixture.rules[0].NameServers='192.0.2.3'
Expect-Failure verify 'chatgpt.com'
Run-Policy domainDNSRestore
if ($fixture.rules.Count -ne 1) { throw 'Edited policy was removed' }
Write-Output 'NRPT lifecycle, namespace conflicts and ownership checks passed'
