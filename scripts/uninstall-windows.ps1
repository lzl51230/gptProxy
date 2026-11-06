$ErrorActionPreference='Stop'
$destination=Join-Path $env:ProgramW6432 'ChatGPT Proxy'
$service=Get-Service ChatGPTProxy -ErrorAction SilentlyContinue
if($service){
 if($service.Status -ne 'Running'){Start-Service ChatGPTProxy}
 $restored=Start-Process "$destination\ChatGPTProxy.App.exe" -ArgumentList '--shutdown' -Wait -PassThru
 if($restored.ExitCode -ne 0){throw 'DNS restoration failed; uninstall aborted and recovery journal retained'}
 Stop-Service ChatGPTProxy
 & sc.exe delete ChatGPTProxy
 if($LASTEXITCODE){throw 'Cannot remove service'}
}
& "$PSScriptRoot\remove-startup-windows.ps1"
# Preserve user preferences, logs, and any recovery evidence; remove only installed program files.
if(Test-Path $destination){Remove-Item -LiteralPath $destination -Recurse -Force}
