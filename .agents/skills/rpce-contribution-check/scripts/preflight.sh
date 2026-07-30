#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 [commit|push|pr-ready]" >&2; }

if (( $# > 1 )); then
  usage
  exit 2
fi

mode="${1:-commit}"
case "$mode" in
  commit|push|pr-ready) ;;
  *)
    usage
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

tmp_root=""
timing_helper="$repo_root/.agents/skills/rpce-contribution-check/scripts/preflight_timing.py"
timing_artifact_dir="$repo_root/.build/validation-artifacts/pr-ready"
timing_receipt_prefix=".build/validation-artifacts/pr-ready"
timing_state=""
timing_enabled=0
timing_broken=0

warn_timing() {
  printf 'WARNING: PR-ready timing receipt unavailable; validation result is unchanged.\n' >&2
}

disable_timing() {
  if (( timing_enabled )); then
    timing_enabled=0
    timing_broken=1
    warn_timing
  fi
}

timing_init() {
  local head_commit
  [[ "$mode" == "pr-ready" ]] || return 0
  head_commit="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  if timing_state="$(python3 "$timing_helper" start \
    --artifact-dir "$timing_artifact_dir" --head-commit "$head_commit" 2>/dev/null)"; then
    timing_enabled=1
  else
    timing_state=""
    timing_broken=1
    warn_timing
  fi
}

timing_phase_start() {
  (( timing_enabled )) || return 0
  if ! python3 "$timing_helper" phase-start --state "$timing_state" --phase "$1" \
    >/dev/null 2>&1; then
    disable_timing
  fi
  return 0
}

timing_phase_pass() {
  (( timing_enabled )) || return 0
  if ! python3 "$timing_helper" phase-pass --state "$timing_state" --phase "$1" \
    >/dev/null 2>&1; then
    disable_timing
  fi
  return 0
}

timing_record_provenance() {
  (( timing_enabled )) || return 0
  if ! python3 "$timing_helper" provenance --state "$timing_state" \
    --base-kind "$1" --outgoing-count "$2" >/dev/null 2>&1; then
    disable_timing
  fi
  return 0
}

timing_record_selection() {
  local changed_path_count="$1"
  shift
  local args=(selection --state "$timing_state" --changed-path-count "$changed_path_count")
  local lane_id
  (( timing_enabled )) || return 0
  for lane_id in "$@"; do
    args+=(--lane-id "$lane_id")
  done
  if ! python3 "$timing_helper" "${args[@]}" >/dev/null 2>&1; then
    disable_timing
  fi
  return 0
}

finalize() {
  local original_exit_code=$?
  local receipt_name=""
  local receipt_status=0
  set +e
  trap - EXIT HUP INT TERM

  if [[ "$mode" == "pr-ready" && -n "${timing_state:-}" ]]; then
    if (( timing_enabled )) && (( ! timing_broken )); then
      receipt_name="$(python3 "$timing_helper" finish --state "$timing_state" \
        --exit-code "$original_exit_code" 2>/dev/null)"
      receipt_status=$?
      if (( receipt_status == 0 )) && [[ -n "$receipt_name" ]]; then
        printf '\nPR-ready timing receipt: %s/%s\n' "$timing_receipt_prefix" "$receipt_name"
      else
        warn_timing
      fi
    else
      python3 "$timing_helper" discard --state "$timing_state" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "${tmp_root:-}" ]]; then
    rm -rf -- "$tmp_root"
  fi
  exit "$original_exit_code"
}

trap finalize EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool '$1'. Install it before committing or pushing."
}

ensure_tmp_root() {
  if [[ -z "$tmp_root" ]]; then
    tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rpce-preflight.XXXXXX")"
  fi
}

scan_staged_index_blobs() {
  local files snapshot
  ensure_tmp_root
  files="$tmp_root/staged-files.z"
  snapshot="$tmp_root/staged-index"
  git diff --cached --name-only --diff-filter=d -z -- > "$files"
  if [[ ! -s "$files" ]]; then
    echo "No non-deleted staged index blobs to scan."
    return
  fi
  mkdir -p "$snapshot"
  git checkout-index --stdin -z --prefix="$snapshot/" < "$files"
  gitleaks dir --no-banner --redact "$snapshot"
}

require_clean_worktree() {
  local status_file
  ensure_tmp_root
  status_file="$tmp_root/status.z"
  git status --porcelain=v1 -z --untracked-files=all > "$status_file"
  if [[ -s "$status_file" ]]; then
    git status --short
    fail "working tree is not clean; commit, stash, or discard changes before pushing"
  fi
}

