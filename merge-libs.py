#!/usr/bin/env python3
"""Merge dex files and native libraries into the APK aapt2 link produced.

aapt2 link emits a resource-only APK. Neither the dex files nor the native
libraries can be handed to it as inputs: aapt2 expects an APTA archive, so a
dex file is rejected with

    magic value is 0x0a786564 but AAPT expects 0x54504141

(0x0a786564 is "dex\\n" read as a little-endian int). There is no --dex flag.
AGP merges them into the finished APK too, so this is the same shape.

Three details matter, and each one is a way to produce an APK that installs and
then fails.

resources.arsc must stay stored, not deflated. The framework reads it with
mmap straight out of the APK, and a deflated one fails to parse with
INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED. Rewriting the archive with
zipfile's default compression would do exactly that, so the original
compression choice is carried through entry by entry.

The lib/<abi>/*.so entries are deflated on purpose. app/build.gradle:126 sets
useLegacyPackaging true, which means extractNativeLibs: the package manager
copies each .so into the app's native library directory at install time. An
APK with uncompressed .so is what the other case wants and is wrong for this
one.

The dex entries must be named classes.dex, classes2.dex, classes3.dex and so
on. The class loader discovers code by that sequence alone and ignores any
other name, so a file called com/termux/app/TermuxActivity.dex sitting in the
APK is code that never loads.
"""

import os
import re
import sys
import zipfile


def dex_entry_name(path):
    """Map a source dex file to the name it must have inside the APK."""
    base = os.path.basename(path)
    if base == "classes.dex":
        return "classes.dex"
    # d8 without --file-per-class writes classes.dex; with a multi-dex split it
    # writes classes2.dex and so on. Anything else is a name the loader will
    # not find, so refuse rather than ship dead code.
    m = re.fullmatch(r"classes(\d*)\.dex", base)
    if not m:
        return None
    return base


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: merge-libs.py <apk> <libdir> [--dex-list FILE]\n")
        return 2
    apk, libdir = sys.argv[1], sys.argv[2]

    dex_list = None
    rest = sys.argv[3:]
    if rest:
        if rest[0] != "--dex-list" or len(rest) < 2:
            sys.stderr.write("error: expected --dex-list FILE\n")
            return 2
        dex_list = rest[1]
        rest = rest[2:]
    if rest:
        sys.stderr.write("error: unexpected argument %r\n" % rest[0])
        return 2

    dex_files = []
    if dex_list:
        with open(dex_list, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    dex_files.append(line)
    if not dex_files:
        sys.stderr.write("error: no dex files to merge; the APK would contain no code\n")
        return 1

    entries = []
    for path in dex_files:
        if not os.path.isfile(path):
            sys.stderr.write("error: dex file listed but missing: %s\n" % path)
            return 1
        name = dex_entry_name(path)
        if name is None:
            sys.stderr.write(
                "error: %s has a name the class loader will not find. Dex files\n"
                "       must be classes.dex, classes2.dex, classes3.dex ...\n" % path)
            return 1
        entries.append((path, name))

    if not os.path.isdir(libdir):
        sys.stderr.write("error: no such directory: %s\n" % libdir)
        return 1

    tmp = apk + ".merging"
    added = []

    with zipfile.ZipFile(apk) as zin:
        # Validate before rewriting, so a truncated input leaves the original
        # untouched instead of a half-written archive.
        bad = zin.testzip()
        if bad is not None:
            sys.stderr.write("error: %s is corrupt at %s\n" % (apk, bad))
            return 1
        existing = set(zin.namelist())

        with zipfile.ZipFile(tmp, "w") as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
                zi.compress_type = item.compress_type
                zi.external_attr = item.external_attr
                zi.create_system = item.create_system
                zout.writestr(zi, data)

            for path, entry in entries:
                if entry in existing:
                    sys.stderr.write("error: %s already in the archive\n" % entry)
                    return 1
                zout.write(path, entry, compress_type=zipfile.ZIP_DEFLATED)
                added.append(entry)

            for abi in sorted(os.listdir(libdir)):
                abi_dir = os.path.join(libdir, abi)
                if not os.path.isdir(abi_dir):
                    continue
                for name in sorted(os.listdir(abi_dir)):
                    entry = "lib/%s/%s" % (abi, name)
                    zout.write(os.path.join(abi_dir, name), entry,
                               compress_type=zipfile.ZIP_DEFLATED)
                    added.append(entry)

    os.replace(tmp, apk)

    # Read the result back rather than trusting what was written.
    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())
        for entry in added:
            if entry not in names:
                sys.stderr.write("error: %s missing after merge\n" % entry)
                return 1
            if z.getinfo(entry).compress_type != zipfile.ZIP_DEFLATED:
                sys.stderr.write("error: %s is stored, not deflated\n" % entry)
                return 1
        if z.getinfo("resources.arsc").compress_type != zipfile.ZIP_STORED:
            sys.stderr.write("error: resources.arsc is deflated, not stored\n")
            return 1
        dex_in_apk = sorted(n for n in names
                            if re.fullmatch(r"classes\d*\.dex", n))

    if not any(n == "classes.dex" for n in dex_in_apk):
        sys.stderr.write("error: no classes.dex in the APK; nothing would load\n")
        return 1

    print("  merged %d dex files and %d native libraries"
          % (len(dex_in_apk), len(added) - len(dex_in_apk)))
    return 0


if __name__ == "__main__":
    sys.exit(main())