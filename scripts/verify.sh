#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/build/ChatGPT Proxy.app"
PROFILE="$PROJECT_DIR/Resources/ChatGPT-Only.pbprofile"
INSTALLER="$PROJECT_DIR/Resources/ProxyBridge-v4.0.0-Universal-Installer.pkg"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
PROXYBRIDGE_IDENTIFIER=com.interceptsuite.ProxyBridge
PRODUCT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
LAUNCHER_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
MINIMUM_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")
PRODUCT_PKG="$PROJECT_DIR/dist/ChatGPT-Proxy-${PRODUCT_VERSION}-Universal.pkg"
LEGACY_DMG="$PROJECT_DIR/dist/ChatGPT-Proxy-${PRODUCT_VERSION}-Universal.dmg"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

swift test
"$PROJECT_DIR/scripts/package.sh"

/usr/bin/plutil -lint "$PROJECT_DIR/Resources/Info.plist"
/usr/bin/jq -e . "$PROFILE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
ARCHITECTURES=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/ChatGPTProxyLauncher")
[[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]

"$PROJECT_DIR/scripts/validate-proxybridge-installer.sh" "$INSTALLER"

/usr/bin/jq -e '
    (.proxyConfigs | length) == 1 and
    .proxyConfigs[0].id == "chatgpt-proxy-relay" and
    .proxyConfigs[0].host == "127.0.0.1" and
    .proxyConfigs[0].port == 17890 and
    .proxyConfigs[0].type == "socks5" and
    (.proxyRules | length) == 2 and
    all(.proxyRules[]; .processNames == "com.openai.*;com.openai.chat;ChatGPT") and
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
EXPANDED_PRODUCT="$VERIFY_ROOT/product"
CHOICES_PLIST="$VERIFY_ROOT/choices.plist"
CHOICES_JSON="$VERIFY_ROOT/choices.json"
cleanup() {
    /bin/rm -rf "$VERIFY_ROOT"
}
trap cleanup EXIT

[[ -f "$PRODUCT_PKG" ]]
[[ ! -e "$LEGACY_DMG" ]]
/usr/sbin/pkgutil --expand-full "$PRODUCT_PKG" "$EXPANDED_PRODUCT"
LAUNCHER_COMPONENT="$EXPANDED_PRODUCT/ChatGPT-Proxy-Launcher.pkg"
PROXYBRIDGE_COMPONENT="$EXPANDED_PRODUCT/ProxyBridge.pkg"
LAUNCHER_PAYLOAD_APP="$LAUNCHER_COMPONENT/Payload/ChatGPT Proxy.app"
PROXYBRIDGE_PAYLOAD_APP="$PROXYBRIDGE_COMPONENT/Payload/ProxyBridge.app"
PROXYBRIDGE_PAYLOAD_EXTENSION="$PROXYBRIDGE_PAYLOAD_APP/Contents/Library/SystemExtensions/com.interceptsuite.ProxyBridge.extension.systemextension"
[[ -d "$LAUNCHER_COMPONENT" ]]
[[ -d "$PROXYBRIDGE_COMPONENT" ]]
[[ -f "$EXPANDED_PRODUCT/Distribution" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/options/@customize)' "$EXPANDED_PRODUCT/Distribution")" == "never" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/options/@require-scripts)' "$EXPANDED_PRODUCT/Distribution")" == "false" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/allowed-os-versions/os-version/@min)' "$EXPANDED_PRODUCT/Distribution")" == "$MINIMUM_SYSTEM_VERSION" ]]
[[ "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/choices-outline)' "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/choices-outline/line)' "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/choices-outline/line/@choice)' "$EXPANDED_PRODUCT/Distribution")" == "default" ]]
[[ "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/choices-outline/line/line)' "$EXPANDED_PRODUCT/Distribution")" == "2" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/choices-outline/line/line[1]/@choice)' "$EXPANDED_PRODUCT/Distribution")" == "$LAUNCHER_IDENTIFIER" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/choices-outline/line/line[2]/@choice)' "$EXPANDED_PRODUCT/Distribution")" == "$PROXYBRIDGE_IDENTIFIER" ]]
[[ "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/choice)' "$EXPANDED_PRODUCT/Distribution")" == "3" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/choice[@id='default'])" "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/choice[@id='$LAUNCHER_IDENTIFIER'][@visible='false']/pkg-ref[@id='$LAUNCHER_IDENTIFIER'])" "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/choice[@id='$PROXYBRIDGE_IDENTIFIER'][@visible='false']/pkg-ref[@id='$PROXYBRIDGE_IDENTIFIER'])" "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/pkg-ref[starts-with(normalize-space(text()), '#')])" "$EXPANDED_PRODUCT/Distribution")" == "2" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/pkg-ref[@id='$LAUNCHER_IDENTIFIER'][normalize-space(text())='#ChatGPT-Proxy-Launcher.pkg'])" "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
[[ "$(/usr/bin/xmllint --xpath "count(/installer-gui-script/pkg-ref[@id='$PROXYBRIDGE_IDENTIFIER'][normalize-space(text())='#ProxyBridge.pkg'])" "$EXPANDED_PRODUCT/Distribution")" == "1" ]]
! /usr/bin/grep -Eq 'system\.run|installation-check|volume-check' "$EXPANDED_PRODUCT/Distribution"

