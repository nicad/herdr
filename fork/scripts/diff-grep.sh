#!/usr/bin/env bash
# Reads a unified diff on stdin and prints added lines matching the patterns file.
# Files whose path matches EXCLUDE_REGEX (awk ERE) are skipped.
# Output: a tab-separated "count<TAB>label" summary, a blank line, then the hits grouped by label.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: git diff A B | diff-grep.sh PATTERNS_FILE [EXCLUDE_REGEX]" >&2; exit 2; }

awk -v patfile="$1" -v exclude="${2:-}" '
BEGIN {
    n = 0
    while ((getline line < patfile) > 0) {
        if (line ~ /^[ \t]*(#|$)/) continue
        split(line, parts, "\t")
        pats[++n] = parts[1]
        labels[n] = (parts[2] == "" ? parts[1] : parts[2])
        counts[n] = 0
    }
    close(patfile)
}
/^\+\+\+ / { file = substr($0, 7); skip = (exclude != "" && file ~ exclude); next }
/^@@ /     { split($0, h, " "); split(h[3], r, ","); lineno = substr(r[1], 2) + 0; next }
/^\+/ {
    if (skip) { lineno++; next }
    text = substr($0, 2)
    for (i = 1; i <= n; i++) {
        if (text ~ pats[i]) {
            counts[i]++
            hits[i] = hits[i] file ":" lineno ": " text "\n"
        }
    }
    lineno++
    next
}
/^-/  { next }
/^ /  { lineno++; next }
END {
    for (i = 1; i <= n; i++) if (counts[i] > 0) printf "%d\t%s\n", counts[i], labels[i]
    print ""
    for (i = 1; i <= n; i++) if (counts[i] > 0) printf "## %s (%d)\n%s\n", labels[i], counts[i], hits[i]
}'
