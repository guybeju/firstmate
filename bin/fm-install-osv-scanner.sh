#!/usr/bin/env bash
# fm-install-osv-scanner.sh - install the pinned, verified osv-scanner build.
#
# Downloads the official GitHub release binary for the host OS/arch, verifies
# its per-asset SHA-256 pin, and installs it as osv-scanner in the destination
# directory. Supported platforms: linux amd64/x86_64, linux arm64/aarch64,
# darwin amd64/x86_64, darwin arm64/aarch64. Pins come from the official
# osv-scanner_SHA256SUMS file on the v2.7.1 release
# (https://github.com/google/osv-scanner/releases/tag/v2.7.1). Verification
# uses sha256sum when present, otherwise shasum -a 256. An unsupported OS/arch
# or a missing pin fails without downloading.
#
# Usage:
#   fm-install-osv-scanner.sh <destination-directory>
#   fm-install-osv-scanner.sh --required-version   print the osv-scanner pin
set -eu

VERSION=2.7.1

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$VERSION"
  exit 0
fi

die() {
  printf 'fm-install-osv-scanner.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-osv-scanner.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are from osv-scanner_SHA256SUMS on the official v2.7.1 release
# (https://github.com/google/osv-scanner/releases/download/v2.7.1/osv-scanner_SHA256SUMS).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ASSET=osv-scanner_linux_amd64
    SHA256=fb7dab19a8bd9bbe5c3189f09d4b7ee1820c9553a23bac202648a56efd2f6ee8
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=osv-scanner_linux_arm64
    SHA256=983d22fbad9724514e3fcc6acc83b5fa64c5ffa6b0d9f510028f22c1b223ff81
    ;;
  Darwin-x86_64|Darwin-amd64)
    ASSET=osv-scanner_darwin_amd64
    SHA256=b8420d5485ba792626315f1bf9a5a2046e971d38eea75bf9090c38852dbc3b1b
    ;;
  Darwin-arm64|Darwin-aarch64)
    ASSET=osv-scanner_darwin_arm64
    SHA256=b22c02877a811c8f78956e8643efa554932b7378f590d13f8e97d4e9448a29f3
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://github.com/google/osv-scanner/releases/download/v${VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-osv-scanner.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ASSET"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-osv-scanner.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-osv-scanner.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the osv-scanner binary"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-osv-scanner.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ASSET" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/osv-scanner"
"$DESTINATION/osv-scanner" --version