resolve_outgoing_base() {
  current_branch="$(git symbolic-ref --quiet --short HEAD)" \
    || fail "push mode requires a current branch; detached HEAD is not supported"
  if upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    && git rev-parse --verify --quiet "${upstream_ref}^{commit}" >/dev/null; then
    base_ref="$upstream_ref"
    base_reason="configured upstream"
    base_kind="configured_upstream"
  elif [[ "$current_branch" != "main" ]] \
    && git rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null; then
    base_ref="refs/remotes/origin/main"
    base_reason="origin/main fallback for a current branch without configured upstream"
    base_kind="origin_main_fallback"
  else
    fail "cannot determine outgoing base for '$current_branch'; configure its upstream or fetch origin/main for a non-main topic branch"
  fi
  range_spec="$base_ref..HEAD"
}

write_range_files() {
  local output="$1"
  git diff --name-only -z "$base_ref"...HEAD -- > "$output"
}

run_pr_ready_path_validations() {
  local files
  ensure_tmp_root
  files="$tmp_root/range-files.z"
  write_range_files "$files"

  local control_plane_paths_pattern='^(Scripts/conductor\.py|Scripts/conductor_diagnostics\.py|Scripts/guardrails\.sh|Scripts/test_conductor_(lifecycle|output|diagnostics|high_output)\.py|Scripts/test_contribution_preflight\.py|\.agents/skills/rpce-contribution-check/scripts/preflight(_timing\.py|\.sh)|Makefile)$'
  local ci_app_test_runner_paths_pattern='^(Scripts/ci_app_test_runner\.py|Scripts/test_ci_app_test_runner\.py|\.github/workflows/ci\.yml)$'
  local swift_paths_pattern='\.swift$'
  local root_test_paths_pattern='^(Sources/RepoPrompt/|Tests/RepoPrompt[^/]*Tests/)'
  local provider_package_paths_pattern='^Packages/RepoPromptAgentProviders/'
  local repoprompt_product_paths_pattern='^Sources/RepoPrompt/'
  local mcp_product_paths_pattern='^(Sources/RepoPromptMCP/|Sources/RepoPromptShared/)'
  local xcode_full_validation_paths_pattern='^(Package\.swift|Package\.resolved|Makefile|Scripts/generate_xcode_workspace\.py|Scripts/xcode_developer_workflow\.sh|\.github/workflows/xcode-workspace\.yml)$'
  local xcode_generator_test_paths_pattern='^(Package\.swift|Package\.resolved|Makefile|Scripts/generate_xcode_workspace\.py|Scripts/xcode_developer_workflow\.sh|Scripts/test_xcode_workspace_generator\.py|\.github/workflows/xcode-workspace\.yml)$'

  local has_control_plane_changes=0
  local has_ci_app_test_runner_changes=0
  local has_swift_changes=0
  local has_root_test_changes=0
  local has_provider_package_changes=0
  local has_repoprompt_product_changes=0
  local has_mcp_product_changes=0
  local has_xcode_generator_test_changes=0
  local has_xcode_full_validation_changes=0
  local changed_path_count=0
  local file

  while IFS= read -r -d '' file; do
    changed_path_count=$((changed_path_count + 1))
    [[ "$file" =~ $control_plane_paths_pattern ]] && has_control_plane_changes=1
    [[ "$file" =~ $ci_app_test_runner_paths_pattern ]] && has_ci_app_test_runner_changes=1
    [[ "$file" =~ $swift_paths_pattern ]] && has_swift_changes=1
    [[ "$file" =~ $root_test_paths_pattern ]] && has_root_test_changes=1
    [[ "$file" =~ $provider_package_paths_pattern ]] && has_provider_package_changes=1
    [[ "$file" =~ $repoprompt_product_paths_pattern ]] && has_repoprompt_product_changes=1
    [[ "$file" =~ $mcp_product_paths_pattern ]] && has_mcp_product_changes=1
    [[ "$file" =~ $xcode_generator_test_paths_pattern ]] && has_xcode_generator_test_changes=1
    [[ "$file" =~ $xcode_full_validation_paths_pattern ]] && has_xcode_full_validation_changes=1
  done < "$files"

  local selected_lane_ids=()
  (( has_control_plane_changes )) && selected_lane_ids+=(conductor_selftests)
  (( has_ci_app_test_runner_changes )) && selected_lane_ids+=(ci_app_test_runner_selftests)
  (( has_swift_changes )) && selected_lane_ids+=(swift_lint)
  (( has_root_test_changes )) && selected_lane_ids+=(root_tests)
  (( has_provider_package_changes )) && selected_lane_ids+=(provider_tests)
  (( has_repoprompt_product_changes )) && selected_lane_ids+=(repoprompt_build)
  (( has_mcp_product_changes )) && selected_lane_ids+=(mcp_build)
  (( has_xcode_generator_test_changes )) && selected_lane_ids+=(xcode_generator_tests)
  (( has_xcode_full_validation_changes )) && selected_lane_ids+=(xcode_workspace_validation)
  if (( ${#selected_lane_ids[@]} )); then
    timing_record_selection "$changed_path_count" "${selected_lane_ids[@]}"
  else
    timing_record_selection "$changed_path_count"
  fi
  timing_phase_pass path_selection

  if (( has_control_plane_changes )); then
    timing_phase_start conductor_selftests
    log "Run conductor self-tests"
    make conductor-selftest
    timing_phase_pass conductor_selftests
  fi
  if (( has_ci_app_test_runner_changes )); then
    timing_phase_start ci_app_test_runner_selftests
    log "Run CI app-test runner self-tests"
    make ci-app-test-runner-selftest
    timing_phase_pass ci_app_test_runner_selftests
  fi
  if (( has_swift_changes )); then
    timing_phase_start swift_lint
    log "Run coordinated Swift lint"
    make dev-lint
    timing_phase_pass swift_lint
  fi
  if (( has_root_test_changes )); then
    timing_phase_start root_tests
    log "Run coordinated root tests"
    make dev-test
    timing_phase_pass root_tests
  fi
  if (( has_provider_package_changes )); then
    timing_phase_start provider_tests
    log "Run coordinated provider tests"
    make dev-provider-test
    timing_phase_pass provider_tests
  fi
  if (( has_repoprompt_product_changes )); then
    timing_phase_start repoprompt_build
    log "Build RepoPrompt product"
    make dev-swift-build PRODUCT=RepoPrompt
    timing_phase_pass repoprompt_build
  fi
  if (( has_mcp_product_changes )); then
    timing_phase_start mcp_build
    log "Build repoprompt-mcp product"
    make dev-swift-build PRODUCT=repoprompt-mcp
    timing_phase_pass mcp_build
  fi
  if (( has_xcode_generator_test_changes )); then
    timing_phase_start xcode_generator_tests
    log "Run Xcode workspace generator tests"
    make xcode-generator-test
    timing_phase_pass xcode_generator_tests
  fi
  if (( has_xcode_full_validation_changes )); then
    timing_phase_start xcode_workspace_validation
    log "Validate generated Xcode workspace"
    make xcode-validate
    timing_phase_pass xcode_workspace_validation
  fi
}

push_success() {
  cat <<'EOF'

Default push safety preflight passed.
Heavyweight lint/test/build lanes were not run. Run `.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready` for the full/PR-ready path-selected local lane.
Release candidate validation remains `make dev-release-preflight` / `make dev-release-artifact`.
Push mode validated only the current branch against the computed range above. It does not validate tags, `--all`, `--mirror`, or arbitrary refspecs.
EOF
}

pr_ready_success() {
  cat <<'EOF'

PR-ready preflight passed.
This included ordinary push safety checks and ran any matching path-selected heavyweight lanes for the computed outgoing range.
Release validation, live smoke, destructive-operation approval, and any specialized matrix evidence may still require explicit commands for the changed boundary.
EOF
}

timing_init

require_tool git
require_tool gitleaks

timing_phase_start whitespace_checks
log "Check whitespace"
git diff --check
git diff --cached --check
timing_phase_pass whitespace_checks

timing_phase_start staged_index_secret_scan
log "Scan staged index blobs for secrets"
scan_staged_index_blobs
timing_phase_pass staged_index_secret_scan

timing_phase_start repository_guardrails
log "Run repository guardrails"
make guardrails
timing_phase_pass repository_guardrails

if [[ "$mode" == "commit" ]]; then
  cat <<'EOF'

Commit preflight passed.
Before committing, review `git status --short`, `git diff --cached --stat`, and `git diff --cached`.
Rerun commit preflight after any staging change. Use `push` mode before pushing committed work.
EOF
  exit 0
fi

timing_phase_start clean_worktree_check
log "Require a clean working tree before push"
require_clean_worktree
timing_phase_pass clean_worktree_check

timing_phase_start outgoing_range_resolution
resolve_outgoing_base
log "Review current-branch outgoing range"
printf 'Current branch: %s\nComparison base (%s): %s\nComputed outgoing range: %s\n' \
  "$current_branch" "$base_reason" "$base_ref" "$range_spec"
git log --oneline "$range_spec"

outgoing_count="$(git rev-list --count "$range_spec")"
timing_record_provenance "$base_kind" "$outgoing_count"
timing_phase_pass outgoing_range_resolution
if [[ "$outgoing_count" == "0" ]]; then
  echo "No outgoing commits in $range_spec."
  if [[ "$mode" == "pr-ready" ]]; then
    pr_ready_success
  else
    push_success
  fi
  exit 0
fi

timing_phase_start outgoing_range_secret_scan
log "Scan outgoing commit range for secrets"
gitleaks git --no-banner --redact --log-opts="$range_spec" .
timing_phase_pass outgoing_range_secret_scan

if [[ "$mode" == "push" ]]; then
  push_success
  exit 0
fi

timing_phase_start path_selection
run_pr_ready_path_validations
pr_ready_success
