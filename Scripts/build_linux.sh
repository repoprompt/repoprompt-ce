#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf '%s\n' 'This entrypoint builds the Linux headless product on a Linux host.' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  printf '%s\n' 'Usage: Scripts/build_linux.sh [debug|release] [conductor swift-build options]' >&2
  exit 2
fi
for tool in swift python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required tool missing: %s. See docs/linux.md.\n' "$tool" >&2
    exit 1
  fi
done

cd -- "$repo_root"
export REPOPROMPT_DEV_BUILD_CACHE_DISABLE=1
static_swift="${REPOPROMPT_LINUX_STATIC_SWIFT:-1}"
if [[ "$static_swift" != 0 && "$static_swift" != 1 ]]; then
  printf '%s\n' 'REPOPROMPT_LINUX_STATIC_SWIFT must be 0 or 1.' >&2
  exit 2
fi
build_options=(--product repoprompt-mcp --configuration "$configuration" --jobs "${SWIFT_JOBS:-4}")
if [[ "$configuration" == release && "$static_swift" == 1 ]]; then
  build_options+=(--static-swift-stdlib)
fi
exec ./conductor swift-build "${build_options[@]}" "$@"
