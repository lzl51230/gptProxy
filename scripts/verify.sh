#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/build/ChatGPT Proxy.app"
PROFILE="$PROJECT_DIR/Resources/ChatGPT-Only.pbprofile"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
PRODUCT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
PRODUCT_ZIP="$PROJECT_DIR/dist/ChatGPT-Proxy-${PRODUCT_VERSION}-Universal.zip"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

swift test
"$PROJECT_DIR/scripts/package.sh"

/usr/bin/plutil -lint "$PROJECT_DIR/Resources/Info.plist"
/usr/bin/jq -e . "$PROFILE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
ARCHITECTURES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/ChatGPTProxyLauncher")
[[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]

/usr/bin/jq -e '
    (.proxyConfigs | length) == 1 and
    .proxyConfigs[0].id == "chatgpt-proxy-relay" and
    .proxyConfigs[0].host == "127.0.0.1" and
    .proxyConfigs[0].port == 17890 and
    .proxyConfigs[0].type == "socks5" and
    (.proxyRules | length) == 2 and
    all(.proxyRules[]; .processNames == "com.openai.*;com.openai.chat;ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*") and
    ([.proxyRules[] | select(.localId == "chatgpt-local-direct")] | length) == 1 and
    (.proxyRules[] | select(.localId == "chatgpt-local-direct") |
        .enabled == true and
        .action == "DIRECT" and
        .protocol == "TCP" and
        .targetHosts == "localhost;127.0.0.1;::1;192.168.*.*;192.168.100.81" and
        .targetPorts == "*") and
    ([.proxyRules[] | select(.localId == "chatgpt-only-proxy")] | length) == 1 and
    (.proxyRules[] | select(.localId == "chatgpt-only-proxy") |
        .enabled == true and
        .action == "chatgpt-proxy-relay" and
        .protocol == "BOTH" and
        .targetHosts == "*" and
        .targetPorts == "*") and
    ([.proxyRules[] |
        select(.enabled == true and .action == "DIRECT" and
            (.protocol == "UDP" or .protocol == "BOTH"))] | length) == 0
' "$PROFILE" >/dev/null

VERIFY_ROOT=$(/usr/bin/mktemp -d /tmp/chatgpt-proxy-verify.XXXXXX)
trap '/bin/rm -rf "$VERIFY_ROOT"' EXIT
/usr/bin/ditto -x -k "$PRODUCT_ZIP" "$VERIFY_ROOT"
EXTRACTED_APP="$VERIFY_ROOT/ChatGPT Proxy.app"
[[ -d "$EXTRACTED_APP" ]]
/usr/bin/codesign --verify --deep --strict "$EXTRACTED_APP"
/usr/bin/cmp "$APP_DIR/Contents/MacOS/ChatGPTProxyLauncher" "$EXTRACTED_APP/Contents/MacOS/ChatGPTProxyLauncher"
/usr/bin/cmp "$PROFILE" "$EXTRACTED_APP/Contents/Resources/ChatGPT-Only.pbprofile"
[[ -z "$(/usr/bin/find "$VERIFY_ROOT" -name '*.pkg' -o -name 'ProxyBridge.app')" ]]
[[ -z "$(/usr/bin/find "$PROJECT_DIR/dist" -maxdepth 1 -name '*.pkg' -o -name 'install.sh')" ]]
print "Verified tests, profile isolation, signatures, universal architectures, and app-only ZIP."
