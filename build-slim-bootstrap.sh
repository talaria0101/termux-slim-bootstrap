#!/usr/bin/env bash
# Build a slim Termux bootstrap containing gh and openssh, and nothing that the
# gh + openssh dependency closure does not need.
#
# Input is the stock bootstrap zip published by termux-packages, not a checkout:
# it already contains a dpkg status database and a .list file per installed
# package, which is what makes this exact rather than a guess about which files
# belong to which package.
#
# Output is a bootstrap zip with the same layout (bin/, lib/, share/, etc/ at the
# root), suitable for termux-app to extract as $PREFIX.
#
# Why this is safe for the stated goal: gh and openssh only need the 18 packages
# in their dependency closure, and none of them depends on apt or dpkg. Removing
# the package manager therefore costs nothing for "gh cs ssh" and costs the
# ability to install anything later, which is the point.
#
# Both aarch64 and arm are supported. They are separate bootstraps, separate
# package indexes and separate stock zips; nothing here is shared between them
# except this script, so --arch picks the index and the output name.

set -euo pipefail

usage() {
	cat <<'EOF'
usage: build-slim-bootstrap.sh [options]

  --arch ARCH        aarch64 (default) or arm
  --stock-zip PATH   stock bootstrap-<arch>.zip from termux-packages releases
  --work DIR         scratch directory (default: ./build-<arch>)
  --out PATH         output zip (default: ./bootstrap-<arch>-slim.zip)
  --keep-manager     keep apt and dpkg even though nothing needs them
  --extra PKG        add a package to the closure, repeatable
  --plan-only        print what would be kept and dropped, build nothing
  -h, --help         this text

Packages kept are computed from the real dependency closure in the termux-main
Packages index for that architecture, not from a hardcoded list.

Build both:

    for a in aarch64 arm; do
        ./build-slim-bootstrap.sh --arch "$a" --stock-zip "stock-$a.zip"
    done
EOF
}

ARCH="aarch64"
STOCK=""
WORK=""
OUT=""
KEEP_MANAGER=0
PLAN_ONLY=0
declare -a EXTRA=()

while [ $# -gt 0 ]; do
	case "$1" in
	--arch) ARCH="$2"; shift 2 ;;
	--stock-zip) STOCK="$2"; shift 2 ;;
	--work) WORK="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--keep-manager) KEEP_MANAGER=1; shift ;;
	--extra) EXTRA+=("$2"); shift 2 ;;
	--plan-only) PLAN_ONLY=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
done

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

case "$ARCH" in
aarch64 | arm) ;;
*)
	die "unsupported --arch \"$ARCH\"; termux publishes aarch64 and arm bootstraps,
       and only those two are built here"
	;;
esac

WORK="${WORK:-./build-$ARCH}"
OUT="${OUT:-./bootstrap-$ARCH-slim.zip}"

# The roots are what the user actually asked for. gh for the API and the
# cs subcommands, openssh because gh cs ssh execs it.
ROOTS=(gh openssh "${EXTRA[@]+"${EXTRA[@]}"}")

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLAN_PY="$HERE/plan.py"

command -v unzip >/dev/null || die "unzip is required"
command -v python3 >/dev/null || die "python3 is required"
# zip(1) is not needed: the repack below uses python3's zipfile, which is
# always available alongside the interpreter already required for plan.py.

if [ -z "$STOCK" ]; then
	die "--stock-zip is required; download bootstrap-$ARCH.zip from
       https://github.com/termux/termux-packages/releases"
fi
[ -f "$STOCK" ] || die "no such file: $STOCK"

# The index is per-architecture: the aarch64 Packages file describes aarch64
# packages and says nothing about arm. Reusing it would resolve dependencies
# against packages that do not exist for the target.
PKG_INDEX="$HERE/Packages-$ARCH"
if [ ! -f "$PKG_INDEX" ]; then
	PKG_INDEX="$WORK/Packages-$ARCH"
	printf 'fetching the termux-main %s package index...\n' "$ARCH"
	mkdir -p "$WORK"
	curl -sSfL -o "$PKG_INDEX" \
		"https://packages-cf.termux.dev/apt/termux-main/dists/stable/main/binary-$ARCH/Packages" ||
		die "could not fetch the $ARCH package index"
