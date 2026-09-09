#!/usr/bin/env bash
#
# depend-reverse.sh
#
# Question: which installed packages depend on this package?
#
# Inverts edges-forward.tsv. Before inverting, resolves each
# dependency name against provides.tsv: "Depends: awk" doesn't mean
# a package literally named "awk" is installed -- it means something
# satisfying the virtual name "awk" is installed (mawk, in a base
# Debian system). Skipping this step would silently drop real edges
# and misreport reverse-dep counts for whatever provides the virtual
# name (section 7 of the v0.4 spec: this is a graph-correctness
# requirement, not an enhancement).
#
# Only Depends/Pre-Depends count toward rdep_count -- Recommends and
# Suggests are optional by Debian policy and would inflate the
# structural signal used for candidate analysis. They're still in
# edges-reverse.tsv (relation column preserved) for anyone who wants
# to look at them specifically.
#
set -euo pipefail

usage() { echo "Usage: $0 --edges-forward FILE --packages FILE --provides FILE --out-dir DIR" >&2; exit 1; }

EDGES=""; PACKAGES=""; PROVIDES=""; OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --edges-forward) EDGES="$2"; shift 2 ;;
        --packages) PACKAGES="$2"; shift 2 ;;
        --provides) PROVIDES="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$EDGES" ] && [ -n "$PACKAGES" ] && [ -n "$PROVIDES" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"
TAB="$(printf '\t')"

RESOLVED="$OUT_DIR/edges-forward-resolved.tsv"
REVERSE="$OUT_DIR/edges-reverse.tsv"
RDEP_SUMMARY="$OUT_DIR/rdep-summary.tsv"

# Resolve each edge's target: real package name, or via-Provides, or
# unresolved (visible, not silently dropped -- section 25 principle
# applied to edges, not just tier/subsystem).
awk -F'\t' -v OFS='\t' \
    -v pkgs_f="$PACKAGES" -v prov_f="$PROVIDES" '
BEGIN {
    while ((getline line < pkgs_f) > 0) { split(line, a, "\t"); real[a[1]] = 1 }
    while ((getline line < prov_f) > 0) { split(line, a, "\t"); providers[a[2]] = providers[a[2]] "," a[1] }
}
{
    pkg=$1; dep=$2; relation=$3; alt=$4
    if (dep in real) {
        print pkg, dep, relation, alt, "direct"
    } else if (dep in providers) {
        n = split(substr(providers[dep], 2), plist, ",")
        for (i = 1; i <= n; i++) print pkg, plist[i], relation, alt, "via-provides"
    } else {
        print pkg, dep, relation, alt, "unresolved"
    }
}' "$EDGES" > "$RESOLVED"

# Invert: dependency <TAB> requiring-package <TAB> relation
awk -F'\t' -v OFS='\t' '{print $2, $1, $3}' "$RESOLVED" > "$REVERSE"

# Aggregation: rdep_count + rdeps list, structural relations only
sort -t "$TAB" -k1,1 "$REVERSE" | awk -F'\t' '
$3 == "Depends" || $3 == "Pre-Depends" {
    if ($1 != prev) {
        if (prev != "") print prev "\t" n "\t" list
        prev = $1; list = $2; n = 1
    } else {
        list = list "," $2; n++
    }
}
END { if (prev != "") print prev "\t" n "\t" list }
' > "$RDEP_SUMMARY"

unresolved=$(awk -F'\t' '$5=="unresolved"' "$RESOLVED" | wc -l)
echo "depend-reverse.sh: $(wc -l < "$REVERSE") reverse edges, $(wc -l < "$RDEP_SUMMARY") packages with structural reverse-deps" >&2
if [ "$unresolved" -gt 0 ]; then
    echo "  WARNING: $unresolved edge(s) point at names not found as a real package or a Provides -- see edges-forward-resolved.tsv (resolution=unresolved)" >&2
fi
