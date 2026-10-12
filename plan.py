#!/usr/bin/env python3
"""
Compare the stock Termux bootstrap's package list against the dependency closure
needed for `gh cs ssh`, and price the difference.

Inputs are both real artefacts, not assumptions:
  * a Packages index from termux-main (the `Packages` file)
  * the stock bootstrap's dpkg `status` database, extracted from the release zip

Reports:
  * the closure of the wanted roots, with sizes
  * stock packages that the closure does not need, with sizes (removable weight)
  * packages the closure wants that stock does not ship (must be added)

Usage: plan.py Packages var/lib/dpkg/status ROOT [ROOT...]
"""

import sys


def parse_packages(path):
    """{name: {"size": int, "deps": [[alternative names]]}}"""
    pkgs = {}
    name = size = None
    deps = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                if name:
                    pkgs[name] = {"size": size or 0, "deps": deps}
                name = size = None
                deps = []
                continue
            if line.startswith(" "):
                continue
            key, _, val = line.partition(":")
            val = val.strip()
            if key == "Package":
                name = val
            elif key == "Size":
                try:
                    size = int(val)
                except ValueError:
                    size = 0
            elif key == "Depends":
                deps = []
                for group in val.split(","):
                    group = group.strip()
                    if not group:
                        continue
                    alts = [
                        a.strip().split(" ")[0].split(":")[0]
                        for a in group.split("|")
                        if a.strip()
                    ]
                    if alts:
                        deps.append(alts)
    if name:
        pkgs[name] = {"size": size or 0, "deps": deps}
    return pkgs


def parse_status(path):
    """{name: installed-size-in-bytes} from a dpkg status file."""
    out = {}
    name = size = None
    installed = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                if name and installed:
                    out[name] = size or 0
                name = size = None
                installed = False
                continue
            if line.startswith(" "):
                continue
            key, _, val = line.partition(":")
            val = val.strip()
            if key == "Package":
                name = val
            elif key == "Status":
                # "install ok installed" is the third word.
                installed = val.split()[-1:] == ["installed"]
            elif key == "Installed-Size":
                # dpkg records KiB here.
                try:
                    size = int(val) * 1024
                except ValueError:
                    size = 0
    if name and installed:
        out[name] = size or 0
    return out


def closure(pkgs, roots):
    seen = {}
    unresolved = set()
    stack = list(roots)
    while stack:
        n = stack.pop()
        if n in seen or n in unresolved:
            continue
        info = pkgs.get(n)
        if info is None:
            unresolved.add(n)
            continue
        seen[n] = info["size"]
        for alts in info["deps"]:
            for alt in alts:
                if alt in pkgs:
                    stack.append(alt)
                    break
            else:
                unresolved.add(" | ".join(alts))
    return seen, unresolved


# Packages the Termux app itself needs, which are not in any dependency closure.
#
# The closure of gh contains no shell, because nothing in a C library depends on
# one. But the app launches $PREFIX/bin/bash as the login shell, and the stock
# bootstrap ships no bin/sh at all, so a bootstrap built from the closure alone
# starts no session. Verified against the stock bootstrap zip: bin/bash exists
# (mode 0700) and bin/sh does not.
#
# coreutils is here for the same reason: ls, cat, mkdir, cp and rm are what a
# person reaches for, and gh's own scripts assume them.
#
# termux-tools is what provides pkg. Nothing in the closure needs it, but
# dropping it removes every supported way of fixing a broken bootstrap, which is
# not a trade worth 552K.
BASE = ["bash", "coreutils", "termux-tools"]


def main(argv):
    # plan.py is called two ways. By hand, to see the numbers:
    #     plan.py Packages status gh openssh
    # From build-slim-bootstrap.sh, which needs machine-readable lists and must
    # not have to parse the printed report:
    #     plan.py --write-lists Packages status gh openssh \
    #         --keep-list keep.txt --drop-list drop.txt
    keep_path = drop_path = None
    args = list(argv[1:])
    if "--write-lists" in args:
        keep_path = take_after(args, "--keep-list")
        drop_path = take_after(args, "--drop-list")
        if keep_path is None or drop_path is None:
            print("--write-lists needs --keep-list and --drop-list", file=sys.stderr)
            return 2
        # Strip the flags and their values together. Removing only the flag names
        # left the paths in the argument list, where they were resolved as if
        # they were package names and reported as unresolved dependencies.
        out = []
        skip = 0
        for a in args:
            if skip:
                skip -= 1
                continue
            if a == "--write-lists":
                continue
            if a in ("--keep-list", "--drop-list"):
                skip = 1
                continue
            out.append(a)
        args = out
    if len(args) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    pkgs = parse_packages(args[0])
    stock = parse_status(args[1])
    roots = args[2:]

    want, unresolved = closure(pkgs, roots)

    # The closure of gh has no shell in it, because nothing in a C library
    # depends on one. But the Termux app launches $PREFIX/bin/bash as the login
    # shell and the stock bootstrap ships no bin/sh, so a bootstrap built from the
    # closure alone starts no session at all. Verified against the stock zip:
    # bin/bash exists and bin/sh does not. These are therefore roots too.
    base, base_unresolved = closure(pkgs, BASE)
    want.update(base)
    unresolved |= base_unresolved

    stock_total = sum(stock.values())
    want_in_stock = {n: s for n, s in want.items() if n in stock}
    extra_needed = sorted(set(want) - set(stock))
    droppable = {n: s for n, s in stock.items() if n not in want}

    print("=== wanted: %s ===" % ", ".join(roots))
    print("closure: %d packages" % len(want))
    print()
    print("--- closure packages stock ALREADY ships (keep) ---")
    for n in sorted(want_in_stock):
        print("  %9s  %s" % (human(want_in_stock[n]), n))
    print()
    print("--- closure packages stock does NOT ship (must add) ---")
    for n in extra_needed:
        print("  %9s  %s" % (human(want.get(n, 0)), n))
    print()
    print("--- stock packages the closure does NOT need (removable) ---")
    for n, s in sorted(droppable.items(), key=lambda kv: -kv[1]):
        print("  %9s  %s" % (human(s), n))
    print()
    print("stock total:      %9s  (%d packages)" % (human(stock_total), len(stock)))
    print("removable:        %9s  (%d packages)" % (human(sum(droppable.values())), len(droppable)))
    print("must add:         %9s  (%d packages)" % (human(sum(want.get(n, 0) for n in extra_needed)), len(extra_needed)))
    print("keep total:       %9s" % human(stock_total - sum(droppable.values()) + sum(want.get(n, 0) for n in extra_needed)))
    if unresolved:
        print()
        print("unresolved dependencies (not in this index):")
        for n in sorted(unresolved)[:20]:
            print("  " + n)

    if keep_path:
        # Keep only what stock already ships: the closure minus the packages that
        # have to be added. Writing the rest as "drop" would try to remove files
        # that are not there.
        keep = sorted(want_in_stock)
        drop = sorted(droppable)
        with open(keep_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keep) + "\n")
        with open(drop_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(drop) + "\n")
        print()
        print("wrote %s (%d kept) and %s (%d dropped)" % (
            keep_path, len(keep), drop_path, len(drop)))
    return 0


def human(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return "%.1f%s" % (n, unit) if unit != "B" else "%dB" % n
        n /= 1024.0
    return str(n)


def take_after(args, flag):
    """The argument following `flag`, or None."""
    try:
        return args[args.index(flag) + 1]
    except (ValueError, IndexError):
        return None


if __name__ == "__main__":
    sys.exit(main(sys.argv))