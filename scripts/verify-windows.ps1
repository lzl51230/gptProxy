param([switch]$CoreOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location "$root\core"
try {
 & cargo test --locked --target-dir "$root\build\rust"
 if($LASTEXITCODE){throw 'Rust tests failed'}
 & cargo build --locked --release --target x86_64-pc-windows-msvc --target-dir "$root\build\rust"
 if($LASTEXITCODE){throw 'Rust build failed'}
} finally {Pop-Location}
# Copy beside the test host so the normal library resolver exercises deployment layout.
& dotnet build "$root\windows\ChatGPTProxy.Tests" -c Release -p:RestoreLockedMode=true
if($LASTEXITCODE){throw 'Binding build failed'}
Copy-Item "$root\build\rust\x86_64-pc-windows-msvc\release\gpt_proxy_core.dll" "$root\windows\ChatGPTProxy.Tests\bin\Release\net10.0\gpt_proxy_core.dll" -Force
& dotnet test "$root\windows\ChatGPTProxy.Tests" -c Release --no-build
if($LASTEXITCODE){throw 'Binding tests failed'}
& python "$root\scripts\qa-core-heartbeat.py" --library "$root\build\rust\x86_64-pc-windows-msvc\release\gpt_proxy_core.dll"
if($LASTEXITCODE){throw 'Native SOCKS/TLS ABI tests failed'}
& python "$root\scripts\qa-core-dns.py" --library "$root\build\rust\x86_64-pc-windows-msvc\release\gpt_proxy_core.dll"
if($LASTEXITCODE){throw 'DNS ABI tests failed'}
if(!$CoreOnly){
 & "$PSScriptRoot\build-windows.ps1" -SkipCore
 $visuals=Join-Path $root 'build\windows-ui-visuals'
 $ui=Start-Process (Join-Path $root 'build\windows\app\ChatGPTProxy.App.exe') -ArgumentList @('--qa-ui',('"'+$visuals+'"')) -Wait -PassThru
 if($ui.ExitCode){throw "WPF visual checks failed; see $visuals"}
}
