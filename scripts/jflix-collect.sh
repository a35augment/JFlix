#!/usr/bin/env bash
#
# jflix-collect.sh
#
# Runs the v0.4 pipeline: eight independent scripts, each producing
# one evidence stream, in the order each one's inputs become
# available. This script does no data processing itself -- it only
# sequences the others and passes paths between them. If you want to
# understand what any one phase actually does, read that script; this
# one is just wiring.
#
# Order (why this order, not some other):
#   1. package.sh collect   - the only script that reads dpkg status
#   2. depend-forward.sh    - explodes package.sh's raw relations
#   3. depend-reverse.sh    - inverts (1)+(2)'s output, needs Provides
#   4. tier.sh               - needs packages.tsv from (1)
#   5. subsystem.sh          - needs packages.tsv from (1)
#   6. file-profile.sh       - independent fan-out, needs packages.tsv
#   7. maintainer.sh         - independent fan-out, needs admindir only
#   8. security.sh           - independent fan-out, needs admindir only
#   9. package.sh aggregate  - joins everything from (1)-(8)
#  10. report.sh             - consumes (9), writes the two reports
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_TIERS_DIR="$REPO_ROOT/configs/depmap-tiers"
DEFAULT_CATEGORIES_DIR="$REPO_ROOT/configs/depmap-categories"

usage() {
    cat >&2 <<EOF
Usage: $0 --rootfs PATH [options]

  --rootfs PATH          Path to the chroot root (required)
  --tiers-dir PATH        (default: $DEFAULT_TIERS_DIR)
  --categories-dir PATH   (default: $DEFAULT_CATEGORIES_DIR)
  --out-dir PATH          (default: <rootfs's parent dir>/depmap-out)
  --jobs N                Parallelism for fan-out phases (default: nproc)
  --skip-file-profile     Skip phases 6-8 (file/maintainer/security evidence)
EOF
    exit 1
}

ROOTFS=""; TIERS_DIR="$DEFAULT_TIERS_DIR"; CATEGORIES_DIR="$DEFAULT_CATEGORIES_DIR"
OUT_DIR=""; JOBS="$(nproc 2>/dev/null || echo 4)"; SKIP_EVIDENCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --tiers-dir) TIERS_DIR="$2"; shift 2 ;;
        --categories-dir) CATEGORIES_DIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --skip-file-profile) SKIP_EVIDENCE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$ROOTFS" ] || usage
ROOTFS="$(cd "$ROOTFS" 2>/dev/null && pwd)" || { echo "ERROR: rootfs dir not found" >&2; exit 1; }
[ -n "$OUT_DIR" ] || OUT_DIR="$(dirname "$ROOTFS")/depmap-out"
mkdir -p "$OUT_DIR"

STATUS_DB="$(find "$ROOTFS" -maxdepth 5 -type f -path '*/var/lib/dpkg/status' 2>/dev/null | head -n1)"
[ -n "$STATUS_DB" ] || { echo "ERROR: no dpkg status db found under $ROOTFS" >&2; exit 1; }
ADMINDIR="$(dirname "$STATUS_DB")"

echo "rootfs:         $ROOTFS" >&2
echo "tiers-dir:      $TIERS_DIR" >&2
echo "categories-dir: $CATEGORIES_DIR" >&2
echo "out-dir:        $OUT_DIR" >&2
echo "" >&2

"$SCRIPT_DIR/package.sh" collect --status "$STATUS_DB" --out-dir "$OUT_DIR"
"$SCRIPT_DIR/depend-forward.sh" --raw-relations "$OUT_DIR/raw-relations.tsv" --out-dir "$OUT_DIR"
"$SCRIPT_DIR/depend-reverse.sh" --edges-forward "$OUT_DIR/edges-forward.tsv" \
    --packages "$OUT_DIR/packages.tsv" --provides "$OUT_DIR/provides.tsv" --out-dir "$OUT_DIR"
"$SCRIPT_DIR/tier.sh" --packages "$OUT_DIR/packages.tsv" --tiers-dir "$TIERS_DIR" --out-dir "$OUT_DIR"
"$SCRIPT_DIR/subsystem.sh" --packages "$OUT_DIR/packages.tsv" --categories-dir "$CATEGORIES_DIR" --out-dir "$OUT_DIR"

if [ "$SKIP_EVIDENCE" -eq 0 ]; then
    "$SCRIPT_DIR/file-profile.sh" --admindir "$ADMINDIR" --packages "$OUT_DIR/packages.tsv" --out-dir "$OUT_DIR" --jobs "$JOBS"
    "$SCRIPT_DIR/maintainer.sh" --admindir "$ADMINDIR" --out-dir "$OUT_DIR" --jobs "$JOBS"
    "$SCRIPT_DIR/security.sh" --rootfs "$ROOTFS" --admindir "$ADMINDIR" --out-dir "$OUT_DIR"
else
    echo "Skipping file-profile/maintainer/security evidence (--skip-file-profile)" >&2
    printf 'package\tbin_files\tlib_files\tservice_unit_files\tdoc_files\n' > "$OUT_DIR/file-profile.tsv"
    printf 'package\tscript\thook\tmatched_line\n' > "$OUT_DIR/maintainer-hooks.tsv"
    printf 'path\tevidence_type\tpackage\n' > "$OUT_DIR/security-evidence.tsv"
fi

"$SCRIPT_DIR/package.sh" aggregate --out-dir "$OUT_DIR"
"$SCRIPT_DIR/report.sh" --composite "$OUT_DIR/packages-composite.tsv" \
    --categories-dir "$CATEGORIES_DIR" --out-dir "$OUT_DIR" --rootfs "$ROOTFS"

echo "" >&2
echo "Done." >&2
echo "  Human-readable report: $OUT_DIR/classification-report.txt" >&2
echo "  Machine-readable TSV:  $OUT_DIR/classification-report.tsv" >&2
echo "  Composite package view: $OUT_DIR/packages-composite.tsv" >&2
echo "" >&2
echo "Candidates (see report for CANDIDATE vs CANDIDATE-WITH-WARNING):" >&2
awk -F'\t' 'NR>1 && $17 ~ /^CANDIDATE/ {print "  " $1 "  [" $17 "]"}' "$OUT_DIR/packages-composite.tsv" >&2
