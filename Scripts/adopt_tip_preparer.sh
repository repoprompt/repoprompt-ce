#!/usr/bin/env bash
# No-build Stable bootstrap: mirror the immutable Tip enclosure and retain its original
# provenance. Never import a signing identity or submit new notarization.
set -euo pipefail
MODE="${1:-verify}"
[[ "$MODE" == verify || "$MODE" == publish ]] || { echo 'Usage: adopt_tip_preparer.sh verify|publish' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY="$SCRIPT_DIR/apple_identity_policy.json"
DECLARATION="$ROOT_DIR/release-rollout.json"
TOOL="$SCRIPT_DIR/stable_rollout.py"
source "$SCRIPT_DIR/release_observation.sh"
python3 "$TOOL" workflow-guard --operation adopt --declaration "$DECLARATION" --policy "$POLICY"
: "${OBSERVATION_GH_TOKEN:?Read token required}"
: "${ADOPTION_OUTPUT_DIR:?A dedicated output directory is required}"
[[ ! -e "$ADOPTION_OUTPUT_DIR" ]] || { echo 'Adoption output directory already exists' >&2; exit 1; }
mkdir -p "$ADOPTION_OUTPUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IFS=$'\t' read -r tag build digest adoption_tag < <(python3 "$TOOL" adoption-values --declaration "$DECLARATION")
printf 'Pinned archived preparer %s (%s), manifest SHA-256 %s\n' "$tag" "$build" "$digest"
IFS=$'\t' read -r tip_repository stable_repository stable_feed public_key legacy_requirement anchor_requirement < <(
    python3 - "$POLICY" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); s=p['sparkle']; i=p['identities']
print('\t'.join((s['tipUpdateRepository'],s['updateRepository'],s['stableFeedURL'],s['sparklePublicEdDSAValue'],i['legacy']['developerIDRequirement'],i['successor']['developerIDRequirement'])))
PY
)
fetch_observed_rollout_pair "$tip_repository" "$tag" tip "$WORK/preparer"
python3 "$TOOL" generate-adoption --policy "$POLICY" --declaration "$DECLARATION" \
    --tip-manifest "$WORK/preparer/manifest.json" --tip-appcast "$WORK/preparer/appcast.xml" \
    --manifest-output "$WORK/adoption.json" --appcast-output "$WORK/appcast.xml"
IFS=$'\t' read -r enclosure manifest_name marketing < <(python3 - "$WORK/preparer/manifest.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); print('\t'.join((m['appcastItems'][0]['enclosureName'],m['appArtifactManifest']['name'],m['marketingVersion'])))
PY
)
fetch_observed_asset "$WORK/preparer/release.json" "$tip_repository" "$enclosure" "$ADOPTION_OUTPUT_DIR/$enclosure"
fetch_observed_asset "$WORK/preparer/release.json" "$tip_repository" "$manifest_name" "$ADOPTION_OUTPUT_DIR/$manifest_name"
python3 - "$WORK/preparer/manifest.json" "$ADOPTION_OUTPUT_DIR" <<'PY'
import hashlib,json,pathlib,sys
m=json.load(open(sys.argv[1])); d=pathlib.Path(sys.argv[2]); i=m['appcastItems'][0]
for name,digest in ((i['enclosureName'],i['enclosureSha256']),(m['appArtifactManifest']['name'],m['appArtifactManifest']['sha256'])):
    if hashlib.sha256((d/name).read_bytes()).hexdigest()!=digest: sys.exit('Published artifact binding mismatch')
if (d/i['enclosureName']).stat().st_size!=i['enclosureSize']: sys.exit('Enclosure size mismatch')
PY
printf '%s' "$public_key" > "$WORK/public-key"
signature="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["appcastItems"][0]["edSignature"])' "$WORK/preparer/manifest.json")"
xcrun swift "$SCRIPT_DIR/verify_sparkle_signature.swift" "$WORK/public-key" "$signature" "$ADOPTION_OUTPUT_DIR/$enclosure"
mkdir "$WORK/extracted"
ditto -x -k "$ADOPTION_OUTPUT_DIR/$enclosure" "$WORK/extracted"
APP="$WORK/extracted/RepoPrompt CE.app"
codesign --verify --deep --strict --all-architectures -R="$legacy_requirement" "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --all-architectures -R="$anchor_requirement" "$APP/Contents/Resources/IdentityMigration/RepoPromptIdentityAnchor"
python3 - "$APP/Contents/Info.plist" "$POLICY" "$build" "$marketing" <<'PY'
import json,plistlib,sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
p=json.load(open(sys.argv[2])); s=p['sparkle']
expected={'CFBundleIdentifier':p['identities']['legacy']['bundleIdentifier'],'CFBundleVersion':sys.argv[3], 'CFBundleShortVersionString':sys.argv[4], 'SUFeedURL':s['stableFeedURL'],'SUPublicEDKey':s['sparklePublicEdDSAValue'], 'RepoPromptIdentityMigrationPhase':'legacy-preparer'}
for key,value in expected.items():
    if info.get(key)!=value: sys.exit('Adopted preparer Info.plist mismatch: '+key)
PY
python3 "$SCRIPT_DIR/write_app_artifact_manifest.py" verify --app "$APP" \
    --manifest "$ADOPTION_OUTPUT_DIR/$manifest_name" --expected-architectures arm64,x86_64
