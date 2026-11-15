param(
    [Parameter(Mandatory)][ValidateSet('domainDNSCheck','domainDNSApply','domainDNSRestore','verify')][string]$operation,
    [Parameter(Mandatory)][guid]$transaction,
    [Parameter(Mandatory)][string]$domainData,
    [ipaddress]$loopback = '127.0.0.1'
)
$domains = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($domainData)))
if (!$domains.Count) { throw "Missing DNS domains" }
$marker = "ChatGPTProxy.DNS/$transaction"
$display = "ChatGPT Proxy DNS"
foreach ($domain in $domains) {
    if ($domain -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw "Invalid DNS domain: $domain" }
}
$expected = @($domains | ForEach-Object { $_; ".$_" })

function Test-Namespaces($actual) {
    return @($actual).Count -eq $expected.Count -and
        -not (Compare-Object -ReferenceObject $expected -DifferenceObject @($actual))
}

function Test-Overlap([string]$pattern, [string]$domain) {
    if ($pattern -eq '.') { return $true }
    # NRPT prefixes end in a dot. Any such prefix can name a child of a protected domain.
    if ($pattern.EndsWith('.')) { return $true }
    if ($pattern.StartsWith('.')) {
        $suffix = $pattern.Substring(1)
        return $suffix -eq $domain -or $domain.EndsWith(".$suffix", 'OrdinalIgnoreCase') -or
            $suffix.EndsWith(".$domain", 'OrdinalIgnoreCase')
    }
    return $pattern -eq $domain -or $pattern.EndsWith(".$domain", 'OrdinalIgnoreCase')
}

$owned = @()
$local = @(Get-DnsClientNrptRule)
foreach ($rule in $local) {
    if ($rule.Comment -eq $marker -and $rule.DisplayName -eq $display -and
        !$rule.DnsSecEnabled -and !$rule.DirectAccessEnabled -and
        !$rule.DnsSecValidationRequired -and !$rule.DnsSecQueryIPsecRequired -and
        (!$rule.NameEncoding -or $rule.NameEncoding -eq 'Disable') -and
        ($rule.NameServers -join ',') -eq $loopback -and (Test-Namespaces $rule.Namespace)) {
        $owned += $rule
    }
}
if ($operation -eq 'domainDNSRestore') {
    foreach ($rule in $owned) { Remove-DnsClientNrptRule -Name $rule.Name -Force }
    return
}

$effective = @(Get-DnsClientNrptPolicy -Effective)
$seen = @{}
foreach ($rule in $local) {
    if ($rule.Name -in $owned.Name) { continue }
    foreach ($ns in $rule.Namespace) {
        foreach ($domain in $domains) {
            if (Test-Overlap $ns $domain) { throw "DNS rule conflict for $domain ($ns)" }
        }
    }
}
foreach ($rule in $effective) {
    foreach ($ns in $rule.Namespace) {
        if ($owned.Count -eq 1 -and $ns -in $expected -and ($rule.NameServers -join ',') -eq $loopback) {
            $seen[$ns] = $true
            continue
        }
        foreach ($domain in $domains) {
            if (Test-Overlap $ns $domain) { throw "Effective DNS policy conflict for $domain ($ns)" }
        }
    }
}
switch ($operation) {
    'domainDNSCheck' { return }
    'domainDNSApply' {
        if ($owned.Count -eq 0) {
            Add-DnsClientNrptRule -Namespace $expected -NameServers $loopback -Comment $marker -DisplayName $display
        }
    }
    'verify' {
        foreach ($ns in $expected) {
            if (!$seen.ContainsKey($ns)) { throw "NRPT policy inactive for $ns" }
        }
    }
    default { throw "Unknown DNS policy operation" }
}
