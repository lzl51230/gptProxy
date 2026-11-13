param([Parameter(Mandatory=$true)][int]$LauncherPid,[Parameter(Mandatory=$true)][long]$LauncherStartTicks,[Parameter(Mandatory=$true)][string]$Source)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Portable protection requires elevation'}
$sourcePath=[IO.Path]::GetFullPath($Source).TrimEnd('\')
$launcher=Get-Process -Id $LauncherPid
$expected=Join-Path $sourcePath 'ChatGPTProxy.App.exe'
if($launcher.StartTime.ToUniversalTime().Ticks -ne $LauncherStartTicks -or $launcher.Path -ne $expected){throw 'Portable launcher identity changed'}
$owner=(Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId=$LauncherPid") -MethodName GetOwnerSid).Sid
if(!$owner){throw 'Cannot identify portable launcher owner'}
$existing=Get-Service ChatGPTProxy -ErrorAction SilentlyContinue
if($existing){
    $registered=(Get-CimInstance Win32_Service -Filter "Name='ChatGPTProxy'").PathName.Trim('"')
    $serviceDirectory=Split-Path $registered
    $config=Get-Content (Join-Path $serviceDirectory 'owner.json') -Raw | ConvertFrom-Json
    if($config.portable){
        $previous=Get-Process -Id $config.launcherPid -ErrorAction SilentlyContinue
        if($previous -and $previous.StartTime.ToUniversalTime().Ticks -eq $config.launcherStartTicks){
            if($previous.Id -eq $LauncherPid -and $config.launcherPath -eq $expected){
                if($existing.Status -ne 'Running'){Start-Service ChatGPTProxy}
                exit 0
            }
            throw 'Another portable session is running; exit it before starting this copy'
        }
        # A dead portable owner is recovered by its existing service, including after reboot.
        if($existing.Status -ne 'Running'){Start-Service ChatGPTProxy}
        $existing.Dispose()
        $deadline=(Get-Date).AddSeconds(90)
        while((Get-Service ChatGPTProxy -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 500}
        if(Get-Service ChatGPTProxy -ErrorAction SilentlyContinue){throw 'Previous portable recovery is incomplete; retained for recovery'}
    }else{
        $oldLauncher=Join-Path (Split-Path $serviceDirectory) 'ChatGPTProxy.App.exe'
        if(Get-Process ChatGPTProxy.App -ErrorAction SilentlyContinue | Where-Object Path -eq $oldLauncher){throw 'Exit the old installed launcher before starting portable protection'}
        if($existing.Status -ne 'Running'){Start-Service ChatGPTProxy}
        $restore=Start-Process $oldLauncher -ArgumentList '--restore' -Wait -PassThru
        if($restore.ExitCode -ne 0){throw 'Existing protection could not restore; portable startup aborted'}
        Stop-Service ChatGPTProxy
        $existing.Dispose()
        & sc.exe delete ChatGPTProxy | Out-Null
        if($LASTEXITCODE){throw 'Cannot replace existing protection service'}
    }
}
$state=Join-Path $env:ProgramData 'ChatGPT Proxy'
if((Test-Path $state) -and ((Get-Item -LiteralPath $state).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Recovery directory is a reparse point'}
New-Item -ItemType Directory -Force $state | Out-Null
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18');$admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$acl.SetOwner($system)
foreach($sid in @($system,$admins)){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
Set-Acl -LiteralPath $state -AclObject $acl
$portableRoot=Join-Path $state 'portable'
if((Test-Path $portableRoot) -and ((Get-Item -LiteralPath $portableRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Portable cache is a reparse point'}
New-Item -ItemType Directory -Force $portableRoot | Out-Null
Set-Acl -LiteralPath $portableRoot -AclObject $acl
$cache=Join-Path $portableRoot ([Guid]::NewGuid().ToString())
# Impersonated reads can lazily load managed runtime assemblies. The owner may read
# this code cache, but only SYSTEM/Administrators can change executable content.
New-Item -ItemType Directory -Force $cache | Out-Null
$codeAcl=[Security.AccessControl.DirectorySecurity]::new();$codeAcl.SetAccessRuleProtection($true,$false);$codeAcl.SetOwner($system)
foreach($sid in @($system,$admins)){$codeAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
$codeAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($owner),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath $cache -AclObject $codeAcl
$target=Join-Path $cache 'Service'
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $sourcePath 'Service\*') $target -Recurse -Force
@{sid=$owner;portable=$true;launcherPath=$expected;launcherPid=$LauncherPid;launcherStartTicks=$LauncherStartTicks;launcherHash=(Get-FileHash $expected -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content (Join-Path $target 'owner.json') -Encoding UTF8
# Auto-start is retained only while a session/recovery is pending, so reboot cannot strand DNS.
try {
New-Service -Name ChatGPTProxy -BinaryPathName ('"'+$target+'\ChatGPTProxy.Service.exe"') -DisplayName 'ChatGPT Proxy Portable Recovery' -StartupType Automatic | Out-Null
& sc.exe failure ChatGPTProxy reset= 86400 actions= restart/1000/restart/1000/restart/1000 | Out-Null
if($LASTEXITCODE){throw 'Cannot configure portable service recovery'}
& sc.exe failureflag ChatGPTProxy 1 | Out-Null
if($LASTEXITCODE){throw 'Cannot configure portable service recovery'}
Start-Service ChatGPTProxy

} catch {
    if(!(Test-Path (Join-Path $state 'recovery-v1.json'))) {
        Stop-Service ChatGPTProxy -ErrorAction SilentlyContinue
        & sc.exe delete ChatGPTProxy | Out-Null
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
