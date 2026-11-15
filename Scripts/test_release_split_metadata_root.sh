#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGED_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGED_ROOT"' EXIT

cp "$REPO_ROOT/version.env" "$STAGED_ROOT/version.env"
# This regression exercises build metadata routing, not the currently activated
# release role. Keep a real legacy declaration in an independent approved root.
APPROVED_ROOT="$STAGED_ROOT/approved-source"
mkdir "$APPROVED_ROOT"
cat > "$APPROVED_ROOT/release-rollout.json" <<'JSON'
{
  "schemaVersion": 1,
  "channel": "stable",
  "currentRole": "legacy",
  "eligibilityProfile": "stable-rollout-v1",
  "expectedMigrationPhase": "disabled",
  "expectedSigningIdentity": "legacy",
  "predecessors": []
}
JSON

REPOPROMPT_RELEASE_SOURCE_ROOT="$STAGED_ROOT" \
REPOPROMPT_APPROVED_SOURCE_ROOT="$APPROVED_ROOT" \
REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$SCRIPT_DIR" \
    bash -c '
        source "$REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR/release.sh"
        expected="$REPOPROMPT_APPROVED_SOURCE_ROOT/release-rollout.json"
        [[ "$ROLLOUT_DECLARATION" == "$expected" ]] || {
            printf "ERROR: expected rollout declaration %s, got %s\n" \
                "$expected" "$ROLLOUT_DECLARATION" >&2
            exit 1
        }
        require_dormant_rollout_declaration
    '

printf 'OK: split-root release metadata resolves from the approved source.\n'
