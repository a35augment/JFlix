#!/usr/bin/env bash
#
# security.sh
#
# Question: which installed files carry elevated privilege by
# default, and which package put them there?
#
# This is attack-surface evidence (section 19), kept independent of
# tier: a package can simultaneously be tier=dependency AND carry a
# setuid binary. That intersection is exactly what this architecture
# is for, and it's arguably more decision-relevant for an
# appliance-hardening goal than the dependency graph itself.
#
# Package attribution is done via a single pass building a path ->
# package index from every info/*.list file, NOT one `dpkg -S` call
# per file found -- consistent with "don't fan out reads of one
# source" (the .list files are already read once each by
# file-profile.sh's fan-out; re-reading them all in one pass here to
# build a lookup index is a different, cheaper operation, not a
# duplicate of that work).
#
set -euo pipefail

usage() { echo "Usage: $0 --rootfs DIR --admindir DIR --out-dir DIR" >&2; exit 1; }

ROOTFS=""; ADMINDIR=""; OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --admindir) ADMINDIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$ROOTFS" ] && [ -n "$ADMINDIR" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

OUT="$OUT_DIR/security-evidence.tsv"

# Build path -> package index in one pass over all .list files.
INDEX="$OUT_DIR/.path-index.tmp"
: > "$INDEX"
for lf in "$ADMINDIR"/info/*.list; do
    [ -f "$lf" ] || continue
    pkg="$(basename "$lf" .list)"
    awk -v p="$pkg" '{print $0"\t"p}' "$lf" >> "$INDEX"
done

attribute() {
    # $1 = absolute path as it would appear in a .list file (no rootfs prefix)
    awk -F'\t' -v target="$1" '$1 == target {print $2; found=1; exit} END{if(!found) print "UNATTRIBUTED"}' "$INDEX"
}

: > "$OUT_DIR/.evidence.tmp"

# setuid / setgid files
find "$ROOTFS" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | while read -r f; do
    rel="${f#"$ROOTFS"}"
    pkg="$(attribute "$rel")"
    printf '%s\tsetuid-or-setgid\t%s\n' "$rel" "$pkg" >> "$OUT_DIR/.evidence.tmp"
done

# file capabilities, if getcap is available on the host running this script
if command -v getcap >/dev/null 2>&1; then
    getcap -r "$ROOTFS" 2>/dev/null | while IFS= read -r line; do
        f="$(echo "$line" | awk '{print $1}')"
        [ -n "$f" ] || continue
        rel="${f#"$ROOTFS"}"
        pkg="$(attribute "$rel")"
        printf '%s\tcapability\t%s\n' "$rel" "$pkg" >> "$OUT_DIR/.evidence.tmp"
    done
else
    echo "security.sh: getcap not found on host -- skipping capability scan (setuid scan still ran)" >&2
fi

{ echo -e "path\tevidence_type\tpackage"; sort -u "$OUT_DIR/.evidence.tmp" 2>/dev/null; } > "$OUT"
rm -f "$INDEX" "$OUT_DIR/.evidence.tmp"

echo "security.sh: $(($(wc -l < "$OUT") - 1)) security-relevant file(s) found" >&2
