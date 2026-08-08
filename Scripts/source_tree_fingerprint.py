#!/usr/bin/env python3
"""Compute a deterministic fingerprint of non-ignored repository source state."""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
from pathlib import Path


class FingerprintError(RuntimeError):
    pass


def source_tree_fingerprint(repo: Path) -> str:
    root = repo.expanduser().resolve()
    process = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        capture_output=True,
        check=False,
    )
    if process.returncode:
        raise FingerprintError(process.stderr.decode("utf-8", errors="replace").strip() or "git ls-files failed")
    digest = hashlib.sha256()
    for raw_relative in sorted(item for item in process.stdout.split(b"\0") if item):
        relative = raw_relative.decode("utf-8", errors="surrogateescape")
        path = root / relative
        encoded_path = os.fsencode(relative)
        digest.update(len(encoded_path).to_bytes(8, "big"))
        digest.update(encoded_path)
        if path.is_symlink():
            payload = os.fsencode(os.readlink(path))
            kind = b"L"
        elif path.is_file():
            payload = path.read_bytes()
            kind = b"F"
        else:
            payload = b""
            kind = b"D"
        digest.update(kind)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    args = parser.parse_args()
    print(source_tree_fingerprint(args.repo))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FingerprintError as error:
        raise SystemExit(f"ERROR: {error}")
