#!/usr/bin/env bash
# End-to-end checks on the finished slim bootstrap.
#
# Everything here reads the built artefact, not the build's own log, so a step that
# prints a reassuring message and produces nothing still fails here. The
# properties checked are the ones a phone depends on: a shell exists, gh and ssh
# exist, every shared library they need is present, and the files dpkg's database
# claims exist really do.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${1:-$HERE/bootstrap-aarch64-slim.zip}"
STOCK="${2:-$HERE/stock-aarch64.zip}"

# Which ELF machine the archive must contain, decided by naming convention. The
# check below reads the ELF header of bin/gh and compares it, so a zip built with
# the wrong --arch fails here rather than on the phone.
case "$BOOTSTRAP" in
*-arm-slim.zip | *arm*) WANT_MACHINE="ARM" ; WANT_ELFCLASS=1 ;;
*) WANT_MACHINE="AArch64"; WANT_ELFCLASS=2 ;;
esac

passed=0
failed=0

ok() {
	passed=$((passed + 1))
	printf '  ok    %s\n' "$1"
}

no() {
	failed=$((failed + 1))
	printf '  FAIL  %s\n' "$1"
	[ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/        /'
	return 0
}

if [ ! -f "$BOOTSTRAP" ]; then
	printf 'no bootstrap to check: %s\n' "$BOOTSTRAP" >&2
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '=== bootstrap checks (%s)\n\n' "$(basename "$BOOTSTRAP")"

# --- the archive itself ---------------------------------------------------

if python3 -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
sys.exit(0 if z.testzip() is None else 1)
" "$BOOTSTRAP"; then
	ok "archive is a valid, uncorrupted zip"
else
	no "archive is a valid, uncorrupted zip"
	exit 1
fi

unzip -q "$BOOTSTRAP" -d "$WORK/root"

slim_bytes=$(stat -c %s "$BOOTSTRAP")

if [ ! -f "$STOCK" ]; then
	printf '  FAIL  no stock archive at %s to compare against\n' "$STOCK"
else
	stock_bytes=$(stat -c %s "$STOCK")

	# Not "slimmer than stock", because that claim is false and asserting it made
	# this suite red forever. bin/gh alone is 14.2MB compressed, so a bootstrap
	# carrying gh is larger than stock whatever else is dropped. The honest
	# comparison is what the trim removed, against what adding gh cost.
	python3 - "$BOOTSTRAP" "$STOCK" <<'PYEOF'
import sys
import zipfile

slim_path, stock_path = sys.argv[1], sys.argv[2]
slim = zipfile.ZipFile(slim_path)
stock = zipfile.ZipFile(stock_path)

slim_names = set(slim.namelist())
stock_names = set(stock.namelist())

removed = [i for i in stock.infolist()
	if not i.is_dir() and i.filename not in slim_names]
added = [i for i in slim.infolist()
	if not i.is_dir() and i.filename not in stock_names]

print("        stock %d bytes, slim %d bytes" % (
	stock_path and __import__("os").stat(stock_path).st_size,
	__import__("os").stat(slim_path).st_size))
print("        trim removed %d files (%.1f MB), adding gh+openssh introduced %d files (%.1f MB)" % (
	len(removed), sum(i.compress_size for i in removed) / 1048576.0,
	len(added), sum(i.compress_size for i in added) / 1048576.0))
PYEOF

	removed_count="$(python3 - "$STOCK" "$BOOTSTRAP" <<'PYEOF2'
import sys
import zipfile

zs = zipfile.ZipFile(sys.argv[1])
zm = set(zipfile.ZipFile(sys.argv[2]).namelist())
print(sum(1 for i in zs.infolist() if not i.is_dir() and i.filename not in zm))
PYEOF2
)"
	if [ "$removed_count" -gt 100 ]; then
		ok "the trim actually removed files ($removed_count gone from stock)"
	else
		no "the trim actually removed files" "only $removed_count removed"
	fi
fi

# --- a usable shell -------------------------------------------------------
#
# The app launches $PREFIX/bin/bash as the login shell. A bootstrap without it
# starts no session at all, and gh's dependency closure contains no shell, so this
# is exactly the failure a naive trim produces.

# bin/bash is a real file: the app launches it as the login shell.
if [ -e "$WORK/root/bin/bash" ]; then
	ok "has bin/bash"
else
	no "has bin/bash" "no login shell; the app starts no session"
fi

