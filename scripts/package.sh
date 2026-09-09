#!/usr/bin/env bash
#
# package.sh - the package-centric data stream.
#
# Two subcommands, two different jobs (per JFlix v0.4 architecture doc):
#
#   package.sh collect   --status FILE --out-dir DIR
#       Reads /var/lib/dpkg/status ONCE. Emits raw, undecided package
#       facts. Does NOT decide tier, subsystem, or candidate status.
#       Produces:
#         packages.tsv        pkg, version, arch, priority, essential, size_kb
#         provides.tsv        pkg, provided_name   (virtual packages)
#         raw-relations.tsv   pkg, relation, raw_field_text (unexploded)
#
#   package.sh aggregate --out-dir DIR
#       Joins every independent evidence stream that OTHER scripts have
#       already written into out-dir (tier-membership.tsv,
#       subsystem-membership.tsv, edges/*, file-profile.tsv,
#       maintainer-hooks.tsv, security-evidence.tsv) into one
#       package-centric composite row. This is the ONLY place these
#       streams get joined. It does not re-derive anything the other
#       scripts already computed.
#
# Fields collected in `collect`, and why:
#   Package, Status, Priority, Essential, Installed-Size, Version,
#   Architecture, Provides, Depends, Pre-Depends, Recommends, Suggests
#   -- these are standard, reliably-present dpkg status fields.
#   Conflicts/Breaks/Replaces are NOT collected yet: they describe
#   exclusion relationships, not dependency edges, and nothing
#   downstream consumes them yet. Add them here first if/when a
#   consumer needs them -- don't collect speculatively.
#
set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage:
  $0 collect   --status FILE --out-dir DIR
  $0 aggregate --out-dir DIR
EOF
    exit 1
}

