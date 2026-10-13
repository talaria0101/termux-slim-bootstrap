# Building the APK

`build-apk.sh` builds a Termux APK that carries the slim bootstrap, so the app
ships `gh` and `ssh` instead of the 33MB stock bootstrap. It uses the SDK tools
directly rather than Gradle.

Output: `apk/termux-app_apt-android-7-debug.apk`, ~86MB, signed with
termux-app's own debug keystore.

## Why not Gradle

This sandbox denies every socket bind, including loopback ephemeral ports:

    CapEff: 0000000000000000
    java.net.BindException: Permission denied
    python: socket.bind(('127.0.0.1', 0)) -> PermissionError

Gradle 9 runs `DaemonTcpServerConnector.start()` in every mode, including
`--foreground`, so `--no-daemon`, `--foreground` and `org.gradle.daemon=false`
were all tried and none help. The build is therefore done with `aapt2`, `javac`,
`d8`, the NDK's clang, `zipalign` and `apksigner`.

## Requirements

    ANDROID_SDK_ROOT   with platforms/android-36
    NDK 29.0.14206865
    build-tools 36.0.0        (not 34.0.0, see below)
    a JDK, 17 or newer
    python3
    termux-app checked out at /workspace/termux-app

    export JAVA_HOME=/usr/lib/jvm/openjdk25
    export PATH="$JAVA_HOME/bin:$PATH"

Both exports are needed, and the reason is easy to misread. `/usr/bin/java`
here is a wrapper whose first lines are

    . /etc/profile.d/jdk.sh
    [ -d "$JAVA_HOME" ] || die ...

and `/etc/profile.d` does not exist, so the wrapper dies before it looks at
`JAVA_HOME` at all:

    /usr/bin/java: 8: .: /etc/profile.d/jdk.sh: No such file or directory

`apksigner` and `zipalign` are shell wrappers that call `java` from `PATH`, so
they fail this way too. The failure looks like a signing or alignment problem
and is neither.

    sdkmanager --sdk_root="$ANDROID_SDK_ROOT" "build-tools;36.0.0"

## build-tools 36.0.0 is required

The `d8` in 34.0.0 is R8 8.2.2 and it crashes with an internal
NullPointerException on any anonymous inner class:

    Error in .../HelpActivity$1.class:
    java.lang.NullPointerException: Cannot invoke "String.length()" because
    "<parameter1>" is null

Reproduced on a four-line file (`return new Runnable() { public void run() {} }`)
with the outer class present on the same command line, so it is not a missing
classpath artifact. A named nested class dexes fine on the same `d8`, which is
what makes the anonymous case the trigger. The identical input dexes cleanly on
36.0.0. This is an R8 bug, not a project problem.

## What it does

1. `resolve-deps.py` walks the Maven POM graph and downloads 86 artifacts.
2. Each AAR's `classes.jar` and `res/` are extracted.
3. `aapt2 compile` per resource tree, then `aapt2 link` to generate four R
   classes.
4. `javac` compiles 183 source files.
5. The NDK builds `libtermux-bootstrap.so` for arm64-v8a and armeabi-v7a, each
   embedding the matching slim bootstrap zip via `.incbin`.
6. `d8` dexes everything into one `classes.dex`.
7. `aapt2 link` builds the resource APK, dex and native libs are merged in,
   then `zipalign` and `apksigner`.

## Things that are easy to get wrong

**AAR resource trees must not be merged together.** Every AAR names its files
`res/values/values.xml`, so `cp -a a/res/. merged/` has each one overwrite the
previous and `aapt2 link` then fails on missing styles
(`Base.V7.Theme.AppCompat.Dialog`) and colours. Each tree is compiled into its
own output directory instead.

**`aapt2 compile --dir a --dir b -o one_dir` also loses files.** `aapt2` names
each flat after the resource type and name only, `values_strings.arsc.flat`, so
two unrelated `strings.xml` files overwrite one another. Verified: compiling two
directories into one output directory yields one flat file, not two.

**`android.jar` has no `java.lang.invoke.LambdaMetafactory`.** `javap` on the
jar's classpath reads it from the JDK, which makes it look present; listing the
archive shows `java/lang/invoke/` holds 18 entries and `LambdaMetafactory` is
not among them. With `-bootclasspath android.jar` every lambda in the project
fails to compile. Dropping `-bootclasspath` is worse: `javac` then resolves
`java.*` against the host JDK, so APIs that exist on JDK 25 and not on Android
compile cleanly. Verified: `List.reversed()` (a JDK 21 `SequencedCollection`
method) compiles against `android.jar` on the classpath and `d8` dexes it
without complaint, because `d8` checks neither the API level nor the existence of
the method. A compiled-but-never-packaged stub supplies the one signature
`javac` needs.

