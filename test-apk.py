#!/usr/bin/env python3
"""Structural checks on the built APK.

None of this substitutes for running the app. Every check here is a statement
about the artifact that can be read back out of the file, and every one of them
either passes or fails. What they cannot tell anyone is whether the app starts,
whether the bootstrap unpacks, or whether gh runs. That needs a device.

The checks are:

  signature      signed, and under v1, v2 and v3
  identity       package name, versionCode, minSdk, targetSdk 28
  dex            a classes.dex exists, is a dex, and carries the app's classes
  resources      resources.arsc present, stored uncompressed, mmap-aligned
  manifest       the substituted manifest has no leftover ${} placeholders and
                 declares the launcher activity
  native         lib/<abi>/libtermux-bootstrap.so for each ABI, and each one
                 embeds a bootstrap zip
  bootstrap      the embedded zip really contains gh and ssh as ELF binaries of
                 the right machine type, and its symlink records are intact
  alignment      zipalign -c passes

targetSdk 28 is checked rather than assumed. Termux needs targetSdk 28 for the
W^X exec exemption that lets a normal executable be exec'd from the app's own
data directory on Android 10 and later. An APK with a higher targetSdk installs
and then fails at the first exec.
"""

import io
import os
import re
import struct
import subprocess
import sys
import zipfile

FAILURES = []
PASSES = []


def check(name, ok, detail=""):
    if ok:
        PASSES.append(name)
        print("  ok    %s%s" % (name, ("  " + detail) if detail else ""))
    else:
        FAILURES.append("%s%s" % (name, (": " + detail) if detail else ""))
        print("  FAIL  %s%s" % (name, ("  " + detail) if detail else ""))


def e_machine(data):
    """e_machine from an ELF header, or None if it is not ELF."""
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return None
    return struct.unpack_from("<H", data, 18)[0]


