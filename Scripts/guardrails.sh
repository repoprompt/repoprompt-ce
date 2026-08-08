#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./Scripts/source_layout_guardrails.sh
./Scripts/contributor_allowlist_guardrails.sh
./Scripts/swiftpm_notice_guardrails.sh
./Scripts/codex_vendor_guardrails.sh
./Scripts/headless_runtime_guardrails.sh
python3 Scripts/test_mcp_tool_latency.py
python3 Scripts/test_mcp_latency_diagnostic_artifact.py
