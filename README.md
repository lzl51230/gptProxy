# ChatGPT Proxy

A macOS 14+ launcher that routes OpenAI desktop app traffic through a
user-selected local SOCKS5 proxy. The default upstream port is `7890`.

The launcher does not change macOS system proxy settings. It runs a loopback
TCP relay on `127.0.0.1:17890`; the bundled ProxyBridge profile matches
`com.openai.*`, legacy `com.openai.chat`, and `ChatGPT`, then sends those flows
to the relay. The launcher requires the current Codex-enabled ChatGPT desktop
client and reports legacy `com.openai.chat` installations as needing an update.

The "打开 .codex" action opens the current user's Codex directory, creating it
if needed.

## Build

Xcode 16 or newer is required.

```sh
make verify
```

The app is written to `build/ChatGPT Proxy.app`, and the unified installer is
written to `dist/ChatGPT-Proxy-2.0-Universal.pkg`. Running the installer places
both ChatGPT Proxy and ProxyBridge in `/Applications`.

The unified installer is unsigned because this project does not include Apple
Developer ID Application or Installer certificates. On another Mac, open it
from the Finder context menu or allow it in Privacy &amp; Security. The build
verifies the upstream ProxyBridge installer before extracting its component;
the installed ProxyBridge app and system extension retain their upstream code
signatures.
