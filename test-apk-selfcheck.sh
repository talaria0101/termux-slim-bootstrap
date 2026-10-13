#!/usr/bin/env bash
# Prove test-apk.py actually fails when the APK is wrong.
#
# Run build-apk.sh first. The targetSdk case needs its intermediate artifacts
# (compiled resources, the linked manifest, the dex list) and skips without
# them rather than passing vacuously.
#
# A structural suite that has only ever seen a good artifact proves nothing: it
# would pass just as happily against a broken one if the checks were vacuous.
# This plants defects, one at a time, in a copy of the real APK and requires
# that each one is caught AND that the specific check responsible is the one
# that fires.
#
# Asserting the specific check matters as much as asserting the non-zero exit.
# Rewriting an APK obviously breaks the signature, so an exit-code-only test
# passes for the wrong reason and would keep passing if the real check were
# deleted. Each case below names the check that must fail.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APK="${1:-$HERE/apk/termux-app_apt-android-7-debug.apk}"
PLANTED="$(mktemp -d)"
trap 'rm -rf "$PLANTED"' EXIT

# Both, not just JAVA_HOME. /usr/bin/java here is a wrapper that sources
# /etc/profile.d/jdk.sh, which does not exist, so it dies before reading
# JAVA_HOME at all. apksigner and zipalign are shell wrappers that call java
# from PATH, so they fail with
#
#   /usr/bin/java: 8: .: /etc/profile.d/jdk.sh: No such file or directory
#
# which looks like a signing failure and is not one.
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/openjdk25}"
export PATH="$JAVA_HOME/bin:$PATH"

if [ ! -f "$APK" ]; then
	printf 'error: no APK at %s\n' "$APK" >&2
	exit 1
fi

fails=0

# expect_catch <label> <planted-apk> <substring that must appear in the failures>
expect_catch() {
	local label="$1" bad="$2" want="$3"
	local out status
	out="$(python3 "$HERE/test-apk.py" "$bad" 2>&1)"
	status=$?
	if [ "$status" -eq 0 ]; then
		printf '  FAIL  %-22s exit 0; the defect was not detected\n' "$label"
		fails=$((fails + 1))
		return
	fi
	if ! printf '%s\n' "$out" | grep -qF "$want"; then
		printf '  FAIL  %-22s exit 1 but the expected check did not fire\n' "$label"
		printf '        wanted a failure mentioning: %s\n' "$want"
		printf '%s\n' "$out" | sed -n '/failures:/,$p' | sed 's/^/        /'
		fails=$((fails + 1))
		return
	fi
	printf '  ok    %-22s caught by: %s\n' "$label" "$want"
}

# plant <output-name> <python-body reading src=argv[1], dst=argv[2]>
plant() {
	local out="$PLANTED/$1.apk"
	shift
	python3 - "$APK" "$out" "$@" || {
		printf '  FAIL  could not build the planted artifact %s\n' "$out" >&2
		fails=$((fails + 1))
	}
	printf '%s' "$out"
}

printf 'proving test-apk.py catches planted defects\n\n'

printf 'baseline\n'
if python3 "$HERE/test-apk.py" "$APK" >/dev/null 2>&1; then
	printf '  ok    the real APK passes\n'
else
	printf '  FAIL  the real APK does not pass; nothing below is meaningful\n'
	exit 1
fi

printf '\nplanted defects\n'

bad="$(plant deflated-arsc <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w") as o:
    for i in z.infolist():
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.compress_type = (zipfile.ZIP_DEFLATED if i.filename == "resources.arsc"
                            else i.compress_type)
        o.writestr(zi, z.read(i.filename))
EOF
)"
expect_catch "deflated resources.arsc" "$bad" "resources.arsc is stored, not deflated"

