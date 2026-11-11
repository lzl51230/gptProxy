# Windows host

Windows 11 x64 uses a WPF tray launcher and a LocalSystem recovery service. The desktop and service each load the same Rust core through the versioned C ABI. Keep their self-contained .NET runtimes in separate directories: WPF and the service have different `WindowsBase.dll` implementations.

The Rust core owns the relay, SOCKS probes, TLS heartbeat, monitor workflow, candidate policy, Clash protocol, DNS forwarding, configuration transforms, recovery transaction and CLI parsing. C# owns Windows process/package activation, named-pipe transport, SCM, WPF, registry/network adapter access and native handles. macOS uses the same Rust operations with SwiftUI and its PF/SystemConfiguration adapters.

## Build

Install Rust through rustup (the repository pins the toolchain), MSVC C++ Build Tools, .NET 10 SDK, Python 3 and OpenSSL (Git for Windows includes it). In a Developer PowerShell:

```powershell
./scripts/verify-windows.ps1
./scripts/package-windows.ps1 -SkipBuild
```

Packaging additionally needs Inno Setup 7 x64. The output is `dist/ChatGPT-Proxy-2.3.3-Windows-x64-Setup.exe`. The installer contains both .NET runtimes, the shared Rust DLL and notices. The Rust DLL statically links the MSVC runtime; end users do not need MSVC Build Tools, the VC++ redistributable or OpenSSL. It does not contain ChatGPT, Clash Party or ProxyBridge. The launcher can download and install the pinned official ProxyBridge 4.1.1 release through the selected local SOCKS port, checking the release hash and installed component hashes.

NuGet lock files and the .NET runtime version are pinned. To deliberately update dependencies, restore with `--force-evaluate`, review all four lock files, then run verification again. Do not overwrite WPF runtime files with the service publish output.

## Lifecycle and recovery

The installer binds the service to the original interactive user's SID. Elevated unattended installation can specify `/OWNERSID=S-1-...`. The named pipe rejects remote clients, authenticates the caller SID and installed launcher path, and exposes only fixed commands. The launcher authenticates the server against SCM's running service PID. Reads of Clash configuration and subscription files impersonate the discovered Clash process, so the service does not grant those paths SYSTEM file access.

Activation starts the relay and ProxyBridge, persists the original DNS configuration, enables loopback DNS and a dynamic WFP session, and validates protection. ChatGPT is activated through its MSIX application identity. Its File > Quit accelerator requests normal shutdown; failure to exit within 15 seconds rolls back protection. The launcher does not force-terminate ChatGPT. The UI reports success only after verifying the new package process.

Closing the launcher window keeps it in the tray. Tray exit restores DNS first. Lost owner heartbeat, launcher exit, CLI failure, repeated verification failure or service restart triggers recovery. The service's owned job closes the CLI when the service crashes, and Windows releases the dynamic WFP session. Recovery runs before accepting another activation. Configuration reloads wait for subscription nodes to become selectable; an interrupted activation retains its original selection instead of adopting a temporary default.

The protected journal is `%ProgramData%\ChatGPT Proxy\recovery-v1.json`, readable only by SYSTEM and Administrators. It records intended changes before mutation. Recovery restores static or automatic DNS by adapter GUID, preserves subsequent explicit user changes and retains the journal if a required adapter is unavailable. Unknown journal versions block mutation and upgrades instead of being discarded.

The installer asks the running launcher to restore and exit before replacing files. Uninstall also requires successful recovery. Preferences remain in `%LocalAppData%\ChatGPT Proxy\settings.json`.

Emergency recovery from an elevated console:

```powershell
& "$env:ProgramFiles\ChatGPT Proxy\ChatGPTProxy.App.exe" --restore
```

## Tests

`verify-windows.ps1` runs Rust and C# binding tests, real SOCKS/TLS fixtures, dual-stack DNS fixtures and both desktop builds. The DNS fixture includes Windows' ICMP-reset behavior when a UDP client closes before its reply. A separate elevated check exercises real WFP filtering:

```powershell
python scripts/qa-core-dns.py --library build/rust/x86_64-pc-windows-msvc/release/gpt_proxy_core.dll --firewall
```

Run that check with protection off and port 53 free. It temporarily blocks external plaintext DNS and restores filtering in `finally`. The installed launcher's `--qa-smoke` exercises preparation, MSIX restart, live observation and restoration. `--qa-protection-hold` is a two-minute recovery test session; it restores on normal completion and lets the service watchdog recover if the test launcher is terminated.

While the monitor is running, a direct GLOBAL selection of DIRECT (case insensitive) starts node recovery immediately, even when the connection is healthy. Candidates belong to the currently selected Clash Party profile and follow enabled region order. With no enabled regions, the monitor asks the user to select regions. Nested selections and custom Direct-type nodes do not trigger this rule. Existing cooldown, candidate validation and protection lifecycle remain in effect.
