#!/usr/bin/env python3
"""Packs the KernelSU/Magisk module zip.

The module archive must contain module files only, but the repository also
carries developer material: tests/, tools/, .workbuddy-ai/, .git/ and previous
release zips. Building with a plain "zip -r ." from the root sweeps all of it
into the module, and the installer then unpacks it onto the device.

So this builds from an explicit **allow-list** rather than a list of
exclusions: adding a new top-level directory to the module is a deliberate edit
to MODULE_FILES / MODULE_DIRS, not something that happens by accident. The
archive is verified before the build is reported as successful — a path outside
the allow-list is a hard error, not a warning.

    python tools/build.py                 # -> nfqws2-android-<version>.zip
    python tools/build.py /tmp/out.zip    # explicit destination

customize.sh additionally refuses to unpack tests/, tools/ and .workbuddy-ai/
even if they somehow end up in the archive, so a hand-made zip cannot leak them
onto a device either.
"""

from __future__ import annotations

import os
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Everything the module needs at runtime, and nothing else.
MODULE_FILES = [
    "action.sh",
    "customize.sh",
    "service.sh",
    "uninstall.sh",
    "module.prop",
    "LICENSE",
    "README.md",
]
MODULE_DIRS = [
    "bin",
    "binaries",
    "blobs",
    "defaults",
    "lib",
    "lists",
    "lua",
    "strategies",
    "webroot",
]

# Never allowed inside the archive, whatever else changes. Checked after the
# build so a future allow-list entry cannot quietly reintroduce them.
FORBIDDEN_PREFIXES = ("tests/", "tools/", ".workbuddy-ai/", ".git/")

# Anything that must be executable once installed.
EXECUTABLE = ("*.sh", "bin/*", "binaries/*/*")


def version() -> str:
    for line in (REPO / "module.prop").read_text(encoding="utf-8").splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip()
    return "unknown"


def module_id() -> str:
    for line in (REPO / "module.prop").read_text(encoding="utf-8").splitlines():
        if line.startswith("id="):
            return line.split("=", 1)[1].strip()
    return "module"


def is_executable(rel: str) -> bool:
    from fnmatch import fnmatch

    return any(fnmatch(rel, pat) for pat in EXECUTABLE)


def collect() -> list[Path]:
    """Every file that belongs in the module, in a stable order."""
    out: list[Path] = []

    for name in MODULE_FILES:
        p = REPO / name
        if not p.is_file():
            sys.exit(f"build: {name} is missing from the repository")
        out.append(p)

    for name in MODULE_DIRS:
        d = REPO / name
        if not d.is_dir():
            sys.exit(f"build: {name}/ is missing from the repository")
        out.extend(sorted(p for p in d.rglob("*") if p.is_file()))

    return out


def main() -> int:
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / f"{module_id()}-{version()}.zip"
    dest = dest.resolve()

    files = collect()

    # Directory entries, so the archive looks like the ones Magisk/KernelSU ship.
    # The top-level module directories are listed explicitly: binaries/ holds only
    # subdirectories, so deriving parents from files alone would skip its entry.
    dirs = sorted(
        {Path(d) for d in MODULE_DIRS}
        | {p.relative_to(REPO).parent for p in files}
        - {Path(".")}
    )

    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for d in dirs:
            z.writestr(str(d).replace(os.sep, "/") + "/", "")
        for p in files:
            rel = str(p.relative_to(REPO)).replace(os.sep, "/")
            info = zipfile.ZipInfo.from_file(p, rel)
            mode = 0o755 if is_executable(rel) else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(info, fh.read())

    # Verify: nothing dev-only, and nothing missing.
    with zipfile.ZipFile(dest) as z:
        names = z.namelist()

    leaked = sorted(n for n in names if n.startswith(FORBIDDEN_PREFIXES))
    if leaked:
        dest.unlink(missing_ok=True)
        sys.exit("build: refusing to ship developer files:\n  " + "\n  ".join(leaked))

    strays = sorted(
        n for n in names
        if n.rstrip("/").split("/")[0] not in set(MODULE_FILES + MODULE_DIRS)
    )
    if strays:
        dest.unlink(missing_ok=True)
        sys.exit("build: archive contains paths outside the allow-list:\n  " + "\n  ".join(strays))

    size = dest.stat().st_size
    print(f"built {dest.name}")
    print(f"  {len(files)} files in {len(names)} entries, {size / 1024:.0f} KiB")
    print(f"  module {module_id()} {version()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
