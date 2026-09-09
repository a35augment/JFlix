#!/usr/bin/env bash
#
# report.sh
#
# Reporting is a CONSUMER of already-aggregated data (section 23) --
# this script computes nothing new. It reads packages-composite.tsv
# (built by `package.sh aggregate`) and formats it two ways:
#
#   classification-report.tsv  - flat, one row per package, all
#                                 composite columns, sorted tier+name
#   classification-report.txt  - grouped: tier section -> subsystem
#                                 sub-section -> package rows, plus
#                                 the exact same SUMMARY block v0.3
#                                 produced (tier counts + KB, TOTAL)
#
# Subsystem display order is derived from the categories-dir filename
# prefixes (01-, 02-, ...), same convention subsystem.sh uses, with
# UNCLASSIFIED always sorted last regardless of prefix.
#
set -euo pipefail

usage() { echo "Usage: $0 --composite FILE --categories-dir DIR --out-dir DIR --rootfs PATH" >&2; exit 1; }

COMPOSITE=""; CAT_DIR=""; OUT_DIR=""; ROOTFS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --composite) COMPOSITE="$2"; shift 2 ;;
        --categories-dir) CAT_DIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$COMPOSITE" ] && [ -n "$CAT_DIR" ] && [ -n "$OUT_DIR" ] && [ -n "$ROOTFS" ] || usage
TAB="$(printf '\t')"

TSV_REPORT="$OUT_DIR/classification-report.tsv"
TXT_REPORT="$OUT_DIR/classification-report.txt"

# Composite columns (1-indexed):
# 1 package 2 version 3 arch 4 tier 5 tier_source 6 subsystem
# 7 fwd_dep_count 8 rdep_count 9 rdeps 10 size_kb 11 bin 12 lib
# 13 unit 14 doc 15 maintainer_hook_count 16 security_evidence_count
# 17 candidate

{
    head -n1 "$COMPOSITE"
    tail -n +2 "$COMPOSITE" | sort -t "$TAB" -k4,4 -k1,1
} > "$TSV_REPORT"

# Subsystem display order: filename prefixes, UNCLASSIFIED forced last
CAT_ORDER=()
for f in "$CAT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    CAT_ORDER+=("$(basename "$f" .txt | sed -E 's/^[0-9]+-//')")
done
CAT_ORDER+=("UNCLASSIFIED")

{
    echo "JFlix package classification report"
    echo "rootfs: $ROOTFS"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    for t in core debian-essential architectural dependency utility; do
        case "$t" in
            core) label="CORE  (manual - substrate, would not survive removal)" ;;
            debian-essential) label="DEBIAN-ESSENTIAL  (auto - Priority: required/important, or Essential: yes)" ;;
            architectural) label="ARCHITECTURAL  (manual - JFlix must decide its role)" ;;
            dependency) label="DEPENDENCY  (auto - unclassified; CANDIDATEs live here)" ;;
            utility) label="UTILITY  (manual - human/admin convenience)" ;;
        esac

        tier_rows=$(awk -F'\t' -v t="$t" 'NR>1 && $4==t' "$COMPOSITE")
        [ -n "$tier_rows" ] || continue

        tier_count=$(echo "$tier_rows" | grep -c .)
        tier_kb=$(echo "$tier_rows" | awk -F'\t' '{s+=$10} END{print s+0}')

        echo "== $label =="
        echo "   $tier_count package(s), ${tier_kb} KB installed"
        echo ""

        for cat in "${CAT_ORDER[@]}"; do
            cat_rows=$(echo "$tier_rows" | awk -F'\t' -v c="$cat" '$6==c' | sort -t "$TAB" -k1,1)
            [ -n "$cat_rows" ] || continue
            cat_count=$(echo "$cat_rows" | grep -c .)
            cat_kb=$(echo "$cat_rows" | awk -F'\t' '{s+=$10} END{print s+0}')

            echo "   -- ${cat^^} ($cat_count pkg, ${cat_kb} KB) --"
            printf "   %-22s %-9s %-9s %-8s %-6s %-6s %s\n" \
                "PACKAGE" "FWD-DEPS" "RDEPS" "SIZE-KB" "HOOKS" "SECEV" "REQUIRED BY / CANDIDATE"
            echo "$cat_rows" | awk -F'\t' '
            {
                pkg=$1; fc=$7; rc=$8; rl=$9; sz=$10; mc=$15; sc=$16; cand=$17
                n = split(rl, parts, ",")
                if (rl == "-") disp = "-"
                else if (n <= 4) disp = rl
                else disp = parts[1] "," parts[2] "," parts[3] "," parts[4] " (+" (n-4) " more)"
                tag = (cand != "-") ? "  [" cand "]" : ""
                printf "   %-22s %-9s %-9s %-8s %-6s %-6s %s%s\n", pkg, fc, rc, sz, mc, sc, disp, tag
            }'
            echo ""
        done
    done

    echo "== SUMMARY =="
    awk -F'\t' 'NR>1{c[$4]++; s[$4]+=$10} END {
        for (t in c) printf "   %-18s %4d pkgs   %8d KB\n", t, c[t], s[t]
    }' "$COMPOSITE" | sort
    total_pkgs=$(tail -n +2 "$COMPOSITE" | wc -l)
    total_kb=$(awk -F'\t' 'NR>1{s+=$10} END{print s+0}' "$COMPOSITE")
    echo "   ------------------------------------------"
    printf "   %-18s %4d pkgs   %8d KB\n" "TOTAL" "$total_pkgs" "$total_kb"

    warn_count=$(awk -F'\t' 'NR>1 && $17=="CANDIDATE-WITH-WARNING"' "$COMPOSITE" | wc -l)
    plain_count=$(awk -F'\t' 'NR>1 && $17=="CANDIDATE"' "$COMPOSITE" | wc -l)
    echo ""
    echo "   Candidates: $plain_count plain, $warn_count with maintainer-hook/security warnings attached"
} > "$TXT_REPORT"

echo "report.sh: wrote $TSV_REPORT and $TXT_REPORT" >&2