# ls and cat are NOT files. They are coreutils aliases listed in SYMLINKS.txt and
# recreated by the app after extraction, exactly like bin/sh. Checking the
# filesystem for them fails on a correct archive. What must exist is the real
# binary they alias.
# The path in SYMLINKS.txt always carries a leading "./", as stock writes it.
for pair in "bin/ls:coreutils" "bin/cat:coreutils" "bin/sh:dash"; do
	alias_path="./${pair%%:*}"
	owner="${pair##*:}"
	# The separator is a literal U+2190 arrow, so match it by codepoint rather
	# than by octal escapes that grep -F never interprets.
	if python3 - "$WORK/root/SYMLINKS.txt" "$owner" "$alias_path" <<'PYEOF2'
import sys
path, owner, alias = sys.argv[1], sys.argv[2], sys.argv[3]
want = owner + "\u2190" + alias
sys.exit(0 if any(line.strip() == want for line in open(path, encoding="utf-8")) else 1)
PYEOF2
	then
		ok "SYMLINKS.txt declares $alias_path"
	else
		no "SYMLINKS.txt declares $alias_path" "$alias_path is an alias, not a file"
	fi
done
if [ -e "$WORK/root/bin/coreutils" ]; then
	ok "has bin/coreutils, the binary those aliases point at"
else
	no "has bin/coreutils, the binary those aliases point at"
fi
if [ -e "$WORK/root/bin/dash" ]; then
	ok "has bin/dash, which bin/sh aliases"
else
	no "has bin/dash, which bin/sh aliases"
fi

if [ -x "$WORK/root/bin/bash" ]; then
	ok "bash is executable"
else
	no "bash is executable" "mode $(stat -c %a "$WORK/root/bin/bash" 2>/dev/null)"
fi

# Architecture-independent packages must be installable in either tree.
#
# 233 packages per index are "Architecture: all", and gh depends on
# ca-certificates, one of them. A guard that compared the Architecture field to
# --arch without allowing "all" rejected it and broke every arm build while the
# aarch64 build still looked fine.
if [ -f "$WORK/root/var/lib/dpkg/info/ca-certificates.list" ]; then
	ok "installs Architecture: all packages such as ca-certificates"
else
	no "installs Architecture: all packages such as ca-certificates" \
		"an arch check rejecting Architecture: all breaks this"
fi

# --- gh and the three binaries gh cs ssh execs -----------------------------
#
# Not just gh: internal/codespaces/ssh.go does LookPath("ssh") and
# exec.CommandContext, and pkg/ssh/ssh_keys.go does LookPath("ssh-keygen").

for b in gh ssh ssh-keygen ssh-add; do
	if [ -x "$WORK/root/bin/$b" ]; then
		ok "bin/$b present and executable"
	else
		no "bin/$b present and executable"
	fi
done

# --- every DT_NEEDED a shipped binary asks for is resolvable ---------------
#
# A missing .so means the dynamic linker refuses to start the program, and on a
# phone that is the difference between gh working and gh not existing. libc, libdl
# and liblog are Bionic's own and are not shipped in the prefix, so they are
# expected to be absent.

missing_libs=""
for bin in gh ssh ssh-keygen ssh-add; do
	[ -f "$WORK/root/bin/$bin" ] || continue
	for needed in $(readelf -d "$WORK/root/bin/$bin" 2>/dev/null |
		grep NEEDED | sed 's/.*\[\(.*\)\]/\1/'); do
		case "$needed" in
		libc.so | libdl.so | liblog.so | libm.so) continue ;;
		esac
		if [ ! -e "$WORK/root/lib/$needed" ]; then
			missing_libs="$missing_libs $bin:$needed"
		fi
	done
done

if [ -z "$missing_libs" ]; then
	ok "every non-Bionic shared library the binaries need is in the tree"
else
	no "every non-Bionic shared library the binaries need is in the tree" "missing:$missing_libs"
fi

# --- the libraries really are ARM64 Android objects -----------------------

# The ELF machine must match the architecture this zip is for. 32-bit arm needs
# /system/bin/linker, aarch64 needs /system/bin/linker64: they are different
# linkers on the device, and getting it wrong means the binary does not start.
if [ "$WANT_MACHINE" = "ARM" ]; then
	WANT_INTERP="/system/bin/linker"
else
	WANT_INTERP="/system/bin/linker64"
fi

