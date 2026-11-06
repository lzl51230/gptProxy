param([ValidateRange(1,65535)][int]$ProxyPort=7890)
$ErrorActionPreference='Stop'
$spec=(Get-Content (Join-Path $PSScriptRoot 'proxybridge-release.json') -Raw | ConvertFrom-Json).windows
$manifest=Get-Content (Join-Path $PSScriptRoot 'proxybridge-files.json') -Raw | ConvertFrom-Json
$directory=Join-Path $env:ProgramW6432 'ProxyBridge'
function Test-Installation {
 foreach($item in $manifest.PSObject.Properties){
  if([IO.Path]::GetFileName($item.Name) -ne $item.Name){throw 'Invalid component manifest'}
  $path=Join-Path $directory $item.Name
  if(!(Test-Path $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item.Value){return $false}
 }
 return $true
}
if(Test-Installation){exit 0}
$stage=Join-Path $env:ProgramData ('ChatGPTProxyInstaller-'+[guid]::NewGuid())
New-Item -ItemType Directory $stage | Out-Null
try {
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $stage -AclObject $acl
 $installer=Join-Path $stage 'ProxyBridge-Setup.exe'
 & "$env:SystemRoot\System32\curl.exe" --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 120 --proto '=https' --proto-redir '=https' --proxy "socks5h://127.0.0.1:$ProxyPort" --output $installer $spec.url
 if($LASTEXITCODE){throw 'ProxyBridge download failed; check the local Clash proxy port'}
 if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $spec.sha256){throw 'ProxyBridge SHA-256 mismatch; installation refused'}
 $process=Start-Process $installer -ArgumentList '/S' -Wait -PassThru
 if($process.ExitCode -ne 0 -or !(Test-Installation)){throw 'ProxyBridge post-install validation failed'}
} finally {Remove-Item -LiteralPath $stage -Recurse -Force}
