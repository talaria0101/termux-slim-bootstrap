#!/usr/bin/env python3
"""Resolve the app's Maven dependencies transitively, without Gradle.

Gradle is unusable in this sandbox (it forks a daemon that needs a socket bind,
and every bind is denied), so the dependency graph that Gradle would compute is
computed here instead.

Repositories, in the order termux-app declares them (build.gradle):
    google(), mavenCentral(), jitpack.io

Conflict resolution is Gradle's: the version nearest the root wins, and ties are
broken by declaration order. That is what "nearest wins" means here, and it is
why the root list below pins appcompat at 1.6.1 even though app/build.gradle does
not mention it: termux-shared/build.gradle:11 declares it and that project is a
root dependency of the app.
"""

import sys
import os
import urllib.request
import xml.etree.ElementTree as ET

REPOS = [
    "https://dl.google.com/dl/android/maven2",
    "https://repo1.maven.org/maven2",
    "https://jitpack.io",
]

# Compile- and runtime-scoped only. These are the roots: every implementation
# and api dependency declared by app, termux-shared, terminal-view and
# terminal-emulator, read off their build.gradle files.
ROOTS = [
    # app/build.gradle:26-37
    ("androidx.annotation", "annotation", "1.9.0"),
    ("androidx.core", "core", "1.13.1"),
    ("androidx.drawerlayout", "drawerlayout", "1.2.0"),
    ("androidx.preference", "preference", "1.2.1"),
    ("androidx.viewpager", "viewpager", "1.0.0"),
    ("com.google.android.material", "material", "1.12.0"),
    ("com.google.guava", "guava", "24.1-jre"),
    ("io.noties.markwon", "core", "4.6.2"),
    ("io.noties.markwon", "ext-strikethrough", "4.6.2"),
    ("io.noties.markwon", "linkify", "4.6.2"),
    ("io.noties.markwon", "recycler", "4.6.2"),
    ("com.google.guava", "listenablefuture", "9999.0-empty-to-avoid-conflict-with-guava"),
    # terminal-view/build.gradle:9
    # terminal-emulator/build.gradle:63
    # (both the same annotation coordinate, already listed)
    # termux-shared/build.gradle:11-31
    ("androidx.appcompat", "appcompat", "1.6.1"),
    ("org.lsposed.hiddenapibypass", "hiddenapibypass", "6.1"),
    ("androidx.window", "window", "1.1.0"),
    ("commons-io", "commons-io", "2.5"),
    ("com.termux", "termux-am-library", "v2.0.0"),
]

# Gradle's POM-scope rule for a Maven dependency graph.
IN_SCOPE = {"compile", "runtime"}

POM_NS = "{http://maven.apache.org/POM/4.0.0}"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "debloat-apk-build/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def text(b):
    return b.decode("utf-8", "replace")


def _head_ok(url):
    """True if a URL exists. Used to pick the artifact extension when a POM's
    declared packaging disagrees with what the repository actually publishes."""
    req = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "debloat-apk-build/1"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except Exception:
        return False


def _version_key(v):
    """Sortable version key: numeric runs compare as numbers, so 1.10.0 sorts
    above 1.9.0 instead of below it the way a string compare would."""
    parts = []
    for chunk in v.replace("-", ".").replace("+", ".").split("."):
        if chunk.isdigit():
            parts.append((1, int(chunk), ""))
        else:
            parts.append((0, 0, chunk))
    return parts


def _version_gt(a, b):
    return _version_key(a) > _version_key(b)


