#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
BINARY_NAME="repoprompt-headless"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Narrow test/automation seams. Production callers use the defaults.
PACKAGE_INPUT_BINARY="${REPOPROMPT_HEADLESS_PACKAGE_INPUT_BINARY:-}"
PACKAGE_EXPECTED_ARCHITECTURES="${REPOPROMPT_HEADLESS_PACKAGE_EXPECTED_ARCHITECTURES:-}"
CODESIGN_TOOL="${REPOPROMPT_HEADLESS_CODESIGN_TOOL:-/usr/bin/codesign}"
LIPO_TOOL="${REPOPROMPT_HEADLESS_LIPO_TOOL:-/usr/bin/lipo}"
TREE_SITTER_SYMBOLS_TOOL="${REPOPROMPT_HEADLESS_TREE_SITTER_SYMBOLS_TOOL:-$CONTROL_PLANE_SCRIPTS_DIR/verify_tree_sitter_symbols.py}"
MANIFEST_TOOL="${REPOPROMPT_HEADLESS_MANIFEST_TOOL:-$CONTROL_PLANE_SCRIPTS_DIR/headless_artifact_manifest.py}"
PROMOTION_TOOL="${REPOPROMPT_HEADLESS_PROMOTION_TOOL:-/bin/mv}"

candidate_dir=""
backup_dir=""
target_had_previous=0
promotion_started=0
transaction_complete=0
active_promotion_pid=""

fail() { echo "ERROR: $*" >&2; exit 1; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }

run_promotion() {
	local status
	printf '+ '; printf '%q ' "$PROMOTION_TOOL" "$@"; printf '\n'
	"$PROMOTION_TOOL" "$@" &
	active_promotion_pid=$!
	if wait "$active_promotion_pid"; then
		status=0
	else
		status=$?
	fi
	active_promotion_pid=""
	return "$status"
}

path_exists() {
	[[ -e "$1" || -L "$1" ]]
}

validate_existing_generation() {
	python3 - "$TARGET_DIR" "$BINARY_NAME" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
binary_name = sys.argv[2]
expected = {binary_name, "artifact-manifest.json"}
entries = {entry.name: entry for entry in os.scandir(root)}
actual = set(entries)
missing = sorted(expected - actual)
unexpected = sorted(actual - expected)
invalid = sorted(
	name
	for name in expected & actual
	if entries[name].is_symlink()
	or not stat.S_ISREG(entries[name].stat(follow_symlinks=False).st_mode)
)
if binary_name in entries and binary_name not in invalid:
	if not os.access(root / binary_name, os.X_OK):
		invalid.append(f"{binary_name} (not executable)")
if missing or unexpected or invalid:
	raise SystemExit(
		"Refusing to replace unmanaged Headless artifact directory: "
		f"expected exactly regular non-symlink leaves {sorted(expected)}; "
		f"missing={missing}, unexpected={unexpected}, invalid={sorted(invalid)}"
	)
PY
}

remove_transaction_path() {
	local path="$1"
	if [[ -d "$path" && ! -L "$path" ]]; then
		/bin/rm -rf "$path"
	elif path_exists "$path"; then
		/bin/rm -f "$path"
	fi
}

cleanup() {
	local status=$?
	trap - EXIT HUP INT TERM
	set +e

	if (( transaction_complete == 0 && promotion_started )); then
		if [[ -n "$backup_dir" && -d "$backup_dir" && ! -L "$backup_dir" ]]; then
			remove_transaction_path "$TARGET_DIR"
			if /bin/mv "$backup_dir" "$TARGET_DIR"; then
				backup_dir=""
			else
				echo "ERROR: failed to restore prior Headless artifact directory: $backup_dir" >&2
				status=1
			fi
		elif (( target_had_previous == 0 )); then
			remove_transaction_path "$TARGET_DIR"
		fi
	fi

	if [[ -n "$candidate_dir" ]] && path_exists "$candidate_dir"; then
		remove_transaction_path "$candidate_dir"
	fi
	if (( transaction_complete )) && [[ -n "$backup_dir" ]] && path_exists "$backup_dir"; then
		remove_transaction_path "$backup_dir"
	fi
	exit "$status"
}

