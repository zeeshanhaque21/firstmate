#!/usr/bin/env bash
# fm-install-wt.sh - install CI's pinned, verified Worktrunk (wt) build.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need wt (spawn and teardown worktree handling). Same pin/checksum discipline
# as fm-install-herdr.sh: official release URL, exact asset, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   fm-install-wt.sh <destination-directory>
#
# Pins Worktrunk v0.82.0, the version the wt command lines in bin/ were verified
# against. Linux assets are the static musl builds.
set -eu

FM_WT_CI_VERSION=0.82.0
FM_WT_CI_TAG="v${FM_WT_CI_VERSION}"
# Bounded download ceiling (bytes). Official 0.82.0 archives are under 9 MiB.
FM_WT_CI_MAX_BYTES=15000000
FM_WT_CI_REPO=max-sixty/worktrunk

die() {
  printf 'fm-install-wt.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-wt.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    TARGET=x86_64-unknown-linux-musl
    SHA256=d1e38cf36d8c14ef0682a6d6617f8a512b1a971feb3dfa437419d00136e19a3e
    ;;
  Linux-aarch64|Linux-arm64)
    TARGET=aarch64-unknown-linux-musl
    SHA256=b907f891bc051dcfc13fa479194e156b356f434a37103522ea1fe1b7ded899b5
    ;;
  Darwin-arm64)
    TARGET=aarch64-apple-darwin
    SHA256=6945bc82e0513d0b974c99fb1d30de24e448697fd533ed6b3f442c66a1b3620c
    ;;
  Darwin-x86_64)
    TARGET=x86_64-apple-darwin
    SHA256=d9c87668baa1aad2b44d5bfb08074609c5e4a186a0948dfed6e65d6e6c5a7744
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Worktrunk assets are linux/darwin x86_64 and arm64"
    ;;
esac

ARCHIVE=worktrunk-${TARGET}.tar.xz
URL="https://github.com/${FM_WT_CI_REPO}/releases/download/${FM_WT_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-wt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-wt.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$FM_WT_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $FM_WT_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Worktrunk archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

tar -xJf "$TMP/$ARCHIVE" -C "$TMP" || die "could not extract $ARCHIVE (tar with xz support is required)"
# Archive layout: worktrunk-<target>/wt (verified for v0.82.0).
BIN="$TMP/worktrunk-${TARGET}/wt"
[ -f "$BIN" ] || die "archive $ARCHIVE did not contain worktrunk-${TARGET}/wt"

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/wt"

installed_version=$("$DESTINATION/wt" --version 2>/dev/null | tr -d '[:space:]')
# wt prints "wt v0.82.0" on --version.
case "$installed_version" in
  "wtv${FM_WT_CI_VERSION}"|"wt${FM_WT_CI_VERSION}") ;;
  *)
    die "installed wt version is '${installed_version:-<empty>}', expected exact pin v${FM_WT_CI_VERSION}"
    ;;
esac

printf 'fm-install-wt.sh: installed wt %s to %s\n' \
  "$installed_version" "$DESTINATION/wt" >&2
"$DESTINATION/wt" --version
