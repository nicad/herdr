#!/usr/bin/env bash
# Installs the pinned Zig release into DEST_DIR/zig-<version>/ after verifying its checksum.
# herdr requires exactly this Zig version to build the vendored libghostty-vt.
# Checksums were copied from https://ziglang.org/download/index.json on 2026-10-20 and are
# pinned here so a changed index cannot change what gets accepted.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: zig-install.sh VERSION DEST_DIR" >&2; exit 2; }
VERSION=$1
DEST=$2

case "$(uname -s)-$(uname -m)" in
Linux-x86_64)  target=x86_64-linux;  sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
Darwin-arm64)  target=aarch64-macos; sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
Darwin-x86_64) target=x86_64-macos;  sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
*)
    echo "no pinned checksum for $(uname -s)-$(uname -m); add one from https://ziglang.org/download/index.json" >&2
    exit 2
    ;;
esac

[ "$VERSION" = "0.16.0" ] || { echo "pinned checksums are for 0.16.0, not $VERSION; update this script" >&2; exit 2; }

ZIG="$DEST/zig-$VERSION/zig"
if [ -x "$ZIG" ] && [ "$("$ZIG" version)" = "$VERSION" ]; then
    echo "zig $VERSION already installed at $ZIG"
    exit 0
fi

mkdir -p "$DEST"
archive="$DEST/zig-$target-$VERSION.tar.xz"
url="https://ziglang.org/download/$VERSION/zig-$target-$VERSION.tar.xz"
echo "downloading $url"
curl -fsSL --proto '=https' --retry 3 -o "$archive" "$url"

if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$archive" | awk '{ print $1 }'); else actual=$(shasum -a 256 "$archive" | awk '{ print $1 }'); fi
if [ "$actual" != "$sha" ]; then
    echo "checksum mismatch for $archive" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    rm -f "$archive"
    exit 1
fi

rm -rf "$DEST/zig-$target-$VERSION" "$DEST/zig-$VERSION"
tar -xJf "$archive" -C "$DEST"
mv "$DEST/zig-$target-$VERSION" "$DEST/zig-$VERSION"
rm -f "$archive"
echo "installed zig $("$ZIG" version) at $ZIG"
