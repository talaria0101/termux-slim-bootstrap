# Termux slim bootstrap with gh and openssh

A Termux bootstrap trimmed to what `gh cs ssh` needs, plus gh and openssh
themselves. Termux already ships both as packages, but the stock bootstrap
contains neither, so a fresh install has to fetch them before you can use them.

Two architectures: **aarch64** (64-bit, any phone from about 2016 on) and
**arm** (32-bit, older or 32-bit-only devices).

## What this is not

This does not make the bootstrap smaller than stock. It makes it *contain what
you asked for*, and it removes what nothing needs.

Measured on both bootstraps:

| arch | stock | this | trim removes | gh+openssh adds |
| --- | --- | --- | --- | --- |
| aarch64 | 33.0 MB | 42.2 MB | 899 files, 11.0 MB | 1865 files, 19.7 MB |
| arm | 29.7 MB | 39.9 MB | 899 files, 9.9 MB | 1865 files, 19.5 MB |

The trim removes 899 files. Adding gh and openssh introduces 1865, and `bin/gh`
alone is about 14 MB compressed. Net: larger than stock, by roughly 9 MB on both,
and carrying gh.

If size matters more than having gh preinstalled, install stock Termux and run
`pkg install gh`, which is exactly what it is built for.

## Building

Both architectures:

    ./build-all.sh

That downloads the stock bootstraps, builds each one, and checks each artefact.
Needs `unzip`, `python3` and network access to `packages-cf.termux.dev`. `zip(1)`
is not needed; the archives are written with python3's zipfile.

One architecture:

    ./build-slim-bootstrap.sh --arch arm --stock-zip stock-arm.zip

Useful options:

    --arch ARCH      aarch64 (default) or arm
    --plan-only      print what would be kept and dropped, build nothing
    --extra PKG      add a package to the closure, repeatable
    --keep-manager   keep apt and dpkg
    --out PATH       output path

`--plan-only` prints the keep and drop lists with sizes and is the fastest way to
see what a change does:

    ./build-slim-bootstrap.sh --stock-zip bootstrap-aarch64.zip --plan-only

## What gets kept, and why it is not just the dependency closure

The keep list is the dependency closure of `gh` and `openssh`, plus three
packages that no closure mentions:

| package | why it is kept |
| --- | --- |
| `bash` | the app launches `$PREFIX/bin/bash` as the login shell |
| `coreutils` | `ls`, `cat`, `mkdir`; gh's own scripts assume them |
| `termux-tools` | provides `pkg`; 552K to keep a way out |

The closure of `gh` contains no shell at all, because nothing in a C library
depends on one. A bootstrap built from the closure alone starts no session, and
the stock bootstrap ships no `bin/sh`, so there is no fallback.

`termux-exec` and `termux-core` are kept because they are what make exec work at
all on Android 10+, where SELinux forbids running binaries from the app's data
directory.

Dropped: 34 packages, 41.5 MB installed, including `apt` and `dpkg`. Nothing in
the closure depends on either. This is the deliberate trade: you cannot install
anything afterwards.

## Installing it

Unpack over `$PREFIX` on a device that already has Termux, with Termux stopped:

    # in Termux, with no session running
    mkdir -p ~/unstuff
    unzip bootstrap-aarch64-slim.zip -d ~/unstuff
    cp -a ~/unstuff/. $PREFIX/
    termux-reload-settings

To build an APK with it instead, replace `app/src/main/cpp/bootstrap-aarch64.zip`
in a termux-app checkout and build normally.

## Tests

    ./test-plan.sh                                      # 10 checks on the keep/drop decision
    ./test-bootstrap.sh bootstrap-aarch64-slim.zip     # 30 checks on aarch64
    ./test-bootstrap.sh bootstrap-arm-slim.zip stock-arm.zip   # 30 checks on arm

`test-plan.sh` guards the decision, `test-bootstrap.sh` guards the artefact. The
second one reads the finished zip rather than the build log, so a step that
prints something reassuring and produces nothing still fails.

Both were checked by planting the defect each one exists to catch: deleting
`bin/bash`, deleting `libcrypto.so.3`, emptying `SYMLINKS.txt`, and stripping
the trailing slash from directory entries each turn the suite red.

## Files

| file | what it does |
| --- | --- |
| `plan.py` | computes the dependency closure, prices it against stock |
| `build-all.sh` | builds and checks both architectures |
| `build-slim-bootstrap.sh` | the build: trim, then add gh and openssh |
| `add-packages.sh` | downloads, verifies and unpacks packages from termux-main |
| `test-plan.sh` | guards on the plan |
| `test-bootstrap.sh` | guards on the built archive |

## Format notes that are easy to get wrong

These cost real debugging time and are recorded so they are not rediscovered:

- **The package index is per-architecture.** `binary-aarch64/Packages` says
  nothing about arm, and reusing it resolves dependencies against packages that
  do not exist for the target. `add-packages.sh` also checks each package's own
  `Architecture` field, so a mismatched index fails the build instead of
  installing foreign binaries.
- **But 233 packages per index are `Architecture: all`,** ca-certificates among
  them, and gh depends on ca-certificates. An arch check that does not allow
  `all` rejects them and breaks every arm build while aarch64 looks fine.
- **dpkg `.list` paths are absolute**, `/data/data/com.termux/files/usr/bin/bash`,
  while the zip is rooted at the prefix, so it holds `bin/bash`. Strip the prefix
  to map between them. Getting this wrong removes nothing and looks like success.
- **The zip stores no symlinks as symlinks.** `SYMLINKS.txt` holds
  `<owning-package><-U+2190><./path>` and the app creates them after extraction.
  `bin/sh`, `bin/ls` and `bin/cat` are aliases, not files. Lose this file and the
  shell loses `sh`.
- **Directory entries need a trailing slash.** Without one, `unzip` creates a file
  called `bin` and every binary in `bin/` collides with it. The archive extracts
  nothing.
- **Stock's own manifests claim 1213 files stock does not ship**, all aliases.
  Compare manifest completeness against stock, never against zero.
- **`du` under-reports on this filesystem.** A 50 MB archive reads as `512`.
  Use `stat -c %s`.
