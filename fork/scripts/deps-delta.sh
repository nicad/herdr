#!/usr/bin/env bash
# Prints the Cargo.lock dependency delta between two revisions.
# First line is a machine-readable summary; sources other than crates.io are listed last.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: deps-delta.sh OLD NEW" >&2; exit 2; }
OLD=$1
NEW=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

CRATES_IO='registry+https://github.com/rust-lang/crates.io-index'

# One line per package: name version source ("path" for workspace members).
packages() {
    git show "$1:Cargo.lock" | awk '
        function unq(s) { gsub(/"/, "", s); return s }
        function flush() {
            if (name != "") printf "%s %s %s\n", name, ver, (src == "" ? "path" : src)
            name = ""; ver = ""; src = ""
        }
        /^\[\[package\]\]/ { flush() }
        /^name = /         { name = unq($3) }
        /^version = /      { ver = unq($3) }
        /^source = /       { src = unq($3) }
        END                { flush() }
    ' | sort
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/deps-delta.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

packages "$OLD" > "$TMP/old"
packages "$NEW" > "$TMP/new"
cut -d' ' -f1 "$TMP/old" | sort -u > "$TMP/old-names"
cut -d' ' -f1 "$TMP/new" | sort -u > "$TMP/new-names"

comm -13 "$TMP/old-names" "$TMP/new-names" > "$TMP/added"
comm -23 "$TMP/old-names" "$TMP/new-names" > "$TMP/removed"
# Lines present only in NEW whose crate already existed: version or source changed.
comm -13 "$TMP/old" "$TMP/new" | while read -r name ver src; do
    if grep -qxF "$name" "$TMP/old-names"; then
        old_ver=$(awk -v n="$name" '$1 == n { print $2 }' "$TMP/old" | paste -sd, -)
        echo "$name $old_ver -> $ver"
    fi
done > "$TMP/changed"

n() { wc -l < "$1" | tr -d ' '; }
echo "added=$(n "$TMP/added") removed=$(n "$TMP/removed") changed=$(n "$TMP/changed")"
echo

echo "## added"
while read -r name; do grep "^$name " "$TMP/new"; done < "$TMP/added"
echo
echo "## removed"
while read -r name; do grep "^$name " "$TMP/old"; done < "$TMP/removed"
echo
echo "## changed"
cat "$TMP/changed"
echo
echo "## sources other than crates.io in NEW (expected: none)"
grep -v " $CRATES_IO\$" "$TMP/new" | grep -v ' path$' || echo "none"