handle_signal() {
	local name="$1"
	local code="$2"
	echo "ERROR: interrupted by $name; restoring prior Headless artifacts" >&2
	if [[ -n "$active_promotion_pid" ]]; then
		kill -TERM "$active_promotion_pid" 2>/dev/null || true
		wait "$active_promotion_pid" 2>/dev/null || true
		active_promotion_pid=""
	fi
	exit "$code"
}

trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

usage() {
	cat <<EOF
Usage: $0 [debug|release]

Builds, signs, stages, and records provenance for standalone RepoPrompt Headless.
It never packages or launches RepoPrompt.app and never touches repoprompt-mcp.
EOF
}

case "$CONF" in
	debug) CONFIG_LABEL="Debug" ;;
	release) CONFIG_LABEL="Release" ;;
	--help|-h) usage; exit 0 ;;
	*) fail "Unknown configuration '$CONF'. Expected debug or release." ;;
esac

cd "$ROOT_DIR"
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"
: "${MARKETING_VERSION:?missing MARKETING_VERSION}"
: "${BUILD_NUMBER:?missing BUILD_NUMBER}"

python3 - "$ROOT_DIR/Sources/RepoPromptHeadless/HeadlessVersion.swift" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for field, expected in (("marketingVersion", sys.argv[2]), ("buildNumber", sys.argv[3])):
	match = re.search(rf'static let {field} = "([^"]+)"', text)
	if not match or match.group(1) != expected:
		raise SystemExit(f"HeadlessVersion.{field} must be generated from version.env ({expected})")
PY

TARGET_DIR="$HEADLESS_TOOLS_ROOT/$CONFIG_LABEL"
TARGET_BINARY="$TARGET_DIR/$BINARY_NAME"
MANIFEST="$TARGET_DIR/artifact-manifest.json"
run mkdir -p "$HEADLESS_TOOLS_ROOT"
run chmod 700 "$HEADLESS_TOOLS_ROOT"

if path_exists "$TARGET_DIR"; then
	if [[ ! -d "$TARGET_DIR" || -L "$TARGET_DIR" ]]; then
		fail "Refusing to replace non-directory Headless artifact path: $TARGET_DIR"
	fi
	validate_existing_generation
fi

if [[ -n "$PACKAGE_INPUT_BINARY" ]]; then
	BUILT_BINARY="$PACKAGE_INPUT_BINARY"
	if [[ -n "$PACKAGE_EXPECTED_ARCHITECTURES" ]]; then
		EXPECTED_ARCHITECTURES="$PACKAGE_EXPECTED_ARCHITECTURES"
	elif [[ "$CONF" == "release" ]]; then
		EXPECTED_ARCHITECTURES="arm64,x86_64"
	else
		EXPECTED_ARCHITECTURES="$("$LIPO_TOOL" -archs "$BUILT_BINARY" | tr ' ' ',')"
	fi
elif [[ "$CONF" == "release" ]]; then
	BUILT_BINARY="$ROOT_DIR/.build/headless-release/$BINARY_NAME"
	run "$CONTROL_PLANE_SCRIPTS_DIR/build_headless_release_product.sh" "$BUILT_BINARY"
	EXPECTED_ARCHITECTURES="arm64,x86_64"
else
	run "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c debug --product "$BINARY_NAME"
	BUILD_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c debug --show-bin-path)"
	BUILT_BINARY="$BUILD_DIR/$BINARY_NAME"
	EXPECTED_ARCHITECTURES="$("$LIPO_TOOL" -archs "$BUILT_BINARY" | tr ' ' ',')"
fi
[[ -f "$BUILT_BINARY" && ! -L "$BUILT_BINARY" && -x "$BUILT_BINARY" ]] ||
	fail "Missing regular built executable: $BUILT_BINARY"

