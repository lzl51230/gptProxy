param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(!$SkipBuild){& "$PSScriptRoot\build-windows.ps1"}
[xml]$props=Get-Content "$root\windows\Directory.Build.props"
$version=$props.Project.PropertyGroup.Version
$stage=Join-Path $root 'build\windows\portable'
if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
$folder=Join-Path $stage 'ChatGPT Proxy'
New-Item -ItemType Directory -Force $folder | Out-Null
Copy-Item "$root\build\windows\app\*" $folder -Recurse -Force
Copy-Item "$PSScriptRoot\start-portable-windows.ps1" $folder
Copy-Item "$root\windows\PORTABLE.txt" $folder
'{"format":1}' | Set-Content (Join-Path $folder 'portable.json') -Encoding UTF8
if(Get-ChildItem $folder -Recurse -Filter owner.json){throw 'Portable bundle must not contain machine-specific identity'}
New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$zip=Join-Path $root "dist\ChatGPT-Proxy-$version-Windows-x64-Portable.zip"
Compress-Archive -Path $folder -DestinationPath $zip -Force
Write-Output $zip