bad="$(plant stored-so <<'EOF'
import sys, zipfile, re
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w") as o:
    for i in z.infolist():
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.compress_type = (zipfile.ZIP_STORED
                            if re.match(r"lib/.*\.so$", i.filename) else i.compress_type)
        o.writestr(zi, z.read(i.filename))
EOF
)"
expect_catch "stored .so" "$bad" ".so is deflated"

bad="$(plant no-dex <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w") as o:
    for i in z.infolist():
        if i.filename.startswith("classes") and i.filename.endswith(".dex"):
            continue
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.compress_type = i.compress_type
        o.writestr(zi, z.read(i.filename))
EOF
)"
expect_catch "no classes.dex" "$bad" "has classes.dex"

bad="$(plant no-arm64 <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w") as o:
    for i in z.infolist():
        if i.filename.startswith("lib/arm64-v8a/"):
            continue
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.compress_type = i.compress_type
        o.writestr(zi, z.read(i.filename))
EOF
)"
expect_catch "missing arm64 lib" "$bad" "native library for both ABIs"

# The defect that would matter most in the field: a bootstrap that installed
# cleanly but had no gh in it. The zip is rewritten without bin/gh, the .so is
# reassembled around it, and the whole APK is re-aligned and re-signed so the
# signature and every other check still pass. Only the gh check can catch this.
bad="$(plant no-gh <<'EOF'
import sys, zipfile, io, os
src, dst = sys.argv[1], sys.argv[2]
entry = "lib/arm64-v8a/libtermux-bootstrap.so"
with zipfile.ZipFile(src) as z:
    so = bytearray(z.read(entry))
    with zipfile.ZipFile(src) as z2:
        infos = z2.infolist()
        payloads = {i.filename: z2.read(i.filename) for i in infos}

start = bytes(so).find(b"PK\x03\x04")
eocd = bytes(so).rfind(b"PK\x05\x06")
inner = bytes(so[start:eocd + 22])
bz = zipfile.ZipFile(io.BytesIO(inner))
out = io.BytesIO()
with zipfile.ZipFile(out, "w") as o:
    for n in bz.namelist():
        if n == "bin/gh":
            continue
        o.writestr(bz.getinfo(n), bz.read(n))
payloads[entry] = bytes(so[:start]) + out.getvalue() + bytes(so[eocd + 22:])

with zipfile.ZipFile(dst, "w") as o:
    for i in infos:
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.compress_type = i.compress_type
        o.writestr(zi, payloads[i.filename])
EOF
)"
# Re-align and re-sign the planted APK. Rewriting the archive breaks the
# signature, so without this the case would be caught by the wrong check.
#
# zipalign refuses identical input and output paths ("Input and output can't be
# same file"), so the aligned copy is a separate file and is what gets signed.
resign() {
	local bad="$1"
	local aligned="$bad.aligned" signed="$bad.signed"
	"$BT/zipalign" -f -p 4 "$bad" "$aligned" >/dev/null 2>&1 || return 1
	"$BT/apksigner" sign --ks "$GRADLE_APP/app/testkey_untrusted.jks" \
		--ks-key-alias "$ks_alias" --ks-pass "pass:$ks_pass" \
		--key-pass "pass:$ks_pass" --min-sdk-version 21 \
		--out "$signed" "$aligned" >/dev/null 2>&1 || return 1
	mv -f "$signed" "$bad"
}

BT="${BUILD_TOOLS:-/workspace/android-sdk/build-tools/36.0.0}"
GRADLE_APP="${APP_DIR:-/workspace/termux-app}"
ks_pass="$(sed -n "s/^[[:space:]]*keyPassword[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
	"$GRADLE_APP/app/build.gradle" | tail -1)"
ks_alias="$(sed -n "s/^[[:space:]]*keyAlias[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
	"$GRADLE_APP/app/build.gradle" | tail -1)"

if resign "$bad"; then
	expect_catch "no gh in bootstrap" "$bad" "has bin/gh"
