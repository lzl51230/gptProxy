#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$BUILD_DIR/ChatGPT Proxy.app"
PACKAGE_WORK_DIR="$BUILD_DIR/package"
COMPONENTS_DIR="$PACKAGE_WORK_DIR/components"
PROXYBRIDGE_EXPANDED_DIR="$PACKAGE_WORK_DIR/proxybridge-expanded"
PROXYBRIDGE_SNAPSHOT_DIR="$PACKAGE_WORK_DIR/private"
DISTRIBUTION_TEMPLATE="$PROJECT_DIR/Resources/Installer/Distribution.xml"
DISTRIBUTION_PATH="$PACKAGE_WORK_DIR/Distribution.xml"
PROXYBRIDGE_INSTALLER="$PROJECT_DIR/Resources/ProxyBridge-v4.1.0-Universal-Installer.pkg"
PROXYBRIDGE_SNAPSHOT="$PROXYBRIDGE_SNAPSHOT_DIR/ProxyBridge-v4.1.0-Universal-Installer.pkg"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
PROXYBRIDGE_IDENTIFIER=com.interceptsuite.ProxyBridge
PRODUCT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
LAUNCHER_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
MINIMUM_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")
PRODUCT_PKG="$DIST_DIR/ChatGPT-Proxy-${PRODUCT_VERSION}-Universal.pkg"
LEGACY_DMG="$DIST_DIR/ChatGPT-Proxy-${PRODUCT_VERSION}-Universal.dmg"
PRODUCT_STAGE_DIR=

cleanup() {
    if [[ -n "$PRODUCT_STAGE_DIR" && -d "$PRODUCT_STAGE_DIR" ]]; then
        /bin/rm -rf "$PRODUCT_STAGE_DIR"
    fi
    if [[ -d "$PROXYBRIDGE_SNAPSHOT_DIR" ]]; then
        /bin/rm -rf "$PROXYBRIDGE_SNAPSHOT_DIR"
    fi
}
trap cleanup EXIT

if [[ ! "$PRODUCT_VERSION" =~ '^[0-9]+([.][0-9]+)*$' ||
      ! "$MINIMUM_SYSTEM_VERSION" =~ '^[0-9]+([.][0-9]+)*$' ||
      ! "$LAUNCHER_IDENTIFIER" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]]; then
    print -u2 "Invalid launcher metadata in $INFO_PLIST"
    exit 1
fi

/bin/rm -rf "$PACKAGE_WORK_DIR"
/bin/mkdir -p "$COMPONENTS_DIR" "$PROXYBRIDGE_SNAPSHOT_DIR" "$DIST_DIR"
/bin/chmod 700 "$PROXYBRIDGE_SNAPSHOT_DIR"
"$PROJECT_DIR/scripts/validate-proxybridge-installer.sh" \
    "$PROXYBRIDGE_INSTALLER" \
    "$PROXYBRIDGE_SNAPSHOT" >/dev/null
PROXYBRIDGE_INSTALLER_SOURCE="$PROXYBRIDGE_SNAPSHOT" \
    "$PROJECT_DIR/scripts/build.sh"

/usr/bin/pkgbuild \
    --component "$APP_DIR" \
    --install-location /Applications \
    --identifier "$LAUNCHER_IDENTIFIER" \
    --version "$PRODUCT_VERSION" \
    "$COMPONENTS_DIR/ChatGPT-Proxy-Launcher.pkg"

/usr/sbin/pkgutil --expand "$PROXYBRIDGE_SNAPSHOT" "$PROXYBRIDGE_EXPANDED_DIR"
proxybridge_components=()
for package_info in "$PROXYBRIDGE_EXPANDED_DIR"/*.pkg/PackageInfo(N); do
    if [[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$package_info")" == "$PROXYBRIDGE_IDENTIFIER" ]]; then
        proxybridge_components+=("${package_info:h}")
    fi
done
(( ${#proxybridge_components[@]} == 1 )) || {
    print -u2 "Expected exactly one $PROXYBRIDGE_IDENTIFIER component package."
    exit 1
}
PROXYBRIDGE_COMPONENT_DIR=${proxybridge_components[1]}
PROXYBRIDGE_PACKAGE_INFO="$PROXYBRIDGE_COMPONENT_DIR/PackageInfo"
PROXYBRIDGE_VERSION=$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$PROXYBRIDGE_PACKAGE_INFO")
[[ "$PROXYBRIDGE_VERSION" =~ '^[0-9]+([.][0-9]+)*$' ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$PROXYBRIDGE_PACKAGE_INFO")" == "/Applications" ]]
/usr/sbin/pkgutil --flatten "$PROXYBRIDGE_COMPONENT_DIR" "$COMPONENTS_DIR/ProxyBridge.pkg"

/usr/bin/sed \
    -e "s/__PRODUCT_VERSION__/$PRODUCT_VERSION/g" \
    -e "s/__LAUNCHER_IDENTIFIER__/$LAUNCHER_IDENTIFIER/g" \
    -e "s/__MINIMUM_SYSTEM_VERSION__/$MINIMUM_SYSTEM_VERSION/g" \
    -e "s/__PROXYBRIDGE_IDENTIFIER__/$PROXYBRIDGE_IDENTIFIER/g" \
    -e "s/__PROXYBRIDGE_VERSION__/$PROXYBRIDGE_VERSION/g" \
    "$DISTRIBUTION_TEMPLATE" > "$DISTRIBUTION_PATH"
/usr/bin/xmllint --noout "$DISTRIBUTION_PATH"

PRODUCT_STAGE_DIR=$(/usr/bin/mktemp -d "$DIST_DIR/.package-output.XXXXXX")
STAGED_PRODUCT_PKG="$PRODUCT_STAGE_DIR/${PRODUCT_PKG:t}"
/usr/bin/productbuild \
    --distribution "$DISTRIBUTION_PATH" \
    --package-path "$COMPONENTS_DIR" \
    "$STAGED_PRODUCT_PKG"
/bin/mv -f "$STAGED_PRODUCT_PKG" "$PRODUCT_PKG"
/bin/rm -f "$LEGACY_DMG"

/bin/cp "$PROJECT_DIR/scripts/install.sh" "$DIST_DIR/install.sh"
print "$PRODUCT_PKG"
