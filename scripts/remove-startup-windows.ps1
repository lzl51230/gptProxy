$ErrorActionPreference='Stop'
$directory=Join-Path $env:ProgramW6432 'ChatGPT Proxy'
$owner=Get-Content "$directory\Service\owner.json" -Raw | ConvertFrom-Json
$sid=[Security.Principal.SecurityIdentifier]::new($owner.sid).Value
$key="Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
if(Test-Path $key){
 $current=(Get-ItemProperty -LiteralPath $key -Name 'ChatGPT Proxy' -ErrorAction SilentlyContinue).'ChatGPT Proxy'
 if($current -eq ('"'+$directory+'\ChatGPTProxy.App.exe"')){Remove-ItemProperty -LiteralPath $key -Name 'ChatGPT Proxy'}
}
