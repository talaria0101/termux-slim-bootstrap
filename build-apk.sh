#!/usr/bin/env bash
# Build the Termux APK by hand, without Gradle.
#
# Why not Gradle: this sandbox denies every socket bind, including loopback
# ephemeral ports, and Gradle 9 forks a daemon that requires one:
#
#     CapEff: 0000000000000000          (no capabilities at all)
#     java.net.BindException: Permission denied
#     python: socket.bind(('127.0.0.1', 0)) -> PermissionError
#
# --no-daemon, --foreground and org.gradle.daemon=false were all tried. Gradle 9
# runs DaemonTcpServerConnector.start() in every mode, including foreground, so
# none of them help. The build is done with the SDK tools directly instead.
#
# What this does, in order:
#   1. resolve the AAR dependencies the sources import
#   2. extract each AAR's classes.jar and merge its resources
#   3. compile all Java against android.jar plus those jars
#   4. compile and link the native bootstrap library with the NDK
#   5. dex the classes with d8
#   6. link resources with aapt2, then package, align and sign
#
# Debug-signed with termux-app's own testkey_untrusted.jks, which is what the
# upstream debug build uses. Not a release key and not for distribution.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP="${APP_DIR:-/workspace/termux-app}"
SDK="${ANDROID_SDK_ROOT:-/workspace/android-sdk}"
NDK="${NDK_HOME:-/workspace/android-sdk/ndk/29.0.14206865}"
OUT="${OUT_DIR:-$HERE/apk}"
WORK="${WORK_DIR:-$HERE/apk-work}"

# Build-tools 36.0.0 specifically, not "whichever is newest". The d8 in
# build-tools 34.0.0 is R8 8.2.2, and it crashes with an internal
# NullPointerException on any anonymous inner class:
#
#   Error in .../HelpActivity$1.class:
#   java.lang.NullPointerException: Cannot invoke "String.length()" because
#   "<parameter1>" is null
#
# An anonymous class has a null inner_name in its InnerClasses attribute, and
# that R8 version dereferences it. Reproduced on a four-line file
# (`return new Runnable() { public void run() {} }`) with the outer class
# present on the same command line, so it is not a missing-classpath artifact.
# A named nested class dexes fine on the same d8, which is what makes the
# anonymous case the trigger. The identical input dexes cleanly on the d8 in
# build-tools 36.0.0, so this is an R8 bug rather than anything about the
# project's sources.
BUILD_TOOLS="$SDK/build-tools/36.0.0"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

step() { printf '\n=== %s\n' "$1"; }

[ -d "$APP" ] || die "termux-app not found at $APP"
[ -x "$BUILD_TOOLS/aapt2" ] || die "aapt2 not found in $BUILD_TOOLS; run sdkmanager for build-tools;36.0.0"
[ -f "$ANDROID_JAR" ] || die "android.jar not found at $ANDROID_JAR"
[ -d "$NDK" ] || die "NDK not found at $NDK"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API=24

# Pin the JDK before anything shells out to a tool that wants java on PATH.
# /usr/bin/java is a wrapper whose first two lines are
#
#     . /etc/profile.d/jdk.sh
#     [ -d "$JAVA_HOME" ] || die ...
#
# and /etc/profile.d does not exist here, so the wrapper dies with
#
#   /usr/bin/java: 8: .: /etc/profile.d/jdk.sh: No such file or directory
#
# before it ever looks at JAVA_HOME. Exporting JAVA_HOME therefore cannot fix
# it, and every SDK wrapper script (d8, apksigner, zipalign) fails this way.
# The failure looks like a d8 problem and is not one. Putting a real java
# first on PATH is what actually resolves it.
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/openjdk25}"
[ -x "$JAVA_HOME/bin/java" ] || die "no java at $JAVA_HOME/bin/java"
[ -x "$JAVA_HOME/bin/javac" ] || die "no javac at $JAVA_HOME/bin/javac"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"

