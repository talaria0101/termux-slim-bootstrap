#!/usr/bin/env python3
"""Flatten every jar's classes into one directory for d8.

d8 accepts a directory of .class files just as happily as a pile of jars, and
doing the flattening here buys two things that matter.

Duplicate classes are detected and named. Handing d8 two jars that both define
the same class produces

    Type androidx.activity.OnBackPressedDispatcherKt$addCallback$callback$1 is
    defined multiple times: .../activity-1.8.0/classes.jar:..., .../activity-ktx-1.5.1/classes.jar:...

which is at least readable, but it arrives very late, after aapt2 has linked and
javac has compiled the whole project, and it says nothing about how to fix it.
Reporting it here, with both owning jars, makes the failure cheap.

module-info.class is dropped. kotlin-stdlib, kotlin-stdlib-jdk7 and
kotlin-stdlib-jdk8 are all multi-release jars carrying
META-INF/versions/9/module-info.class, so the same entry arrives three times.
It is Java module metadata with no meaning on Android, and it must not be
dexed.

Identical duplicates are tolerated and counted, because that case is benign: two
jars shipping byte-for-byte the same class is not a packaging conflict. Only a
real disagreement is an error.
"""

import hashlib
import os
import sys
import zipfile


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: assemble-classes.py <outdir> <jar> [jar...]\n")
        return 2
    outdir = sys.argv[1]
    jars = sys.argv[2:]

    written = {}
    identical = 0
    total = 0

    for jar in jars:
        if not os.path.isfile(jar):
            sys.stderr.write("error: no such jar: %s\n" % jar)
            return 1
        try:
            archive = zipfile.ZipFile(jar)
        except zipfile.BadZipFile as e:
            sys.stderr.write("error: %s is not a readable zip: %s\n" % (jar, e))
            return 1
        with archive:
            for name in archive.namelist():
                if not name.endswith(".class"):
                    continue
                if name.endswith("/module-info.class"):
                    continue
                if name.startswith("META-INF/"):
                    continue
                data = archive.read(name)
                digest = hashlib.sha256(data).hexdigest()
                if name in written:
                    if written[name][1] == digest:
                        identical += 1
                    else:
                        sys.stderr.write(
                            "error: %s is defined differently in two jars:\n"
                            "         %s\n"
                            "         %s\n"
                            "  This has to be resolved in the dependency graph, not here.\n"
                            % (name, written[name][0], jar))
                        return 1
                    continue
                dest = os.path.join(outdir, name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(data)
                written[name] = (jar, digest)
                total += 1

    print("  %d classes from %d jars" % (total, len(jars)))
    if identical:
        print("  %d byte-identical duplicates collapsed" % identical)
    return 0


if __name__ == "__main__":
    sys.exit(main())