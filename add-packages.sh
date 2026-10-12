#!/usr/bin/env bash
# Add packages to a bootstrap tree that are not in the stock bootstrap.
#
# Stock ships neither gh nor openssh, so a bootstrap trimmed to the gh+openssh
# closure still has to acquire those 9 packages somewhere. This downloads them from
# termux-main, verifies each one against the Packages index, and unpacks them into
# the tree in the same layout the app expects.
#
# Packages are installed by unpacking, not by running dpkg, which is how the app
# itself installs its own bootstrap. Maintainer scripts are therefore not run;
# see the note at the end on which scripts matter.

set -euo pipefail

usage() {
	cat <<'EOF'
usage: add-packages.sh --root DIR --packages INDEX [--arch ARCH] [PACKAGE...]

  --root DIR      extracted bootstrap root (the tree that becomes $PREFIX)
  --packages IDX  termux-main Packages index, for filenames and checksums
  --arch ARCH     package architecture: aarch64 (default) or arm. Checked against
                  each package's own Architecture field, so the wrong Packages
                  index is caught rather than installing foreign binaries.
  PACKAGE...      packages to add, in dependency order or not: missing
                  dependencies are added automatically
EOF
}

ROOT=""
INDEX=""
ARCH="aarch64"
declare -a WANT=()

while [ $# -gt 0 ]; do
	case "$1" in
	--root) ROOT="$2"; shift 2 ;;
	--packages) INDEX="$2"; shift 2 ;;
	--arch) ARCH="$2"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) WANT+=("$1"); shift ;;
	esac
done

[ -n "$ROOT" ] || { usage >&2; exit 2; }
[ -n "$INDEX" ] && [ -f "$INDEX" ] || { printf 'error: --packages must name a Packages index\n' >&2; exit 2; }
[ -d "$ROOT" ] || { printf 'error: no such directory: %s\n' "$ROOT" >&2; exit 2; }
[ ${#WANT[@]} -gt 0 ] || { usage >&2; exit 2; }

BASE_URL="https://packages-cf.termux.dev/apt/termux-main"
PREFIX_IN_DEVICE="/data/data/com.termux/files/usr"

ROOT="$(cd "$ROOT" && pwd)"

# Scratch space for the deb cache and for unpacking. Declared before CACHE because
# CACHE defaults to a path inside it.
#
# WORK must be OUTSIDE the root tree. The default here used to be
# $ROOT/.deb-cache, so every downloaded .deb was packed into the bootstrap: 16.8MB
# of cache inside a 59MB archive, 180% the size of the stock bootstrap it was
# meant to shrink.
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/termux-debs.XXXXXXXX")}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
CACHE="${CACHE:-$WORK/deb-cache}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd)"

# Pull filename, sha256 and dependencies for one package out of the index.
# Prints "<filename>\n<sha256>\n<dep1> <dep2> ..." on success, exits 1 if the
# package is not in the index.
lookup() {
	python3 - "$INDEX" "$1" "$ARCH" <<'PYEOF'
import sys

index_path, want, arch = sys.argv[1], sys.argv[2], sys.argv[3]
stanza = {}
name = None
with open(index_path, encoding="utf-8", errors="replace") as fh:
	for line in fh:
		line = line.rstrip("\n")
		if not line.strip():
			if name == want:
				break
			stanza = {}
			name = None
			continue
		if line.startswith(" "):
			continue
		key, _, val = line.partition(":")
		if key == "Package":
			name = val.strip()
			stanza = {}
		else:
			stanza[key] = val.strip()

if name != want:
	sys.exit(1)

# Refuse a package built for another architecture.
#
# ARCH was accepted by the option parser and then never used, so pointing this at
# an aarch64 Packages file with --arch arm silently installed aarch64 binaries
# into an arm tree: wrong architecture, and it would only fail on the phone.
#
# Architecture "all" is architecture-independent and appears in every index
# (233 of them, ca-certificates and openssl among them), so it is accepted
# regardless of --arch. Rejecting it broke every arm build, because gh depends on
# ca-certificates.
pkg_arch = stanza.get("Architecture", "")
if pkg_arch and pkg_arch not in (arch, "all"):
	sys.stderr.write(
		"architecture mismatch: %s is %s but this build is %s\n" % (want, pkg_arch, arch))
	sys.exit(2)

fn = stanza.get("Filename", "")
sha = stanza.get("SHA256", "")
deps = []
for group in stanza.get("Depends", "").split(","):
	group = group.strip()
	if not group:
		continue
	# First alternative that the index knows about is the one to take.
	for alt in group.split("|"):
		alt = alt.strip().split(" ")[0].split(":")[0]
		if alt:
			deps.append(alt)
			break
print(fn)
print(sha)
print(" ".join(deps))
PYEOF
}

# Depth-first install: fetch and unpack, then recurse into anything missing.
declare -A DONE=()
declare -A MISSING=()

install_one() {
	local pkg="$1" fn sha rel

	if [ -n "${DONE[$pkg]:-}" ]; then
		return 0
	fi
	DONE[$pkg]=1

	info=""
	rc=0
	info="$(lookup "$pkg")" || rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 2 ]; then
			# Wrong architecture: a hard error, not a missing package. Report it as
			# such, so the final summary does not claim a package is missing when the
			# real problem is that the Packages file is for another arch.
			ARCH_MISMATCH=1
			printf '  aborting: the index is not for %s\n' "$ARCH" >&2
			return 1
		fi
		MISSING[$pkg]=1
		printf '  not in index: %s\n' "$pkg" >&2
		return 1
	fi
	fn="$(printf '%s\n' "$info" | sed -n 1p)"
	sha="$(printf '%s\n' "$info" | sed -n 2p)"
	deps="$(printf '%s\n' "$info" | sed -n 3p)"

	local deb="$CACHE/$(basename "$fn")"
	if [ ! -f "$deb" ]; then
		printf '  fetching %s\n' "$(basename "$fn")"
		curl -sSfL -o "$deb" "$BASE_URL/$fn" || {
			printf '  download failed: %s\n' "$fn" >&2
			return 1
		}
	fi

	# Verify against the index. An unchecked deb from the network would be
	# installed straight into the app's $PREFIX.
	if [ -n "$sha" ]; then
		local got
		got="$(sha256sum "$deb" | cut -d' ' -f1)"
		if [ "$got" != "$sha" ]; then
			printf '  SHA256 mismatch for %s\n' "$(basename "$fn")" >&2
			printf '    want %s\n    got  %s\n' "$sha" "$got" >&2
			return 1
		fi
	else
		printf '  no SHA256 in index for %s, refusing to install unverified\n' "$pkg" >&2
		return 1
	fi

	printf '  unpacking %s\n' "$pkg"
	# The deb's data.tar.* holds ./data/data/com.termux/files/usr/... which is
	# exactly $PREFIX. Extract, then lift the prefix out.
	local tmp
	tmp="$(mktemp -d)"
	# --no-same-owner everywhere: the debs record Termux's own uid and gid, and
	# restoring them fails on this filesystem. tar then aborts part way through,
	# leaving a half-unpacked package while printing only warnings.
	(cd "$tmp" && ar x "$deb" && for t in data.tar.*; do
		case "$t" in
		*.xz) tar --no-same-owner -xf "$t" ;;
		*.gz) tar --no-same-owner -xf "$t" ;;
		*.zst) tar --no-same-owner --zstd -xf "$t" ;;
		*) tar --no-same-owner -xf "$t" ;;
		esac
	done)

	local src="$tmp$PREFIX_IN_DEVICE"
	if [ ! -d "$src" ]; then
		printf '  unexpected layout in %s (no %s)\n' "$(basename "$fn")" "$PREFIX_IN_DEVICE" >&2
		rm -rf "$tmp"
		return 1
	fi
	# -a keeps the mode bits: bash is 0700 and several binaries rely on it.
	cp -a "$src/." "$ROOT/"

	# Record the file manifest so the package is visible to dpkg and so a later
	# build knows it is already present. Built from what was just unpacked, in
	# the on-device path form dpkg uses.
	mkdir -p "$ROOT/var/lib/dpkg/info"
	python3 - "$src" "$ROOT" "$pkg" <<'PYEOF2'
