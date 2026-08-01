#!/usr/bin/env python3
"""Validate the exact CI run, Actions artifact, and Tip stage metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


FULL_SHA = re.compile(r"[0-9a-f]{40}")
FILE_DIGEST = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not parse {path.name}: {error}")


def require_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        fail(f"{label} mismatch: expected {expected!r}, got {actual!r}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"could not hash {path}: {error}")
    return digest.hexdigest()


def write_github_output(path: Path, values: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as output:
        for name, value in values.items():
            output.write(f"{name}={value}\n")


def resolve_artifact(args: argparse.Namespace) -> dict[str, object]:
    if not FULL_SHA.fullmatch(args.expected_sha):
        fail("expected SHA must be a full lowercase 40-character SHA")
    if args.run_id < 1 or args.run_attempt < 1:
        fail("CI run ID and attempt must be positive integers")

    run = read_json(args.run_json)
    workflow = read_json(args.workflow_json)
    artifacts_document = read_json(args.artifacts_json)
    if not isinstance(run, dict) or not isinstance(workflow, dict) or not isinstance(artifacts_document, dict):
        fail("GitHub API documents must be JSON objects")

    require_equal(run.get("id"), args.run_id, "CI run ID")
    require_equal(run.get("run_attempt"), args.run_attempt, "CI run attempt")
    require_equal(run.get("name"), args.workflow_name, "CI workflow name")
    require_equal(run.get("workflow_id"), workflow.get("id"), "CI workflow ID")
    require_equal(str(run.get("path", "")).split("@", 1)[0], args.workflow_path, "CI workflow path")
    require_equal(str(workflow.get("path", "")).split("@", 1)[0], args.workflow_path, "workflow API path")
    require_equal(run.get("event"), args.event, "CI event")
    require_equal(run.get("head_branch"), args.branch, "CI head branch")
    require_equal(run.get("status"), "completed", "CI status")
    require_equal(run.get("conclusion"), "success", "CI conclusion")
    require_equal(run.get("head_sha"), args.expected_sha, "CI head SHA")
    require_equal((run.get("repository") or {}).get("full_name"), args.repository, "CI repository")
    require_equal((run.get("head_repository") or {}).get("full_name"), args.repository, "CI head repository")
    repository_id = (run.get("repository") or {}).get("id")
    head_repository_id = (run.get("head_repository") or {}).get("id")
    if not isinstance(repository_id, int) or repository_id < 1:
        fail("CI repository ID must be a positive integer")
    require_equal(head_repository_id, repository_id, "CI head repository ID")

    name_pattern = re.compile(
        rf"RepoPrompt-CE-tip-stage-{args.run_id}-([1-9][0-9]*)-{args.expected_sha}"
    )
    artifacts = artifacts_document.get("artifacts")
    if not isinstance(artifacts, list):
        fail("workflow artifacts response must contain an artifacts array")
    candidates: list[tuple[int, dict[str, object]]] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not isinstance(artifact.get("name"), str):
            continue
        match = name_pattern.fullmatch(artifact["name"])
        if match is None:
            continue
        artifact_attempt = int(match.group(1))
        if artifact_attempt > args.run_attempt:
            fail("Tip stage artifact attempt exceeds the completed CI run attempt")
        candidates.append((artifact_attempt, artifact))
    if not candidates:
        fail("expected at least one run-bound Tip stage artifact")
    artifact_attempt = max(attempt for attempt, _ in candidates)
    matching = [artifact for attempt, artifact in candidates if attempt == artifact_attempt]
    if len(matching) != 1:
        fail(f"expected exactly one Tip stage artifact for attempt {artifact_attempt}, got {len(matching)}")
    artifact = matching[0]
    expected_name = f"RepoPrompt-CE-tip-stage-{args.run_id}-{artifact_attempt}-{args.expected_sha}"
    artifact_id = artifact.get("id")
    if not isinstance(artifact_id, int) or artifact_id < 1:
        fail("Tip stage artifact ID must be a positive integer")
    if artifact.get("expired") is not False:
        fail("Tip stage artifact is expired")
    size = artifact.get("size_in_bytes")
    if not isinstance(size, int) or size < 1:
        fail("Tip stage artifact must be nonempty")
    artifact_run = artifact.get("workflow_run") or {}
    require_equal(artifact_run.get("id"), args.run_id, "artifact workflow run ID")
    require_equal(artifact_run.get("head_sha"), args.expected_sha, "artifact head SHA")
    require_equal(artifact_run.get("head_branch"), args.branch, "artifact head branch")
    require_equal(artifact_run.get("repository_id"), repository_id, "artifact repository ID")
    require_equal(artifact_run.get("head_repository_id"), repository_id, "artifact head repository ID")

    return {
        "artifact-id": artifact_id,
        "artifact-name": expected_name,
        "source-run-attempt": artifact_attempt,
    }


def verify_stage_metadata(args: argparse.Namespace) -> None:
    metadata = read_json(args.metadata)
    if not isinstance(metadata, dict):
        fail("Tip stage metadata must be a JSON object")
    expected_keys = {
        "schema_version",
        "repository",
        "workflow",
        "event",
        "branch",
        "run_id",
        "run_attempt",
        "head_sha",
        "artifact_name",
        "stable_build_number",
        "commit_sequence",
        "build_number",
        "tag",
        "archive",
        "archive_sha256",
        "checksum",
        "checksum_sha256",
        "app_manifest_sha256",
    }
    require_equal(set(metadata), expected_keys, "Tip stage metadata keys")
    expected_values = {
        "schema_version": 1,
        "repository": args.repository,
        "workflow": args.workflow_path,
        "event": args.event,
        "branch": args.branch,
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "head_sha": args.expected_sha,
        "artifact_name": args.artifact_name,
        "stable_build_number": args.stable_build_number,
        "commit_sequence": args.commit_sequence,
        "build_number": args.build_number,
        "tag": args.tag,
        "archive": args.archive.name,
        "checksum": args.checksum.name,
    }
    for key, expected in expected_values.items():
        require_equal(metadata.get(key), expected, f"Tip stage metadata {key}")

    archive_digest = sha256(args.archive)
    checksum_digest = sha256(args.checksum)
    manifest_digest = sha256(args.app_manifest)
    for key, expected in {
        "archive_sha256": archive_digest,
        "checksum_sha256": checksum_digest,
        "app_manifest_sha256": manifest_digest,
    }.items():
        value = metadata.get(key)
        if not isinstance(value, str) or not FILE_DIGEST.fullmatch(value):
            fail(f"Tip stage metadata {key} must be a lowercase SHA-256")
        require_equal(value, expected, f"Tip stage metadata {key}")

    try:
        checksum_lines = args.checksum.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"could not read stage checksum: {error}")
    expected_checksum_line = f"{archive_digest}  {args.archive.name}"
    require_equal(checksum_lines, [expected_checksum_line], "stage checksum contents")
    print("OK: Tip stage metadata matches the exact successful CI artifact.")


def positive_integer(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer") from None
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-path", required=True)
    parser.add_argument("--event", default="push")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--run-id", required=True, type=positive_integer)
    parser.add_argument("--run-attempt", required=True, type=positive_integer)
    parser.add_argument("--expected-sha", required=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve_parser = subparsers.add_parser("resolve")
    add_common(resolve_parser)
    resolve_parser.add_argument("--workflow-name", default="CI")
    resolve_parser.add_argument("--run-json", required=True, type=Path)
    resolve_parser.add_argument("--workflow-json", required=True, type=Path)
    resolve_parser.add_argument("--artifacts-json", required=True, type=Path)
    resolve_parser.add_argument("--github-output", required=True, type=Path)

    metadata_parser = subparsers.add_parser("verify-metadata")
    add_common(metadata_parser)
    metadata_parser.add_argument("--artifact-name", required=True)
    metadata_parser.add_argument("--stable-build-number", required=True)
    metadata_parser.add_argument("--commit-sequence", required=True, type=positive_integer)
    metadata_parser.add_argument("--build-number", required=True)
    metadata_parser.add_argument("--tag", required=True)
    metadata_parser.add_argument("--metadata", required=True, type=Path)
    metadata_parser.add_argument("--archive", required=True, type=Path)
    metadata_parser.add_argument("--checksum", required=True, type=Path)
    metadata_parser.add_argument("--app-manifest", required=True, type=Path)

    args = parser.parse_args()
    if args.command == "resolve":
        values = resolve_artifact(args)
        write_github_output(args.github_output, values)
        print(json.dumps(values, sort_keys=True, separators=(",", ":")))
    else:
        verify_stage_metadata(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