[ $# -ge 1 ] || usage
MODE="$1"; shift

case "$MODE" in
    collect)
        STATUS_DB=""; OUT_DIR=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --status) STATUS_DB="$2"; shift 2 ;;
                --out-dir) OUT_DIR="$2"; shift 2 ;;
                *) echo "Unknown arg: $1" >&2; usage ;;
            esac
        done
        [ -n "$STATUS_DB" ] && [ -n "$OUT_DIR" ] || usage
        mkdir -p "$OUT_DIR"

        PACKAGES_OUT="$OUT_DIR/packages.tsv"
        PROVIDES_OUT="$OUT_DIR/provides.tsv"
        RAW_REL_OUT="$OUT_DIR/raw-relations.tsv"

        awk -v PACKAGES_OUT="$PACKAGES_OUT" -v PROVIDES_OUT="$PROVIDES_OUT" -v RAW_REL_OUT="$RAW_REL_OUT" '
        function joincont(i,   field, j, cont) {
            field = $i
            sub(/^[A-Za-z-]+: /, "", field)
            j = i + 1
            while (j <= NF && $j ~ /^ /) {
                cont = $j; sub(/^ /, "", cont)
                field = field " " cont
                j++
            }
            return field
        }
        BEGIN { RS=""; FS="\n" }
        {
            pkg=""; installed=0; priority="unknown"; essential="no"
            size=0; version=""; arch=""; provides=""
            depends=""; predepends=""; recommends=""; suggests=""
            for (i = 1; i <= NF; i++) {
                line = $i
                if (line ~ /^Package: /) { pkg=line; sub(/^Package: /,"",pkg) }
                else if (line ~ /^Status: .*installed/) { installed=1 }
                else if (line ~ /^Priority: /) { priority=line; sub(/^Priority: /,"",priority) }
                else if (line ~ /^Essential: /) { essential=line; sub(/^Essential: /,"",essential) }
                else if (line ~ /^Installed-Size: /) { size=line; sub(/^Installed-Size: /,"",size); size+=0 }
                else if (line ~ /^Version: /) { version=line; sub(/^Version: /,"",version) }
                else if (line ~ /^Architecture: /) { arch=line; sub(/^Architecture: /,"",arch) }
                else if (line ~ /^Provides: /) { provides = joincont(i) }
                else if (line ~ /^Depends: /) { depends = joincont(i) }
                else if (line ~ /^Pre-Depends: /) { predepends = joincont(i) }
                else if (line ~ /^Recommends: /) { recommends = joincont(i) }
                else if (line ~ /^Suggests: /) { suggests = joincont(i) }
            }
            if (pkg != "" && installed) {
                print pkg "\t" version "\t" arch "\t" priority "\t" essential "\t" size > PACKAGES_OUT

                if (provides != "") {
                    gsub(/\([^)]*\)/, "", provides); gsub(/ /, "", provides)
                    n = split(provides, parts, ",")
                    for (k = 1; k <= n; k++) if (parts[k] != "") print pkg "\t" parts[k] > PROVIDES_OUT
                }
                if (depends != "") {
                    gsub(/\([^)]*\)/, "", depends); gsub(/[ \t]+/, " ", depends); gsub(/^ | $/, "", depends)
                    print pkg "\tDepends\t" depends > RAW_REL_OUT
                }
                if (predepends != "") {
                    gsub(/\([^)]*\)/, "", predepends); gsub(/[ \t]+/, " ", predepends); gsub(/^ | $/, "", predepends)
                    print pkg "\tPre-Depends\t" predepends > RAW_REL_OUT
                }
                if (recommends != "") {
                    gsub(/\([^)]*\)/, "", recommends); gsub(/[ \t]+/, " ", recommends); gsub(/^ | $/, "", recommends)
                    print pkg "\tRecommends\t" recommends > RAW_REL_OUT
                }
                if (suggests != "") {
                    gsub(/\([^)]*\)/, "", suggests); gsub(/[ \t]+/, " ", suggests); gsub(/^ | $/, "", suggests)
                    print pkg "\tSuggests\t" suggests > RAW_REL_OUT
                }
            }
        }' "$STATUS_DB"

        # awk '> FILE' only creates the file if at least one line was
        # ever written to it. Touch all three so downstream scripts
        # can always rely on them existing, even empty.
        touch "$PACKAGES_OUT" "$PROVIDES_OUT" "$RAW_REL_OUT"

        echo "package.sh collect: $(wc -l < "$PACKAGES_OUT") packages, $(wc -l < "$PROVIDES_OUT") provides entries, $(wc -l < "$RAW_REL_OUT") relation records" >&2
        ;;

    aggregate)
        OUT_DIR=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --out-dir) OUT_DIR="$2"; shift 2 ;;
                *) echo "Unknown arg: $1" >&2; usage ;;
            esac
        done
        [ -n "$OUT_DIR" ] || usage

        PACKAGES="$OUT_DIR/packages.tsv"
        TIER="$OUT_DIR/tier-membership.tsv"
        SUBSYS="$OUT_DIR/subsystem-membership.tsv"
        FWD_COUNTS="$OUT_DIR/edges-forward-counts.tsv"
        RDEP_SUMMARY="$OUT_DIR/rdep-summary.tsv"
        FILEPROF="$OUT_DIR/file-profile.tsv"
        MAINT="$OUT_DIR/maintainer-hooks.tsv"
        SEC="$OUT_DIR/security-evidence.tsv"
        OUT="$OUT_DIR/packages-composite.tsv"

        for f in "$PACKAGES" "$TIER" "$SUBSYS" "$FWD_COUNTS" "$RDEP_SUMMARY"; do
            [ -f "$f" ] || { echo "ERROR: missing required stream: $f (run the earlier phases first)" >&2; exit 1; }
        done
        # these three are optional evidence streams -- aggregate must
        # still work if they haven't been run yet
        touch "$FILEPROF" "$MAINT" "$SEC" 2>/dev/null || true

        awk -F'\t' -v OFS='\t' \
            -v tier_f="$TIER" -v subsys_f="$SUBSYS" \
            -v fwd_f="$FWD_COUNTS" -v rdep_f="$RDEP_SUMMARY" \
            -v fileprof_f="$FILEPROF" -v maint_f="$MAINT" -v sec_f="$SEC" '
        function addcsv(map, key, val) {
            if (map[key] == "") map[key] = val
            else map[key] = map[key] "," val
        }
        BEGIN {
            while ((getline line < tier_f) > 0) {
                split(line, a, "\t"); tier[a[1]] = a[2]; tsrc[a[1]] = a[3]
            }
            while ((getline line < subsys_f) > 0) {
                split(line, a, "\t")
                addcsv(subsys, a[1], a[2])
            }
            while ((getline line < fwd_f) > 0) { split(line, a, "\t"); fwd[a[1]] = a[2] }
            while ((getline line < rdep_f) > 0) { split(line, a, "\t"); rdepcount[a[1]] = a[2]; rdeplist[a[1]] = a[3] }
            while ((getline line < fileprof_f) > 0) {
                if (line ~ /^package\t/) continue
                split(line, a, "\t"); binf[a[1]]=a[2]; libf[a[1]]=a[3]; unitf[a[1]]=a[4]; docf[a[1]]=a[5]
            }
            while ((getline line < maint_f) > 0) {
                if (line ~ /^package\t/) continue
                split(line, a, "\t"); maintcount[a[1]]++
            }
            while ((getline line < sec_f) > 0) {
                if (line ~ /^path\t/) continue
                split(line, a, "\t")
                # a[3] is the owning package for setuid/capability evidence
                if (a[3] != "" && a[3] != "UNATTRIBUTED") seccount[a[3]]++
            }
            print "package","version","arch","tier","tier_source","subsystem","fwd_dep_count","rdep_count","rdeps","size_kb","bin_files","lib_files","unit_files","doc_files","maintainer_hook_count","security_evidence_count","candidate"
        }
        {
            pkg=$1; ver=$2; arch=$3; pr=$4; ess=$5; sz=$6
            t = (pkg in tier) ? tier[pkg] : "dependency"
            src = (pkg in tsrc) ? tsrc[pkg] : "auto (unclassified)"
            sub_ = (pkg in subsys) ? subsys[pkg] : "UNCLASSIFIED"
            fc = (pkg in fwd) ? fwd[pkg] : 0
            rc = (pkg in rdepcount) ? rdepcount[pkg] : 0
            rl = (pkg in rdeplist) ? rdeplist[pkg] : "-"
            bf = (pkg in binf) ? binf[pkg] : 0
            lf = (pkg in libf) ? libf[pkg] : 0
            uf = (pkg in unitf) ? unitf[pkg] : 0
            df = (pkg in docf) ? docf[pkg] : 0
            mc = (pkg in maintcount) ? maintcount[pkg] : 0
            sc = (pkg in seccount) ? seccount[pkg] : 0

            cand = "-"
            if (t == "dependency" && rc == 0) {
                cand = (mc > 0 || sc > 0) ? "CANDIDATE-WITH-WARNING" : "CANDIDATE"
            }
            print pkg, ver, arch, t, src, sub_, fc, rc, rl, sz, bf, lf, uf, df, mc, sc, cand
        }' "$PACKAGES" > "$OUT"

        echo "package.sh aggregate: wrote $(($(wc -l < "$OUT") - 1)) rows to $OUT" >&2
        ;;
    *)
        usage
        ;;
esac