else
	printf '  FAIL  %-22s could not re-sign the planted APK\n' "no gh in bootstrap"
	fails=$((fails + 1))
fi

# The targetSdkVersion case is built the honest way: re-link the resources with
# a different --target-sdk-version, re-merge, re-align and re-sign. Anything
# cheaper would corrupt the signature and trip the wrong check, which is exactly
# the flaw this script exists to avoid.
#
# This matters more than the other cases. targetSdk 28 is what grants Termux the
# W^X exec exemption on Android 10+, so an APK with targetSdk 33 installs
# cleanly and then fails at the first exec. A check that only reads the manifest
# is the only thing standing between that and a user.
printf '\nspecial case: wrong targetSdkVersion, rebuilt and re-signed properly\n'
# Not under $PLANTED: that directory is removed by the EXIT trap, and the
# intermediate artifacts have to survive until the final check reads them.
TS="${TMPDIR:-/tmp}/termux-selfcheck-targetsdk.$$"
mkdir -p "$TS"
trap 'rm -rf "$PLANTED" "$TS" "$NOR"' EXIT
SDK="${ANDROID_SDK_ROOT:-/workspace/android-sdk}"
WORK="${WORK_DIR:-$HERE/apk-work}"

if [ -d "$WORK/res" ] && [ -f "$WORK/AndroidManifest.xml" ] && [ -f "$WORK/flats-order.txt" ]; then
	flats=()
	while read -r f; do flats+=(-R "$f"); done <"$WORK/flats-order.txt"
	"$BT/aapt2" link -I "$SDK/platforms/android-36/android.jar" \
		--manifest "$WORK/AndroidManifest.xml" \
		--min-sdk-version 21 --target-sdk-version 33 \
		--version-code 118 --version-name 0.118.0 --auto-add-overlay \
		-o "$TS/base.apk" "${flats[@]}" 2>/dev/null
	if [ -s "$TS/base.apk" ]; then
		python3 "$HERE/merge-libs.py" "$TS/base.apk" "$WORK/apk/lib" \
			--dex-list "$WORK/dexfiles.txt" >/dev/null
		"$BT/zipalign" -f -p 4 "$TS/base.apk" "$TS/al.apk"
		if "$BT/apksigner" sign --ks "$GRADLE_APP/app/testkey_untrusted.jks" \
			--ks-key-alias "$ks_alias" --ks-pass "pass:$ks_pass" \
			--key-pass "pass:$ks_pass" --min-sdk-version 21 \
			--out "$TS/bad.apk" "$TS/al.apk" 2>"$TS/sign.log"; then
			# Confirm it really is the targetSdk that differs, so this cannot
			# pass by tripping some unrelated check.
			# aapt2 dump writes its last line without a trailing newline, so
			# grep -q in a pipe never sees that line as complete and the
			# match silently fails. Read into a variable instead.
			badging="$("$BT/aapt2" dump badging "$TS/bad.apk" 2>/dev/null)"
			case "$badging" in
			*"targetSdkVersion:'33'"*)
				expect_catch "targetSdk 33" "$TS/bad.apk" "targetSdkVersion is 28"
				;;
			*)
				printf '  FAIL  %-22s the rebuilt APK is not targetSdk 33, case is void\n' \
					"targetSdk 33"
				fails=$((fails + 1))
				;;
			esac
		else
			printf '  FAIL  %-22s could not re-sign the rebuilt APK\n' "targetSdk 33"
			grep -v '^WARNING' "$TS/sign.log" | head -5 | sed 's/^/        /'
			fails=$((fails + 1))
		fi
	else
		printf '  SKIP  %-22s no compiled resources in %s\n' "targetSdk 33" "$WORK"
	fi
else
	printf '  SKIP  %-22s build-apk.sh has not been run (%s missing)\n' "targetSdk 33" "$WORK"
fi

