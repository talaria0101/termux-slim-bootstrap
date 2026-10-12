Termux bootstrap trimmed to what `gh cs ssh` needs, with gh and openssh already installed.

Neither gh nor openssh is in the stock Termux bootstrap, so a fresh install has to
fetch both before `gh cs ssh` can run. These archives have them, and drop the 34
packages nothing in their dependency closure uses, including apt and dpkg.

## Assets

| File | Device |
| --- | --- |
| `bootstrap-aarch64-slim.zip` | 64-bit ARM, any phone from about 2016 on |
| `bootstrap-arm-slim.zip` | 32-bit ARM, older or 32-bit-only devices |

## Verify

```
sha256sum -c SHA256SUMS
```

## This is larger than stock

| arch | stock | this | trim removes | gh + openssh adds |
| --- | --- | --- | --- | --- |
| aarch64 | 33.0 MB | 42.2 MB | 899 files, 11.0 MB | 1865 files, 19.7 MB |
| arm | 29.7 MB | 39.9 MB | 899 files, 9.9 MB | 1865 files, 19.5 MB |

`bin/gh` alone is about 14 MB compressed. If size matters more than having gh
preinstalled, install stock Termux and run `pkg install gh`, which is what it is
built for.

## Installing

Unpack over `$PREFIX` with Termux stopped:

```
mkdir -p ~/unstuff
unzip bootstrap-aarch64-slim.zip -d ~/unstuff
cp -a ~/unstuff/. $PREFIX/
termux-reload-settings
```

Or to build an APK with it, replace `app/src/main/cpp/bootstrap-<arch>.zip` in a
termux-app checkout.

## Caveat

Not tested on a device. Every check is structural: ELF machine type, Bionic
interpreter, DT_NEEDED resolution, dpkg manifest consistency, and the symlink
table.