for bin in gh ssh ssh-keygen; do
	[ -f "$WORK/root/bin/$bin" ] || continue
	machine="$(readelf -h "$WORK/root/bin/$bin" 2>/dev/null | grep Machine | sed 's/.*: *//')"
	interp="$(readelf -l "$WORK/root/bin/$bin" 2>/dev/null | grep -o '/system/bin/linker[0-9]*')"
	if printf '%s' "$machine" | grep -q "$WANT_MACHINE"; then
		ok "bin/$bin is $WANT_MACHINE"
	else
		no "bin/$bin is $WANT_MACHINE" "machine: $machine"
	fi
	if [ "$interp" = "$WANT_INTERP" ]; then
		ok "bin/$bin asks for $WANT_INTERP"
	else
		no "bin/$bin asks for $WANT_INTERP" "got: ${interp:-none}"
	fi
done

# --- symlinks -------------------------------------------------------------
#
# SYMLINKS.txt is the only record of bin/sh and every coreutils alias, because the
# archive stores no symlinks as symlinks. Losing it silently removes sh, ls, cat
# and more.

if [ -f "$WORK/root/SYMLINKS.txt" ]; then
	n="$(grep -c . "$WORK/root/SYMLINKS.txt" 2>/dev/null || echo 0)"
	if [ "$n" -gt 100 ]; then
		ok "SYMLINKS.txt has $n entries"
	else
		no "SYMLINKS.txt has $n entries" "expected over 100; every alias would be missing"
	fi
	if grep -q '←./bin/sh$' "$WORK/root/SYMLINKS.txt"; then
		ok "SYMLINKS.txt still declares bin/sh"
	else
		no "SYMLINKS.txt still declares bin/sh"
	fi
else
	no "SYMLINKS.txt exists"
fi

# --- the dpkg database matches the tree -----------------------------------

status_pkgs=$(grep -c '^Package: ' "$WORK/root/var/lib/dpkg/status" 2>/dev/null || echo 0)
if [ "$status_pkgs" -gt 10 ]; then
	ok "dpkg status lists $status_pkgs packages"
else
	no "dpkg status lists packages" "only $status_pkgs"
fi

if [ ! -e "$WORK/root/var/lib/dpkg/info/apt.list" ]; then
	ok "apt is no longer in the database"
else
	no "apt is no longer in the database" "the package manager was meant to be dropped"
fi

for p in bash coreutils gh openssh; do
	if [ -f "$WORK/root/var/lib/dpkg/info/$p.list" ]; then
		ok "dpkg records $p"
	else
		no "dpkg records $p"
	fi
done

# Every file a kept package claims must exist.
#
# Measured against the stock bootstrap rather than against zero, because the stock
# manifests are themselves incomplete: they list 1213 paths that stock does not
# ship, and every one of those is a symlink alias (bin/sh, bin/ls, and the rest of
# coreutils) that the app creates from SYMLINKS.txt after extraction. Counting those
# as damage would flag a perfectly correct archive, and it did, with 203
# "missing" files that were never missing.

count_missing() {
	# $1 = extracted root. Prints how many claimed paths are absent.
	python3 - "$1" <<'PYEOF2'
import glob
import os
import sys

root = sys.argv[1]
prefix = "/data/data/com.termux/files/usr"
missing = 0
for lst in glob.glob(os.path.join(root, "var/lib/dpkg/info/*.list")):
	with open(lst, errors="replace") as fh:
		for line in fh:
			p = line.strip()
			if not p.startswith(prefix):
				continue
			rel = p[len(prefix):]
			full = root + rel
			if not os.path.exists(full) and not os.path.islink(full):
				missing += 1
print(missing)
PYEOF2
}

# Extract the stock archive before testing for the directory. Checking first made
# the comparison silently skip every time, so the manifest check never ran.
if [ -f "$STOCK" ] && unzip -q "$STOCK" -d "$WORK/stock" 2>/dev/null; then
	stock_missing="$(count_missing "$WORK/stock")"
	slim_missing="$(count_missing "$WORK/root")"
	printf '        stock claims %s absent paths, slim claims %s\n' \
		"$stock_missing" "$slim_missing"
	if [ "$slim_missing" -le "$stock_missing" ]; then
		ok "no more missing files than stock itself has ($slim_missing <= $stock_missing)"
	else
		no "no more missing files than stock itself has" \
			"slim=$slim_missing stock=$stock_missing"
	fi
else
	printf '  FAIL  could not extract the stock archive for comparison\n'
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]