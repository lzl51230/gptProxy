#!/bin/zsh
set -euo pipefail

EXPECTED_SHA256=df64a77b9bd1a6f9d41b4c7e2169dbf86c23441c6751b65a0a55c016a6253d0a
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