def align_ktx(resolved):
    """Move each `X-ktx` onto the version of `X` that was actually resolved.

    androidx merged the Kotlin extensions into the base artifacts and kept
    publishing the `-ktx` coordinates as empty stubs at matching versions.
    Verified directly: activity-ktx:1.8.0, fragment-ktx:1.5.5, core-ktx:1.13.1
    and savedstate-ktx:1.2.1 all exist and their classes.jar holds zero class
    files, while the older activity-ktx:1.5.1 that the POM graph asks for still
    contains the pre-merge copies.

    Without this, the graph holds activity:1.8.0 (pulled by material) and
    activity-ktx:1.5.1 (pulled by preference) at the same time, and both ship
    androidx/activity/OnBackPressedDispatcherKt$addCallback$callback$1. d8 then
    refuses to dex the project:

      Type androidx.activity.OnBackPressedDispatcherKt$addCallback$callback$1
      is defined multiple times

    The two copies are not even identical (1519 vs 1523 bytes), so there is no
    version of d8 that accepts both.

    Only versions that actually exist are used. Where the aligned `-ktx` is not
    published, lifecycle-runtime-ktx has no 2.6.2 for instance, the version the
    graph asked for is kept.
    """
    changed = []
    for (g, a), entry in list(resolved.items()):
        if not a.endswith("-ktx"):
            continue
        base = a[:-len("-ktx")]
        if (g, base) not in resolved:
            continue
        current = entry[0]
        base_version = resolved[(g, base)][0]
        if base_version == current:
            continue
        # Only ever align upwards. The base artifact can resolve lower than the
        # extension does: appcompat pulls fragment:1.2.5 at depth 1 while
        # fragment-ktx:1.3.6 arrives at depth 1 too and wants fragment:1.3.6,
        # so nearest-wins keeps 1.2.5. Aligning fragment-ktx down onto 1.2.5
        # would be a downgrade of an artifact nobody asked to downgrade.
        if not _version_gt(base_version, current):
            continue
        pom = "%s/%s/%s/%s-%s.pom" % (g.replace(".", "/"), a, base_version, a, base_version)
        if not any(_head_ok("%s/%s" % (repo, pom)) for repo in REPOS):
            continue
        resolved[(g, a)] = (base_version, entry[1], entry[2])
        changed.append("%s:%s %s -> %s" % (g, a, current, base_version))
    return changed


def find_pom(group, artifact, version):
    """Return (repo_base, pom_url) for the first repository that has it."""
    path = "%s/%s/%s/%s-%s.pom" % (
        group.replace(".", "/"), artifact, version, artifact, version)
    for repo in REPOS:
        url = "%s/%s" % (repo, path)
        try:
            return repo, url, fetch(url)
        except urllib.error.HTTPError:
            continue
        except urllib.error.URLError as e:
            print("  repo %s unreachable: %s" % (repo, e), file=sys.stderr)
            continue
    return None, None, None


def pom_deps(group, artifact, version):
    """Direct compile/runtime dependencies declared by a POM, plus its packaging.

    property substitution for ${project.version} and friends is handled because
    markwon's POMs use ${project.version}.
    """
    _, _, raw = find_pom(group, artifact, version)
    if raw is None:
        return "jar", []
    root = ET.fromstring(raw)

    props = {}
    node = root.find(POM_NS + "properties")
    if node is not None:
        for child in node:
            props[child.tag.split("}")[-1]] = (child.text or "").strip()

    # Walk the parent chain, nearest first. Two things come from it:
    #
    #   properties: ${animal.sniffer.version} and friends resolve there.
    #   dependencyManagement: guava 24.1-jre declares jsr305 with NO version of
    #     its own and inherits 1.3.9 from guava-parent. Dropping those deps for
    #     want of a version is why javax.annotation.Nullable went unresolved:
    #     jsr305 is the only thing in the graph that declares it.
    managed = {}
    chain = []
    parent = root.find(POM_NS + "parent")
    while parent is not None:
        pg = (parent.findtext(POM_NS + "groupId") or "").strip()
        pa = (parent.findtext(POM_NS + "artifactId") or "").strip()
        pv = (parent.findtext(POM_NS + "version") or "").strip()
        if not (pg and pa and pv):
            break
        chain.append((pg, pa, pv))
        parent = parent.find(POM_NS + "parent")

    for pg, pa, pv in chain:
        _, _, praw = find_pom(pg, pa, pv)
        if praw is None:
            continue
        proot = ET.fromstring(praw)
        pnode = proot.find(POM_NS + "properties")
        if pnode is not None:
            for child in pnode:
                # Nearest POM wins, so only fill in what is not already set.
                props.setdefault(child.tag.split("}")[-1], (child.text or "").strip())
        dm = proot.find(POM_NS + "dependencyManagement")
        if dm is not None:
            dnode = dm.find(POM_NS + "dependencies")
            if dnode is not None:
                for dep in dnode.findall(POM_NS + "dependency"):
                    dg = (dep.findtext(POM_NS + "groupId") or "").strip()
                    da = (dep.findtext(POM_NS + "artifactId") or "").strip()
                    dv = (dep.findtext(POM_NS + "version") or "").strip()
                    if dg and da and dv:
                        managed.setdefault((dg, da), dv)

    packaging = (root.findtext(POM_NS + "packaging") or "jar").strip()
    if packaging == "bundle":
        packaging = "aar"
    # The declared packaging is only a hint. Several jars (guava 24.1-jre among
    # them) say "aar" while only publishing a .jar, so the artifact that is
    # actually downloadable is what decides the extension.
    if packaging == "aar":
        probe = "%s/%s/%s/%s-%s.aar" % (
            group.replace(".", "/"), artifact, version, artifact, version)
        if not any(_head_ok("%s/%s" % (repo, probe)) for repo in REPOS):
            packaging = "jar"

    def expand(s):
        s = (s or "").strip()
        for _ in range(4):
            new = s
            for key, val in props.items():
                new = new.replace("${%s}" % key, val)
                new = new.replace("${project.version}", version)
            if new == s:
                break
            s = new
        return s

    out = []
    node = root.find(POM_NS + "dependencies")
    if node is None:
        return packaging, out
    for dep in node.findall(POM_NS + "dependency"):
        scope = (dep.findtext(POM_NS + "scope") or "compile").strip()
        optional = (dep.findtext(POM_NS + "optional") or "false").strip()
        if scope not in IN_SCOPE or optional == "true":
            continue
        dg = expand(dep.findtext(POM_NS + "groupId"))
        da = expand(dep.findtext(POM_NS + "artifactId"))
        dv = expand(dep.findtext(POM_NS + "version"))
        dtype = (dep.findtext(POM_NS + "type") or "jar").strip()
        if not (dg and da):
            continue
        if not dv:
            # Version managed by a parent POM's dependencyManagement.
            dv = expand(managed.get((dg, da), ""))
        if not dv:
            continue
        out.append((dg, da, dv, dtype))
    return packaging, out