**`aapt2 link` ignores `-o` when `--java` is present.** It generates `R.java`
and exits 0 without writing the output file, so the R pass and the packaging
pass have to be separate invocations. The build checks for the file rather than
trusting the exit code.

**`aapt2 link` cannot take dex as input.** A dex starts with `dex\n` and aapt2
expects an APTA archive:

    magic value is 0x0a786564 but AAPT expects 0x54504141

There is no `--dex` flag. AGP does the same thing: link the resources, then
merge `classes*.dex` into the resulting APK.

**`resources.arsc` must stay stored, not deflated.** The framework reads it with
`mmap` straight out of the APK and a deflated one fails to install with
`INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED`. Rewriting the archive with
`zipfile`'s default compression would do exactly that.

**The `.so` entries must be deflated.** `app/build.gradle:126` sets
`useLegacyPackaging true`, which means `extractNativeLibs`: the package manager
copies each `.so` out at install time. An APK with uncompressed `.so` is what
the other case wants and is wrong for this one.

**Maven version ranges are not versions.** Google's POMs use hard ranges like
`[1.6.1]`, where the brackets mean one required version. Unexpanded they
produce URLs like `appcompat-resources/[1.6.1].jar`, which 404s.

**A POM can inherit a dependency version from its parent.** `guava:24.1-jre`
declares `jsr305` with no version of its own and takes `1.3.9` from
`guava-parent`'s `dependencyManagement`. Dropping such dependencies is why
`javax.annotation.Nullable` went unresolved; jsr305 is the only thing in the
graph that declares it.

**A declared packaging is only a hint.** `guava:24.1-jre`'s POM says `aar`
while only a `.jar` is published.

**`-ktx` artifacts have to be aligned with their base artifact.** androidx
merged the Kotlin extensions into the base artifacts and kept publishing the
`-ktx` coordinates as empty stubs at matching versions. Left alone, the graph
holds `activity:1.8.0` (pulled by material) and `activity-ktx:1.5.1` (pulled by
preference) at once, both shipping
`OnBackPressedDispatcherKt$addCallback$callback$1`, and `d8` refuses:

    Type androidx.activity.OnBackPressedDispatcherKt$addCallback$callback$1 is
    defined multiple times

The two copies are not identical (1519 vs 1523 bytes). Alignment only ever
moves a version upwards; aligning downwards would downgrade an artifact nobody
asked to downgrade.

**`bin/ls` and `bin/sh` are not in the bootstrap as files.** The bootstrap
stores no symlinks as symlinks. `SYMLINKS.txt` records
`<owning-package>←<./path>` and the installer recreates them, so `bin/ls` and
`bin/sh` appear there as `coreutils←./bin/ls` and `dash←./bin/sh`. Dropping that
file leaves an app that starts no session.

## Testing

    python3 test-apk.py apk/termux-app_apt-android-7-debug.apk
    bash test-apk-selfcheck.sh

`test-apk.py` makes 33 structural checks against the built file: signature
scheme, package identity, targetSdk 28, dex contents, `resources.arsc`
compression, native libraries per ABI, the embedded bootstrap's `gh` and `ssh`
verified as ELF of the right machine type, and the symlink records.

`test-apk-selfcheck.sh` plants defects and requires each to be caught by the
specific check meant to catch it. Asserting only a non-zero exit would be
misleading: rewriting an APK obviously breaks its signature, so an exit-code-only
test passes for the wrong reason and would keep passing if the real check were
deleted. The `targetSdk` case is rebuilt and re-signed properly for the same
reason.

## Reproducibility

Content-reproducible, not byte-reproducible. Two builds from the same sources
produce the same entry set and byte-identical content in every entry. They
differ in seven timestamps that `d8` and `apksigner` stamp into their output,
which changes the SHA-256. Verified by building twice and diffing entry by
entry: 0 entries with differing content, 7 with differing timestamps
(`classes.dex`, `classes2.dex`, and the five `META-INF` signature files).

Forcing timestamps on `jar` does not help, because the ones that matter are
written by the dexer and the signer. `SOURCE_DATE_EPOCH` is the usual lever and
has not been tried here.

## Not verified

No part of this has been installed or run on a device or emulator. Nothing here
checks that the app starts, that the bootstrap unpacks, that the recorded
symlinks resolve, or that `gh` runs. The structural checks confirm the artifact
contains what it should; they say nothing about whether it works.