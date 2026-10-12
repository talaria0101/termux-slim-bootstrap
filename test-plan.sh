#!/usr/bin/env bash
# Checks on the slim bootstrap plan.
#
# Each case is written so it must fail if the plan regresses. A plan that deletes
# bash or termux-exec looks fine and yields an app that cannot start a session, so
# those are asserted directly rather than inferred from the totals.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="$HERE/Packages"
STATUS="$HERE/ex/var/lib/dpkg/status"

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
}

if [ ! -f "$PACKAGES" ] || [ ! -f "$STATUS" ]; then
	printf 'cannot run: need Packages and the stock bootstrap extracted at ex/\n'
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '=== plan guards\n'

python3 "$HERE/plan.py" --write-lists "$PACKAGES" "$STATUS" gh openssh \
	--keep-list "$WORK/keep" --drop-list "$WORK/drop" >/dev/null 2>&1
status=$?
if [ "$status" -eq 0 ]; then
	ok "plan.py --write-lists runs"
else
	no "plan.py --write-lists runs" "exit $status"
	printf '\n0 passed, %d failed\n' "$failed"
	exit 1
fi

# The dependency closure of gh has no shell in it, so the shell has to be
# requested explicitly. Without this the plan drops bash and the app cannot start.
for pkg in bash coreutils termux-exec termux-core; do
	if grep -qx "$pkg" "$WORK/keep"; then
		ok "keeps $pkg"
	else
		no "keeps $pkg" "dropping it would leave no usable session"
	fi
	if grep -qx "$pkg" "$WORK/drop"; then
		no "does not drop $pkg" "present in both keep and drop"
	fi
done

# gh and openssh are the point of the exercise.
for pkg in gh openssh; do
	if grep -qx "$pkg" "$WORK/drop"; then
		no "$pkg is not being removed" "it is absent from stock, so it must be added, not dropped"
	fi
done

# apt and dpkg are the intended removals: nothing in the closure needs them.
# This is a deliberate trade, so it is asserted rather than left implicit.
for pkg in apt dpkg; do
	if grep -qx "$pkg" "$WORK/drop"; then
		ok "drops $pkg (nothing in the closure needs it)"
	else
		no "drops $pkg" "expected it in the drop list"
	fi
done

# The keep and drop lists must not overlap, or a file could be removed after
# being kept.
overlap="$(sort "$WORK/keep" >"$WORK/keep.sorted"; sort "$WORK/drop" >"$WORK/drop.sorted"; comm -12 "$WORK/keep.sorted" "$WORK/drop.sorted" | tr '\n' ' ')"
if [ -z "$overlap" ]; then
	ok "keep and drop lists are disjoint"
else
	no "keep and drop lists are disjoint" "overlap: $overlap"
fi

# Every package named must really exist in the index, so a typo cannot silently
# drop nothing while looking like it worked.
missing=""
while read -r pkg; do
	[ -n "$pkg" ] || continue
	grep -qx "Package: $pkg" "$PACKAGES" || missing="$missing $pkg"
done <"$WORK/drop"
if [ -z "$missing" ]; then
	ok "every dropped package exists in the termux-main index"
else
	no "every dropped package exists in the termux-main index" "not in index:$missing"
fi

# The stock bootstrap has a dpkg status database; the plan must have read it.
stock_count="$(grep -c '^Package: ' "$STATUS")"
if [ "$stock_count" -gt 10 ]; then
	ok "stock status database has $stock_count packages"
else
	no "stock status database looks unreadable" "only $stock_count packages"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]