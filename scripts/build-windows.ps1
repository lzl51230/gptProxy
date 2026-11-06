param([switch]$SkipCore)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(!$SkipCore){
 Push-Location "$root\core"
 try {
 & cargo build --manifest-path "$root\core\Cargo.toml" --locked --release --target x86_64-pc-windows-msvc --target-dir "$root\build\rust"
 if($LASTEXITCODE){throw 'Rust build failed'}
 } finally {Pop-Location}
}
$stage="$root\build\windows\app"
if(Test-Path $stage){Remove-Item $stage -Recurse -Force}
New-Item -ItemType Directory -Force $stage | Out-Null
foreach($project in @('ChatGPTProxy.App','ChatGPTProxy.Service')){
 if(Test-Path "$root\build\windows\$project"){Remove-Item "$root\build\windows\$project" -Recurse -Force}
 & dotnet publish "$root\windows\$project" -c Release -r win-x64 --self-contained true -p:RestoreLockedMode=true -o "$root\build\windows\$project"
 if($LASTEXITCODE){throw "$project build failed"}
 $target=if($project -eq 'ChatGPTProxy.App'){$stage}else{Join-Path $stage 'Service'}
 New-Item -ItemType Directory -Force $target | Out-Null
 Copy-Item "$root\build\windows\$project\*" $target -Recurse -Force
 Copy-Item "$root\build\rust\x86_64-pc-windows-msvc\release\gpt_proxy_core.dll" $target -Force
 Copy-Item "$root\windows\proxybridge-files.json" $target -Force
}
Copy-Item "$root\build\rust\x86_64-pc-windows-msvc\release\gpt_proxy_core.dll" $stage -Force
Copy-Item "$root\windows\proxybridge-files.json" $stage -Force
Copy-Item "$root\Resources\THIRD_PARTY_NOTICES.md" $stage -Force
Copy-Item "$root\core\resources\proxybridge-release.json" $stage -Force
Copy-Item "$root\scripts\install-proxybridge-windows.ps1" $stage -Force
$sysroot=(& rustc --print sysroot).Trim()
Copy-Item "$sysroot\share\doc\rust\COPYRIGHT-library.html" "$stage\Rust-Std-Notices.html"
$notices=Join-Path $stage 'Notices'
foreach($project in @('ChatGPTProxy.App','ChatGPTProxy.Service')) {
 $assets=Get-Content "$root\windows\$project\obj\project.assets.json" -Raw | ConvertFrom-Json
 foreach($library in $assets.libraries.PSObject.Properties) {
  if($library.Value.type -ne 'package'){continue}
  foreach($folder in $assets.packageFolders.PSObject.Properties.Name) {
   $package=Join-Path $folder $library.Value.path
   if(!(Test-Path $package)){continue}
   $target=Join-Path $notices ($library.Name.Replace('/','-'))
   foreach($file in Get-ChildItem $package -File | Where-Object {$_.Name -match '^(LICENSE|COPYING|COPYRIGHT|THIRD.PARTY.NOTICES)'}) {
    New-Item -ItemType Directory -Force $target | Out-Null
    Copy-Item $file.FullName $target -Force
   }
  }
 }
}
foreach($name in @('microsoft.netcore.app.runtime.win-x64','microsoft.windowsdesktop.app.runtime.win-x64')) {
 $package=Join-Path $env:USERPROFILE ".nuget\packages\$name\10.0.14"
 if(!(Test-Path $package)){throw "Missing runtime notices: $name"}
 $target=Join-Path $notices $name
 New-Item -ItemType Directory -Force $target | Out-Null
 Get-ChildItem $package -File | Where-Object {$_.Name -match '^(LICENSE|THIRD.PARTY.NOTICES)'} | Copy-Item -Destination $target
}
Write-Output "Windows staging directory: $stage"
