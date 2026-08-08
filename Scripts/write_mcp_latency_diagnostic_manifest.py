#!/usr/bin/env python3
"""Write the isolated, non-release MCP latency diagnostic app manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import platform
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
ARTIFACT_KIND = "optimized_mcp_latency_diagnostic_server"
PROVENANCE_NAME = "RepoPromptMCPLatencyDiagnosticProvenance.json"
EXPECTED_DEFINES = {
    "RepoPromptApp": ["MCP_LATENCY_DIAGNOSTICS"],
    "RepoPromptDomainRuntime": ["MCP_LATENCY_DIAGNOSTICS"],
    "RepoPromptMCP": ["MCP_LATENCY_TRACE"],
    "RepoPromptShared": ["MCP_LATENCY_DIAGNOSTICS"],
}


class ManifestError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_within(path: Path, root: Path) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(root.expanduser().resolve())
    except ValueError as error:
        raise ManifestError(f"path escapes diagnostic artifact root: {resolved}") from error
    return resolved


def build_manifest(app: Path, output: Path, artifact_root: Path) -> dict[str, Any]:
    root = artifact_root.expanduser().resolve()
    app = require_within(app, root)
    output = require_within(output, root)
    executable = require_within(app / "Contents/MacOS/RepoPrompt", root)
    helper = require_within(app / "Contents/MacOS/repoprompt-mcp", root)
    provenance_path = require_within(app / "Contents/Resources" / PROVENANCE_NAME, root)
    info_path = require_within(app / "Contents/Info.plist", root)
    for path in (executable, helper, provenance_path, info_path):
        if not path.is_file():
            raise ManifestError(f"missing diagnostic artifact member: {path}")
    if not os.access(executable, os.X_OK) or not os.access(helper, os.X_OK):
        raise ManifestError("diagnostic app executables must be executable")

    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance.get("artifact_kind") != ARTIFACT_KIND:
        raise ManifestError("diagnostic provenance artifact kind mismatch")
    if provenance.get("ordinary_release_artifact") is not False:
        raise ManifestError("diagnostic provenance must be explicitly non-release")
    if provenance.get("swift_configuration") != "release":
        raise ManifestError("diagnostic server must use Swift release configuration")
    if provenance.get("server_diagnostic_configuration") != "optimized_diagnostic":
        raise ManifestError("diagnostic server configuration mismatch")
    if provenance.get("diagnostic_surface") != "mcp_latency_v1":
        raise ManifestError("diagnostic surface mismatch")
    if provenance.get("enabled_defines_by_target") != EXPECTED_DEFINES:
        raise ManifestError("diagnostic target defines mismatch")
    artifact_id = provenance.get("artifact_id")
    if not isinstance(artifact_id, str) or not artifact_id:
        raise ManifestError("diagnostic provenance must include an artifact ID")
    if not isinstance(provenance.get("commit"), str) or not provenance["commit"]:
        raise ManifestError("diagnostic provenance must include a commit identity")
    if not isinstance(provenance.get("dirty"), bool):
        raise ManifestError("diagnostic provenance must record dirty state")
    source_fingerprint = provenance.get("source_fingerprint_sha256")
    if not isinstance(source_fingerprint, str) or len(source_fingerprint) != 64:
        raise ManifestError("diagnostic provenance must include a source fingerprint")

    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != "com.pvncher.repoprompt.ce.mcp-latency-diagnostic":
        raise ManifestError("diagnostic bundle identifier must use the fixed isolated identity")
    signing_mode = info.get("RepoPromptSigningMode")
    storage_backend = info.get("RepoPromptDebugSecureStorageBackend")
    if signing_mode != "mcp-latency-diagnostic-adhoc":
        raise ManifestError("diagnostic signing mode marker mismatch")
    if storage_backend != "alternate-in-memory":
        raise ManifestError("diagnostic secure-storage marker mismatch")

    return {
        "schema_version": SCHEMA_VERSION,
        "artifact_id": artifact_id,
        "artifact_kind": ARTIFACT_KIND,
        "ordinary_release_artifact": False,
        "swift_configuration": "release",
        "server_diagnostic_configuration": "optimized_diagnostic",
        "diagnostic_surface": "mcp_latency_v1",
        "enabled_defines_by_target": provenance.get("enabled_defines_by_target"),
        "commit": provenance.get("commit"),
        "dirty": provenance.get("dirty"),
        "source_fingerprint_sha256": source_fingerprint,
        "bundle_path": str(app),
        "signing_mode": signing_mode,
        "secure_storage_backend": storage_backend,
        "bundle_identifier": bundle_id,
        "executable_path": str(executable),
        "executable_sha256": sha256(executable),
        "embedded_cli_path": str(helper),
        "embedded_cli_sha256": sha256(helper),
        "provenance_path": str(provenance_path),
        "provenance_sha256": sha256(provenance_path),
        "architecture": platform.machine(),
    }


def write_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    payload = build_manifest(args.app, args.output, args.artifact_root)
    write_atomic(args.output.expanduser().resolve(), payload)
    print(args.output.expanduser().resolve())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        raise SystemExit(f"ERROR: {error}")
