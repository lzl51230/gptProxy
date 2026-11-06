param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(!$SkipBuild){& "$PSScriptRoot\build-windows.ps1"}
$compiler=Join-Path $env:ProgramW6432 'Inno Setup 7\ISCC.exe'
if(!(Test-Path $compiler)){throw 'Install the verified Inno Setup 7 x64 build tool first'}
& $compiler "$root\windows\installer\ChatGPTProxy.iss"
if($LASTEXITCODE){throw 'Windows installer compilation failed'}