# Confirm the wrapper problem is actually gone, rather than assuming the PATH
# change worked.
if ! "$JAVA" -version >/dev/null 2>&1; then
	die "$JAVA_HOME/bin/java does not run"
fi

mkdir -p "$OUT"
rm -rf "$WORK"
mkdir -p "$WORK"/{classes,dex,res,jni,apk}

# --- 1. dependencies -------------------------------------------------------
#
# resolve-deps.py walks the POM graph itself. A hand-written list is not enough:
# the sources import transitive types (org.commonmark.node.Node for markwon's
# ext-strikethrough, javax.annotation.Nullable via guava's jsr305,
# org.jetbrains.annotations.NotNull via kotlin-stdlib), and a list that names
# only the direct dependencies fails to resolve all three.

GOOGLE_MAVEN="https://dl.google.com/dl/android/maven2"

fetch() {
	# fetch <url> <dest>: download unless already present.
	local url="$1" dest="$2"
	if [ -f "$dest" ] && [ -s "$dest" ]; then
		return 0
	fi
	mkdir -p "$(dirname "$dest")"
	printf '  fetch %s\n' "$(basename "$dest")"
	if ! curl -sSfL -o "$dest" "$url"; then
		printf '  FAILED: %s\n' "$url" >&2
		return 1
	fi
}

DL="$WORK/dl"
step "resolving dependencies"
python3 "$HERE/resolve-deps.py" "$DL" || die "dependency resolution failed"

JARS=()
# Read through a temp file rather than <(...): this sandbox has no /dev/fd, so
# process substitution fails with "No such file or directory" and silently
# drops every array element.
find "$DL" -maxdepth 1 \( -name '*.aar' -o -name '*.jar' \) ! -name 'desugar_jdk_libs*' | sort > "$WORK/jars.txt"
while read -r f; do JARS+=("$f"); done < "$WORK/jars.txt"
printf '  %d artifacts\n' "${#JARS[@]}"

step "extracting AAR classes and resources"
AAR_JARS=()
AAR_RES=()
AAR_DIRS=()
for aar in "${JARS[@]}"; do
	case "$aar" in
	*.aar)
		name="$(basename "$aar")"
		name="${name%.aar}"
		dir="$DL/aar-$name"
		mkdir -p "$dir"
		unzip -qo "$aar" -d "$dir" || die "could not unpack $aar"
		if [ -f "$dir/classes.jar" ]; then
			AAR_JARS+=("$dir/classes.jar")
		fi
		# Every AAR is recorded, including the 26 that carry no resources at
		# all. AAR_DIRS is what the R-class namespace list is derived from, and
		# an AAR with no res/ still has bytecode that may reference its own
		# R class. Deriving the list from AAR_RES instead silently dropped
		# androidx.cursoradapter, androidx.loader, androidx.print,
		# androidx.viewpager and 16 more.
		AAR_DIRS+=("$dir")
		if [ -d "$dir/res" ]; then
			AAR_RES+=("$dir/res")
		fi
		;;
	*.jar) AAR_JARS+=("$aar") ;;
	esac
done
printf '  %d jars on the compile classpath\n' "${#AAR_JARS[@]}"
printf '  %d AARs, %d with resource trees\n' "${#AAR_DIRS[@]}" "${#AAR_RES[@]}"

# --- 2. resources ---------------------------------------------------------

step "compiling and linking resources"