# Expose the verified app for a later env-i smoke step, never execute it with tokens.
ditto "$APP" "$ADOPTION_OUTPUT_DIR/RepoPrompt CE.app"
rollout_name="RepoPrompt-$marketing-$build-stable-rollout.json"
cp "$WORK/adoption.json" "$ADOPTION_OUTPUT_DIR/$rollout_name"
cp "$WORK/appcast.xml" "$ADOPTION_OUTPUT_DIR/appcast.xml"
(cd "$ADOPTION_OUTPUT_DIR"; shasum -a 256 "$enclosure" "$manifest_name" > SHA256SUMS)

check_handoff() {
    fetch_observed_rollout_pair "$stable_repository" latest stable "$WORK/live-stable"
    fetch_observed_rollout_pair "$tip_repository" latest tip "$WORK/live-tip"
    python3 "$TOOL" validate-live-stable-progression --policy "$POLICY" \
        --candidate-manifest "$WORK/adoption.json" --candidate-appcast "$WORK/appcast.xml" \
        --live-manifest "$WORK/live-stable/manifest.json" --live-appcast "$WORK/live-stable/appcast.xml"
    python3 "$TOOL" validate-stable-tip-floor --policy "$POLICY" \
        --stable-manifest "$WORK/adoption.json" --stable-appcast "$WORK/appcast.xml" \
        --tip-manifest "$WORK/live-tip/manifest.json" --tip-appcast "$WORK/live-tip/appcast.xml"
}
check_handoff
if [[ "$MODE" == verify ]]; then
    echo 'Verified unchanged archived preparer; runtime migration remains UNVERIFIED. No publication performed.'
    exit 0
fi
: "${PUBLIC_UPDATE_GH_TOKEN:?Protected publication token required}"
# Serve exact authenticated bytes from Stable: shipped clients infer the channel
# from the enclosure repository. Keep the immutable original Tip release too.
mkdir "$WORK/feed"
cp "$WORK/adoption.json" "$WORK/feed/$rollout_name"
cp "$WORK/appcast.xml" "$WORK/feed/appcast.xml"
cp "$ADOPTION_OUTPUT_DIR/$enclosure" "$WORK/feed/$enclosure"
cp "$ADOPTION_OUTPUT_DIR/$manifest_name" "$WORK/feed/$manifest_name"
(cd "$WORK/feed"; shasum -a 256 appcast.xml "$rollout_name" "$enclosure" "$manifest_name" > SHA256SUMS)
update_gh() { GH_TOKEN="$PUBLIC_UPDATE_GH_TOKEN" gh "$@"; }
prepare_adoption_release "$WORK/feed" "$stable_repository" "$adoption_tag" \
    "Unchanged Tip preparer $tag ($build). Runtime credential migration UNVERIFIED, accepted risk. Authorization: ${GITHUB_SHA:-local}." "$WORK"
check_handoff
# Reconcile exact draft/public bytes again at the mutation boundary.
mkdir "$WORK/rechecked"
update_gh release download "$adoption_tag" --repo "$stable_repository" --dir "$WORK/rechecked"
diff -qr "$WORK/feed" "$WORK/rechecked"
update_gh release edit "$adoption_tag" --repo "$stable_repository" --draft=false --latest
converged=false
for attempt in 1 2 3 4 5 6 7; do
    if observe_release "$stable_repository" latest "$WORK/published-latest.json" &&
        python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["tag_name"] != sys.argv[2])' "$WORK/published-latest.json" "$adoption_tag" &&
        curl --disable --fail --silent --show-error --location --connect-timeout 10 --max-time 30 "$stable_feed" --output "$WORK/published-appcast.xml" &&
        cmp -s "$WORK/appcast.xml" "$WORK/published-appcast.xml"; then
        converged=true
        break
    fi
    [[ "$attempt" == 7 ]] || sleep 5
done
[[ "$converged" == true ]] || { echo 'Adoption is public but latest feed did not converge after bounded reads; inspect before retrying' >&2; exit 1; }
# GitHub's newly uploaded mirror must bind the very same bytes and public URL.
python3 - "$WORK/published-latest.json" "$WORK/adoption.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2])); item=m['appcastItems'][0]
assets=[a for a in r['assets'] if a['name']==item['enclosureName'] and a.get('state')=='uploaded']
if (len(assets)!=1 or assets[0].get('browser_download_url')!=item['url']
        or assets[0].get('size')!=item['enclosureSize']
        or assets[0].get('digest')!='sha256:'+item['enclosureSha256']):
    sys.exit('Adoption is PUBLIC but mirrored ZIP API binding failed; inspect before retrying')
PY
# Publication is a point of no return. On a failed discovery check, report a
# public-but-unverified state; do not roll back, delete, or overwrite the release.
if ! bash "$SCRIPT_DIR/check_stable_preparer_update.sh" public "$ADOPTION_OUTPUT_DIR/$rollout_name" "$ADOPTION_OUTPUT_DIR/public-updater-check"; then
    echo 'Adoption is PUBLIC but the real Stable 43 updater check failed; inspect evidence before any retry or transition' >&2
    exit 1
fi
echo "Published unchanged archived preparer through Stable delivery; actual Stable 43 updater discovery passed. Runtime credential migration remains UNVERIFIED."
