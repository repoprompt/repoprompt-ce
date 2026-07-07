#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./Scripts/source_layout_guardrails.sh
./Scripts/contributor_allowlist_guardrails.sh
./Scripts/swiftpm_notice_guardrails.sh
