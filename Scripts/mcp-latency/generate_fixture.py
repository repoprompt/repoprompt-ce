#!/usr/bin/env python3
"""Generate deterministic MCP latency workspaces outside this repository."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SCHEMA_VERSION = 1
SEED = "mcp-tool-latency-v1-2026-07-29"
MANIFEST_SUFFIX = ".manifest.json"
PROFILES = {
    "small": (500, 1),
    "medium": (10_000, 2),
    "large": (50_000, 4),
}


class FixtureError(RuntimeError):
    pass


@dataclass(frozen=True)
class FixtureSpec:
    name: str
    file_count: int
    root_count: int


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def ensure_external_output(output: Path, repo: Path | None = None) -> Path:
    repo = (repo or repository_root()).resolve()
    resolved = output.expanduser().resolve()
    if resolved == repo or repo in resolved.parents:
        raise FixtureError("fixture output must be outside the repository")
    return resolved


def manifest_path_for_output(output: Path) -> Path:
    return output.with_name(f"{output.name}{MANIFEST_SUFFIX}")


def relative_file_path(index: int, root_index: int) -> Path:
    extension = ("swift", "txt", "md", "json")[index % 4]
    basename = "Duplicate.swift" if index % 113 == 0 else f"file_{index:06d}.{extension}"
    components = [
        f"root-{root_index + 1}",
        f"fanout-{index % 64:02d}",
        f"branch-{(index // 64) % 16:02d}",
    ]
    if index % 97 == 0:
        components.extend(f"deep-{depth}" for depth in range(8))
    return Path(*components, basename)


def file_content(index: int, root_index: int) -> bytes:
    markers = [
        f"seed={SEED}",
        f"file_index={index}",
        f"root_index={root_index}",
        "LATENCY_COMMON",
    ]
    if index % 97 == 0:
        markers.append("LATENCY_RARE")
    if index % 211 == 0:
        markers.append("literal.with.regex[characters]")
    markers.append(f"payload={'x' * (32 + index % 127)}")
    return ("\n".join(markers) + "\n").encode("utf-8")


def manifest_digest(entries: Iterable[tuple[str, bytes]]) -> str:
    digest = hashlib.sha256()
    for relative, payload in sorted(entries):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(payload)
        digest.update(b"\0")
    return digest.hexdigest()


def generate_fixture(output: Path, spec: FixtureSpec, *, repo: Path | None = None) -> dict[str, object]:
    output = ensure_external_output(output, repo)
    manifest_path = manifest_path_for_output(output)
    if output.exists():
        raise FixtureError(f"fixture output already exists: {output}")
    if manifest_path.exists():
        raise FixtureError(f"fixture manifest already exists: {manifest_path}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=output.parent))
    temporary_manifest = temporary.with_name(f"{temporary.name}{MANIFEST_SUFFIX}")
    entries: list[tuple[str, bytes]] = []
    root_counts = [0] * spec.root_count
    maximum_depth = 0
    total_bytes = 0
    try:
        (temporary / "empty-root").mkdir()
        for index in range(spec.file_count):
            root_index = index % spec.root_count
            relative = relative_file_path(index, root_index)
            payload = file_content(index, root_index)
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            entries.append((relative.as_posix(), payload))
            root_counts[root_index] += 1
            maximum_depth = max(maximum_depth, len(relative.parts) - 1)
            total_bytes += len(payload)

        expected = {
            "content_literal_LATENCY_COMMON": spec.file_count,
            "content_literal_LATENCY_RARE": sum(1 for index in range(spec.file_count) if index % 97 == 0),
            "content_regex_literal_with_regex_characters": sum(
                1 for index in range(spec.file_count) if index % 211 == 0
            ),
            "path_duplicate_basename": sum(1 for index in range(spec.file_count) if index % 113 == 0),
            "zero_match": 0,
        }
        manifest: dict[str, object] = {
            "schema_version": SCHEMA_VERSION,
            "generator": "Scripts/mcp-latency/generate_fixture.py",
            "profile": spec.name,
            "seed": SEED,
            "root_count": spec.root_count,
            "root_file_counts": root_counts,
            "file_count": spec.file_count,
            "total_file_bytes": total_bytes,
            "workspace_inventory": {
                "manifest_location": "external_sibling",
                "root_paths": [
                    *(f"root-{index + 1}" for index in range(spec.root_count)),
                    "empty-root",
                ],
                "populated_root_count": spec.root_count,
                "empty_root_count": 1,
                "workspace_root_count": spec.root_count + 1,
                "measured_file_count": spec.file_count,
                "measured_file_bytes": total_bytes,
                "digest_scope": "measured_payload_files_only",
            },
            "maximum_relative_directory_depth": maximum_depth,
            "expected_search_counts": expected,
            "digest_algorithm": "sha256(relative-path\\0content\\0)",
            "digest": manifest_digest(entries),
        }
        temporary_manifest.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.rename(temporary, output)
        os.rename(temporary_manifest, manifest_path)
        return manifest
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        temporary_manifest.unlink(missing_ok=True)
        if output.exists() and not manifest_path.exists():
            shutil.rmtree(output, ignore_errors=True)
        raise


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--output", required=True, help="new external directory; must not be inside the checkout")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    count, roots = PROFILES[args.profile]
    try:
        manifest = generate_fixture(Path(args.output), FixtureSpec(args.profile, count, roots))
    except FixtureError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
