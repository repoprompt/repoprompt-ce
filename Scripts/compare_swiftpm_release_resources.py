#!/usr/bin/env python3
"""Compare architecture-independent SwiftPM release resources deterministically."""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def signature(root: Path) -> dict[str, tuple[str, int, str]]:
    result: dict[str, tuple[str, int, str]] = {}
    for path in [root, *sorted(root.rglob("*"), key=lambda item: str(item.relative_to(root)))]:
        relative = "." if path == root else path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        permissions = stat.S_IMODE(mode)
        if stat.S_ISDIR(mode):
            result[relative] = ("directory", permissions, "")
        elif stat.S_ISREG(mode):
            result[relative] = ("file", permissions, sha256(path))
        elif stat.S_ISLNK(mode):
            result[relative] = ("symlink", permissions, os.readlink(path))
        else:
            fail(f"unsupported SwiftPM resource entry: {path}")
    return result


def resource_roots(build_dir: Path) -> dict[str, Path]:
    roots = {path.name: path for path in build_dir.glob("*.bundle") if path.is_dir()}
    sparkle = build_dir / "Sparkle.framework"
    if not sparkle.is_dir():
        fail(f"missing SwiftPM Sparkle.framework: {sparkle}")
    roots[sparkle.name] = sparkle
    return roots


def main() -> int:
    if len(sys.argv) != 3:
        fail("usage: compare_swiftpm_release_resources.py <arm64-bin-dir> <x86_64-bin-dir>")
    arm_dir = Path(sys.argv[1])
    intel_dir = Path(sys.argv[2])
    if not arm_dir.is_dir() or not intel_dir.is_dir():
        fail("both SwiftPM release bin directories must exist")

    arm_roots = resource_roots(arm_dir)
    intel_roots = resource_roots(intel_dir)
    if set(arm_roots) != set(intel_roots):
        missing_arm = sorted(set(intel_roots) - set(arm_roots))
        missing_intel = sorted(set(arm_roots) - set(intel_roots))
        fail(
            "SwiftPM resource root mismatch; "
            f"missing from arm64={missing_arm}, missing from x86_64={missing_intel}"
        )

    for name in sorted(arm_roots):
        arm_signature = signature(arm_roots[name])
        intel_signature = signature(intel_roots[name])
        if arm_signature != intel_signature:
            differing = sorted(
                key
                for key in set(arm_signature) | set(intel_signature)
                if arm_signature.get(key) != intel_signature.get(key)
            )
            preview = ", ".join(differing[:10])
            suffix = "" if len(differing) <= 10 else f" (+{len(differing) - 10} more)"
            fail(f"SwiftPM resource differs across architectures: {name}: {preview}{suffix}")

    print(
        "OK: SwiftPM release resources are equivalent across arm64 and x86_64: "
        + ", ".join(sorted(arm_roots))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
