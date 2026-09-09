#!/usr/bin/env bash
#
# depend-forward.sh
#
# Question: what does each package depend on?
#
# Reads package.sh's raw-relations.tsv (already version-stripped,
# continuation-joined, one relation field per line) and explodes the
# comma/pipe-separated text into one edge per line:
#
#   package   dependency   relation   alternative
#
# relation    is Depends / Pre-Depends / Recommends / Suggests
# alternative is "primary" or "alt" (for "a | b" alternative groups)
#
# Does NOT touch dpkg status directly -- that's package.sh's job.
# Does NOT reduce to a count -- that's a derived aggregation, done
# separately (see edges-forward-counts.tsv, built at the bottom).
#
set -euo pipefail

usage() { echo "Usage: $0 --raw-relations FILE --out-dir DIR" >&2; exit 1; }

RAW=""; OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --raw-relations) RAW="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$RAW" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

EDGES="$OUT_DIR/edges-forward.tsv"
COUNTS="$OUT_DIR/edges-forward-counts.tsv"

awk -F'\t' -v OFS='\t' '
function trim(s) { gsub(/^ +| +$/, "", s); return s }
{
    pkg = $1; relation = $2
    n = split($3, deps, / *, */)
    for (d = 1; d <= n; d++) {
        m = split(deps[d], alts, / *\| */)
        for (a = 1; a <= m; a++) {
            tok = trim(alts[a])
            if (tok != "") print pkg, tok, relation, (a==1 ? "primary" : "alt")
        }
    }
}' "$RAW" > "$EDGES"

# Derived aggregation: forward-dep count per package, counting only
# Depends/Pre-Depends (the structural relations) so a package with a
# long Recommends list doesn't look more load-bearing than it is.
awk -F'\t' '$3 == "Depends" || $3 == "Pre-Depends" {c[$1]++} END {for (p in c) print p"\t"c[p]}' \
    "$EDGES" | sort > "$COUNTS"

echo "depend-forward.sh: $(wc -l < "$EDGES") edges, $(wc -l < "$COUNTS") packages with structural forward deps" >&2
