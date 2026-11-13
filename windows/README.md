# Windows host

Windows 11 x64 uses a WPF tray launcher and a LocalSystem recovery service. The desktop and service each load the same Rust core through the versioned C ABI. Keep their self-contained .NET runtimes in separate directories: WPF and the service have different `WindowsBase.dll` implementations.

The Rust core owns the relay, SOCKS probes, TLS heartbeat, monitor workflow, candidate policy, Clash protocol, DNS forwarding, configuration transforms, recovery transaction and CLI parsing. C# owns Windows process/package activation, named-pipe transport, SCM, WPF, registry/network adapter access and native handles. macOS uses the same Rust operations with SwiftUI and its PF/SystemConfiguration adapters.

## Build

Install Rust through rustup (the repository pins the toolchain), MSVC C++ Build Tools, .NET 10 SDK, Python 3 and OpenSSL (Git for Windows includes it). In a Developer PowerShell:

```powershell
./scripts/verify-windows.ps1
./scripts/package-windows.ps1 -SkipBuild
```

The output is `dist/ChatGPT-Proxy-2.3.9-Windows-x64-Portable.zip`; packaging uses PowerShell and no installer compiler. Extract the entire folder and run `ChatGPTProxy.App.exe`. The ZIP contains both .NET runtimes, the shared Rust DLL and notices. The Rust DLL statically links the MSVC runtime; end users do not need MSVC Build Tools, the VC++ redistributable or OpenSSL. It does not contain ChatGPT, Clash Party or ProxyBridge. The launcher can download and install the pinned official ProxyBridge 4.1.1 release through the selected local SOCKS port, checking the release hash and installed component hashes.

Clash configuration files and subscription source files support up to 32 MiB per file. Reads are bounded, recovery records allow up to 256 MiB, and oversized input reports its size limit. Configuration reads still impersonate the Clash process user.

The `Windows release package` GitHub Actions workflow can build an existing `vX.Y.Z` tag, run the same verification, and produce the versioned portable ZIP with a SHA-256 file. It adjusts only Windows version metadata to match the requested tag and records the source commit in the workflow artifact.

NuGet lock files and the .NET runtime version are pinned. To deliberately update dependencies, restore with `--force-evaluate`, review all four lock files, then run verification again. Do not overwrite WPF runtime files with the service publish output.

## Lifecycle and recovery

The portable launcher requests administrator authorization only when protection is enabled. The bootstrap validates the launcher's PID, start time and executable path, then copies the recovery service into a cache writable only by SYSTEM/Administrators (the owner has read/execute access for impersonated runtime loads) under `%ProgramData%\ChatGPT Proxy\portable`. Its protected owner record binds the caller SID, portable launcher path and executable hash. Named-pipe clients authenticate the server against SCM; the service authenticates the launcher before accepting fixed commands. Configuration reads still impersonate the Clash process user.

The temporary service is automatic while recovery may be needed. On normal tray exit or loss of the launcher, it restores the network, exits, unregisters itself and removes its runtime cache. After a crash or reboot, it restores before cleanup; failed recovery retains the journal and service. The portable folder can then be moved or deleted. No runtime binary is executed from a user-writable path by the registered service.

Activation starts the relay and ProxyBridge, persists the original DNS configuration, enables loopback DNS and a dynamic WFP session, and validates protection. ChatGPT is activated through its MSIX application identity. Its File > Quit accelerator requests normal shutdown; failure to exit within 15 seconds rolls back protection. The launcher does not force-terminate ChatGPT. The UI reports success only after verifying the new package process.

Closing the launcher window keeps it in the tray. Tray exit restores DNS first. Lost owner heartbeat, launcher exit, CLI failure, repeated verification failure or service restart triggers recovery. The service's owned job closes the CLI when the service crashes, and Windows releases the dynamic WFP session. Recovery runs before accepting another activation. Configuration reloads wait for subscription nodes to become selectable; an interrupted activation retains its original selection instead of adopting a temporary default.

The protected journal is `%ProgramData%\ChatGPT Proxy\recovery-v1.json`, readable only by SYSTEM and Administrators. It records intended changes before mutation. Recovery restores static or automatic DNS by adapter GUID, preserves subsequent explicit user changes and retains the journal if a required adapter is unavailable. Unknown journal versions block mutation and upgrades instead of being discarded.

Settings live in `Data/settings.json` beside the portable launcher. Enabling login startup registers that folder's path, so moving the folder requires updating that option. ZIP packaging does not provide a trusted publisher signature; Windows may still show a reputation/publisher prompt.

For migration, restore and exit an old installed version first. Portable startup can replace its recovery service after successful restoration, but does not delete the old program files. Close a separately running ProxyBridge desktop instance before enabling protection.

Emergency recovery while the portable session exists:

```powershell
& 'path\to\ChatGPT Proxy\ChatGPTProxy.App.exe' --restore
```

Recovery records are retained under ProgramData if restoration fails; do not remove them to force startup.

## Tests

`verify-windows.ps1` runs Rust and C# binding tests, real SOCKS/TLS fixtures, dual-stack DNS fixtures and both desktop builds. The DNS fixture includes Windows' ICMP-reset behavior when a UDP client closes before its reply. A separate elevated check exercises real WFP filtering:

```powershell
python scripts/qa-core-dns.py --library build/rust/x86_64-pc-windows-msvc/release/gpt_proxy_core.dll --firewall
```

Run that check with protection off and port 53 free. It temporarily blocks external plaintext DNS and restores filtering in `finally`. The installed launcher's `--qa-smoke` exercises preparation, MSIX restart, live observation and restoration. `--qa-protection-hold` is a two-minute recovery test session; it restores on normal completion and lets the service watchdog recover if the test launcher is terminated.

While the monitor is running, a direct GLOBAL selection of DIRECT (case insensitive) starts node recovery immediately, even when the connection is healthy. Candidates belong to the currently selected Clash Party profile and follow enabled region order. With no enabled regions, the monitor asks the user to select regions. Nested selections and custom Direct-type nodes do not trigger this rule. Existing cooldown, candidate validation and protection lifecycle remain in effect.
