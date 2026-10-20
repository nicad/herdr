#!/usr/bin/env bash
# Writes a review bundle for the upstream range OLD..NEW under REPORTS_DIR/<date>_<old>_<new>/.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: sync-report.sh OLD NEW REPORTS_DIR" >&2; exit 2; }
OLD=$1
NEW=$2
REPORTS=$3

HERE=$(cd "$(dirname "$0")" && pwd)
FORK=$(dirname "$HERE")
ROOT=$(dirname "$FORK")
cd "$ROOT"

[ -n "$OLD" ] || { echo "OLD is empty: no merge-base with upstream found; run 'make fetch' or pass OLD=<rev>" >&2; exit 2; }
for rev in "$OLD" "$NEW"; do
    git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || { echo "unknown revision: $rev" >&2; exit 2; }
done

OLD_SHA=$(git rev-parse --short "$OLD")
NEW_SHA=$(git rev-parse --short "$NEW")
DIR="$REPORTS/$(date +%Y-%m-%d)_${OLD_SHA}_${NEW_SHA}"
mkdir -p "$DIR"

count() { wc -l < "$1" | tr -d ' '; }

git log --oneline "$OLD..$NEW" > "$DIR/commits.txt"
git diff --stat "$OLD" "$NEW" > "$DIR/stat.txt"
git diff --name-status --diff-filter=A "$OLD" "$NEW" > "$DIR/new-files.txt"
git diff --numstat "$OLD" "$NEW" | awk '$1 == "-" { print $3 }' > "$DIR/binaries.txt"

# Watched paths: git pathspecs, comments and blank lines stripped. Word splitting is intended.
WATCH=$(grep -vE '^[[:space:]]*(#|$)' "$FORK/watchlist.txt")
# shellcheck disable=SC2086
git diff --name-status "$OLD" "$NEW" -- $WATCH > "$DIR/watchlist-files.txt"
# shellcheck disable=SC2086
git diff "$OLD" "$NEW" -- $WATCH > "$DIR/watchlist.diff"

"$HERE/deps-delta.sh" "$OLD" "$NEW" > "$DIR/deps-delta.txt"

git diff "$OLD" "$NEW" -- \
    vendor/libghostty-vt.vendor.json vendor/libghostty-vt.patches.md vendor/patches \
    'vendor/*.zon' 'vendor/*.zon.nix' vendor/libghostty-vt/build.zig \
    build.rs crates/ghostty-vt/build.rs flake.lock > "$DIR/vendor-and-build.diff"

# Documentation, tests and skills do not ship in the binary; their hits are noise.
FLAG_EXCLUDE='^(docs/|skills/|tests/|.*/tests/|.*_tests?\.rs$|.*\.mdx?$)'
git diff "$OLD" "$NEW" | "$HERE/diff-grep.sh" "$FORK/diff-patterns.txt" "$FLAG_EXCLUDE" > "$DIR/flags.txt"

vendor_commit() {
    git show "$1:vendor/libghostty-vt.vendor.json" 2>/dev/null | awk -F'"' '/source_commit/ { print $4 }'
}
OLD_VENDOR=$(vendor_commit "$OLD")
NEW_VENDOR=$(vendor_commit "$NEW")

{
    echo "# Upstream sync report $OLD_SHA..$NEW_SHA ($(date +%Y-%m-%d))"
    echo
    echo "- commits: $(count "$DIR/commits.txt")"
    echo "- files changed: $(git diff --name-only "$OLD" "$NEW" | wc -l | tr -d ' ')"
    echo "- new files: $(count "$DIR/new-files.txt"); binary files: $(count "$DIR/binaries.txt")"
    echo "- watched files touched: $(count "$DIR/watchlist-files.txt")"
    echo "- dependencies: $(head -1 "$DIR/deps-delta.txt")"
    if [ "$OLD_VENDOR" = "$NEW_VENDOR" ]; then
        echo "- vendored libghostty-vt: unchanged ($NEW_VENDOR)"
    else
        echo "- vendored libghostty-vt: CHANGED $OLD_VENDOR -> $NEW_VENDOR"
        echo "  compare: https://github.com/ghostty-org/ghostty/compare/$OLD_VENDOR...$NEW_VENDOR"
        echo "  advisories: https://github.com/ghostty-org/ghostty/security/advisories"
    fi
    echo "- flagged added lines by pattern:"
    awk -F'\t' 'NF == 2 { printf "  - %s: %s\n", $2, $1 } /^$/ { exit }' "$DIR/flags.txt"
    echo
    echo "Files in this directory: commits.txt stat.txt new-files.txt binaries.txt watchlist-files.txt watchlist.diff deps-delta.txt vendor-and-build.diff flags.txt"
    echo
    echo "Next: review against fork/REVIEW.md, for example:"
    echo "  claude \"Follow fork/REVIEW.md for report $DIR\""
} > "$DIR/summary.md"

cat "$DIR/summary.md"
