#!/usr/bin/env bash
# Check discovery with the real public Stable 43 host and its embedded Sparkle.
# candidate: serve generated feed on loopback; public: use Stable's normal URL.
# No application launch, installation, signing, notarization, or Keychain use.
set -euo pipefail
MODE="${1:?candidate|public}"; MANIFEST="${2:?Expected rollout manifest}"; WORK="${3:?Fresh evidence directory}"
[[ "$MODE" == candidate || "$MODE" == public ]] || exit 64
[[ ! -e "$WORK" ]] || { echo 'Updater evidence directory already exists' >&2; exit 1; }
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_observation.sh"
POLICY="$SCRIPT_DIR/apple_identity_policy.json"
IFS=$'\t' read -r repository requirement < <(python3 - "$POLICY" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); print(p['sparkle']['updateRepository']+'\t'+p['identities']['legacy']['developerIDRequirement'])
PY
)
if [[ -n "${4:-}" ]]; then
    # Optional content-addressed local cache. The unconditional pin below is
    # the same authority; this cannot select a different host or skip checks.
    cp "$4" "$WORK/baseline.zip"
else
    observe_release "$repository" v1.9.0 "$WORK/baseline-release.json"
    fetch_observed_asset "$WORK/baseline-release.json" "$repository" RepoPrompt-1.9.0-43.zip "$WORK/baseline.zip"
fi
python3 - "$WORK/baseline.zip" <<'PY'
import hashlib,pathlib,sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()!='6ef40f86f4335fe9fb10e513b138d2139972b7e29a37aba8796a254b244b712e':
    sys.exit('Public Stable 43 archive pin mismatch')
PY
ditto -x -k "$WORK/baseline.zip" "$WORK/host"
APP="$WORK/host/RepoPrompt CE.app"
codesign --verify --deep --strict --all-architectures -R="$requirement" "$APP"
xcrun stapler validate "$APP"
# Compile only a standalone diagnostic, linking the shipped framework. Never
# rebuild or modify the official host app. Run all diagnostic code without tokens.
FRAMEWORKS="$APP/Contents/Frameworks"
xcrun clang -fobjc-arc -fmodules-cache-path="$WORK/clang-cache" -framework Foundation \
    -F "$FRAMEWORKS" -framework Sparkle -Wl,-rpath,"$FRAMEWORKS" \
    "$SCRIPT_DIR/check_stable_preparer_update.m" -o "$WORK/updater-check"
# Freeze the exact shipped channel classifier, not a model of today's client.
GH_TOKEN="${OBSERVATION_GH_TOKEN:?Read token required}" gh api \
    'repos/repoprompt/repoprompt-ce/contents/Sources/RepoPrompt/App/Sparkle/SparkleUpdateManager.swift?ref=d617b63ae968e906da437ffd718d652ab6ba78d6' \
    --jq .content | base64 -D > "$WORK/shipped-update-manager.swift"
python3 - "$WORK" "$POLICY" "$MANIFEST" <<'PY'
import hashlib,json,pathlib,sys
w=pathlib.Path(sys.argv[1]); p=json.load(open(sys.argv[2])); m=json.load(open(sys.argv[3]))
s=(w/'shipped-update-manager.swift').read_text()
a=s.index('    nonisolated static func updateChannel(forAppcastItemURL'); b=s.index('\n    nonisolated static func makePassiveAppcastRequest',a)
f=s[a:b]
if hashlib.sha256(f.encode()).hexdigest()!='dab6523c2389b4c776ca35e26c6e8196e837adb2a9daef1c03514e05f5a168cd':
    sys.exit('Shipped channel classifier pin mismatch')
f=f.replace('    nonisolated static func updateChannel','func updateChannel')
s='import Foundation\nenum UpdateChannel: CaseIterable { case stable,tip\n var feedURLString:String { self == .stable ? '+json.dumps(p['sparkle']['stableFeedURL'])+' : '+json.dumps(p['sparkle']['tipFeedURL'])+' }\n}\n'+f
s+='\nlet itemURL=URL(string:'+json.dumps(m['appcastItems'][0]['url'])+')!\nguard updateChannel(forAppcastItemURL:itemURL) == .stable else { fatalError("Published Stable client rejects this enclosure as a different channel") }\nprint("SHIPPED_STABLE_CHANNEL_RULE_PASS")\n'
(w/'channel-check.swift').write_text(s)
PY
mkdir -p "$WORK/home" "$WORK/tmp"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$WORK/home" TMPDIR="$WORK/tmp" \
    xcrun swift -module-cache-path "$WORK/swift-cache" "$WORK/channel-check.swift"
# Run a genuine user-initiated SPUUpdater.checkForUpdates cycle. The custom
# driver records found/not-found and always dismisses; never selects Install.
python3 - "$MODE" "$WORK" "$APP" "$MANIFEST" "$POLICY" <<'PY'
import functools,http.server,json,os,pathlib,subprocess,sys,threading
mode,w,app,manifest,policy=sys.argv[1:]; w=pathlib.Path(w); manifest=pathlib.Path(manifest).resolve()
p=json.load(open(policy)); server=None
try:
    if mode=='candidate':
        handler=functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(manifest.parent))
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        feed=f'http://127.0.0.1:{server.server_port}/appcast.xml'
    else: feed=p['sparkle']['stableFeedURL']
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(w/'home'),'TMPDIR':str(w/'tmp')}
    try:
        result=subprocess.run([str(w/'updater-check'),app,str(manifest),feed],env=env,timeout=75,capture_output=True,text=True)
    except subprocess.TimeoutExpired as error:
        def decoded(value): return value.decode(errors='replace') if isinstance(value,bytes) else (value or '')
        log=decoded(error.stdout)+decoded(error.stderr)+'\nPROBE_SUPERVISOR_TIMEOUT\n'
        (w/'updater-check.log').write_text(log); print(log,end=''); sys.exit(9)
    log=result.stdout+result.stderr; (w/'updater-check.log').write_text(log); print(log,end='')
    if result.returncode: sys.exit(result.returncode)
    (w/'receipt.json').write_text(json.dumps(dict(mode=mode,hostBuild='43',targetBuild='43.24.43',
        check='SPUUpdater.checkForUpdates',shippedChannelRule='passed',updateFound=True,
        delegateFidelity='Sparkle engine; shipped app delegate/UI not exercised',
        installed=False,appLaunched=False,runtimeCredentialMigration='unverified'),indent=2)+'\n')
finally:
    if server: server.shutdown(); server.server_close()
PY
