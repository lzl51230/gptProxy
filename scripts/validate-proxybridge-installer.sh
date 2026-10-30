#!/bin/zsh
set -euo pipefail

EXPECTED_SHA256=c375fff53349f009e7bedacb47528642041776f859f58972bfad02b190ef7dec
SOURCE_INSTALLER=${1:?Usage: validate-proxybridge-installer.sh source.pkg [snapshot.pkg]}
VALIDATED_INSTALLER=${2:-$SOURCE_INSTALLER}

if [[ ! -f "$SOURCE_INSTALLER" ]]; then
    print -u2 "ProxyBridge installer not found: $SOURCE_INSTALLER"
    exit 1
fi

if [[ "$VALIDATED_INSTALLER" != "$SOURCE_INSTALLER" ]]; then
    /bin/mkdir -p "${VALIDATED_INSTALLER:h}"
    /bin/chmod 700 "${VALIDATED_INSTALLER:h}"
    /bin/cp "$SOURCE_INSTALLER" "$VALIDATED_INSTALLER"
    /bin/chmod 600 "$VALIDATED_INSTALLER"
fi

actual_sha256=$(/usr/bin/shasum -a 256 "$VALIDATED_INSTALLER" | /usr/bin/awk '{print $1}')
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
    print -u2 "ProxyBridge installer SHA-256 mismatch."
    exit 1
fi

if ! /usr/sbin/pkgutil --check-signature "$VALIDATED_INSTALLER" >/dev/null; then
    print -u2 "ProxyBridge installer package signature is invalid."
    exit 1
fi

print "$VALIDATED_INSTALLER"
