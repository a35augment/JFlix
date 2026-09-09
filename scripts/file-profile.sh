#!/usr/bin/env bash
#
# file-profile.sh
#
# Question: what kind of files did each package actually put on disk?
#
# This is the genuinely-parallel evidence collector: each package's
# .list file under dpkg's info dir is an independent unit of work, so
# find+xargs/parallel fan-out is the right tool here (unlike the
# dependency graph, which is one status file read once). Extracted
# unchanged in logic from v0.3's phase 3.
#
set -euo pipefail

usage() { echo "Usage: $0 --admindir DIR --packages FILE --out-dir DIR [--jobs N]" >&2; exit 1; }

ADMINDIR=""; PACKAGES=""; OUT_DIR=""; JOBS="$(nproc 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
    case "$1" in
        --admindir) ADMINDIR="$2"; shift 2 ;;
        --packages) PACKAGES="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$ADMINDIR" ] && [ -n "$PACKAGES" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

OUT="$OUT_DIR/file-profile.tsv"

profile_one() {
    pkg="$1"
    listfile="$ADMINDIR/info/${pkg}.list"
    [ -f "$listfile" ] || { echo -e "$pkg\t0\t0\t0\t0"; return; }
    bin=$(grep -Ec '/s?bin/' "$listfile" || true)
    lib=$(grep -Ec '/lib/' "$listfile" || true)
    unit=$(grep -Ec '/systemd/|/init\.d/|/udev/rules\.d/' "$listfile" || true)
    doc=$(grep -Ec '/man/|/doc/' "$listfile" || true)
    echo -e "${pkg}\t${bin}\t${lib}\t${unit}\t${doc}"
}
export -f profile_one
export ADMINDIR

cut -f1 "$PACKAGES" | sort -u > "$OUT_DIR/.pkglist.tmp"

if command -v parallel >/dev/null 2>&1; then
    parallel -j "$JOBS" profile_one {} < "$OUT_DIR/.pkglist.tmp" > "$OUT_DIR/.profile.tmp"
else
    xargs -P "$JOBS" -I{} bash -c 'profile_one "$@"' _ {} < "$OUT_DIR/.pkglist.tmp" > "$OUT_DIR/.profile.tmp"
fi

{ echo -e "package\tbin_files\tlib_files\tservice_unit_files\tdoc_files"; sort "$OUT_DIR/.profile.tmp"; } > "$OUT"
rm -f "$OUT_DIR/.pkglist.tmp" "$OUT_DIR/.profile.tmp"

echo "file-profile.sh: profiled $(($(wc -l < "$OUT") - 1)) packages (jobs=$JOBS)" >&2
