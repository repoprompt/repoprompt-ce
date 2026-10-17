#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# OverseerPermissionPolicy is the single owner of the full-access versus restricted delegation
# decision. Production code must ask it instead of reading the setting inputs directly.
policy_owner="Sources/RepoPrompt/Features/AgentMode/Runtime/Delegation/OverseerPermissionPolicy.swift"
setting_input="Sources/RepoPrompt/Features/AgentMode/Runtime/Delegation/DelegationScopeRuntime.swift"

status=0

stored_reads="$(grep -R -n --include='*.swift' -F 'OverseerGlobalAutoApprove.isEnabled()' Sources | grep -v -F "$setting_input:" || true)"
if [[ -n "$stored_reads" ]]; then
  echo "$stored_reads" >&2
  echo "error: read Overseer full access through OverseerPermissionPolicy, not OverseerGlobalAutoApprove.isEnabled()" >&2
  status=1
fi

input_reads="$(grep -R -n --include='*.swift' -E 'isGlobalAutoApproveEnabled\(\)' Sources | grep -v -F "$policy_owner:" || true)"
if [[ -n "$input_reads" ]]; then
  echo "$input_reads" >&2
  echo "error: only OverseerPermissionPolicy may evaluate DelegationScopeRuntime.isGlobalAutoApproveEnabled()" >&2
  status=1
fi

exit "$status"