fi

rm -rf "$WORK/root"
mkdir -p "$WORK/root"
printf 'unpacking the stock bootstrap...\n'
unzip -q "$STOCK" -d "$WORK/root"

STATUS="$WORK/root/var/lib/dpkg/status"
[ -f "$STATUS" ] || die "the stock zip has no dpkg status database at
       var/lib/dpkg/status; is it really a termux bootstrap?"

# Ask plan.py which packages the closure needs. It prints the plan and writes the
# two name lists, so the shell and the Python cannot disagree about the answer.
printf '\nresolving the dependency closure of: %s\n\n' "${ROOTS[*]}"
python3 "$PLAN_PY" --write-lists "$PKG_INDEX" "$STATUS" \
	"${ROOTS[@]}" \
	--keep-list "$WORK/keep.txt" \
	--drop-list "$WORK/drop.txt" |
	sed 's/^/  /'

KEEP_LIST="$WORK/keep.txt"
DROP_LIST="$WORK/drop.txt"

if [ "$PLAN_ONLY" -eq 1 ]; then
	printf '\n--plan-only: nothing was built.\n'
	exit 0
fi

if [ "$KEEP_MANAGER" -eq 0 ]; then
	# The package manager is only being dropped because the closure does not need
	# it. With --keep-manager the packages below stay.
	grep -vxE 'apt|dpkg' "$KEEP_LIST" >"$KEEP_LIST.tmp" 2>/dev/null || true
	mv "$KEEP_LIST.tmp" "$KEEP_LIST"
fi

printf '\nremoving %d packages the closure does not need...\n' "$(wc -l <"$DROP_LIST")"

# Remove each dropped package's files, using the dpkg .list manifests so this is
# exact. A file claimed by both a dropped and a kept package must survive, so the
# kept manifests are collected first and used as a guard.
KEEP_ALL="$WORK/kept-files.txt"
: >"$KEEP_ALL"
# Same prefix-stripping as below, so the guard set is in root-relative form.
PREFIX_IN_LISTS="/data/data/com.termux/files/usr"
while read -r pkg; do
	[ -n "$pkg" ] || continue
	if [ -f "$WORK/root/var/lib/dpkg/info/$pkg.list" ]; then
		sed -e "s|^$PREFIX_IN_LISTS||" "$WORK/root/var/lib/dpkg/info/$pkg.list" >>"$KEEP_ALL"
	fi
done <"$KEEP_LIST"
# Strip blanks with sed, not `grep -v`: grep exits 1 when it filters out nothing,
# and under `set -e` that aborts the build right here, silently, after the
# "removing N packages" line and before anything is removed.
sed -e '/^$/d' "$KEEP_ALL" | sort -u -o "$KEEP_ALL" "$KEEP_ALL"

removed=0
kept_shared=0
# dpkg writes .list paths in on-device form, /data/data/com.termux/files/usr/bin/bash,
# while the bootstrap zip is rooted at the prefix itself, so it holds bin/bash. Strip
# the prefix to get a path inside $WORK/root. Without this the targets never resolve
# and nothing is removed, which looks like a successful build and is not one.
PREFIX_IN_LISTS="/data/data/com.termux/files/usr"
while read -r pkg; do
	[ -n "$pkg" ] || continue
	list="$WORK/root/var/lib/dpkg/info/$pkg.list"
	[ -f "$list" ] || continue
	while read -r path; do
		[ -n "$path" ] || continue
		rel="${path#$PREFIX_IN_LISTS}"
		[ "$rel" != "$path" ] || continue
		# A path outside $PREFIX (for example /data or /system) is not ours to
		# delete; the zip does not contain it either.
		[ -n "$rel" ] || continue
		target="$WORK/root$rel"
		[ -e "$target" ] || [ -L "$target" ] || continue
		# dpkg records directories in .list as well as files. They are left alone
		# here and pruned by find -type d -empty below, which cannot fail on a
		# directory whose contents are still there.
		[ -d "$target" ] && [ ! -L "$target" ] && continue
		if grep -qxF "$rel" "$KEEP_ALL"; then
			# Still owned by a package we are keeping.
			kept_shared=$((kept_shared + 1))
			continue
		fi
		rm -f "$target"
		removed=$((removed + 1))
	done <"$list"
