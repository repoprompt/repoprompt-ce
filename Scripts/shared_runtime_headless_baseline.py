#!/usr/bin/env python3
"""Manage the reviewed hardened headless source/test baseline manifest."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
HEADLESS_ROOTS = (
    "Sources/RepoPromptHeadless",
    "Tests/RepoPromptHeadlessTests",
)
DEFAULT_MANIFEST = ROOT / "Scripts/Fixtures/shared-runtime-headless-reviewed.sha256"
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")


class ReviewedHeadlessBaselineError(AssertionError):
    """Raised when the reviewed headless baseline contract is invalid or drifts."""


def _is_in_scope(relative: str, roots: Iterable[str]) -> bool:
    return any(relative.startswith(f"{root}/") for root in roots)


def collect_entries(repository_root: Path, roots: tuple[str, ...] = HEADLESS_ROOTS) -> dict[str, str]:
    entries: dict[str, str] = {}
    for root in roots:
        source_root = repository_root / root
        if not source_root.is_dir():
            raise ReviewedHeadlessBaselineError(f"Reviewed headless baseline root is missing: {root}")
        for path in sorted(source_root.rglob("*")):
            if path.is_symlink():
                relative = path.relative_to(repository_root).as_posix()
                raise ReviewedHeadlessBaselineError(
                    f"Reviewed headless baseline does not permit symlinks: {relative}"
                )
            if not path.is_file():
                continue
            relative = path.relative_to(repository_root).as_posix()
            if "\n" in relative:
                raise ReviewedHeadlessBaselineError(
                    f"Reviewed headless baseline cannot encode a newline in a path: {relative!r}"
                )
            entries[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not entries:
        raise ReviewedHeadlessBaselineError("Reviewed headless baseline contains no files")
    return entries


def render_manifest(entries: dict[str, str]) -> str:
    lines = [
        "# Reviewed hardened headless source/test baseline.",
        "# Regenerate only after explicit review of the complete headless trees:",
        "#   python3 Scripts/shared_runtime_headless_baseline.py --write",
        "# Format: <sha256>  <repository-relative-path>",
    ]
    lines.extend(f"{entries[path]}  {path}" for path in sorted(entries))
    return "\n".join(lines) + "\n"


def parse_manifest(
    manifest_path: Path,
    roots: tuple[str, ...] = HEADLESS_ROOTS,
) -> dict[str, str]:
    if not manifest_path.is_file():
        raise ReviewedHeadlessBaselineError(
            f"Reviewed headless baseline manifest is missing: {manifest_path}"
        )

    entries: dict[str, str] = {}
    manifest_text = manifest_path.read_bytes().decode("utf-8")
    for line_number, line in enumerate(manifest_text.split("\n"), 1):
        if not line or line.startswith("#"):
            continue
        digest, separator, relative = line.partition("  ")
        if not separator or not DIGEST_PATTERN.fullmatch(digest) or not relative:
            raise ReviewedHeadlessBaselineError(
                f"Invalid reviewed headless baseline entry at {manifest_path}:{line_number}"
            )
        if relative.startswith("/") or ".." in Path(relative).parts or not _is_in_scope(relative, roots):
            raise ReviewedHeadlessBaselineError(
                f"Reviewed headless baseline entry is outside the locked trees: {relative}"
            )
        if relative in entries:
            raise ReviewedHeadlessBaselineError(
                f"Duplicate reviewed headless baseline entry: {relative}"
            )
        entries[relative] = digest

    if not entries:
        raise ReviewedHeadlessBaselineError("Reviewed headless baseline manifest contains no entries")
    return entries


def verify_reviewed_headless_baseline(
    repository_root: Path = ROOT,
    manifest_path: Path = DEFAULT_MANIFEST,
    roots: tuple[str, ...] = HEADLESS_ROOTS,
) -> None:
    expected = parse_manifest(manifest_path, roots)
    actual = collect_entries(repository_root, roots)

    expected_paths = set(expected)
    actual_paths = set(actual)
    added = sorted(actual_paths - expected_paths)
    removed = sorted(expected_paths - actual_paths)
    if added or removed:
        raise ReviewedHeadlessBaselineError(
            "Reviewed headless tree path set drifted: "
            f"added={added}, removed={removed}"
        )

    changed = sorted(path for path in expected if actual[path] != expected[path])
    if changed:
        raise ReviewedHeadlessBaselineError(
            f"Reviewed headless file content drifted: {changed}"
        )


def write_reviewed_headless_baseline(
    repository_root: Path = ROOT,
    manifest_path: Path = DEFAULT_MANIFEST,
    roots: tuple[str, ...] = HEADLESS_ROOTS,
) -> int:
    entries = collect_entries(repository_root, roots)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(render_manifest(entries), encoding="utf-8")
    return len(entries)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true", help="verify the reviewed baseline (default)")
    action.add_argument("--write", action="store_true", help="rewrite the manifest from the complete trees")
    args = parser.parse_args()

    try:
        if args.write:
            count = write_reviewed_headless_baseline()
            print(f"Wrote reviewed headless baseline for {count} files: {DEFAULT_MANIFEST.relative_to(ROOT)}")
        else:
            verify_reviewed_headless_baseline()
            print("OK: reviewed hardened headless source/test baseline passed.")
        return 0
    except ReviewedHeadlessBaselineError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