# Every res/ that contributes to the APK: the app's own, each library
# project's, and each AAR's.
#
# Each tree is compiled into its OWN output directory, and they are not merged
# first. Both facts are load-bearing:
#
#   cp -a a/res/. merged/ overwrites: every AAR names its files
#     res/values/values.xml, so the copies land on each other and link then
#     fails on missing styles (Base.V7.Theme.AppCompat.Dialog) and colours.
#
#   aapt2 compile --dir a --dir b -o one_dir collides: aapt2 names each flat
#     after the resource type and name only, values_strings.arsc.flat, so two
#     unrelated strings.xml files overwrite one another. Verified: compiling
#     two dirs each holding values/strings.xml into one output dir yields one
#     flat file, not two.
#
# Separate output directories need no renaming at all, which also sidesteps
# aapt2's rule that a resource filename may not contain '.' outside the
# extension, a rule that renaming nine-patch .9.png files trips over.
RES_DIRS=("$APP/app/src/main/res" "$APP/termux-shared/src/main/res"
	"$APP/terminal-view/src/main/res")
for d in "${AAR_RES[@]}"; do RES_DIRS+=("$d"); done

COMPILED="$WORK/res/compiled"
mkdir -p "$COMPILED"

# Order matters for overrides: the app's resources must come last so they win
# over any library that defines the same name. aapt2 takes the last definition.
i=0
: > "$WORK/flats-order.txt"
# Library trees first, app's last.
for d in "${RES_DIRS[@]:1}" "${RES_DIRS[0]}"; do
	[ -d "$d" ] || continue
	out="$COMPILED/$i"
	i=$((i + 1))
	mkdir -p "$out"
	if ! "$BUILD_TOOLS/aapt2" compile --dir "$d" -o "$out" 2>"$WORK/aapt2-compile.log"; then
		printf 'aapt2 compile failed for %s:\n' "$d"
		tail -25 "$WORK/aapt2-compile.log"
		exit 1
	fi
	# Record this tree's flats in compile order. The order is the override
	# order, so sorting the list afterwards would silently give the app's
	# resources no priority over a library's.
	find "$out" -name '*.flat' | sort >> "$WORK/flats-order.txt"
done

# The manifest needs two substitutions Gradle normally makes.
#
#   ${TERMUX_PACKAGE_NAME} is a manifestPlaceholder (app/build.gradle:54).
#   the package attribute is absent because AGP takes it from
#     `namespace "com.termux"` (app/build.gradle:16) rather than the file.
MANIFEST="$WORK/AndroidManifest.xml"
python3 - "$APP/app/src/main/AndroidManifest.xml" "$MANIFEST" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
text = text.replace("${TERMUX_PACKAGE_NAME}", "com.termux")
# Insert package="com.termux" into the <manifest ...> start tag, unless the
# source manifest already declares one.
if not re.search(r"<manifest[^>]*\bpackage\s*=", text, re.S):
    text = re.sub(r"(<manifest\b)", r'\1 package="com.termux"', text, count=1)
if "${" in text:
    leftover = sorted(set(re.findall(r"\$\{([A-Za-z_]+)\}", text)))
    sys.stderr.write("error: unsubstituted manifest placeholders: %s\n"
                     % ", ".join(leftover))
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(text)
PYEOF

GEN="$WORK/gen"
mkdir -p "$GEN"

# Link once to get R.java. The app's own resources win over library ones, so
# the app's res/ must be listed first: aapt2 takes the first definition it
# sees for a given name.
# This pass exists only to generate R.java. aapt2 writes no APK while --java is
# present, which is why packaging below builds the APK with a separate
# invocation. -o is still given because aapt2 requires a value for it.
AAPT_OUT="$WORK/res/base.apk"
AAPT_LINK=("$BUILD_TOOLS/aapt2" link
	-I "$ANDROID_JAR"
	--manifest "$MANIFEST"
	--java "$GEN"
	--min-sdk-version 21
	--target-sdk-version 28
	--version-code 118
	--version-name 0.118.0
	--auto-add-overlay
	-o "$AAPT_OUT")

FLATS=()
while read -r f; do FLATS+=(-R "$f"); done < "$WORK/flats-order.txt"
printf '  %s compiled resource files from %s trees\n' "${#FLATS[@]}" "$i"

