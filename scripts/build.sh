#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/ChatGPT Proxy.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

rm -rf "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64" "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

"$PROJECT_DIR/scripts/build-core.sh" aarch64-apple-darwin
"$PROJECT_DIR/scripts/build-core.sh" x86_64-apple-darwin

GPTPROXY_RUST_TARGET=aarch64-apple-darwin swift build -c release --arch arm64 --scratch-path "$BUILD_DIR/arm64"
GPTPROXY_RUST_TARGET=x86_64-apple-darwin swift build -c release --arch x86_64 --scratch-path "$BUILD_DIR/x86_64"

ARM_PRODUCTS=$(swift build -c release --arch arm64 --scratch-path "$BUILD_DIR/arm64" --show-bin-path)
INTEL_PRODUCTS=$(swift build -c release --arch x86_64 --scratch-path "$BUILD_DIR/x86_64" --show-bin-path)
/usr/bin/lipo -create "$ARM_PRODUCTS/ChatGPTProxyApp" "$INTEL_PRODUCTS/ChatGPTProxyApp" -output "$MACOS_DIR/ChatGPTProxyLauncher"
/usr/bin/lipo -create "$ARM_PRODUCTS/DNSProtectionHelper" "$INTEL_PRODUCTS/DNSProtectionHelper" -output "$RESOURCES_DIR/DNSProtectionHelper"
/bin/chmod 755 "$RESOURCES_DIR/DNSProtectionHelper"
/usr/bin/codesign --force --sign - "$RESOURCES_DIR/DNSProtectionHelper"
/bin/chmod 755 "$MACOS_DIR/ChatGPTProxyLauncher"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
/bin/cp "$PROJECT_DIR/Resources/ChatGPT-Only.pbprofile" "$RESOURCES_DIR/ChatGPT-Only.pbprofile"
/bin/cp "$PROJECT_DIR/Resources/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
RUST_SYSROOT=$(cd "$PROJECT_DIR" && "$HOME/.cargo/bin/rustc" --print sysroot)
/bin/cp "$RUST_SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$RESOURCES_DIR/Rust-Std-Notices.html"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

print "$APP_DIR"
