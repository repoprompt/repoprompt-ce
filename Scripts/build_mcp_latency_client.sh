#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/.build/mcp-latency/optimized"
SCRATCH_DIR="${OUTPUT_DIR}/scratch"
ARTIFACT_PATH="${OUTPUT_DIR}/repoprompt-mcp"
MANIFEST_PATH="${OUTPUT_DIR}/artifact-manifest.json"

cd "${REPO_ROOT}"
mkdir -p "${OUTPUT_DIR}" "${SCRATCH_DIR}"
RPCE_ENABLE_MCP_LATENCY_TRACE=1 swift build \
  --scratch-path "${SCRATCH_DIR}" \
  -c release \
  --product repoprompt-mcp
BIN_DIR="$(RPCE_ENABLE_MCP_LATENCY_TRACE=1 swift build \
  --scratch-path "${SCRATCH_DIR}" \
  -c release \
  --show-bin-path)"
install -m 0755 "${BIN_DIR}/repoprompt-mcp" "${ARTIFACT_PATH}"

python3 - "${REPO_ROOT}" "${ARTIFACT_PATH}" "${MANIFEST_PATH}" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
artifact = pathlib.Path(sys.argv[2])
manifest = pathlib.Path(sys.argv[3])
payload = {
    "schema_version": 1,
    "artifact_kind": "optimized_mcp_latency_diagnostic_client",
    "configuration": "release",
    "commit": subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True,
        text=True, capture_output=True,
    ).stdout.strip(),
    "enabled_defines": ["MCP_LATENCY_TRACE"],
    "ordinary_release_artifact": False,
    "product_path": str(artifact),
    "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
}
temporary = manifest.with_suffix(".json.tmp")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(manifest)
PY

printf 'Optimized MCP latency diagnostic client: %s\n' "${ARTIFACT_PATH}"
printf 'Artifact manifest: %s\n' "${MANIFEST_PATH}"
