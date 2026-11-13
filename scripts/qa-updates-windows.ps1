param(
 [ValidateSet('ui','success-stopped','startup-failure','corrupt','success-running','cancel-authorization','authorization')][string]$Case='success-stopped',
 [string]$Target='',
 [int]$TimeoutSeconds=420,
 [switch]$PrepareFixtures
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path $PSScriptRoot -Parent
if($PrepareFixtures) {
 $fixtures=Join-Path $root 'dist\qa\fixtures'
 foreach($version in @('2.3.9','2.4.0')) {
  $folder=Join-Path $fixtures "$version\ChatGPT Proxy"
  New-Item -ItemType Directory -Force $folder | Out-Null
  Copy-Item (Join-Path $root 'build\windows\portable\ChatGPT Proxy\*') $folder -Recurse -Force
  & dotnet publish (Join-Path $root 'windows\ChatGPTProxy.App') -c Debug -r win-x64 --self-contained true -p:RestoreLockedMode=true "-p:Version=$version" -o $folder
  if($LASTEXITCODE -ne 0){throw 'QA fixture publish failed'}
  $files=@(Get-ChildItem $folder -File -Recurse | Where-Object Name -ne 'update-manifest.json' | ForEach-Object {$_.FullName.Substring($folder.TrimEnd('\').Length+1).Replace('\','/')})
  @{Version=$version;Runtime='win-x64';Files=$files} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $folder 'update-manifest.json') -Encoding utf8
 }
 Compress-Archive -Path (Join-Path $fixtures '2.4.0\ChatGPT Proxy') -DestinationPath (Join-Path $fixtures 'new.zip') -CompressionLevel Fastest -Force
}
$output=Join-Path $root ("dist\qa\gptproxy-qa-"+$Case+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $output | Out-Null
if($Case -eq 'ui') {
 $executable=Join-Path $root 'build\windows\app\ChatGPTProxy.App.exe'
 $arguments='--qa-ui "'+$output+'"'
} else {
 if(!$Target){$Target=Join-Path $output 'installed'}
 if(Test-Path $Target){throw 'QA target must not already exist'}
 New-Item -ItemType Directory -Force $Target | Out-Null
 Copy-Item (Join-Path $root 'dist\qa\fixtures\2.3.9\ChatGPT Proxy\*') $Target -Recurse -Force
 New-Item -ItemType Directory -Force (Join-Path $Target 'Data') | Out-Null
 '{"port":"7890","paused":true,"regions":[],"theme":2,"themeId":"darkModern"}' | Set-Content (Join-Path $Target 'Data\settings.json') -Encoding ascii
 'user file preserved' | Set-Content (Join-Path $Target 'user-extra.txt') -Encoding ascii
 @{scenario=$Case;zip=(Join-Path $root 'dist\qa\fixtures\new.zip')} | ConvertTo-Json | Set-Content (Join-Path $output 'case.json') -Encoding utf8
 $executable=Join-Path $Target 'ChatGPTProxy.App.exe'
 $arguments=''
}
# Limited interactive task exercises the actual desktop token. Never supplies or stores credentials.
$taskName='GPTProxy-Update-QA-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$command="`$env:GPTPROXY_QA_UPDATE_ROOT='$output'; & '$executable' $arguments"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$action=New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -EncodedCommand $encoded"
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
try {
 Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
 Start-ScheduledTask -TaskName $taskName
 Write-Output "QA output: $output"
 $result=Join-Path $output $(if($Case -eq 'ui'){'result.txt'}else{'result.json'})
 $started=[DateTime]::UtcNow
 $deadline=$started.AddSeconds($TimeoutSeconds)
 while(!(Test-Path $result)) {
  if(([DateTime]::UtcNow-$started).TotalSeconds -gt 5 -and (Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and $Case -eq 'ui'){throw "UI process exited before producing results: $output"}
  if(Test-Path (Join-Path $output 'error.txt')){throw (Get-Content (Join-Path $output 'error.txt') -Raw)}
  if([DateTime]::UtcNow -gt $deadline){throw "Desktop QA timed out: $output"}
  Start-Sleep -Milliseconds 500
 }
 Get-Content $result
 if($Case -ne 'ui' -and !(Get-Content $result -Raw | ConvertFrom-Json).success){throw 'Desktop update QA failed'}
 # Let the QA window restore protection and exit before the next scenario.
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 while((Get-Process ChatGPTProxy.App -ErrorAction SilentlyContinue | Where-Object Path -eq $executable)) {
  if([DateTime]::UtcNow -gt $deadline){throw 'QA launcher did not exit; inspect recovery state'}
  Start-Sleep -Milliseconds 500
 }
 if($Case -ne 'ui' -and (Get-Content (Join-Path $Target 'user-extra.txt') -Raw).Trim() -ne 'user file preserved'){throw 'User file was modified'}
} finally {Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}
