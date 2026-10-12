#!/usr/bin/env bash
# Publish both bootstraps as a release, with a checksum file.
#
# The archives are release assets rather than committed files: together they are
# 82MB, and they are reproducible from the scripts with ./build-all.sh.
#
# A tag is required, because a release is the only way to attach assets and
# gh release create has no untagged mode.

set -euo pipefail

TAG="${1:-}"
if [ -z "$TAG" ]; then
	printf 'usage: release.sh TAG\n' >&2
	printf '  TAG must look like v0.1.0 (semver, as GitHub expects)\n' >&2
	exit 2
fi

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ARCHES=(aarch64 arm)

missing=0
for arch in "${ARCHES[@]}"; do
	if [ ! -f "bootstrap-$arch-slim.zip" ]; then
		printf 'missing bootstrap-%s-slim.zip; run ./build-all.sh first\n' "$arch" >&2
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	exit 1
fi

# Recompute rather than trusting a checked-in file, so the manifest always
# describes the bytes actually being uploaded.
sha256sum bootstrap-aarch64-slim.zip bootstrap-arm-slim.zip > SHA256SUMS
printf 'checksums:\n'
sed 's/^/  /' SHA256SUMS

if gh release view "$TAG" >/dev/null 2>&1; then
	printf 'release %s already exists; deleting it first\n' "$TAG"
	gh release delete "$TAG" --yes --cleanup-tag
fi

gh release create "$TAG" \
	bootstrap-aarch64-slim.zip \
	bootstrap-arm-slim.zip \
	SHA256SUMS \
	--title "$TAG: Termux bootstrap with gh and openssh" \
	--notes-file "$HERE/RELEASE-NOTES.md"

printf '\npublished %s\n' "$TAG"
gh release view "$TAG" --json assets --jq '.assets[] | "  " + .name + "  " + (.size|tostring) + " bytes"'