#!/usr/bin/env bash
# Static checks on a built herdr binary. Writes OUT_DIR/*.txt and, when BASELINE_DIR is given,
# fails if any baseline file differs. Works on macOS (otool/nm) and Linux (readelf/nm).
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: binary-check.sh BIN OUT_DIR [BASELINE_DIR]" >&2; exit 2; }
BIN=$1
OUT=$2
BASE=${3:-}
[ -x "$BIN" ] || { echo "no executable at $BIN (run: make -C fork build)" >&2; exit 2; }
mkdir -p "$OUT"

case $(uname -s) in
Darwin)
    otool -L "$BIN" | tail -n +2 | awk '{ print $1 }' | sort > "$OUT/linked-libs.txt"
    nm -u -j "$BIN" | sort -u > "$OUT/undefined-symbols.txt"
    codesign -dvvv "$BIN" > "$OUT/codesign.txt" 2>&1 || true
    ;;
Linux)
    readelf -d "$BIN" | awk '/NEEDED/ { gsub(/[][]/, "", $5); print $5 }' | sort > "$OUT/linked-libs.txt"
    nm -D -u "$BIN" | awk '{ print $NF }' | sort -u > "$OUT/undefined-symbols.txt"
    ;;
*)
    echo "unsupported OS: $(uname -s)" >&2
    exit 2
    ;;
esac

# Symbols that would indicate keychain, TCC, dynamic loading, debugging or shell use.
grep -E '^_?(Sec(Item|Keychain|Access|Trust|Key|Code|Task)[A-Za-z]*|LA(Context|Policy)[A-Za-z]*|SSLCreate[A-Za-z]*|dlopen|dlsym|AXIsProcessTrusted|CGWindowList[A-Za-z]*|CGDisplayCreateImage|IOHIDRequestAccess|AVCaptureDevice[A-Za-z]*|CLLocationManager[A-Za-z]*|ptrace|task_for_pid|csops|posix_spawn[a-z_]*|execve|execvp|system|popen|keyctl|connect|socket|bind)(@.*)?$' \
    "$OUT/undefined-symbols.txt" > "$OUT/flagged-symbols.txt" || true

# grep exits 1 on no match, which pipefail would turn into a silent exit; an empty file is a valid result.
strings -n 8 "$BIN" | { grep -oE 'https?://[A-Za-z0-9._/-]+' || true; } | sort -u > "$OUT/urls.txt"
strings -n 2 "$BIN" \
    | { grep -E '^(/usr/bin/[a-z-]+|/bin/[a-z]+|/usr/local/bin/[a-z-]+|osascript|open|pbcopy|pbpaste|launchctl|afplay|terminal-notifier|notify-send|xdg-open|wl-copy|xclip|xsel|ssh|scp|git|curl|sh|bash|zsh|powershell|powershell\.exe|cmd\.exe)$' || true; } \
    | sort -u > "$OUT/exec-strings.txt"

"$BIN" --version > "$OUT/version.txt" 2>&1 || true
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$BIN"; else shasum -a 256 "$BIN"; fi | awk '{ print $1 }' > "$OUT/sha256.txt"

echo "binary-check: wrote $OUT ($(cat "$OUT/version.txt"), sha256 $(cat "$OUT/sha256.txt"))"
[ -n "$BASE" ] || exit 0

if [ ! -d "$BASE" ]; then
    echo "no baseline at $BASE; review $OUT then run: make -C fork baseline" >&2
    exit 1
fi

changed=0
for f in linked-libs undefined-symbols flagged-symbols urls exec-strings; do
    if diff -u "$BASE/$f.txt" "$OUT/$f.txt" > "$OUT/$f.diff"; then
        rm -f "$OUT/$f.diff"
    else
        echo "CHANGED: $f (see $OUT/$f.diff)"
        changed=1
    fi
done

if [ $changed -eq 0 ]; then
    echo "binary-check: matches baseline"
else
    echo "binary-check: review the diffs above, then accept with: make -C fork baseline" >&2
    exit 1
fi