"${AAPT_LINK[@]}" "${FLATS[@]}" 2>"$WORK/aapt2-link.log" || {
	printf 'aapt2 link failed:\n'
	tail -30 "$WORK/aapt2-link.log"
	exit 1
}

# One R class per namespace in the dependency graph. aapt2 generates R only for
# the package named in the manifest, so every library namespace needs its own
# link pass with --custom-package.
#
# This must cover ALL of them, not just the ones Termux's own sources import.
# Published AARs do not ship an R class of their own: appcompat 1.6.1's
# classes.jar contains zero R$ entries, because R is generated per application,
# not per library. So the library bytecode references e.g.
# androidx.cardview.R$attr.cardViewStyle as a real getstatic, and that class has
# to be in the APK or the loader throws NoClassDefFoundError the first time a
# CardView is inflated.
#
# An earlier build generated only four namespaces (com.termux from the manifest,
# plus com.termux.shared, com.termux.view and androidx.appcompat). The official
# Termux v0.118.3 arm64 APK has R classes for 46 namespaces; that build had 4.
# Verified by listing the class descriptors of both.
#
# The namespace of each AAR is its own package attribute in its AndroidManifest,
# so the list is read from the artifacts rather than hardcoded. Two -ktx AARs
# declare a package with a ".ktx" suffix (androidx.activity.ktx,
# androidx.core.ktx) that no code ever references; those are still generated,
# because aapt2 is the only thing that can decide whether a namespace is needed
# and generating a harmless extra R costs a few KB.
R_NAMESPACES=()
: > "$WORK/namespaces.txt"
# The manifest package is generated by the main link pass.
printf 'com.termux\n' >> "$WORK/namespaces.txt"
for d in "${AAR_DIRS[@]}"; do
	pkg="$(sed -n 's/.*package="\([^"]*\)".*/\1/p' "$d/AndroidManifest.xml" 2>/dev/null | head -1)"
	[ -n "$pkg" ] && printf '%s\n' "$pkg" >> "$WORK/namespaces.txt"
done
# The three library projects in this repo, from their `namespace` in build.gradle.
for proj in termux-shared terminal-view terminal-emulator; do
	pkg="$(sed -n 's/^[[:space:]]*namespace[[:space:]]*[=]*[[:space:]]*"\([^"]*\)".*/\1/p' \
		"$APP/$proj/build.gradle" 2>/dev/null | head -1)"
	[ -n "$pkg" ] && printf '%s\n' "$pkg" >> "$WORK/namespaces.txt"
done
# Sort and drop duplicates; aapt2 is invoked once per namespace.
sort -u "$WORK/namespaces.txt" | grep -v '^com.termux$' > "$WORK/namespaces-extra.txt"
while read -r pkg; do R_NAMESPACES+=("$pkg"); done < "$WORK/namespaces-extra.txt"

for pkg in "${R_NAMESPACES[@]}"; do
	outdir="$GEN"
	"$BUILD_TOOLS/aapt2" link \
		-I "$ANDROID_JAR" \
		--manifest "$MANIFEST" \
		--java "$outdir" \
		--custom-package "$pkg" \
		--min-sdk-version 21 \
		--target-sdk-version 28 \
		--version-code 118 \
		--version-name 0.118.0 \
		--auto-add-overlay \
		-o "$WORK/res/base-$pkg.apk" \
		"${FLATS[@]}" 2>"$WORK/aapt2-link-$pkg.log" || {
		printf 'aapt2 link for %s failed:\n' "$pkg"
		tail -20 "$WORK/aapt2-link-$pkg.log"
		exit 1
	}
done

for pkg in "${R_NAMESPACES[@]}"; do
	[ -f "$GEN/$(printf '%s' "$pkg" | tr . /)/R.java" ] ||
		die "aapt2 did not generate $pkg/R.java"
done
[ -f "$GEN/com/termux/R.java" ] || die "aapt2 did not generate com/termux/R.java"
printf '  generated R for %s namespaces (%s project namespaces + %s AARs)\n' \
	"$(( ${#R_NAMESPACES[@]} + 1 ))" "3" "${#AAR_RES[@]}"

# --- 3. compile ------------------------------------------------------------

step "compiling Java"

# The app's own sources, plus the three library projects it depends on.
find "$APP/app/src/main/java" "$APP/termux-shared/src/main/java" \
	"$APP/terminal-view/src/main/java" "$APP/terminal-emulator/src/main/java" \
	-name "*.java" > "$WORK/sources.txt"

# R.java, generated by aapt2 above, is a source file like any other.
find "$GEN" -name 'R.java' >> "$WORK/sources.txt"

printf '  %s source files\n' "$(wc -l <"$WORK/sources.txt")"

# BuildConfig is the one generated class aapt2 does not produce. It belongs in
# the namespace package com.termux (app/build.gradle:16), not in the app's own
# com.termux.app: the sources import com.termux.BuildConfig directly.
mkdir -p "$GEN/com/termux"
if [ -f "$GEN/com/termux/BuildConfig.java" ]; then
	printf '  note: aapt2 produced a BuildConfig; leaving it alone\n'
else
	cat > "$GEN/com/termux/BuildConfig.java" <<'EOF'
package com.termux;

/** Hand-written stand-in for the BuildConfig AGP generates. */
public final class BuildConfig {
	/** Must match the packageVariant the bootstrap was built for. */
	public static final String TERMUX_PACKAGE_VARIANT = "apt-android-7";
	public static final boolean DEBUG = true;
	public static final String APPLICATION_ID = "com.termux";
	public static final String BUILD_TYPE = "debug";
	public static final int VERSION_CODE = 118;
	public static final String VERSION_NAME = "0.118.0";
}
EOF
fi
echo "$GEN/com/termux/BuildConfig.java" >> "$WORK/sources.txt"

CP="$ANDROID_JAR"
for j in "${AAR_JARS[@]}"; do
	CP="$CP:$j"
done

# android.jar has no java.lang.invoke.LambdaMetafactory. Confirmed by listing
# the archive: java/lang/invoke/ holds 18 entries and LambdaMetafactory is not
# among them, even though the class does exist on a real device.
#
# That breaks javac on any lambda. javac emits invokedynamic and resolves
# LambdaMetafactory.metafactory against the boot classpath, so with
# -bootclasspath android.jar alone every lambda in the project is a compile
# error:
#
#   SettingsActivity.java:115: error: cannot find symbol
#       symbol: method metafactory(...)  location: interface LambdaMetafactory
#
# The obvious fix, dropping -bootclasspath, is worse than the disease. With
# android.jar only on the classpath, javac resolves java.* against the host
# JDK, so APIs that exist on JDK 25 and not on Android compile cleanly and
# produce a dex file that fails at runtime. Verified: List.reversed() (a JDK 21
# SequencedCollection method) compiles against android.jar on the classpath,
# and d8 dexes it without complaint, because d8 checks neither the API level
# of a call nor the existence of the method.
#
# So the stub is compiled against android.jar and added to the boot classpath
# only. It supplies the one signature javac needs; it is never dexed into the
# APK, and the device supplies the real implementation.
STUB="$WORK/stub"
mkdir -p "$STUB/src/java/lang/invoke" "$STUB/classes"
cat > "$STUB/src/java/lang/invoke/LambdaMetafactory.java" <<'EOF'
package java.lang.invoke;

/**
 * Compile-time stub, never packaged.
 *
 * android.jar omits this class although the device provides it. The body
 * throws rather than returning null so that anything which ever reached it at
 * runtime fails loudly instead of dereferencing a null CallSite.
 */
public final class LambdaMetafactory {
	public static CallSite metafactory(MethodHandles.Lookup caller, String interfaceMethodName,
			MethodType factoryType, MethodType interfaceMethodType, MethodHandle implementation,
			MethodType dynamicMethodType) throws LambdaConversionException {
		throw new UnsupportedOperationException("compile-time stub, never packaged");
	}
}
EOF
"$JAVAC" -source 8 -target 8 -nowarn \
	-bootclasspath "$ANDROID_JAR" -d "$STUB/classes" \
	"$STUB/src/java/lang/invoke/LambdaMetafactory.java" 2>"$WORK/stub.log" || {
	printf 'could not compile the LambdaMetafactory stub:\n'
	cat "$WORK/stub.log"
	exit 1
}
BOOTCP="$ANDROID_JAR:$STUB/classes"

# Guava is needed at compile time and is a plain jar, so it is on the classpath
# already. The Android platform jar has stub methods that throw, which is fine for
# compiling: the real implementations are in the device's framework.
set +e
javac_bin="$JAVAC"
"$javac_bin" \
	-source 8 -target 8 \
	-bootclasspath "$BOOTCP" \
	-classpath "$CP" \
	-encoding UTF-8 \
	-nowarn \
	-proc:none \
	-d "$WORK/classes" \
	@"$WORK/sources.txt" 2>"$WORK/javac.log"
javac_status=$?
set -e

if [ "$javac_status" -ne 0 ]; then
	printf 'javac failed, first errors:\n'
	grep -E "error:|错误" "$WORK/javac.log" | head -25
	printf '\n(%s errors total)\n' "$(grep -c 'error:' "$WORK/javac.log")"
	exit 1
fi
printf '  compiled %s classes\n' "$(find "$WORK/classes" -name '*.class' | wc -l)"

# --- 3. native -------------------------------------------------------------

step "building the native bootstrap library"
# libtermux-bootstrap.so carries the bootstrap zip as a byte array and hands it to
# TermuxInstaller. Built for one ABI at a time because the .S file selects on
# preprocessor macros.
for abi in arm64-v8a armeabi-v7a; do
	case "$abi" in
	arm64-v8a)
		ARCH=arm64
		TARGET=aarch64-linux-android
		;;
	armeabi-v7a)
		ARCH=arm
		TARGET=armv7a-linux-androideabi
		;;
	esac
	cc="$TOOLCHAIN/bin/${TARGET}${API}-clang"

	mkdir -p "$WORK/jni/$abi"
	# The .incbin name must match the arch: bootstrap-aarch64.zip or bootstrap-arm.zip.
	arch_zip="aarch64"
	[ "$ARCH" = "arm" ] && arch_zip="arm"
	src_dir="$WORK/jni/$abi"
	cp "$APP/app/src/main/cpp/termux-bootstrap-zip.S" "$src_dir/"
	cp "$APP/app/src/main/cpp/termux-bootstrap.c" "$src_dir/"

	if [ -f "$APP/$HERE/slim/$arch_zip.zip" ]; then
		cp "$APP/$HERE/slim/$arch_zip.zip" "$src_dir/bootstrap-$arch_zip.zip"
	else
		cp "$APP/app/src/main/cpp/bootstrap-$arch_zip-slim.zip" "$src_dir/bootstrap-$arch_zip.zip"
	fi

	(cd "$src_dir" && "$cc" -shared -fPIC -O2 -o "libtermux-bootstrap.so" \
		termux-bootstrap.c termux-bootstrap-zip.S)

	printf '  %-14s %s\n' "$abi" "$(du -h "$src_dir/libtermux-bootstrap.so" | cut -f1)"
done

# --- 4. dex ----------------------------------------------------------------

step "dexing"
# d8 needs the desugared library for the Java 8 time APIs on old devices, or it
# will not link.
#
# Version note: app/build.gradle:123 declares desugar_jdk_libs:1.1.5, but that
# release predates the d8 in build-tools 36.0.0 and does not supply the
# j$.desugar... classes it expects. 2.1.5 is used instead.
DESUGAR="$DL/desugar_jdk_libs.jar"
fetch "$GOOGLE_MAVEN/com/android/tools/desugar_jdk_libs/2.1.5/desugar_jdk_libs-2.1.5.jar" "$DESUGAR" ||
	die "could not fetch desugar_jdk_libs"

# Flatten the project's own classes together with every dependency jar first.
# Doing it here rather than handing d8 the raw jars means a class defined
# differently by two jars is reported as such, instead of surfacing as d8's
# "defined multiple times" after resources have already been linked.
ALLJARS=("$WORK/classes.jar")
for j in "${AAR_JARS[@]}"; do
	[ -f "$j" ] && ALLJARS+=("$j")
done

# The project's own classes are already loose files; zip them so the flattener
# has one input shape to read.
(cd "$WORK/classes" && "$JAVA" -version >/dev/null 2>&1;
 find . -name '*.class' -printf '%P\n' > "$WORK/classfiles.txt")
"$JAVA_HOME/bin/jar" --create --file "$WORK/classes.jar" \
	-C "$WORK/classes" . 2>"$WORK/jar.log" || {
	printf 'could not jar the project classes:\n'
	tail -10 "$WORK/jar.log"
	exit 1
}

DEXDIR="$WORK/dexinput"
rm -rf "$DEXDIR"
mkdir -p "$DEXDIR"
python3 "$HERE/assemble-classes.py" "$DEXDIR" "${ALLJARS[@]}" || {
	printf 'class assembly failed (see above for the conflicting jars)\n'
	exit 1
}

# d8 accepts a jar or a .class file as program input but not a bare directory
# ("Unsupported source file type"), so the flattened tree is re-zipped.
DEXJAR="$WORK/dexinput.jar"
"$JAVA_HOME/bin/jar" --create --file "$DEXJAR" -C "$DEXDIR" . 2>"$WORK/jar2.log" || {
	printf 'could not jar the flattened classes:\n'
	tail -10 "$WORK/jar2.log"
	exit 1
}

# One dex file. --file-per-class is deliberately not used: it emits one dex per
# class (9649 of them here) and every one of them has to be opened and its
# header parsed at process start. classes.dex is what the loader looks for and
# a single dex is well inside the 64K method limit at this size.
"$BUILD_TOOLS/d8" \
	--release \
	--min-api 21 \
	--lib "$ANDROID_JAR" \
	--lib "$STUB/classes" \
	--lib "$DESUGAR" \
	--output "$WORK/dex" \
	"$DEXJAR" 2>"$WORK/d8.log" || {
	printf 'd8 failed:\n'
	tail -20 "$WORK/d8.log"
	exit 1
}
printf '  %s dex files\n' "$(find "$WORK/dex" -name '*.dex' | wc -l)"

# --- 5. package ------------------------------------------------------------

step "packaging"

# The native library goes in lib/<abi>/. app/build.gradle:126 sets
# useLegacyPackaging true, which means extractNativeLibs=true: the loader
# reads the .so from the APK rather than mapping it in place, so the entries
# are compressed. Storing them uncompressed is what an aligned APK expects for
# the other case and is wrong for this one.
for abi in arm64-v8a armeabi-v7a; do
	[ -f "$WORK/jni/$abi/libtermux-bootstrap.so" ] || die "no native lib for $abi"
	mkdir -p "$WORK/apk/lib/$abi"
	cp "$WORK/jni/$abi/libtermux-bootstrap.so" "$WORK/apk/lib/$abi/"
done

# aapt2 link builds the resource-only APK. It cannot take the dex files as
# inputs: passing one produces
#
#   magic value is 0x0a786564 but AAPT expects 0x54504141
#
# because aapt2 expects an APTA archive and a dex file starts with "dex\n".
# There is no --dex flag either. AGP does the same thing: link the resources,
# then merge classes*.dex into the resulting APK.
find "$WORK/dex" -name '*.dex' | sort > "$WORK/dexfiles.txt"
DEX_COUNT="$(wc -l <"$WORK/dexfiles.txt")"
[ "$DEX_COUNT" -gt 0 ] || die "no dex files produced"

# The R.java pass above also passed --java, and aapt2 behaves differently when
# it is present: it generates R.java and ignores -o entirely, exiting 0 without
# writing the output file. Verified directly: link with -o and no --java writes
# the APK, link with both writes nothing and still reports success.
#
# So packaging is a separate aapt2 link with no --java. It reuses the same
# arguments otherwise, and the manifest placeholder substitution is already
# baked into $MANIFEST.
UNSIGNED="$WORK/apk/unsigned.apk"
AAPT_PKG=("$BUILD_TOOLS/aapt2" link
	-I "$ANDROID_JAR"
	--manifest "$MANIFEST"
	--min-sdk-version 21
	--target-sdk-version 28
	--version-code 118
	--version-name 0.118.0
	--auto-add-overlay
	-o "$UNSIGNED")

"${AAPT_PKG[@]}" "${FLATS[@]}" 2>"$WORK/aapt2-pkg.log" || {
	printf 'aapt2 package step failed:\n'
	tail -30 "$WORK/aapt2-pkg.log"
	exit 1
}
# aapt2 can exit 0 without producing output, so the file is checked rather than
# the exit code alone.
[ -s "$UNSIGNED" ] || die "aapt2 link exited 0 but wrote no APK at $UNSIGNED"

# Merge in the dex files and the native libraries. zipfile rewrites the
# archive, so resources.arsc keeps its content but moves; zipalign below fixes
# the offsets that matter, since it is stored uncompressed.
python3 "$HERE/merge-libs.py" "$UNSIGNED" "$WORK/apk/lib" \
	--dex-list "$WORK/dexfiles.txt" || die "could not merge dex and native libs"

step "aligning"
ALIGNED="$WORK/apk/aligned.apk"
"$BUILD_TOOLS/zipalign" -f -p 4 "$UNSIGNED" "$ALIGNED" || die "zipalign failed"

step "signing"
# Read the debug keystore settings out of the project's own build.gradle rather
# than repeating them here. The alias is 'alias', not a tool default, and
# getting it wrong produces "Failed to load signer" from deep inside the JDK.
KEYSTORE="$APP/app/testkey_untrusted.jks"
[ -f "$KEYSTORE" ] || die "test keystore not found at $KEYSTORE"

gradle_prop() {
	# gradle_prop <key>: last assignment of key in app/build.gradle.
	sed -n "s/^[[:space:]]*$1[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" \
		"$APP/app/build.gradle" | tail -1
}
KEY_ALIAS="$(gradle_prop keyAlias)"
KEY_PASS="$(gradle_prop keyPassword)"
[ -n "$KEY_ALIAS" ] || die "could not read keyAlias from app/build.gradle"
[ -n "$KEY_PASS" ] || die "could not read keyPassword from app/build.gradle"

SIGNED="$OUT/termux-app_apt-android-7-debug.apk"
"$BUILD_TOOLS/apksigner" sign \
	--ks "$KEYSTORE" \
	--ks-key-alias "$KEY_ALIAS" \
	--ks-pass "pass:$KEY_PASS" \
	--key-pass "pass:$KEY_PASS" \
	--min-sdk-version 21 \
	--out "$SIGNED" "$ALIGNED" 2>"$WORK/apksigner.log" || {
	printf 'apksigner failed:\n'
	grep -v "^WARNING" "$WORK/apksigner.log" | tail -20
	exit 1
}

"$BUILD_TOOLS/apksigner" verify --min-sdk-version 21 "$SIGNED" || die "signature does not verify"

printf '\n%s\n' "built $SIGNED"
ls -l "$SIGNED" | awk '{printf "  %s bytes\n", $5}'