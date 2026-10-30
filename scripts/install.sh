#!/bin/zsh
set -euo pipefail
if (( $# != 1 )); then
    print -u2 'Usage: install.sh /path/to/ChatGPT-Proxy-Universal.pkg'
    exit 2
fi
INSTALL_PACKAGE=${1:A}
[[ -f "$INSTALL_PACKAGE" ]] || { print -u2 'Installer package not found.'; exit 1; }
if (( EUID == 0 )); then
    /usr/sbin/installer -pkg "$INSTALL_PACKAGE" -target /
else
    /usr/bin/pgrep -x ChatGPTProxyLauncher >/dev/null && /usr/bin/osascript -e 'tell application id "local.alex.chatgpt-proxy" to quit' 2>/dev/null || true
    /usr/bin/pgrep -x ProxyBridge >/dev/null && /usr/bin/osascript -e 'tell application "ProxyBridge" to quit' 2>/dev/null || true
    sudo /usr/sbin/installer -pkg "$INSTALL_PACKAGE" -target /
    /usr/bin/open '/Applications/ChatGPT Proxy.app'
fi
