#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$PROJECT_DIR/build/ChatGPT Proxy.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
"$PROJECT_DIR/scripts/build.sh"
mkdir -p "$DIST_DIR"
ARCHIVE_DIR="$PROJECT_DIR/build/legacy-distributions"
for old in "$DIST_DIR"/ChatGPT-Proxy-*-Universal.pkg(N) "$DIST_DIR/install.sh"(N); do
    mkdir -p "$ARCHIVE_DIR"
    mv "$old" "$ARCHIVE_DIR/${old:t}"
done
STAGE=$(/usr/bin/mktemp -d "$DIST_DIR/.zip-output.XXXXXX")
trap '/bin/rm -rf "$STAGE"' EXIT
ZIP="ChatGPT-Proxy-${VERSION}-Universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGE/$ZIP"
mv -f "$STAGE/$ZIP" "$DIST_DIR/$ZIP"
print "$DIST_DIR/$ZIP"
