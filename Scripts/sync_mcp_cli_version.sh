#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-sync}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CLI_SOURCE="$ROOT_DIR/Sources/RepoPromptMCP/main.swift"
HEADLESS_VERSION_SOURCE="$ROOT_DIR/Sources/RepoPromptHeadless/HeadlessVersion.swift"

source "$SCRIPT_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"

python3 - "$MODE" "$CLI_SOURCE" "$HEADLESS_VERSION_SOURCE" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PYTHON'
import re
import sys
from pathlib import Path

mode, cli_source_path, headless_source_path, marketing_version, build_number = sys.argv[1:]
cli_source = Path(cli_source_path)
headless_source = Path(headless_source_path)

def replace_exactly_one(text: str, pattern: re.Pattern[str], expected: str, label: str) -> tuple[str, bool, str]:
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one {label} declaration, found {len(matches)}")
    current = matches[0]
    return text.replace(current, expected, 1), current != expected, current

cli_text = cli_source.read_text(encoding="utf-8")
cli_pattern = re.compile(r'^let CLI_VERSION = "[^"]+"$', re.MULTILINE)
expected_cli = f'let CLI_VERSION = "{marketing_version}"'
cli_synced_text, cli_changed, current_cli = replace_exactly_one(cli_text, cli_pattern, expected_cli, f"MCP CLI version in {cli_source}")

headless_text = headless_source.read_text(encoding="utf-8")
headless_marketing_pattern = re.compile(r'^    static let marketingVersion = "[^"]+"$', re.MULTILINE)
headless_build_pattern = re.compile(r'^    static let buildNumber = "[^"]+"$', re.MULTILINE)
expected_headless_marketing = f'    static let marketingVersion = "{marketing_version}"'
expected_headless_build = f'    static let buildNumber = "{build_number}"'
headless_synced_text, headless_marketing_changed, current_headless_marketing = replace_exactly_one(
    headless_text,
    headless_marketing_pattern,
    expected_headless_marketing,
    f"Headless marketing version in {headless_source}",
)
headless_synced_text, headless_build_changed, current_headless_build = replace_exactly_one(
    headless_synced_text,
    headless_build_pattern,
    expected_headless_build,
    f"Headless build number in {headless_source}",
)

if mode == "--check":
    mismatches = []
    if cli_changed:
        mismatches.append(f"MCP CLI has {current_cli}, expected {expected_cli}")
    if headless_marketing_changed:
        mismatches.append(f"Headless has {current_headless_marketing.strip()}, expected {expected_headless_marketing.strip()}")
    if headless_build_changed:
        mismatches.append(f"Headless has {current_headless_build.strip()}, expected {expected_headless_build.strip()}")
    if mismatches:
        raise SystemExit(
            "ERROR: MCP CLI/headless versions are out of sync with version.env. "
            "Run ./Scripts/release.sh sync-cli-version after updating version.env.\n- "
            + "\n- ".join(mismatches)
        )
    print(f"OK: MCP CLI and headless versions match release metadata ({marketing_version}, build {build_number}).")
elif mode == "sync":
    changed = False
    if cli_changed:
        cli_source.write_text(cli_synced_text, encoding="utf-8")
        print(f"Updated MCP CLI version to {marketing_version}: {cli_source}")
        changed = True
    else:
        print(f"OK: MCP CLI version already matches release metadata ({marketing_version}).")
    if headless_marketing_changed or headless_build_changed:
        headless_source.write_text(headless_synced_text, encoding="utf-8")
        print(f"Updated Headless version to {marketing_version} (build {build_number}): {headless_source}")
        changed = True
    else:
        print(f"OK: Headless version already matches release metadata ({marketing_version}, build {build_number}).")
    if not changed:
        print("OK: all executable versions already match release metadata.")
else:
    raise SystemExit(f"ERROR: usage: {sys.argv[0]} [sync|--check]")
PYTHON