done <"$DROP_LIST"

printf '  removed %d files, kept %d shared with a kept package\n' "$removed" "$kept_shared"

# The dpkg database must agree with what is on disk, or the second-stage scripts
# and any later `dpkg -l` will be wrong. Drop the removed packages' control data
# and rewrite status to match.
printf 'rewriting the dpkg database...\n'
while read -r pkg; do
	[ -n "$pkg" ] || continue
	rm -f "$WORK/root/var/lib/dpkg/info/$pkg".*
	rmdir "$WORK/root/var/lib/dpkg/info/$pkg".d 2>/dev/null || true
done <"$DROP_LIST"

python3 - "$WORK/root/var/lib/dpkg/status" "$DROP_LIST" <<'PYEOF'
import sys

status_path, drop_path = sys.argv[1], sys.argv[2]
with open(drop_path, encoding="utf-8") as fh:
	dropped = {line.strip() for line in fh if line.strip()}

kept, out, skipping = [], [], False
with open(status_path, encoding="utf-8", errors="replace") as fh:
	for line in fh:
		if not line.strip():
			# End of a stanza. Keep it only if the stanza was kept.
			if skipping:
				skipping = False
				continue
			out.append("\n")
			continue
		if line.startswith(" "):
			if not skipping:
				out.append(line)
			continue
		if line.startswith("Package: "):
			name = line[len("Package: "):].strip()
			skipping = name in dropped
		if not skipping:
			out.append(line)

with open(status_path, "w", encoding="utf-8") as fh:
	fh.writelines(out)

print("  status now lists %d packages" % (sum(
	1 for line in open(status_path, encoding="utf-8")
	if line.startswith("Package: "))))
PYEOF

# Empty directories left behind by removals waste space in the zip.
printf 'pruning empty directories...\n'
find "$WORK/root" -type d -empty -delete 2>/dev/null || true

# SYMLINKS.txt must be preserved, not regenerated.
#
# The stock bootstrap stores no symlinks as symlinks in the zip. Each line is
# "<owning package><-U+2190><./path>", for example "coreutils<-./bin/sha384sum",
# and the app creates those links after extraction. The first field is the package
# that owns the link, not a link target.
#
# An earlier version of this script rebuilt the file from the extracted tree and
# recorded 0 entries, which would have removed all 1213 aliases: bin/sh, and every
# coreutils name like bin/ls, are symlinks and would simply not exist. The zip
# therefore carries the stock SYMLINKS.txt through unchanged, minus lines whose
# link belongs to a package that was dropped.
printf 'filtering SYMLINKS.txt...\n'
python3 - "$WORK/root/SYMLINKS.txt" "$DROP_LIST" "$KEEP_LIST" <<'PYEOF'
import sys

path, drop_path, keep_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(drop_path, encoding="utf-8") as fh:
	dropped = {line.strip() for line in fh if line.strip()}
with open(keep_path, encoding="utf-8") as fh:
	kept = {line.strip() for line in fh if line.strip()}

with open(path, encoding="utf-8") as fh:
	lines = [line.rstrip("\n") for line in fh if line.strip()]

kept_lines, gone = [], 0
for line in lines:
	owner, _, relpath = line.partition("\u2190")
	owner = owner.strip()
	if owner in dropped:
		gone += 1
		continue
	kept_lines.append(line)

with open(path, "w", encoding="utf-8") as fh:
	fh.write("\n".join(kept_lines))
	if kept_lines:
		fh.write("\n")

print("  %d symlink entries kept, %d belonged to dropped packages" % (len(kept_lines), gone))
if not kept_lines:
	print("  WARNING: no symlinks left; bin/sh and the coreutils names would be missing")
