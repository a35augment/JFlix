#!/usr/bin/env bash
#
# TestDepen.sh
#
# Interactive front-end for jflix-depmap.sh. Prompts for a rootfs
# directory, works out where the report should land, and runs the
# dependency graph + classification pass against it.
#
# Run it from anywhere - it locates its own sibling script and the
# repo's configs/depmap-tiers by its own path, not your cwd.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPMAP="$SCRIPT_DIR/jflix-collect.sh"
TIERS_DIR="$REPO_ROOT/configs/depmap-tiers"

if [ ! -x "$DEPMAP" ]; then
    echo "ERROR: expected jflix-collect.sh next to this script at $DEPMAP" >&2
    exit 1
fi

# Let the user pass the dir as an argument to skip the prompt
# (e.g. TestDepen.sh experiments/002-mmdebstrap/rootfs), otherwise ask.
if [ $# -ge 1 ]; then
    INPUT_DIR="$1"
else
    echo "JFlix dependency tester"
    echo "Repo root: $REPO_ROOT"
    echo
    # offer the known experiment rootfs dirs as a quick pick, if any exist
    mapfile -t FOUND < <(find "$REPO_ROOT/experiments" -maxdepth 2 -type d -name rootfs 2>/dev/null | sort)
    if [ "${#FOUND[@]}" -gt 0 ]; then
        echo "Found existing rootfs dirs:"
        i=1
        for d in "${FOUND[@]}"; do
            echo "  [$i] ${d#$REPO_ROOT/}"
            i=$((i+1))
        done
        echo "  [0] enter a different path"
        read -rp "Pick a number, or press Enter to type a path: " choice
        if [ -n "${choice:-}" ] && [ "$choice" != "0" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#FOUND[@]}" ] 2>/dev/null; then
            INPUT_DIR="${FOUND[$((choice-1))]}"
        fi
    fi
    if [ -z "${INPUT_DIR:-}" ]; then
        read -rp "Path to the rootfs dir to test (relative or absolute): " INPUT_DIR
    fi
fi

[ -n "$INPUT_DIR" ] || { echo "No path given, aborting." >&2; exit 1; }

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: '$INPUT_DIR' is not a directory" >&2
    exit 1
fi

RESOLVED="$(cd "$INPUT_DIR" && pwd)"
OUT_DIR="$(dirname "$RESOLVED")/depmap-out"

echo
echo "rootfs:    $RESOLVED"
echo "tiers-dir: $TIERS_DIR"
echo "out-dir:   $OUT_DIR"
read -rp "Run it? [Y/n] " confirm
case "${confirm:-y}" in
    [nN]*) echo "Cancelled."; exit 0 ;;
esac

"$DEPMAP" --rootfs "$RESOLVED" --tiers-dir "$TIERS_DIR" --out-dir "$OUT_DIR" "${@:2}"

echo
echo "Report written to: $OUT_DIR/classification-report.tsv"