def resolve_range(group, artifact, version):
    """Turn a Maven version range or LATEST into a concrete version.

    Google's POMs use hard ranges like "[1.6.1]" and "[2.6.2]", where the
    brackets mean a single required version rather than a range to search.
    appcompat-resources and lifecycle-common both do this. Leaving them
    unexpanded produced URLs like appcompat-resources/[1.6.1].jar, which
    404s, and the artifact was silently reported missing.
    """
    v = version
    while v[:1] in "[(":
        v = v[1:]
    while v[-1:] in "])":
        v = v[:-1]
    if v.startswith("v"):
        v = v[1:]
    return v or version


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "dl"

    # Breadth-first with nearest-wins: a coordinate already resolved is never
    # revisited, so the first version to reach it is the one that wins.
    resolved = {}   # (g, a) -> (version, packaging, depth)
    order = []
    queue = []
    for g, a, v in ROOTS:
        queue.append((g, a, v, "jar", 0))

    seen = set()
    while queue:
        g, a, v, dtype, depth = queue.pop(0)
        key = (g, a)
        if key in resolved:
            continue
        packaging, deps = pom_deps(g, a, v)
        resolved[key] = (v, packaging, depth)
        order.append((g, a, v, packaging, depth))
        print("  %s%s:%s:%s (%s, depth %d)"
              % ("  " * depth, g, a, v, packaging, depth))
        for dg, da, dv, dt in deps:
            dv = resolve_range(dg, da, dv)
            if (dg, da) in resolved:
                continue
            if (dg, da, dv, dt) in seen:
                continue
            seen.add((dg, da, dv, dt))
            queue.append((dg, da, dv, dt, depth + 1))

    print("\n%d coordinates resolved" % len(order))

    changed = align_ktx(resolved)
    if changed:
        print("\naligning -ktx artifacts onto their base versions")
        for line in changed:
            print("  %s" % line)
        # Reorder so the downloaded set matches the aligned versions.
        order = [(g, a, resolved[(g, a)][0], resolved[(g, a)][1], resolved[(g, a)][2])
                 for (g, a) in resolved]

    # Download the artifact for each. aar and jar both matter: an aar needs
    # its classes.jar extracted and its res/ merged, a jar goes straight onto
    # the compile classpath.
    print("\nfetching artifacts")
    os.makedirs(outdir, exist_ok=True)
    for g, a, v, packaging, depth in order:
        # Guava's listenablefuture is the empty-to-avoid-conflict artifact and
        # legitimately publishes no jar; skip rather than fail.
        ext = "aar" if packaging == "aar" else "jar"
        path = "%s/%s/%s/%s-%s.%s" % (g.replace(".", "/"), a, v, a, v, ext)
        dest = os.path.join(outdir, "%s-%s-%s.%s" % (a, v, g, ext))
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            continue
        for repo in REPOS:
            url = "%s/%s" % (repo, path)
            try:
                data = fetch(url)
            except Exception:
                continue
            with open(dest, "wb") as f:
                f.write(data)
            print("  %-60s %8d bytes" % (dest, len(data)))
            break
        else:
            print("  MISSING %s:%s:%s (%s)" % (g, a, v, ext), file=sys.stderr)

    # A stable, readable list of what the classpath should contain.
    with open(os.path.join(outdir, "classpath.txt"), "w") as f:
        for g, a, v, packaging, depth in order:
            f.write("%s:%s:%s:%s\n" % (g, a, v, packaging))


if __name__ == "__main__":
    main()