PYEOF

# Stock does not ship gh or openssh, so a trimmed bootstrap has to acquire them.
# Trimming alone produces something smaller but still without the tools it was
# built for.
printf '\nadding gh and openssh...\n'
ADD_LIST="$WORK/add.txt"
printf '%s\n' "${ROOTS[@]}" >"$ADD_LIST"
# WORK is passed so the deb cache survives between runs and lives outside the
# root tree, so no .deb ends up inside the bootstrap.
CACHE_DIR="$WORK/deb-cache"
mkdir -p "$CACHE_DIR"
WORK="$WORK" CACHE="$CACHE_DIR" bash "$HERE/add-packages.sh" \
	--arch "$ARCH" --root "$WORK/root" --packages "$PKG_INDEX" "${ROOTS[@]}" |
	sed 's/^/  /'

printf '\nzipping...\n'

rm -f "$OUT"
# Stored, not deflated. The payload is already-compressed ELF binaries, so
# deflating them costs CPU and saves almost nothing, and the app extracts this
# exactly once at first run. The stock bootstrap is built the same way.
python3 - "$WORK/root" "$OUT" <<'PYEOF2'
import os
import sys
import zipfile

root, out = sys.argv[1], sys.argv[2]

# Deflate, as the stock bootstrap does. An earlier version stored every entry
# uncompressed on the reasoning that ELF binaries do not compress, which is wrong:
# the stock zip is 90MB uncompressed and 33MB on disk, and storing made the "slim"
# bootstrap larger than the stock one it was meant to shrink.
#
# followlinks=False because the tree is full of symlinked directories such as
# lib/terminfo -> ../share/terminfo. A symlink must be recorded as a symlink, not
# followed into, or the archive balloons and duplicates whole subtrees.
entries = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
	dirnames.sort()
	for name in sorted(filenames + dirnames):
		full = os.path.join(dirpath, name)
		rel = os.path.relpath(full, root)
		if rel in entries:
			continue
		entries.append(rel)
entries.sort()

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, allowZip64=True,
		compresslevel=9) as zf:
	for rel in entries:
		full = os.path.join(root, rel)
		info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
		info.compress_type = zipfile.ZIP_DEFLATED

		if os.path.islink(full):
			# Symlinks are recorded in SYMLINKS.txt and recreated by the app, so
			# store the target as the entry's content rather than as a link the
			# extractor would have to interpret.
			info.external_attr = (0o120777 | 0o777) << 16
			zf.writestr(info, os.readlink(full).encode())
			continue
		if os.path.isdir(full):
			# The name must keep its trailing slash. Without it the entry is stored
			# as a zero-length FILE named "bin", and extracting creates a file called
			# bin that every binary in bin/ then collides with. The stock archive has
			# 295 directory entries with trailing slashes for this reason.
			if not rel.endswith("/"):
				rel += "/"
			info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = (0o040755) << 16
			zf.writestr(info, b"")
			continue

		info.external_attr = (0o100000 | (os.stat(full).st_mode & 0o777)) << 16
		with open(full, "rb") as fh:
			zf.writestr(info, fh.read())

print("  %d entries" % len(entries))
PYEOF2

printf '\nbuilt %s (%s)\n' "$OUT" "$ARCH"
# stat, not du: on a sparse filesystem du under-reports and printed "512 on disk"
# for a 50MB archive, which reads like a build failure.
printf '  %s (%s bytes, %d files)\n' \
	"$(python3 -c "import sys;print('%.1fM' % (int(sys.argv[1])/1048576))" "$(stat -c %s "$OUT")")" \
	"$(stat -c %s "$OUT")" \
	"$(python3 -c "import sys,zipfile;print(len(zipfile.ZipFile(sys.argv[1]).namelist()))" "$OUT")"
printf '  packages kept: %s\n' "$(wc -l <"$KEEP_LIST")"
printf '\nInstall it by replacing the bootstrap in a termux-app build, or unpack it\n'
printf 'over $PREFIX on a device that already has Termux installed.\n'