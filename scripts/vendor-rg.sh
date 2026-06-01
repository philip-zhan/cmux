#!/usr/bin/env bash
# Vendor a pinned, universal ripgrep (rg) binary into the cmux app bundle.
#
# Global search and quick-open shell out to `rg`. Bundling a universal
# (arm64 + x86_64) build makes both features work out of the box on any Mac,
# while the in-app resolvers still prefer a user-configured or PATH `rg` first
# and only fall back to this bundled copy when nothing else is found.
#
# The binary is intentionally NOT committed to git (see .gitignore); it is
# fetched on first setup/build, mirroring how the GhosttyKit/cmuxd artifacts are
# generated rather than checked in. The download is checksum-pinned and cached.
#
# Usage:
#   scripts/vendor-rg.sh                 # install to Resources/bin/rg
#   scripts/vendor-rg.sh --dest PATH     # install to a specific path
#   scripts/vendor-rg.sh --force         # re-install even if already current
set -euo pipefail

RG_VERSION="15.1.0"
SHA256_ARM64="378e973289176ca0c6054054ee7f631a065874a352bf43f0fa60ef079b6ba715"
SHA256_X86_64="64811cb24e77cac3057d6c40b63ac9becf9082eedd54ca411b475b755d334882"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/Resources/bin/rg"
CACHE_DIR="${CMUX_VENDOR_CACHE:-$HOME/Library/Caches/cmux-vendor/ripgrep}"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "vendor-rg.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Fast, idempotent skip: a usable copy is present (universal, both slices) and
# already at the pinned version. This keeps the per-build invocation cheap.
if [ "$FORCE" != "1" ] && [ -x "$DEST" ]; then
  archs="$(lipo -archs "$DEST" 2>/dev/null || true)"
  version_line="$("$DEST" --version 2>/dev/null | head -1 || true)"
  if [[ "$archs" == *arm64* && "$archs" == *x86_64* && "$version_line" == *"ripgrep $RG_VERSION"* ]]; then
    exit 0
  fi
fi

verify_sha() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "vendor-rg.sh: checksum mismatch for $(basename "$file")" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    return 1
  fi
}

# Extract the `rg` binary for one target triple into $out, using a checksum-
# verified, cached tarball (re-downloaded if missing or corrupt).
fetch_slice() {
  local triple="$1" sha="$2" out="$3"
  local tarball="$CACHE_DIR/ripgrep-$RG_VERSION-$triple.tar.gz"
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$tarball" ] || ! verify_sha "$tarball" "$sha" >/dev/null 2>&1; then
    local url="https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/ripgrep-$RG_VERSION-$triple.tar.gz"
    echo "vendor-rg.sh: downloading $url" >&2
    curl -fsSL --retry 3 -o "$tarball.tmp" "$url"
    mv "$tarball.tmp" "$tarball"
  fi
  verify_sha "$tarball" "$sha"
  tar xzOf "$tarball" "ripgrep-$RG_VERSION-$triple/rg" > "$out"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch_slice "aarch64-apple-darwin" "$SHA256_ARM64" "$WORK/rg-arm64"
fetch_slice "x86_64-apple-darwin"  "$SHA256_X86_64" "$WORK/rg-x86_64"

lipo -create -output "$WORK/rg-universal" "$WORK/rg-arm64" "$WORK/rg-x86_64"
chmod 755 "$WORK/rg-universal"

mkdir -p "$(dirname "$DEST")"
mv "$WORK/rg-universal" "$DEST"
echo "vendor-rg.sh: installed universal ripgrep $RG_VERSION -> $DEST" >&2
