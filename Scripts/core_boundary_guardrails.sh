#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_ROOT="Sources/RepoPromptCore"
MACOS_ROOT="Sources/RepoPromptCoreMacOS"
POSIX_ROOT="Sources/RepoPromptPOSIXSupport"
SHARED_ROOT="Sources/RepoPromptShared"
SYNTAX_BRIDGE_ROOT="Sources/RepoPromptSyntaxCBridge"
failures=0

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

report_matches() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output status

  set +e
  output="$(grep -n -E -- "$pattern" "$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    fail "$label"
    printf '%s\n' "$output" >&2
  elif [[ "$status" -ne 1 ]]; then
    printf 'ERROR: core boundary grep failed while checking: %s\n' "$label" >&2
    printf '%s\n' "$output" >&2
    exit "$status"
  fi
}

swift_files_under() {
  find "$1" -type f -name '*.swift' -print | sort
}

for required_root in "$CORE_ROOT" "$MACOS_ROOT" "$POSIX_ROOT" "$SHARED_ROOT" "$SYNTAX_BRIDGE_ROOT"; do
  if [[ ! -d "$required_root" ]]; then
    fail "required boundary source root missing: $required_root"
  fi
done

shared_swift_files=()
while IFS= read -r file; do
  shared_swift_files+=("$file")
done < <(swift_files_under "$SHARED_ROOT")
if [[ "${#shared_swift_files[@]}" -eq 0 ]]; then
  fail "$SHARED_ROOT contains no Swift files"
else
  shared_non_foundation_imports="$(grep -n -E '^[[:space:]]*import[[:space:]]+' "${shared_swift_files[@]}" | grep -v -E 'import[[:space:]]+Foundation$' || true)"
  if [[ -n "$shared_non_foundation_imports" ]]; then
    fail "$SHARED_ROOT must be Foundation-only"
    printf '%s\n' "$shared_non_foundation_imports" >&2
  fi
  report_matches \
    "POSIX descriptor/socket ownership leaked back into $SHARED_ROOT" \
    'POSIXDescriptor|fcntl|FD_CLOEXEC|SHUT_RDWR|sockaddr|Darwin|Glibc|SystemPackage' \
    "${shared_swift_files[@]}"
fi

core_swift_files=()
while IFS= read -r file; do
  core_swift_files+=("$file")
done < <(swift_files_under "$CORE_ROOT")
if [[ "${#core_swift_files[@]}" -eq 0 ]]; then
  fail "$CORE_ROOT contains no Swift files"
else
  report_matches \
    "forbidden Apple UI/native import found under $CORE_ROOT" \
    '^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(AppKit|SwiftUI|Cocoa|Sparkle|KeyboardShortcuts|CoreServices|Security|Darwin|Glibc|SystemPackage|OSLog|os|RepoPromptShared|RepoPromptPOSIXSupport|RepoPromptCoreMacOS)([.]|[[:space:]]|$)' \
    "${core_swift_files[@]}"
  report_matches \
    "app-owned runtime or embedded-policy reference found under $CORE_ROOT" \
    '(^|[^[:alnum:]_])(WindowState|WindowStatesManager|NSApplication|NSWorkspace|SecureKeyValueStorageFactory|MacOSFSEventsWatcherFactory)([^[:alnum:]_]|$)|Bundle[.]main|UserDefaults[.]standard|applicationSupportDirectory' \
    "${core_swift_files[@]}"
  report_matches \
    "Darwin-backed descriptor/socket type leaked into Core contracts" \
    'POSIXDescriptorConfigurationError|connectedFileDescriptor|sockaddr|FileDescriptor|Darwin[.]|Glibc[.]' \
    "${core_swift_files[@]}"
fi

if [[ ! -f "$POSIX_ROOT/Descriptors/POSIXDescriptorSupport.swift" ]]; then
  fail "POSIX descriptor support must be single-sourced under $POSIX_ROOT/Descriptors"
fi

report_matches \
  "app packaging mentions a standalone headless command; keep headless independently packaged" \
  'repoprompt-headless|rpce-headless' \
  Scripts/package_app.sh

if [[ "$failures" -ne 0 ]]; then
  printf 'Core boundary guardrails failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
  exit 1
fi

printf 'OK: enforced Core/Shared/POSIX boundary guardrails passed.\n'