/usr/sbin/installer -showChoicesXML -pkg "$PRODUCT_PKG" > "$CHOICES_PLIST"
/usr/bin/plutil -convert json -o "$CHOICES_JSON" "$CHOICES_PLIST"
/usr/bin/jq -e \
    --arg launcherIdentifier "$LAUNCHER_IDENTIFIER" \
    --arg launcherPath "file://localhost${PRODUCT_PKG}#ChatGPT-Proxy-Launcher.pkg" \
    --arg proxyBridgeIdentifier "$PROXYBRIDGE_IDENTIFIER" \
    --arg proxyBridgePath "file://localhost${PRODUCT_PKG}#ProxyBridge.pkg" '
    def resolvedChoice($identifier; $path):
        [.. | objects | select(.choiceIdentifier? == $identifier)] as $choices |
        ($choices | length) == 1 and
        $choices[0].choiceIsEnabled == true and
        $choices[0].choiceIsSelected == 1 and
        $choices[0].pathsOfActivePackagesInChoice == [$path];
    resolvedChoice($launcherIdentifier; $launcherPath) and
    resolvedChoice($proxyBridgeIdentifier; $proxyBridgePath)
' "$CHOICES_JSON" >/dev/null

[[ ! -e "$LAUNCHER_COMPONENT/Scripts" ]]
[[ ! -e "$PROXYBRIDGE_COMPONENT/Scripts" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$LAUNCHER_COMPONENT/PackageInfo")" == "$LAUNCHER_IDENTIFIER" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$LAUNCHER_COMPONENT/PackageInfo")" == "/Applications" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$PROXYBRIDGE_COMPONENT/PackageInfo")" == "$PROXYBRIDGE_IDENTIFIER" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$PROXYBRIDGE_COMPONENT/PackageInfo")" == "/Applications" ]]
PROXYBRIDGE_VERSION=$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$PROXYBRIDGE_COMPONENT/PackageInfo")
[[ "$(/usr/bin/xmllint --xpath "string(/installer-gui-script/pkg-ref[@id='$LAUNCHER_IDENTIFIER']/@version)" "$EXPANDED_PRODUCT/Distribution")" == "$PRODUCT_VERSION" ]]
[[ "$(/usr/bin/xmllint --xpath "string(/installer-gui-script/pkg-ref[@id='$PROXYBRIDGE_IDENTIFIER']/@version)" "$EXPANDED_PRODUCT/Distribution")" == "$PROXYBRIDGE_VERSION" ]]
/usr/bin/lsbom -s "$LAUNCHER_COMPONENT/Bom" | /usr/bin/grep -Fx './ChatGPT Proxy.app' >/dev/null
/usr/bin/lsbom -s "$PROXYBRIDGE_COMPONENT/Bom" | /usr/bin/grep -Fx './ProxyBridge.app' >/dev/null
[[ -d "$LAUNCHER_PAYLOAD_APP" ]]
[[ -d "$PROXYBRIDGE_PAYLOAD_APP" ]]
[[ -d "$PROXYBRIDGE_PAYLOAD_EXTENSION" ]]
"$PROJECT_DIR/scripts/validate-proxybridge-installer.sh" "$LAUNCHER_PAYLOAD_APP/Contents/Resources/ProxyBridge-v4.0.0-Universal-Installer.pkg"
/usr/bin/codesign --verify --deep --strict "$PROXYBRIDGE_PAYLOAD_APP"
/usr/bin/codesign --verify --strict "$PROXYBRIDGE_PAYLOAD_EXTENSION"

trap - EXIT
cleanup

print "Verified tests, profile isolation, signatures, hashes, universal architectures, and unified installer payload."
