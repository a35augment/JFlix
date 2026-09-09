# jflix-depmap

Dependency-graph + taxonomy classifier for the JFlix debootstrap rootfs.

## Usage (from WSL2, against your real chroot)

```bash
sudo ./jflix-depmap.sh --rootfs /path/to/rootfs --tiers-dir ./tiers --out-dir ./out
```

Needs root (or read access to `rootfs/var/lib/dpkg`) since the status db
and per-package `.list` files are owned by root after debootstrap.

Flags:
- `--jobs N` — parallelism for the file-profile fan-out (default: nproc)
- `--skip-file-profile` — dependency graph + classification only, faster

## What it does

1. **find** locates `var/lib/dpkg/status` inside the rootfs.
2. **awk** parses every installed stanza's `Depends`/`Pre-Depends` in a
   single pass, strips version constraints inline, and explodes
   alternatives (`a | b`) into separate edges tagged `primary`/`alt`.
3. The edge list is inverted (still awk) into `reverse-deps.tsv`:
   for every package, who actually requires it and how many.
4. **grep -Fxf** cross-references the installed set against
   `tiers/core.txt`, `tiers/architectural.txt`, `tiers/utility.txt`.
   Anything left over is provisionally "dependency" tier — present
   only because something else pulled it in, not by policy choice.
5. **find + xargs/parallel** fan out per-package: each installed
   package's `dpkg -L` file list is independently classified
   (bin / lib / systemd-or-udev-unit / doc) via grep+sed-style pattern
   counts. This is the one step that's genuinely parallel — the
   dependency graph above is not, since it's one status file, not one
   file per package (see the comment block at the top of the script
   for why fan-out isn't used there).
6. Final report joins tier + forward-dep-count + reverse-dep-count +
   reverse-dep-list per package, and flags `CANDIDATE`: dependency-tier
   packages with **zero** reverse-deps inside the installed set — real
   leaves, worth testing removal against, not assumed-safe.

## Output files (in --out-dir)

- `classification-report.tsv` — the main deliverable
- `forward-edges.tsv` / `reverse-deps.tsv` — the raw graph
- `file-profile.tsv` — per-package bin/lib/unit/doc file counts
- `tier-*.txt` — the resolved tier membership lists

## Notes / honesty about limits

- `CANDIDATE` means "nothing *installed* needs it," not "safe to
  remove." A package can still be needed by systemd unit ordering,
  a postinst script, or something outside the dependency graph
  (e.g. `Recommends`/`Suggests` aren't parsed — deliberately, since
  JFlix's philosophy is minimal-by-proof, and Recommends are opt-in
  by policy, not structural need).
- Alternative deps (`a | b`) are recorded as reverse-deps on *both*
  alternatives, since dpkg only guarantees one is satisfied, not
  which. Don't remove either side of an alt group based on this
  report alone without checking which one is actually installed.
- `libc6`, `libgcc-s1`, etc. will show huge reverse-dep counts and
  are self-evidently core — the tool doesn't need to tell you that;
  it's most useful for the mid-tier packages where the answer isn't
  obvious.
