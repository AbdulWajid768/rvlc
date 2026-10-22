#!/usr/bin/env python3
"""Copy the non-system dynamic libraries an executable needs into an app bundle.

Usage: bundle_dylibs.py <app>/Contents/MacOS/<exe> <app>/Contents/Frameworks <notice-file>

* Follows absolute (/opt/homebrew, /usr/local, /opt/local), @rpath and
  @loader_path references recursively.
* Rewrites every reference to @rpath/<name>, gives the executable an rpath of
  @executable_path/../Frameworks and each library an rpath of @loader_path,
  and removes rpaths that point outside the bundle, so the app never loads
  libraries from the build machine.
* Writes a third-party notice listing every bundled library with its Homebrew
  formula, version and declared license (best effort; verify before release).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
EXTERNAL_PREFIXES = ("/opt/homebrew/", "/usr/local/", "/opt/local/")


def run(*args: str, check: bool = True) -> str:
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout


def deps(path: str) -> list[str]:
    lines = run("otool", "-L", path).splitlines()[1:]
    return [line.strip().split(" (")[0] for line in lines if line.strip()]


def rpaths(path: str) -> list[str]:
    out = run("otool", "-l", path)
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", out)


def own_id(path: str) -> str | None:
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def resolve(ref: str, referrer: str) -> str | None:
    """Resolve a dependency reference to a real file, or None for system libs."""
    if ref.startswith(SYSTEM_PREFIXES):
        return None
    base = os.path.dirname(os.path.realpath(referrer))
    if ref.startswith("@loader_path/"):
        cand = os.path.join(base, ref[len("@loader_path/"):])
        return os.path.realpath(cand) if os.path.exists(cand) else None
    if ref.startswith("@rpath/"):
        name = ref[len("@rpath/"):]
        for rp in rpaths(referrer):
            rp = rp.replace("@loader_path", base).replace("@executable_path", base)
            cand = os.path.join(rp, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        for prefix in ("/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"):
            cand = os.path.join(prefix, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None
    if ref.startswith(EXTERNAL_PREFIXES):
        return os.path.realpath(ref)
    return None


def formula_of(real: str) -> tuple[str, str] | None:
    m = re.search(r"/Cellar/([^/]+)/([^/]+)/", real)
    return (m.group(1), m.group(2)) if m else None


def main() -> int:
    exe, frameworks, notice = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(frameworks, exist_ok=True)
    copied: dict[str, str] = {}  # real source path -> bundled file name
    unresolved: list[str] = []
    queue = [exe]
    seen: set[str] = set()
    while queue:
        current = queue.pop()
        if current in seen:
            continue
        seen.add(current)
        for ref in deps(current):
            real = resolve(ref, current)
            if real is None and ref.startswith("@"):
                # An @rpath/@loader_path dependency we cannot find would fail at launch.
                if os.path.basename(ref) != os.path.basename(current):
                    unresolved.append(f"{os.path.basename(current)} -> {ref}")
                continue
            if real is None or real == os.path.realpath(current):
                continue
            if real not in copied:
                # Keep the referenced name (e.g. libmpv.2.dylib), not the versioned real file name.
                name = os.path.basename(ref)
                dest = os.path.join(frameworks, name)
                owner = next((src for src, n in copied.items() if n == name), None)
                if owner is not None and owner != real:
                    print(f"ERROR: two different libraries are both named {name}:\n  {owner}\n  {real}", file=sys.stderr)
                    return 1
                if not os.path.exists(dest):
                    shutil.copy2(real, dest)
                    os.chmod(dest, 0o755)
                copied[real] = name
                queue.append(real)

    def rewrite(target: str, is_exe: bool) -> None:
        source = target if is_exe else next(src for src, n in copied.items() if os.path.join(frameworks, n) == target)
        args: list[str] = []
        for ref in deps(source if not is_exe else target):
            real = resolve(ref, source)
            if real in copied:
                args += ["-change", ref, "@rpath/" + copied[real]]
        if not is_exe:
            args += ["-id", "@rpath/" + os.path.basename(target)]
        if args:
            run("install_name_tool", *args, target)
        for rp in rpaths(target):
            if not rp.startswith(("@loader_path", "@executable_path")) or rp.startswith("@loader_path/.."):
                run("install_name_tool", "-delete_rpath", rp, target, check=False)
        wanted = "@executable_path/../Frameworks" if is_exe else "@loader_path"
        if wanted not in rpaths(target):
            run("install_name_tool", "-add_rpath", wanted, target)

    for name in copied.values():
        rewrite(os.path.join(frameworks, name), is_exe=False)
    rewrite(exe, is_exe=True)

    # Third-party notice from Homebrew metadata.
    formulae: dict[str, tuple[str, list[str]]] = {}
    for real, name in copied.items():
        f = formula_of(real)
        if f:
            formulae.setdefault(f[0], (f[1], []))[1].append(name)
    licenses: dict[str, str] = {}
    if formulae and shutil.which("brew"):
        try:
            info = json.loads(run("brew", "info", "--json=v2", *sorted(formulae)))
            for item in info.get("formulae", []):
                licenses[item["name"]] = item.get("license") or "unknown"
        except subprocess.CalledProcessError:
            pass
    with open(notice, "w", encoding="utf-8") as fh:
        fh.write("# Third-party libraries bundled with RVLC\n\n")
        fh.write("Generated by scripts/bundle_dylibs.py from Homebrew metadata. Licenses are as declared by\n")
        fh.write("Homebrew and must be verified before distribution. Corresponding source code for every\n")
        fh.write("GPL/LGPL component is available from the upstream projects listed at https://formulae.brew.sh.\n\n")
        fh.write("| Component | Version | License | Files |\n|---|---|---|---|\n")
        for name in sorted(formulae):
            version, files = formulae[name]
            fh.write(f"| {name} | {version} | {licenses.get(name, 'unknown')} | {', '.join(sorted(files))} |\n")
    print(f"Bundled {len(copied)} libraries from {len(formulae)} components")

    # Verify nothing still points outside the bundle.
    leaks = []
    for target in [exe] + [os.path.join(frameworks, n) for n in copied.values()]:
        for ref in deps(target):
            if ref.startswith(EXTERNAL_PREFIXES):
                leaks.append(f"{os.path.basename(target)} -> {ref}")
    if leaks:
        print("ERROR: external references remain:\n  " + "\n  ".join(leaks), file=sys.stderr)
        return 1
    if unresolved:
        print("ERROR: unresolved library references:\n  " + "\n  ".join(unresolved), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
