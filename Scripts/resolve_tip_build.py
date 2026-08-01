#!/usr/bin/env python3
"""Resolve deterministic RepoPrompt CE Tip build metadata."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


FULL_SHA = re.compile(r"[0-9a-f]{40}")
STABLE_BUILD = re.compile(r"[1-9][0-9]{0,3}")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail((result.stderr or result.stdout or "git command failed").strip())
    return result.stdout.strip()


def validate_stable_build(value: object, source: str) -> str:
    if not isinstance(value, str) or not STABLE_BUILD.fullmatch(value):
        fail(f"{source} must be a canonical positive decimal with at most four digits")
    return value


def parse_stable_build(appcast: Path) -> str:
    import xml.etree.ElementTree as ET

    try:
        root = ET.parse(appcast).getroot()
    except (OSError, ET.ParseError) as error:
        fail(f"could not parse stable appcast: {error}")
    versions = [
        (element.text or "").strip()
        for element in root.iter()
        if element.tag.rsplit("}", 1)[-1] == "version"
    ]
    if len(versions) != 1:
        fail(f"stable appcast must contain exactly one sparkle:version, got {len(versions)}")
    return validate_stable_build(versions[0], "stable appcast sparkle:version")


def read_stage_metadata(path: Path) -> dict[str, object]:
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not parse Tip stage metadata: {error}")
    if not isinstance(metadata, dict):
        fail("Tip stage metadata must be a JSON object")
    return metadata


def resolve(
    repository: Path,
    commit: str,
    stable_build: str,
    app_name: str,
) -> dict[str, object]:
    if not FULL_SHA.fullmatch(commit):
        fail("Tip commit must be a full lowercase 40-character SHA")
    resolved_commit = run_git(repository, "rev-parse", "--verify", f"{commit}^{{commit}}")
    if resolved_commit != commit:
        fail(f"Tip commit did not resolve exactly: expected {commit}, got {resolved_commit}")
    sequence_text = run_git(repository, "rev-list", "--count", commit)
    if not sequence_text.isdigit():
        fail("Tip commit sequence must be numeric")
    sequence = int(sequence_text)
    if sequence < 1 or sequence > 9999:
        fail("Tip commit sequence must be between 1 and 9999")

    stable_build = validate_stable_build(stable_build, "stable build number")
    short_sha = commit[:12]
    build_number = f"{stable_build}.{sequence // 100}.{sequence % 100}"
    tag = f"tip-{short_sha}"
    archive_basename = f"{app_name}-tip-{short_sha}-{build_number}"
    return {
        "commit": commit,
        "short_sha": short_sha,
        "stable_build_number": stable_build,
        "commit_sequence": sequence,
        "build_number": build_number,
        "tag": tag,
        "archive_basename": archive_basename,
    }


def write_github_output(path: Path, metadata: dict[str, object]) -> None:
    names = {
        "commit": "commit",
        "short_sha": "short-sha",
        "stable_build_number": "stable-build-number",
        "commit_sequence": "commit-sequence",
        "build_number": "build-number",
        "tag": "tag",
        "archive_basename": "archive-basename",
    }
    with path.open("a", encoding="utf-8") as output:
        for key, name in names.items():
            output.write(f"{name}={metadata[key]}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    stable_source = parser.add_mutually_exclusive_group(required=True)
    stable_source.add_argument("--stable-appcast", type=Path)
    stable_source.add_argument("--stage-metadata", type=Path)
    parser.add_argument("--app-name", default="RepoPrompt")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    stage_metadata = None
    if args.stable_appcast is not None:
        stable_build = parse_stable_build(args.stable_appcast)
    else:
        stage_metadata = read_stage_metadata(args.stage_metadata)
        stable_build = validate_stable_build(
            stage_metadata.get("stable_build_number"),
            "Tip stage metadata stable_build_number",
        )

    metadata = resolve(args.repository, args.commit, stable_build, args.app_name)
    if stage_metadata is not None:
        expected = {
            "head_sha": metadata["commit"],
            "stable_build_number": metadata["stable_build_number"],
            "commit_sequence": metadata["commit_sequence"],
            "build_number": metadata["build_number"],
            "tag": metadata["tag"],
            "archive": f"{metadata['archive_basename']}-stage.zip",
        }
        for key, value in expected.items():
            if stage_metadata.get(key) != value:
                fail(
                    f"Tip stage metadata {key} mismatch: "
                    f"expected {value!r}, got {stage_metadata.get(key)!r}"
                )
    if args.github_output is not None:
        write_github_output(args.github_output, metadata)
    print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
