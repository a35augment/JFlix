#!/usr/bin/env bash
#
# tier.sh
#
# Question: which of the five tiers does each package fall into?
#   CORE | DEBIAN-ESSENTIAL | ARCHITECTURAL | DEPENDENCY | UTILITY
#
# Tier is a classification dimension, independent of subsystem.
# core.txt/architectural.txt/utility.txt remain external data (JFlix
# policy decisions), not hardcoded here. debian-essential is detected
# from package.sh's packages.tsv (Priority/Essential), not manually
# maintained. Anything left over is "dependency" by default -- not a
# judgment, just "nobody has classified this yet."
#
set -euo pipefail

usage() { echo "Usage: $0 --packages FILE --tiers-dir DIR --out-dir DIR" >&2; exit 1; }

PACKAGES=""; TIERS_DIR=""; OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --packages) PACKAGES="$2"; shift 2 ;;
        --tiers-dir) TIERS_DIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$PACKAGES" ] && [ -n "$TIERS_DIR" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

OUT="$OUT_DIR/tier-membership.tsv"
cut -f1 "$PACKAGES" | sort -u > "$OUT_DIR/.all-packages.tmp"

grep -Fxf "$TIERS_DIR/core.txt" "$OUT_DIR/.all-packages.tmp" 2>/dev/null > "$OUT_DIR/.tier-core.tmp" || true
grep -Fxf "$TIERS_DIR/architectural.txt" "$OUT_DIR/.all-packages.tmp" 2>/dev/null > "$OUT_DIR/.tier-arch.tmp" || true
grep -Fxf "$TIERS_DIR/utility.txt" "$OUT_DIR/.all-packages.tmp" 2>/dev/null > "$OUT_DIR/.tier-util.tmp" || true

cat "$OUT_DIR/.tier-core.tmp" "$OUT_DIR/.tier-arch.tmp" "$OUT_DIR/.tier-util.tmp" 2>/dev/null \
    | sort -u > "$OUT_DIR/.tiered-known.tmp"
comm -23 "$OUT_DIR/.all-packages.tmp" "$OUT_DIR/.tiered-known.tmp" > "$OUT_DIR/.tier-leftover.tmp"

# Debian-essential auto-detection straight from packages.tsv:
# priority is column 4, essential is column 5
awk -F'\t' '$4 == "required" || $4 == "important" || $5 == "yes" {print $1}' "$PACKAGES" \
    | sort -u > "$OUT_DIR/.essential-by-priority.tmp"

comm -12 "$OUT_DIR/.tier-leftover.tmp" "$OUT_DIR/.essential-by-priority.tmp" > "$OUT_DIR/.tier-essential.tmp"
comm -23 "$OUT_DIR/.tier-leftover.tmp" "$OUT_DIR/.essential-by-priority.tmp" > "$OUT_DIR/.tier-dependency.tmp"

{
    awk '{print $0"\tcore\tmanual (tiers/core.txt)"}' "$OUT_DIR/.tier-core.tmp"
    awk '{print $0"\tarchitectural\tmanual (tiers/architectural.txt)"}' "$OUT_DIR/.tier-arch.tmp"
    awk '{print $0"\tutility\tmanual (tiers/utility.txt)"}' "$OUT_DIR/.tier-util.tmp"
    awk '{print $0"\tdebian-essential\tauto (Priority/Essential)"}' "$OUT_DIR/.tier-essential.tmp"
    awk '{print $0"\tdependency\tauto (unclassified)"}' "$OUT_DIR/.tier-dependency.tmp"
} > "$OUT"

rm -f "$OUT_DIR"/.*.tmp

echo "tier.sh: classified $(wc -l < "$OUT") packages" >&2
