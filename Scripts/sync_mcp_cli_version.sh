#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-sync}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CLI_SOURCE="$ROOT_DIR/Sources/RepoPromptMCP/main.swift"

source "$SCRIPT_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"

python3 - "$MODE" "$CLI_SOURCE" "$MARKETING_VERSION" <<'PYTHON'
import re
import sys
from pathlib import Path

mode, source_path, marketing_version = sys.argv[1:]
source = Path(source_path)
text = source.read_text(encoding="utf-8")
pattern = re.compile(r'^let CLI_VERSION = "[^"]+"$', re.MULTILINE)
matches = pattern.findall(text)
if len(matches) != 1:
    raise SystemExit(
        f"ERROR: expected exactly one MCP CLI version declaration in {source}, found {len(matches)}"
    )

current = matches[0]
expected = f'let CLI_VERSION = "{marketing_version}"'
if mode == "--check":
    if current != expected:
        raise SystemExit(
            "ERROR: MCP CLI version is out of sync with version.env. "
            "Run ./Scripts/release.sh sync-cli-version after updating version.env."
        )
    print(f"OK: MCP CLI version matches release metadata ({marketing_version}).")
elif mode == "sync":
    if current == expected:
        print(f"OK: MCP CLI version already matches release metadata ({marketing_version}).")
    else:
        source.write_text(text.replace(current, expected, 1), encoding="utf-8")
        print(f"Updated MCP CLI version to {marketing_version}: {source}")
else:
    raise SystemExit(f"ERROR: usage: {sys.argv[0]} [sync|--check]")
PYTHON
