#!/usr/bin/env bash
# Build both supported architectures and check both artefacts.
#
# Two arches, because that is what Termux publishes bootstraps for that are worth
# carrying: aarch64 for any phone from about 2016 on, and arm for older or
# 32-bit-only devices. They are built separately because the stock zip, the
# package index and every binary in them differ.
#
# Nothing here is shared between the two builds except the scripts, so a failure
# in one says nothing about the other and both are attempted.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 1

# Termux bootstrap release tag. Pinned rather than "latest" so a rebuild is
# reproducible and so a rerun does not silently switch to a newer Termux.
BOOTSTRAP_TAG="bootstrap-2026.10.11-r1+apt.android-7"
RELEASE_URL="https://github.com/termux/termux-packages/releases/download/${BOOTSTRAP_TAG//+/%2B}"

ARCHES=(aarch64 arm)

missing=0
for arch in "${ARCHES[@]}"; do
	stock="stock-$arch.zip"

	printf '\n=== %s ===\n' "$arch"

	if [ ! -f "$stock" ]; then
		printf 'downloading the stock %s bootstrap...\n' "$arch"
		if ! curl -sSfL -o "$stock" "$RELEASE_URL/bootstrap-$arch.zip"; then
			printf 'could not download the %s stock bootstrap\n' "$arch" >&2
			missing=1
			continue
		fi
	fi

	if ! bash "$HERE/build-slim-bootstrap.sh" \
		--arch "$arch" --stock-zip "$stock" \
		--out "bootstrap-$arch-slim.zip"; then
		printf 'build FAILED for %s\n' "$arch" >&2
		missing=1
		continue
	fi

	if ! bash "$HERE/test-bootstrap.sh" "bootstrap-$arch-slim.zip" "$stock"; then
		printf 'checks FAILED for %s\n' "$arch" >&2
		missing=1
	fi
done

printf '\n===================================\n'
for arch in "${ARCHES[@]}"; do
	out="bootstrap-$arch-slim.zip"
	if [ -f "$out" ]; then
		printf '  %-28s %10d bytes\n' "$out" "$(stat -c %s "$out")"
	else
		printf '  %-28s MISSING\n' "$out"
		missing=1
	fi
done

if [ "$missing" -ne 0 ]; then
	printf '\nsomething did not build\n'
	exit 1
fi
printf '\nboth architectures built and checked\n'