import os
import sys

# Walk the package's OWN unpacked tree, not the whole root. Walking the root made
# every added package claim every file in the bootstrap, so the manifests
# disagreed with each other and dpkg's view of ownership became meaningless.
src, root, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = "/data/data/com.termux/files/usr"
entries = []
for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
	rel_dir = os.path.relpath(dirpath, src)
	entries.append(prefix + "/" + rel_dir if rel_dir != "." else prefix + "/")
	for name in sorted(filenames):
		rel = os.path.normpath(os.path.join(rel_dir, name))
		entries.append(prefix + "/" + rel)
with open(os.path.join(root, "var/lib/dpkg/info", pkg + ".list"), "w",
		encoding="utf-8") as fh:
	fh.write("\n".join(sorted(set(entries))) + "\n")
PYEOF2

	# Only now is $tmp disposable: the manifest above reads it.
	rm -rf "$tmp"

	# Dependencies that are not yet present.
	for dep in $deps; do
		case "$dep" in
		*":"*) continue ;; # architecture-qualified, handled by the index
		esac
		if [ -z "${DONE[$dep]:-}" ]; then
			install_one "$dep" || true
		fi
	done
	return 0
}

printf 'adding %s to %s\n' "${WANT[*]}" "$ROOT"
declare -a QUEUE=("${WANT[@]}")
processed=0
failed=0
while [ ${#QUEUE[@]} -gt 0 ]; do
	pkg="${QUEUE[0]}"
	QUEUE=("${QUEUE[@]:1}")
	if [ -n "${DONE[$pkg]:-}" ]; then
		continue
	fi
	# Only fetch something the stock bootstrap does not already ship. Its dpkg
	# manifests are in the tree, so their presence is the test.
	if [ -f "$ROOT/var/lib/dpkg/info/$pkg.list" ]; then
		DONE[$pkg]=1
		continue
	fi
	if install_one "$pkg"; then
		processed=$((processed + 1))
	else
		failed=$((failed + 1))
	fi
done

if [ "${ARCH_MISMATCH:-0}" -eq 1 ]; then
	printf '\n0 packages added: the index does not describe %s packages.\n' "$ARCH"
	printf 'Use Packages-%s, or --arch for the architecture the index is for.\n' "$ARCH"
	exit 1
fi

printf '\n%d packages added, %d could not be resolved\n' "$processed" "$failed"
if [ "$failed" -gt 0 ]; then
	printf 'missing: %s\n' "${!MISSING[*]}"
	exit 1
fi