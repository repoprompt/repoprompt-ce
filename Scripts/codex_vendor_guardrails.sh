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
grep -F "rust-v0.144.6" docs/releasing.md >/dev/null ||
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
        fail "$script must verify the exact target-specific Codex bundle"
    grep -F -- '--arch all' "$script" >/dev/null ||
        fail "$script must require both pinned Codex targets"
    if grep -F -- '--arch aarch64-apple-darwin' "$script" >/dev/null; then
        fail "$script must not validate only the arm64 Codex package"
    fi
done

printf 'OK: pinned Codex artifact, universal bundle, and legal inventory contracts are complete.\n'
