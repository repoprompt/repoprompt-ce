#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail "Usage: $0 <source-ref> <checkout-root>"
}

[[ "$#" == "2" ]] || usage

SOURCE_REF="$1"
CHECKOUT_ROOT="$2"

[[ -n "$SOURCE_REF" ]] || fail "source_ref is required"
[[ "$SOURCE_REF" != -* ]] || fail "Signed test build source_ref must not start with '-'"
[[ "$SOURCE_REF" != *$'\n'* && "$SOURCE_REF" != *$'\r'* ]] || fail "Signed test build source_ref must be a single line"
[[ "$SOURCE_REF" != *:* ]] || fail "Signed test builds must use refs from the canonical upstream repository, not fork shorthand refs"
case "$SOURCE_REF" in
    refs/pull/*|pull/*|refs/remotes/*|*/pull/*)
        fail "Signed test builds must use an exact upstream branch, tag, or full SHA, not a pull-request or remote ref"
        ;;
esac

[[ -d "$CHECKOUT_ROOT/.git" ]] || fail "Missing git checkout: $CHECKOUT_ROOT"

checkout_commit="$(git -C "$CHECKOUT_ROOT" rev-parse --verify HEAD^{commit})"
[[ "$checkout_commit" =~ ^[0-9a-f]{40}$ ]] || fail "Resolved checkout commit is not a full SHA: $checkout_commit"

fetch_args=(
    -C "$CHECKOUT_ROOT"
)
server_url="${GITHUB_SERVER_URL:-https://github.com}"
server_url="${server_url%/}/"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    fetch_args+=(
        -c "http.$server_url.extraheader=AUTHORIZATION: bearer $GITHUB_TOKEN"
    )
elif [[ -n "${GH_TOKEN:-}" ]]; then
    fetch_args+=(
        -c "http.$server_url.extraheader=AUTHORIZATION: bearer $GH_TOKEN"
    )
fi
fetch_args+=(
    fetch
    --prune
    --tags
    origin
    '+refs/heads/*:refs/remotes/origin/*'
    '+refs/tags/*:refs/tags/*'
)

git "${fetch_args[@]}"

resolve_commit=""
branch_ref=""
tag_ref=""

resolve_branch() {
    local branch_name="$1"
    [[ -n "$branch_name" ]] || return 1
    git -C "$CHECKOUT_ROOT" check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1 || return 1
    git -C "$CHECKOUT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch_name" || return 1
    git -C "$CHECKOUT_ROOT" rev-parse --verify "refs/remotes/origin/$branch_name^{commit}"
}

resolve_tag() {
    local tag_name="$1"
    [[ -n "$tag_name" ]] || return 1
    git -C "$CHECKOUT_ROOT" check-ref-format "refs/tags/$tag_name" >/dev/null 2>&1 || return 1
    git -C "$CHECKOUT_ROOT" show-ref --verify --quiet "refs/tags/$tag_name" || return 1
    git -C "$CHECKOUT_ROOT" rev-parse --verify "refs/tags/$tag_name^{commit}"
}

if [[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
    resolve_commit="$(git -C "$CHECKOUT_ROOT" rev-parse --verify "$SOURCE_REF^{commit}")" || \
        fail "Signed test build SHA is not a commit: $SOURCE_REF"
elif [[ "$SOURCE_REF" == refs/heads/* ]]; then
    branch_name="${SOURCE_REF#refs/heads/}"
    resolve_commit="$(resolve_branch "$branch_name")" || \
        fail "Signed test build source_ref is not an exact upstream branch: $SOURCE_REF"
elif [[ "$SOURCE_REF" == refs/tags/* ]]; then
    tag_name="${SOURCE_REF#refs/tags/}"
    resolve_commit="$(resolve_tag "$tag_name")" || \
        fail "Signed test build source_ref is not an exact upstream tag: $SOURCE_REF"
elif [[ "$SOURCE_REF" == refs/* ]]; then
    fail "Signed test builds must use refs/heads/<branch>, refs/tags/<tag>, a short upstream branch or tag, or a full SHA"
else
    branch_commit=""
    tag_commit=""
    if branch_commit="$(resolve_branch "$SOURCE_REF")"; then
        branch_ref="refs/remotes/origin/$SOURCE_REF"
    fi
    if tag_commit="$(resolve_tag "$SOURCE_REF")"; then
        tag_ref="refs/tags/$SOURCE_REF"
    fi

    if [[ -n "$branch_commit" && -n "$tag_commit" ]]; then
        fail "Signed test build source_ref is ambiguous; use refs/heads/$SOURCE_REF or refs/tags/$SOURCE_REF"
    elif [[ -n "$branch_commit" ]]; then
        resolve_commit="$branch_commit"
    elif [[ -n "$tag_commit" ]]; then
        resolve_commit="$tag_commit"
    else
        fail "Signed test build source_ref must be an exact upstream branch, exact upstream tag, or full 40-hex SHA: $SOURCE_REF"
    fi
fi

[[ "$resolve_commit" =~ ^[0-9a-f]{40}$ ]] || fail "Resolved source_ref is not a full SHA: $resolve_commit"
[[ "$resolve_commit" == "$checkout_commit" ]] || \
    fail "Signed test build source_ref resolves to $resolve_commit, but checkout HEAD is $checkout_commit"

containing_refs=()
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
        refs/remotes/origin/HEAD|refs/remotes/origin/pull/*) continue ;;
    esac
    containing_refs+=("$ref")
done < <(
    git -C "$CHECKOUT_ROOT" for-each-ref \
        --format='%(refname)' \
        --contains "$resolve_commit" \
        refs/remotes/origin refs/tags | \
    sort
)

[[ "${#containing_refs[@]}" -gt 0 ]] || \
    fail "Signed test build commit $resolve_commit is not reachable from any upstream branch or tag in the canonical repository"

reachable_refs="$(IFS=,; printf '%s' "${containing_refs[*]}")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'commit=%s\n' "$resolve_commit"
        printf 'reachable_refs=%s\n' "$reachable_refs"
    } >> "$GITHUB_OUTPUT"
fi

printf '%s\n' "$resolve_commit"
