#!/usr/bin/env bash
#
# maintainer.sh
#
# Question: does this package's install/remove machinery couple it to
# something the Depends graph can't see?
#
# Depends/Pre-Depends only capture "needs this package to unpack."
# They say nothing about a postinst calling `systemctl enable`, or a
# preinst calling `useradd`. That's a different relationship type
# entirely (section 17 of the v0.4 spec) -- collected here as its own
# evidence stream, never silently folded into a dependency edge.
#
# Fan-out is genuinely justified here: each package's maintainer
# scripts are independent files, so find+xargs/parallel is the right
# tool, same reasoning as file-profile.sh.
#
set -euo pipefail

usage() { echo "Usage: $0 --admindir DIR --out-dir DIR [--jobs N]" >&2; exit 1; }

ADMINDIR=""; OUT_DIR=""; JOBS="$(nproc 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
    case "$1" in
        --admindir) ADMINDIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[ -n "$ADMINDIR" ] && [ -n "$OUT_DIR" ] || usage
mkdir -p "$OUT_DIR"

OUT="$OUT_DIR/maintainer-hooks.tsv"
HOOK_PATTERN='systemctl|deb-systemd-helper|update-rc\.d|invoke-rc\.d|useradd|groupadd|adduser --system|update-alternatives'
export HOOK_PATTERN

scan_one() {
    path="$1"
    base="$(basename "$path")"
    pkg="${base%.*}"
    script_type="${base##*.}"
    grep -nE "$HOOK_PATTERN" "$path" 2>/dev/null | while IFS=: read -r _lineno line; do
        hook="$(echo "$line" | grep -oE "$HOOK_PATTERN" | head -1)"
        clean="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        printf '%s\t%s\t%s\t%s\n' "$pkg" "$script_type" "$hook" "$clean"
    done
}
export -f scan_one

find "$ADMINDIR/info" -maxdepth 1 -type f \
    \( -name '*.postinst' -o -name '*.preinst' -o -name '*.prerm' -o -name '*.postrm' \) \
    > "$OUT_DIR/.scripts.tmp" 2>/dev/null || true

if [ -s "$OUT_DIR/.scripts.tmp" ]; then
    if command -v parallel >/dev/null 2>&1; then
        parallel -j "$JOBS" scan_one {} < "$OUT_DIR/.scripts.tmp" > "$OUT_DIR/.hooks.tmp"
    else
        xargs -P "$JOBS" -I{} bash -c 'scan_one "$@"' _ {} < "$OUT_DIR/.scripts.tmp" > "$OUT_DIR/.hooks.tmp"
    fi
else
    : > "$OUT_DIR/.hooks.tmp"
fi

{ echo -e "package\tscript\thook\tmatched_line"; sort "$OUT_DIR/.hooks.tmp"; } > "$OUT"
rm -f "$OUT_DIR/.scripts.tmp" "$OUT_DIR/.hooks.tmp"

echo "maintainer.sh: $(($(wc -l < "$OUT") - 1)) hook(s) found across $(cut -f1 "$OUT" | tail -n +2 | sort -u | wc -l) package(s)" >&2
