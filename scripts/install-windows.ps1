param([Parameter(Mandatory=$true)][string]$OwnerSid,[string]$Source=(Join-Path (Split-Path $PSScriptRoot -Parent) 'build\windows\app'))
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Installation requires elevation'}
$sid=[Security.Principal.SecurityIdentifier]::new($OwnerSid)
$destination=Join-Path $env:ProgramW6432 'ChatGPT Proxy'
$state=Join-Path $env:ProgramData 'ChatGPT Proxy'
$existing=Get-Service ChatGPTProxy -ErrorAction SilentlyContinue
if($existing){
 if($existing.Status -ne 'Running'){Start-Service ChatGPTProxy}
 $restored=Start-Process "$destination\ChatGPTProxy.App.exe" -ArgumentList '--restore' -Wait -PassThru
 if($restored.ExitCode -ne 0){throw 'Existing service could not restore DNS; upgrade aborted'}
 $closed=Start-Process "$destination\ChatGPTProxy.App.exe" -ArgumentList '--shutdown' -Wait -PassThru
 if($closed.ExitCode -ne 0 -and (Get-Process ChatGPTProxy.App -ErrorAction SilentlyContinue)){throw 'Close the existing launcher before upgrading'}
 Stop-Service ChatGPTProxy
}
foreach($path in @($destination,$state)){
 if((Test-Path $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Installation directory is a reparse point'}
 New-Item -ItemType Directory -Force $path | Out-Null
}
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18');$admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$acl.SetOwner($system)
foreach($account in @($system,$admins)){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($account,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
Set-Acl -LiteralPath $state -AclObject $acl
if([IO.Path]::GetFullPath($Source).TrimEnd('\') -ne [IO.Path]::GetFullPath($destination).TrimEnd('\')){Copy-Item "$Source\*" $destination -Recurse -Force}
@{sid=$sid.Value} | ConvertTo-Json | Set-Content "$destination\Service\owner.json" -Encoding UTF8
if(!$existing){New-Service -Name ChatGPTProxy -BinaryPathName ('"'+$destination+'\Service\ChatGPTProxy.Service.exe"') -DisplayName 'ChatGPT Proxy Protection' -StartupType Automatic | Out-Null}
& sc.exe config ChatGPTProxy binPath= ('"'+$destination+'\Service\ChatGPTProxy.Service.exe"')
if($LASTEXITCODE){throw 'Cannot configure service executable'}
& sc.exe failure ChatGPTProxy reset= 86400 actions= restart/1000/restart/1000/restart/1000
if($LASTEXITCODE){throw 'Cannot configure service recovery'}
& sc.exe failureflag ChatGPTProxy 1
Start-Service ChatGPTProxy
