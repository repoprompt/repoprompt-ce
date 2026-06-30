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
cleanup() {
  if [[ -n "${tmp_root:-}" ]]; then
    rm -rf -- "$tmp_root"
  fi
}
trap cleanup EXIT
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
  elif [[ "$current_branch" != "main" ]] \
    && git rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null; then
    base_ref="refs/remotes/origin/main"
    base_reason="origin/main fallback for a current branch without configured upstream"
  else
    fail "cannot determine outgoing base for '$current_branch'; configure its upstream or fetch origin/main for a non-main topic branch"
  fi
  range_spec="$base_ref..HEAD"
}

write_range_files() {
  local output="$1"
  git diff --name-only -z "$base_ref"...HEAD -- > "$output"
}

range_contains() {
  local files="$1"
  local pattern="$2"
  local file
  while IFS= read -r -d '' file; do
    if [[ "$file" =~ $pattern ]]; then
      return 0
    fi
  done < "$files"
  return 1
}

run_pr_ready_validation_if_range_contains() {
  local files="$1"
  local pattern="$2"
  local label="$3"
  shift 3
  if range_contains "$files" "$pattern"; then
    log "$label"
    "$@"
  fi
}

run_pr_ready_path_validations() {
  local files
  ensure_tmp_root
  files="$tmp_root/range-files.z"
  write_range_files "$files"

  local control_plane_paths_pattern='^(Scripts/conductor\.py|Scripts/test_conductor_(lifecycle|output)\.py|Scripts/test_contribution_preflight\.py|\.agents/skills/rpce-contribution-check/scripts/preflight\.sh|Makefile)$'
  local ci_app_test_runner_paths_pattern='^(Scripts/ci_app_test_runner\.py|Scripts/test_ci_app_test_runner\.py|\.github/workflows/ci\.yml)$'
  local swift_paths_pattern='\.swift$'
  local root_test_paths_pattern='^(Sources/RepoPrompt/|Tests/RepoPromptTests/)'
  local provider_package_paths_pattern='^Packages/RepoPromptAgentProviders/'
  local repoprompt_product_paths_pattern='^Sources/RepoPrompt/'
  local mcp_product_paths_pattern='^(Sources/RepoPromptMCP/|Sources/RepoPromptShared/)'
  local xcode_full_validation_paths_pattern='^(Package\.swift|Package\.resolved|Makefile|Scripts/generate_xcode_workspace\.py|Scripts/xcode_developer_workflow\.sh|\.github/workflows/xcode-workspace\.yml)$'
  local xcode_generator_test_paths_pattern='^(Package\.swift|Package\.resolved|Makefile|Scripts/generate_xcode_workspace\.py|Scripts/xcode_developer_workflow\.sh|Scripts/test_xcode_workspace_generator\.py|\.github/workflows/xcode-workspace\.yml)$'

  run_pr_ready_validation_if_range_contains "$files" "$control_plane_paths_pattern" "Run conductor self-tests" \
    make conductor-selftest
  run_pr_ready_validation_if_range_contains "$files" "$ci_app_test_runner_paths_pattern" "Run CI app-test runner self-tests" \
    make ci-app-test-runner-selftest
  run_pr_ready_validation_if_range_contains "$files" "$swift_paths_pattern" "Run coordinated Swift lint" \
    make dev-lint
  run_pr_ready_validation_if_range_contains "$files" "$root_test_paths_pattern" "Run coordinated root tests" \
    make dev-test
  run_pr_ready_validation_if_range_contains "$files" "$provider_package_paths_pattern" "Run coordinated provider tests" \
    make dev-provider-test
  run_pr_ready_validation_if_range_contains "$files" "$repoprompt_product_paths_pattern" "Build RepoPrompt product" \
    make dev-swift-build PRODUCT=RepoPrompt
  run_pr_ready_validation_if_range_contains "$files" "$mcp_product_paths_pattern" "Build repoprompt-mcp product" \
    make dev-swift-build PRODUCT=repoprompt-mcp
  run_pr_ready_validation_if_range_contains "$files" "$xcode_generator_test_paths_pattern" "Run Xcode workspace generator tests" \
    make xcode-generator-test
  run_pr_ready_validation_if_range_contains "$files" "$xcode_full_validation_paths_pattern" "Validate generated Xcode workspace" \
    make xcode-validate
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

require_tool git
require_tool gitleaks

log "Check whitespace"
git diff --check
git diff --cached --check

log "Scan staged index blobs for secrets"
scan_staged_index_blobs

log "Run repository guardrails"
make guardrails

if [[ "$mode" == "commit" ]]; then
  cat <<'EOF'

Commit preflight passed.
Before committing, review `git status --short`, `git diff --cached --stat`, and `git diff --cached`.
Rerun commit preflight after any staging change. Use `push` mode before pushing committed work.
EOF
  exit 0
fi

log "Require a clean working tree before push"
require_clean_worktree

resolve_outgoing_base
log "Review current-branch outgoing range"
printf 'Current branch: %s\nComparison base (%s): %s\nComputed outgoing range: %s\n' \
  "$current_branch" "$base_reason" "$base_ref" "$range_spec"
git log --oneline "$range_spec"

outgoing_count="$(git rev-list --count "$range_spec")"
if [[ "$outgoing_count" == "0" ]]; then
  echo "No outgoing commits in $range_spec."
  if [[ "$mode" == "pr-ready" ]]; then
    pr_ready_success
  else
    push_success
  fi
  exit 0
fi

log "Scan outgoing commit range for secrets"
gitleaks git --no-banner --redact --log-opts="$range_spec" .

if [[ "$mode" == "push" ]]; then
  push_success
  exit 0
fi

run_pr_ready_path_validations
pr_ready_success