candidate_dir="$(mktemp -d "$HEADLESS_TOOLS_ROOT/.${CONFIG_LABEL}.candidate.XXXXXX")"
run chmod 700 "$candidate_dir"
CANDIDATE_BINARY="$candidate_dir/$BINARY_NAME"
CANDIDATE_MANIFEST="$candidate_dir/artifact-manifest.json"

run cp "$BUILT_BINARY" "$CANDIDATE_BINARY"
run chmod 700 "$CANDIDATE_BINARY"
run "$CODESIGN_TOOL" --force --sign "$SIGN_IDENTITY" --timestamp=none "$CANDIDATE_BINARY"
run "$CODESIGN_TOOL" --verify --strict --verbose=2 "$CANDIDATE_BINARY"
run "$CANDIDATE_BINARY" --version
run python3 "$TREE_SITTER_SYMBOLS_TOOL" \
	--binary "$CANDIDATE_BINARY" \
	--expect exact \
	--label "Candidate RepoPrompt Headless"

run python3 "$MANIFEST_TOOL" write \
	--binary "$CANDIDATE_BINARY" \
	--artifact-path "$TARGET_BINARY" \
	--output "$CANDIDATE_MANIFEST" \
	--source-root "$ROOT_DIR" \
	--configuration "$CONF" \
	--version "$MARKETING_VERSION" \
	--build "$BUILD_NUMBER" \
	--expected-architectures "$EXPECTED_ARCHITECTURES" \
	--lipo-tool "$LIPO_TOOL"
run python3 "$MANIFEST_TOOL" verify \
	--binary "$CANDIDATE_BINARY" \
	--artifact-path "$TARGET_BINARY" \
	--manifest "$CANDIDATE_MANIFEST" \
	--source-root "$ROOT_DIR" \
	--configuration "$CONF" \
	--version "$MARKETING_VERSION" \
	--build "$BUILD_NUMBER" \
	--expected-architectures "$EXPECTED_ARCHITECTURES" \
	--lipo-tool "$LIPO_TOOL"
run chmod 600 "$CANDIDATE_MANIFEST"

promotion_started=1
if path_exists "$TARGET_DIR"; then
	target_had_previous=1
	reserved_backup="$(mktemp -d "$HEADLESS_TOOLS_ROOT/.${CONFIG_LABEL}.backup.XXXXXX")"
	if ! rmdir "$reserved_backup"; then
		remove_transaction_path "$reserved_backup"
		fail "Unable to reserve Headless backup path: $reserved_backup"
	fi
	backup_dir="$reserved_backup"
	run_promotion "$TARGET_DIR" "$backup_dir"
fi
run_promotion "$candidate_dir" "$TARGET_DIR"
candidate_dir=""

# Verify the promoted pair through the fixed public paths before committing.
run "$CODESIGN_TOOL" --verify --strict --verbose=2 "$TARGET_BINARY"
run "$TARGET_BINARY" --version
run python3 "$TREE_SITTER_SYMBOLS_TOOL" \
	--binary "$TARGET_BINARY" \
	--expect exact \
	--label "Packaged RepoPrompt Headless"
run python3 "$MANIFEST_TOOL" verify \
	--binary "$TARGET_BINARY" \
	--artifact-path "$TARGET_BINARY" \
	--manifest "$MANIFEST" \
	--source-root "$ROOT_DIR" \
	--configuration "$CONF" \
	--version "$MARKETING_VERSION" \
	--build "$BUILD_NUMBER" \
	--expected-architectures "$EXPECTED_ARCHITECTURES" \
	--lipo-tool "$LIPO_TOOL"

transaction_complete=1
if [[ -n "$backup_dir" ]]; then
	remove_transaction_path "$backup_dir" ||
		echo "WARNING: unable to remove verified prior Headless backup: $backup_dir" >&2
	backup_dir=""
fi
printf 'Created standalone headless artifact: %s\nManifest: %s\n' "$TARGET_BINARY" "$MANIFEST"
