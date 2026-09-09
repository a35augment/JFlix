#!/usr/bin/env bash
#
# subsystem.sh
#
# Question: what part of the operating system does this package
# participate in? (a dimension independent of tier)
#
# Reads every NN-name.txt file in categories-dir (the numeric prefix
# controls display order; the id is the filename with the prefix and
# .txt stripped, e.g. "08-device-kernel.txt" -> "device-kernel").
#
# The output schema is one row per (package, category) match, NOT one
# row per package -- a package that genuinely shows up in two category
# files gets two rows. Currently the 13 seeded category files are
# curated to be mutually exclusive (no package appears twice), but the
# schema does not assume or enforce that, per section 9/10 of the
# v0.4 spec: secondary categories are allowed when evidence supports
# them, never invented.
#
# Anything not matched by any category file gets an explicit
# UNCLASSIFIED row -- never silently dropped (section 25).
#
set -euo pipefail

usage() { echo "Usage: $0 --packages FILE --categories-dir DIR --out-dir DIR" >&2; exit 1; }

PACKAGES=""; CAT_DIR=""; OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --packages) PACKAGES="$2"; shift 2 ;;
        --categories-dir) CAT_DIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$PACKAGES" ] && [ -n "$CAT_DIR" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

OUT="$OUT_DIR/subsystem-membership.tsv"
cut -f1 "$PACKAGES" | sort -u > "$OUT_DIR/.all-packages.tmp"
: > "$OUT_DIR/.matched.tmp"
: > "$OUT"

for f in "$CAT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .txt)"
    catid="$(echo "$base" | sed -E 's/^[0-9]+-//')"
    matches="$(grep -Fxf "$f" "$OUT_DIR/.all-packages.tmp" 2>/dev/null || true)"
    [ -n "$matches" ] || continue
    echo "$matches" | awk -v cat="$catid" -v src="manual (categories/$base.txt)" -F'\t' '{print $1"\t"cat"\t"src}' >> "$OUT"
    echo "$matches" >> "$OUT_DIR/.matched.tmp"
done

sort -u "$OUT_DIR/.matched.tmp" -o "$OUT_DIR/.matched.tmp" 2>/dev/null || true
comm -23 "$OUT_DIR/.all-packages.tmp" "$OUT_DIR/.matched.tmp" > "$OUT_DIR/.unmatched.tmp" 2>/dev/null || true
awk '{print $0"\tUNCLASSIFIED\tauto (no category file matched)"}' "$OUT_DIR/.unmatched.tmp" >> "$OUT"

rm -f "$OUT_DIR"/.*.tmp

total_pkgs=$(cut -f1 "$OUT" | sort -u | wc -l)
unclassified=$(awk -F'\t' '$2=="UNCLASSIFIED"' "$OUT" | wc -l)
echo "subsystem.sh: $(wc -l < "$OUT") category relationships across $total_pkgs packages ($unclassified unclassified)" >&2