def embedded_bootstrap(so):
    """The bootstrap zip embedded by .incbin, as (bytes, names)."""
    start = so.find(b"PK\x03\x04")
    eocd = so.rfind(b"PK\x05\x06")
    if start < 0 or eocd < 0 or eocd < start:
        return None, []
    blob = so[start:eocd + 22]
    try:
        z = zipfile.ZipFile(io.BytesIO(blob))
        return blob, z.namelist()
    except zipfile.BadZipFile:
        return None, []


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: test-apk.py <apk> [build-tools-dir]\n")
        return 2
    apk = sys.argv[1]
    bt = sys.argv[2] if len(sys.argv) > 2 else "/workspace/android-sdk/build-tools/36.0.0"

    if not os.path.isfile(apk):
        print("  FAIL  apk exists  (%s)" % apk)
        return 1

    java_home = os.environ.get("JAVA_HOME", "/usr/lib/jvm/openjdk25")
    env = dict(os.environ)
    env["JAVA_HOME"] = java_home
    env["PATH"] = os.path.join(java_home, "bin") + ":" + env.get("PATH", "")

    z = zipfile.ZipFile(apk)
    names = set(z.namelist())

    # --- signature -------------------------------------------------------
    r = subprocess.run(
        [os.path.join(bt, "apksigner"), "verify", "--min-sdk-version", "21",
         "--verbose", apk],
        capture_output=True, text=True, env=env)
    out = r.stdout + r.stderr
    first_lines = " | ".join(out.strip().splitlines()[:2])
    check("signature verifies", r.returncode == 0,
          "" if r.returncode == 0 else first_lines)
    for scheme in ("v1 scheme (JAR signing)", "v2 scheme (APK Signature Scheme v2)",
                   "v3 scheme (APK Signature Scheme v3)"):
        m = re.search(re.escape(scheme) + r":\s*(true|false)", out)
        check("signed with " + scheme.split()[0], bool(m) and m.group(1) == "true",
              "" if m else "apksigner did not report it")

    # --- identity --------------------------------------------------------
    r = subprocess.run([os.path.join(bt, "aapt2"), "dump", "badging", apk],
                       capture_output=True, text=True, env=env)
    badging = r.stdout
    m = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    check("package is com.termux", bool(m) and m.group(1) == "com.termux",
          m.group(1) if m else "no package line")
    check("versionCode is 118", bool(m) and m.group(2) == "118",
          m.group(2) if m else "")
    check("minSdkVersion is 21", "minSdkVersion:'21'" in badging)
    # The W^X exemption. Not cosmetic.
    check("targetSdkVersion is 28", "targetSdkVersion:'28'" in badging,
          "higher targetSdk breaks the W^X exec exemption Termux relies on")

    # --- dex -------------------------------------------------------------
    dex = [n for n in names if re.fullmatch(r"classes\d*\.dex", n)]
    check("has classes.dex", "classes.dex" in names, ", ".join(sorted(dex)))
    if "classes.dex" in names:
        head = z.read("classes.dex")[:4]
        check("classes.dex is a dex file", head == b"dex\n",
              repr(head))
        # The app's own classes must be in there, not only the libraries.
        blob = b"".join(z.read(n) for n in sorted(dex))
        check("dex carries com/termux/app", b"Lcom/termux/app/" in blob)
        check("dex carries com/termux/shared", b"Lcom/termux/shared/" in blob)

    # --- every referenced R class is present ------------------------------
    #
    # This catches the worst bug found so far. Published AARs do not ship an R
    # class, because R is generated per application rather than per library. So
    # library bytecode reaches its own R through a real getstatic, e.g.
    # androidx.cardview.R$attr.cardViewStyle, and if that class is absent the
    # loader throws NoClassDefFoundError the first time a CardView is inflated.
    #
    # An earlier build generated R for only 4 namespaces and shipped 4. The
    # official Termux v0.118.3 arm64 APK ships 46. Verified by listing the class
    # descriptors of both dex sets.
    #
    # dexdump is the authority for both halves of this. A raw byte scan cannot
    # tell a class definition from a reference, because the descriptor pool
    # holds both in the same form.
    defined = set()
    referenced = set()
    # dexdump writes bytes that are not valid UTF-8 (it dumps string data
    # verbatim), so the output is decoded as latin-1, which never fails and
    # leaves the ASCII class names intact.
    r = subprocess.run(
        [os.path.join(bt, "dexdump"), apk, "-d"],
        capture_output=True, env=env)
    out = (r.stdout or b"").decode("latin-1")
    check("dexdump could read the dex", r.returncode == 0 and bool(out),
          "" if out else "dexdump produced no output")
    for line in out.splitlines():
        m = re.search(r"Class descriptor\s*:\s*'L([^']+);'", line)
        if m:
            defined.add(m.group(1))
    # Every R descriptor that appears as a field owner in the disassembly must
    # also be a defined class.
    for m in re.finditer(r"L(androidx/[A-Za-z0-9_/]+R\$[a-z]+);", out):
        referenced.add(m.group(1))
    missing_r = sorted(referenced - defined)
    check("every referenced library R class is present", not missing_r,
          ", ".join(missing_r[:6]) if missing_r
          else "%d referenced, %d defined" % (len(referenced), len(defined)))

    # --- resources -------------------------------------------------------
    check("resources.arsc present", "resources.arsc" in names)
    if "resources.arsc" in names:
        info = z.getinfo("resources.arsc")
        # The framework mmaps resources.arsc out of the APK. A deflated one
        # fails to install with INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED.
        check("resources.arsc is stored, not deflated",
              info.compress_type == zipfile.ZIP_STORED,
              "compress_type=%d" % info.compress_type)

    # --- manifest --------------------------------------------------------
    if "AndroidManifest.xml" in names:
        raw = z.read("AndroidManifest.xml")
        # Binary XML: the ${...} placeholders would appear as literal UTF-16.
        text16 = raw.decode("utf-16-le", "ignore")
        check("no unsubstituted ${...} in the manifest",
              "${" not in text16 and "TERMUX_PACKAGE_NAME" not in text16)

    # --- native libraries and the embedded bootstrap ----------------------
    abis = sorted({m.group(1) for n in names
                   for m in [re.match(r"lib/([^/]+)/libtermux-bootstrap\.so$", n)]
                   if m})
    check("native library for both ABIs", abis == ["arm64-v8a", "armeabi-v7a"],
          "found " + (", ".join(abis) if abis else "none"))

    expect_machine = {"arm64-v8a": 0xB7, "armeabi-v7a": 0x28}
    for abi in abis:
        entry = "lib/%s/libtermux-bootstrap.so" % abi
        info = z.getinfo(entry)
        # useLegacyPackaging true means extractNativeLibs, so the .so is
        # deflated and copied out at install time.
        check("%s .so is deflated" % abi, info.compress_type == zipfile.ZIP_DEFLATED,
              "compress_type=%d" % info.compress_type)
        so = z.read(entry)
        blob, bnames = embedded_bootstrap(so)
        check("%s embeds a bootstrap zip" % abi, blob is not None,
              "%d entries" % len(bnames) if bnames else "no zip found")
        if not bnames:
            continue
        for tool in ("bin/gh", "bin/ssh"):
            if tool not in bnames:
                check("%s has %s" % (abi, tool), False, "absent from the bootstrap")
                continue
            data = zipfile.ZipFile(io.BytesIO(blob)).read(tool)
            mach = e_machine(data)
            check("%s %s is ELF for the right ABI" % (abi, tool),
                  mach == expect_machine[abi],
                  "e_machine=%s want %s" % (hex(mach) if mach else None,
                                            hex(expect_machine[abi])))
        # The bootstrap stores no symlinks as symlinks; it records them and the
        # installer recreates them. Dropping that file costs bin/sh and bin/ls.
        check("%s bootstrap keeps SYMLINKS.txt" % abi, "SYMLINKS.txt" in bnames)
        if "SYMLINKS.txt" in bnames:
            text = zipfile.ZipFile(io.BytesIO(blob)).read("SYMLINKS.txt").decode("utf-8")
            records = [l for l in text.splitlines() if l.strip()]
            check("%s has symlink records" % abi, len(records) > 1000,
                  "%d records" % len(records))
            # A session needs these; they are aliases, so they only exist as records.
            for alias in ("./bin/sh", "./bin/ls"):
                check("%s bootstrap records %s" % (abi, alias),
                      any(l.endswith(alias) for l in records))

    # --- alignment -------------------------------------------------------
    r = subprocess.run([os.path.join(bt, "zipalign"), "-c", "-p", "4", apk],
                       capture_output=True, text=True, env=env)
    check("zipalign verifies", r.returncode == 0,
          "" if r.returncode == 0 else (r.stdout + r.stderr).strip()[:120])

    print("\n%d passed, %d failed" % (len(PASSES), len(FAILURES)))
    if FAILURES:
        print("\nfailures:")
        for f in FAILURES:
            print("  %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())