# The R-class defect: every library R class stripped from the dex. This is the
# pre-fix APK. Published AARs do not ship R, so library bytecode references
# e.g. androidx.cardview.R$attr through a real getstatic, and the loader throws
# NoClassDefFoundError on first use. Rebuilt here from the real dex rather than
# approximated, so the case cannot pass by tripping an unrelated check.
printf '\nspecial case: every library R class stripped from the dex\n'
NOR="${TMPDIR:-/tmp}/termux-selfcheck-nor.$$"
rm -rf "$NOR"
mkdir -p "$NOR"
trap 'rm -rf "$PLANTED" "$TS" "$NOR"' EXIT

if [ -d "$WORK/dexinput" ] && [ -f "$WORK/dexfiles.txt" ]; then
	cp -a "$WORK/dexinput" "$NOR/dexinput"
	before="$(find "$NOR/dexinput" -path '*/androidx/*' -name 'R*.class' | wc -l)"
	find "$NOR/dexinput/androidx" -name 'R*.class' -delete 2>/dev/null
	after="$(find "$NOR/dexinput" -path '*/androidx/*' -name 'R*.class' | wc -l)"
	if [ "$before" -eq 0 ] || [ "$after" -ne 0 ]; then
		printf '  FAIL  %-22s could not strip the library R classes (%s -> %s)\n' \
			"no library R" "$before" "$after"
		fails=$((fails + 1))
	else
		(cd "$NOR/dexinput" && "$JAVA_HOME/bin/jar" --create --file "$NOR/in.jar" .)
		mkdir -p "$NOR/dex"
		"$BT/d8" --release --min-api 21 \
			--lib "$SDK/platforms/android-36/android.jar" \
			--lib "$WORK/stub/classes" \
			--lib "$WORK/dl/desugar_jdk_libs.jar" \
			--output "$NOR/dex" "$NOR/in.jar" >/dev/null 2>&1
		ls "$NOR"/dex/*.dex > "$NOR/dexlist.txt" 2>/dev/null
		flats=()
		while read -r f; do flats+=(-R "$f"); done <"$WORK/flats-order.txt"
		"$BT/aapt2" link -I "$SDK/platforms/android-36/android.jar" \
			--manifest "$WORK/AndroidManifest.xml" \
			--min-sdk-version 21 --target-sdk-version 28 \
			--version-code 118 --version-name 0.118.0 --auto-add-overlay \
			-o "$NOR/base.apk" "${flats[@]}" 2>/dev/null
		if [ -s "$NOR/base.apk" ] && [ -s "$NOR/dexlist.txt" ]; then
			python3 "$HERE/merge-libs.py" "$NOR/base.apk" "$WORK/apk/lib" \
				--dex-list "$NOR/dexlist.txt" >/dev/null
			"$BT/zipalign" -f -p 4 "$NOR/base.apk" "$NOR/al.apk" >/dev/null 2>&1
			if "$BT/apksigner" sign --ks "$GRADLE_APP/app/testkey_untrusted.jks" \
				--ks-key-alias "$ks_alias" --ks-pass "pass:$ks_pass" \
				--key-pass "pass:$ks_pass" --min-sdk-version 21 \
				--out "$NOR/bad.apk" "$NOR/al.apk" >/dev/null 2>&1; then
				expect_catch "no library R" "$NOR/bad.apk" \
					"every referenced library R class is present"
			else
				printf '  FAIL  %-22s could not re-sign\n' "no library R"
				fails=$((fails + 1))
			fi
		else
			printf '  FAIL  %-22s could not rebuild the stripped APK\n' "no library R"
			fails=$((fails + 1))
		fi
	fi
else
	printf '  SKIP  %-22s %s/dexinput missing; build-apk.sh first\n' "no library R" "$WORK"
fi

printf '\n'
if [ "$fails" -ne 0 ]; then
	printf '%d planted defect(s) slipped through\n' "$fails"
	exit 1
fi
printf 'every planted defect was caught by the check meant to catch it\n'