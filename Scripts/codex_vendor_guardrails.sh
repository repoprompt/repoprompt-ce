#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

python3 Scripts/codex_runtime_artifact.py validate-manifest

python3 Scripts/validate_codex_update_workflow.py
grep -F 'python3 Scripts/test_codex_update_candidate.py' Makefile >/dev/null ||
    fail "release-selftest must cover guarded Codex update candidates"
grep -F 'python3 Scripts/test_codex_update_workflow.py' Makefile >/dev/null ||
    fail "release-selftest must cover the structured Codex candidate workflow contract"
grep -F 'Scripts/codex_update_candidate.py' docs/releasing.md >/dev/null ||
    fail "docs/releasing.md is missing the guarded Codex update flow"

for path in \
    ThirdPartyLicenses/codex/LICENSE \
    ThirdPartyLicenses/codex/NOTICE \
    ThirdPartyLicenses/codex/README.md \
    ThirdPartyLicenses/codex/ZSH-LICENCE \
    ThirdPartyLicenses/codex/SHA256SUMS; do
    [[ -f "$path" ]] || fail "Missing Codex legal inventory file: $path"
done

(
    cd ThirdPartyLicenses/codex
    unexpected_directory="$(find . -mindepth 1 -type d -print -quit)"
    [[ -z "$unexpected_directory" ]] ||
        fail "Codex legal inventory must remain flat; unexpected directory: $unexpected_directory"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
        sed 's#^./##' | sort > "$TMP_DIR/legal-files"
    awk '{ print $2 }' SHA256SUMS | sort > "$TMP_DIR/legal-sums"
    diff -u "$TMP_DIR/legal-files" "$TMP_DIR/legal-sums" ||
        fail "Codex legal checksum inventory is incomplete"
    shasum -a 256 -c SHA256SUMS
)

grep -F "## OpenAI Codex" THIRD_PARTY_NOTICES.md >/dev/null ||
    fail "THIRD_PARTY_NOTICES.md is missing the OpenAI Codex section"
grep -F "codex-resources/zsh/bin/zsh" THIRD_PARTY_NOTICES.md >/dev/null ||
    fail "THIRD_PARTY_NOTICES.md is missing the bundled Zsh notice"
grep -F "rust-v0.149.0" docs/releasing.md >/dev/null ||
    fail "docs/releasing.md is missing the pinned Codex release"
grep -F 'Contents/Resources/BundledRuntimes/Codex/<target>/' docs/releasing.md >/dev/null ||
    fail "docs/releasing.md is missing the target-specific bundled Codex layout"
grep -F 'CODEX_BUNDLE_ARCH="all"' Scripts/package_app.sh >/dev/null ||
    fail "public packaging must select all pinned Codex targets"
grep -F 'stage-bundle' Scripts/package_app.sh >/dev/null ||
    fail "packaging must use the authoritative Codex bundle staging helper"
for script in \
    Scripts/main_tip_release.sh \
    Scripts/promote_release.sh \
    Scripts/publish_public_update_test.sh \
    Scripts/release.sh \
    Scripts/sign_staged_release.sh \
    Scripts/validate_staged_release.sh; do
    grep -F 'verify-bundle' "$script" >/dev/null ||
        fail "$script must verify the target-specific Codex bundle contract"
    grep -F -- '--arch all' "$script" >/dev/null ||
        fail "$script must require both pinned Codex targets"
    if grep -F -- '--arch aarch64-apple-darwin' "$script" >/dev/null; then
        fail "$script must not validate only the arm64 Codex package"
    fi
done

grep -F 'list-bundle-signing-plan --arch all' Scripts/sign_staged_release.sh >/dev/null ||
    fail "Developer ID signing must enumerate every manifest-owned Codex Mach-O with its entitlement profile"
grep -F 'sign_path "$CODEX_BUNDLE/$relative_path"' Scripts/sign_staged_release.sh >/dev/null ||
    fail "Developer ID signing must sign each enumerated Codex Mach-O at its final bundle path"
grep -F 'sign_path "$CODEX_BUNDLE/$relative_path" --entitlements "$CODEX_V8_ENTITLEMENTS"' Scripts/sign_staged_release.sh >/dev/null ||
    fail "Developer ID signing must apply the trusted V8 JIT entitlement allowlist to profiled Codex executables"
grep -F 'CODEX_V8_ENTITLEMENTS="$TRUSTED_ROOT/AppBundle/CodexV8JIT.entitlements"' Scripts/sign_staged_release.sh >/dev/null ||
    fail "Developer ID signing must source the Codex V8 entitlement allowlist from the trusted control plane"
if grep -F 'sign_path "$CODEX_BUNDLE' Scripts/sign_staged_release.sh | grep -F -- '--preserve-metadata' >/dev/null; then
    fail "Codex signing must use the explicit entitlement allowlist, never vendor entitlement preservation"
fi
python3 - <<'PYTHON' || fail "Codex release entitlement policy drifted from the trusted closed-world profile"
import json
import plistlib
import sys
from pathlib import Path

V8_PROFILE = {
    "com.apple.security.cs.allow-jit": True,
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
}
EXPECTED_RELEASE_PROFILES = {
    "bin/codex": V8_PROFILE,
    "bin/codex-code-mode-host": V8_PROFILE,
    "codex-path/rg": {},
    "codex-resources/zsh/bin/zsh": {},
}
manifest = json.loads(Path("Vendor/Codex/manifest.json").read_text(encoding="utf-8"))
if manifest.get("schemaVersion") != 2:
    sys.exit("pinned Codex manifest must use entitlement-aware schema version 2")
if manifest.get("releaseSigningEntitlements") != EXPECTED_RELEASE_PROFILES:
    sys.exit("pinned release-signing entitlement profiles must grant V8 JIT to exactly bin/codex and bin/codex-code-mode-host")
for policy in manifest.get("signedExecutables", []):
    if policy.get("entitlements") != V8_PROFILE:
        sys.exit(f"vendor signature policy for {policy.get('path')} must pin exactly the two approved V8 entitlements")
plist = plistlib.loads(Path("AppBundle/CodexV8JIT.entitlements").read_bytes())
if plist != V8_PROFILE:
    sys.exit("AppBundle/CodexV8JIT.entitlements must contain exactly the two approved V8 entitlements")
PYTHON
for script in \
    Scripts/main_tip_release.sh \
    Scripts/promote_release.sh \
    Scripts/publish_public_update_test.sh \
    Scripts/release.sh \
    Scripts/sign_staged_release.sh; do
    grep -F -- '--signed-team-identifier' "$script" >/dev/null ||
        fail "$script must verify final Codex Mach-Os against the RepoPrompt Developer ID team"
done

printf 'OK: pinned Codex artifact, universal bundle, and legal inventory contracts are complete.\n'
