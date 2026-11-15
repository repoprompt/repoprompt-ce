#!/usr/bin/env bash
# Sourced by the protected publishers. All URLs are derived from policy and
# authenticated API metadata; downloaded bytes must match that metadata.
observe_release() {
    local repository="$1" selector="$2" output="$3"
    local endpoint="repos/$repository/releases/latest"
    [[ "$selector" == latest ]] || endpoint="repos/$repository/releases/tags/$selector"
    GH_TOKEN="${OBSERVATION_GH_TOKEN:?Missing read token for release observation}" \
        gh api "$endpoint" > "$output" || return 1
    python3 - "$output" "$selector" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get('draft') is not False or r.get('prerelease') is not False:
    sys.exit('Release observation requires a published non-prerelease')
if sys.argv[2] != 'latest' and r.get('tag_name') != sys.argv[2]:
    sys.exit('Release observation tag mismatch')
PY
}

fetch_observed_asset() {
    local metadata="$1" repository="$2" name="$3" output="$4"
    local url
    url="$(python3 - "$metadata" "$repository" "$name" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assets = [a for a in r['assets'] if a['name'] == sys.argv[3] and a.get('state') == 'uploaded']
if len(assets) != 1:
    sys.exit('Expected one uploaded asset: ' + sys.argv[3])
a = assets[0]
url = f"https://github.com/{sys.argv[2]}/releases/download/{r['tag_name']}/{sys.argv[3]}"
if a.get('browser_download_url') != url:
    sys.exit('Observed asset URL mismatch')
print(url)
PY
)" || return 1
    local asset_id
    asset_id="$(python3 - "$metadata" "$name" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); a=next(a for a in r['assets'] if a['name']==sys.argv[2])
if not a.get('digest'):
    if not isinstance(a.get('id'),int) or a['id']<=0: sys.exit('Historical asset lacks API identity')
    print(a['id'])
PY
)" || return 1
    if [[ -n "$asset_id" ]]; then
        # Older assets may have no API digest. In that case fetch bytes through
        # the authenticated API asset identity, not an unbound public redirect.
        GH_TOKEN="${OBSERVATION_GH_TOKEN:?Missing read token}" gh api \
            "repos/$repository/releases/assets/$asset_id" -H 'Accept: application/octet-stream' > "$output" || return 1
    else
        curl --disable --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 600 --retry 3 "$url" --output "$output" || return 1
    fi
    python3 - "$metadata" "$name" "$output" <<'PY'
import hashlib, json, pathlib, re, sys
r = json.load(open(sys.argv[1]))
a = next(a for a in r['assets'] if a['name'] == sys.argv[2])
p = pathlib.Path(sys.argv[3])
digest = a.get('digest')
if digest is not None and digest != '' and not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    sys.exit('Observed asset has malformed GitHub SHA-256: ' + sys.argv[2])
if p.stat().st_size != a['size'] or (digest and 'sha256:' + hashlib.sha256(p.read_bytes()).hexdigest() != digest):
    sys.exit('Observed asset size/digest mismatch: ' + sys.argv[2])
PY
}

# Reconcile metadata-only adoption drafts without overwriting any asset. Caller
# supplies update_gh (protected token wrapper) and rechecks handoff before publish.
prepare_adoption_release() {
    local feed="$1" repository="$2" tag="$3" notes="$4" work="$5"
    update_gh api --paginate --slurp "repos/$repository/releases?per_page=100" > "$work/releases.json" || return 1
    local existing
    existing="$(python3 - "$work/releases.json" "$tag" <<'PY'
import json,sys
releases=[r for page in json.load(open(sys.argv[1])) for r in page if r['tag_name']==sys.argv[2]]
if len(releases)>1: sys.exit('Duplicate adoption release tags; refusing ambiguous mutation')
if releases and releases[0].get('prerelease') is not False: sys.exit('Adoption release must not be a prerelease')
print('yes' if releases else 'no')
PY
)" || return 1
    if [[ "$existing" == yes ]]; then
        mkdir "$work/existing"
        update_gh release download "$tag" --repo "$repository" --dir "$work/existing" || return 1
        diff -qr "$feed" "$work/existing" || return 1
    else
        update_gh release create "$tag" "$feed/"* --repo "$repository" --draft --latest=false \
            --title "RepoPrompt CE archived preparer" --notes "$notes" || return 1
    fi
}

fetch_observed_rollout_pair() {
    local repository="$1" selector="$2" channel="$3" directory="$4"
    mkdir -p "$directory"
    observe_release "$repository" "$selector" "$directory/release.json" || return 1
    local name
    name="$(python3 - "$directory/release.json" "$channel" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
names = [a['name'] for a in r['assets'] if (a['name'] == 'identity-rollout.json' if sys.argv[2] == 'tip' else a['name'].endswith('-stable-rollout.json'))]
if len(names) != 1:
    sys.exit('Expected exactly one rollout manifest')
print(names[0])
PY
)" || return 1
    fetch_observed_asset "$directory/release.json" "$repository" "$name" "$directory/manifest.json" || return 1
    fetch_observed_asset "$directory/release.json" "$repository" appcast.xml "$directory/appcast.xml"
}
