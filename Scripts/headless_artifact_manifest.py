#!/usr/bin/env python3
"""Write and verify the standalone RepoPrompt Headless artifact manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


class ManifestError(RuntimeError):
    pass


def run(*argv: str, cwd: Path | None = None) -> str:
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise ManifestError(f"command failed ({' '.join(argv)}): {result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def architectures(path: Path, lipo_tool: Path) -> list[str]:
    return sorted(run(str(lipo_tool), "-archs", str(path)).split())


def expected_architectures(raw: str) -> list[str]:
    return sorted(item.strip() for item in raw.split(",") if item.strip())


def git_metadata(root: Path) -> dict[str, object]:
    status = run("git", "status", "--porcelain=v1", "--untracked-files=normal", cwd=root)
    return {
        "commit": run("git", "rev-parse", "HEAD", cwd=root),
        "dirty": bool(status),
        "statusPorcelain": status.splitlines(),
    }


def binary_version(binary: Path) -> str:
    return run(str(binary), "--version")


def absolute_normalized_path(raw: str) -> Path:
    normalized = os.path.normpath(raw)
    if not os.path.isabs(raw) or normalized != raw:
        raise argparse.ArgumentTypeError(
            f"must be an absolute normalized path, got {raw!r}"
        )
    return Path(raw)


def build_payload(args: argparse.Namespace) -> dict[str, object]:
    binary_input = args.binary.absolute()
    if binary_input.is_symlink() or not binary_input.is_file():
        raise ManifestError(f"artifact must be a regular non-symlink file: {binary_input}")
    binary = binary_input.resolve()
    artifact_path = args.artifact_path.resolve() if args.artifact_path else binary
    file_stat = binary.stat()
    actual_architectures = architectures(binary, args.lipo_tool)
    expected = expected_architectures(args.expected_architectures)
    if actual_architectures != expected:
        raise ManifestError(f"architecture mismatch: expected {expected}, got {actual_architectures}")
    expected_version_output = f"repoprompt-headless {args.version} (build {args.build})"
    observed_version = binary_version(binary)
    if observed_version != expected_version_output:
        raise ManifestError(f"version mismatch: expected {expected_version_output!r}, got {observed_version!r}")
    return {
        "schemaVersion": 1,
        "product": "repoprompt-headless",
        "target": "RepoPromptHeadless",
        "displayName": "RepoPrompt Headless",
        "protocolVersion": "2024-11-05",
        "configuration": args.configuration,
        "version": args.version,
        "build": args.build,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": git_metadata(args.source_root.resolve()),
        "artifact": {
            "path": str(artifact_path),
            "sha256": sha256(binary),
            "size": file_stat.st_size,
            "mode": format(stat.S_IMODE(file_stat.st_mode), "04o"),
            "ownerUID": file_stat.st_uid,
            "architectures": actual_architectures,
            "versionOutput": observed_version,
        },
    }


def write_manifest(args: argparse.Namespace) -> None:
    payload = build_payload(args)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
    os.chmod(output, 0o600)
    print(output)


def verify_manifest(args: argparse.Namespace) -> None:
    expected = build_payload(args)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ManifestError("manifest root must be an object")
    for key in ("schemaVersion", "product", "target", "displayName", "protocolVersion", "configuration", "version", "build"):
        if manifest.get(key) != expected.get(key):
            raise ManifestError(f"manifest field {key} mismatch: expected {expected.get(key)!r}, got {manifest.get(key)!r}")
    artifact = manifest.get("artifact")
    if not isinstance(artifact, dict):
        raise ManifestError("manifest artifact must be an object")
    for key in ("path", "sha256", "size", "mode", "ownerUID", "architectures", "versionOutput"):
        if artifact.get(key) != expected["artifact"][key]:
            raise ManifestError(f"manifest artifact field {key} mismatch")
    source = manifest.get("source", {})
    if not isinstance(source, dict):
        raise ManifestError("manifest source must be an object")
    for key in ("commit", "dirty", "statusPorcelain"):
        if source.get(key) != expected["source"][key]:
            raise ManifestError(f"manifest source field {key} mismatch")
    print(f"OK: verified {args.manifest}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="action", required=True)
    for action in ("write", "verify"):
        child = subparsers.add_parser(action)
        child.add_argument("--binary", type=Path, required=True)
        child.add_argument("--source-root", type=Path, required=True)
        child.add_argument("--configuration", choices=("debug", "release"), required=True)
        child.add_argument("--version", required=True)
        child.add_argument("--build", required=True)
        child.add_argument("--expected-architectures", required=True)
        child.add_argument("--artifact-path", type=absolute_normalized_path)
        child.add_argument("--lipo-tool", type=Path, default=Path("/usr/bin/lipo"))
        if action == "write":
            child.add_argument("--output", type=Path, required=True)
        else:
            child.add_argument("--manifest", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.action == "write":
            write_manifest(args)
        else:
            verify_manifest(args)
        return 0
    except (ManifestError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
