#!/usr/bin/env python3
"""Hermetic shell-boundary tests; no real keys, Swift compiler or GitHub traffic.

The admission CLI and CryptoKit verifier are test doubles here. Their own tests
own semantics/cryptography; these tests check shell wiring, failure propagation,
versioned parent selection, inventories, and activation/stale-parent fences.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True
import tip_history as history

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
REPOSITORY = "repoprompt/repoprompt-ce-tip-updates"
SIGNATURE = base64.b64encode(b"s" * 64).decode()

ADMISSION_STUB = '''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
sys.path.insert(0, os.environ["HOOK_REAL_SCRIPTS"])
import tip_history as h
args = sys.argv[1:]
def arg(name): return args[args.index(name) + 1]
def read(name): return json.load(open(arg(name)))
with open(os.environ["HOOK_LOG"], "a") as f: f.write(json.dumps(args) + "\\n")
if args[0] == "verify-parent":
    raw = pathlib.Path(arg("--envelope")).read_bytes()
    p = h.page_from_envelope(raw)
    assert p["generatedForTag"] == arg("--tag")
    assert hashlib.sha256(raw).hexdigest() == arg("--sha256")
elif args[0] == "verify-candidate":
    assert ("--parent-envelope" in args) != ("--bootstrap" in args)
    c = h.page_from_envelope(pathlib.Path(arg("--envelope")).read_bytes())
    if "--parent-envelope" in args:
        parent = pathlib.Path(arg("--parent-envelope")).read_bytes()
        assert c == h.assemble_page(c["entries"][0], c["updateRepository"], parent), "parent superseded"
    if c["entries"][0]["download"]:
        assert c["entries"][0]["download"]["expandedSize"] == int(arg("--expanded-size"))
elif args[0] == "build-payload":
    n, m = read("--notes"), read("--manifest")
    e = dict(n, tag=m["sourceTag"], buildNumber=m["buildNumber"],
             historyCatalogSha256=None, origin="catalog",
             download={"expandedSize": int(arg("--expanded-size"))} if os.environ.get("HOOK_PACKAGE") != "1" else None)
    parent = pathlib.Path(arg("--parent-envelope")).read_bytes() if "--parent-envelope" in args else None
    seeds = read("--bootstrap")["entries"] if "--bootstrap" in args else None
    pathlib.Path(arg("--output")).write_bytes(h.canonical(h.assemble_page(e, os.environ["TIP_UPDATE_REPOSITORY"], parent, seeds)))
else:
    raise SystemExit("unexpected admission command")
'''

CURL_STUB = '''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
url = next(x for x in reversed(a) if x.startswith("https://"))
with open(os.environ["HOOK_NETWORK_LOG"], "a") as f: f.write(url + "\\n")
assert not any("Authorization:" in x for x in a), "signing downloads must be anonymous"
out = pathlib.Path(a[a.index("--output") + 1])
if "api.github.com" in url:
    source = os.environ.get("HOOK_ORIGINAL_RELEASE") if "/releases/tags/" in url else None
    raw = pathlib.Path(source or os.environ["HOOK_RELEASE"]).read_bytes()
    out.write_bytes(raw)
    print(os.environ.get("HOOK_HTTP_STATUS", "200"), end="")
else:
    assert "/releases/download/" in url and "/latest/" not in url
    if os.environ.get("HOOK_ASSET_404") == "1": raise SystemExit(22)
    source = os.environ.get("HOOK_ORIGINAL_PARENT") if (os.environ.get("HOOK_ORIGINAL_TAG", "!") + "/tip-history.json") in url else None
    out.write_bytes(pathlib.Path(source or os.environ["HOOK_PARENT"]).read_bytes())
'''

VERIFIER_STUB = '''#!/usr/bin/env python3
import json, os, pathlib, sys
assert sys.argv[1] == "swift" and pathlib.Path(sys.argv[2]).name == "verify_sparkle_signature.swift"
key, signature, message = sys.argv[3:]
expected = json.load(open(os.environ["HOOK_APPLE_POLICY"]))["sparkle"]["sparklePublicEdDSAValue"]
assert pathlib.Path(key).read_text().strip() == expected
assert pathlib.Path(message).read_bytes().startswith(b"repoprompt-tip-history-v1\\n")
with open(os.environ["HOOK_LOG"], "a") as f: f.write(json.dumps(["crypto", message]) + "\\n")
if os.environ.get("HOOK_BAD_SIGNATURE") == "1": raise SystemExit(1)
'''

SIGNER_STUB = '''#!/usr/bin/env python3
import base64, os, pathlib, sys
assert sys.argv[1:4] == ["--ed-key-file", "-", "-p"]
assert pathlib.Path(sys.argv[4]).read_bytes().startswith(b"repoprompt-tip-history-v1\\n")
assert not os.environ.get("GH_TOKEN") and not os.environ.get("GITHUB_TOKEN")
assert sys.stdin.read() == "fixture-not-a-private-key"
print(base64.b64encode(b"s" * 64).decode())
'''


class TipReleaseHistoryHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tip-history-hooks-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Parent")
        self.parent_commit = self.git("rev-parse", "HEAD")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Candidate")
        self.commit = self.git("rev-parse", "HEAD")
        self.tag = "tip-" + self.commit[:12]
        self.parent_tag = "tip-" + self.parent_commit[:12]
        self.policy = self.scripts / "tip_history_policy.json"
        self.write(self.policy, {"schemaVersion": 1, "historyEnabledSinceTag": self.tag})
        (self.scripts / "tip_history.py").symlink_to(SCRIPTS / "tip_history.py")
        (self.scripts / "apple_identity_policy.json").symlink_to(SCRIPTS / "apple_identity_policy.json")
        self.executable(self.scripts / "tip_history_admission.py", ADMISSION_STUB)
        for name, stub in (("curl", CURL_STUB), ("xcrun", VERIFIER_STUB), ("sign_update", SIGNER_STUB)):
            self.executable(self.bin / name, stub)
        self.entry = {"tag": self.parent_tag, "releaseCommit": self.parent_commit, "buildNumber": "37.1.0", "historyCatalogSha256": None, "origin": "catalog"}
        self.parent = self.root / "parent.json"
        self.parent.write_bytes(history.wrap(history.canonical(history.assemble_page(self.entry, REPOSITORY, None)), SIGNATURE))
        self.release = self.root / "release.json"
        self.set_release(catalog=True)
        self.work = self.root / "work"
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.manifest = self.dist / "identity-rollout.json"
        self.metadata = self.dist / "fixture-metadata.json"
        self.artifact = self.dist / "fixture-artifact-manifest.json"
        self.archive = self.dist / "fixture.zip"
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("RepoPrompt CE.app/Contents/MacOS/Fixture", b"fixture executable")
        self.write(self.artifact, {})
        m = {"releaseCommit": self.commit, "sourceTag": self.tag, "buildNumber": "37.1.1", "marketingVersion": "1.0", "currentRole": "preparer", "signingIdentity": "legacy", "migrationPhase": "legacy-preparer", "appcastItems": [{"installationType": "application", "enclosureName": "fixture.zip"}]}
        self.write(self.manifest, m)
        m["appArtifactManifest"] = {"name": self.artifact.name, "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest()}
        self.write(self.manifest, m)
        self.write(self.metadata, {"commit": self.commit, "short_sha": self.commit[:12], "tag": self.tag, "build_number": m["buildNumber"], "marketing_version": "1.0", "rollout_role": "preparer", "signing_identity": "legacy", "migration_phase": "legacy-preparer"})
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TIP_UPDATE_REPOSITORY=REPOSITORY, TIP_COMMIT=self.commit, TIP_TAG=self.tag,
                        TIP_BUILD_NUMBER="37.1.1", HOOK_REAL_SCRIPTS=str(SCRIPTS),
                        HOOK_RELEASE=str(self.release), HOOK_PARENT=str(self.parent),
                        HOOK_LOG=str(self.root / "calls"), HOOK_NETWORK_LOG=str(self.root / "network"),
                        HOOK_APPLE_POLICY=str(SCRIPTS / "apple_identity_policy.json"))

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    @staticmethod
    def executable(path, content):
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def set_release(self, catalog):
        asset = {"name": "tip-history.json", "state": "uploaded", "browser_download_url": f"https://github.com/{REPOSITORY}/releases/download/{self.parent_tag}/tip-history.json", "size": self.parent.stat().st_size, "digest": "sha256:" + hashlib.sha256(self.parent.read_bytes()).hexdigest()}
        self.write(self.release, {"draft": False, "prerelease": False, "tag_name": self.parent_tag, "assets": [asset] if catalog else []})

    def shell(self, commands, *, full=False, success=True):
        setup = ("source " + shlex.quote(str(SCRIPTS / "main_tip_release.sh")) + "; trap - EXIT\n") if full else ("REPOPROMPT_TIP_HISTORY_LIBRARY_ONLY=1 source " + shlex.quote(str(SCRIPTS / "main_tip_release.sh")) + "\n")
        setup += "tip_history_context " + shlex.quote(str(self.scripts)) + "\n"
        result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + setup + commands], cwd=ROOT, env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def resolve(self, *, success=True):
        return self.shell(f'tip_history_resolve_parent {shlex.quote(str(self.work))}', success=success)

    def test_versioned_parent_and_external_signature_before_admission(self):
        self.resolve()
        self.assertEqual((self.work / "parent-envelope.json").read_bytes(), self.parent.read_bytes())
        urls = Path(self.env["HOOK_NETWORK_LOG"]).read_text().splitlines()
        self.assertEqual(urls, [f"https://api.github.com/repos/{REPOSITORY}/releases/latest", f"https://github.com/{REPOSITORY}/releases/download/{self.parent_tag}/tip-history.json"])
        calls = [json.loads(line) for line in Path(self.env["HOOK_LOG"]).read_text().splitlines()]
        self.assertEqual([c[0] for c in calls], ["crypto", "verify-parent"])

    def test_parent_metadata_and_crypto_fail_closed(self):
        original = json.loads(self.release.read_text())
        for change in ("duplicate", "url", "size", "digest", "signature", "404"):
            with self.subTest(change=change):
                r = copy.deepcopy(original)
                self.env.pop("HOOK_BAD_SIGNATURE", None)
                self.env.pop("HOOK_ASSET_404", None)
                if change == "duplicate": r["assets"] *= 2
                elif change == "url": r["assets"][0]["browser_download_url"] = "https://example.invalid/catalog"
                elif change == "size": r["assets"][0]["size"] += 1
                elif change == "digest": r["assets"][0]["digest"] = "sha256:" + "0" * 64
                elif change == "signature": self.env["HOOK_BAD_SIGNATURE"] = "1"
                else: self.env["HOOK_ASSET_404"] = "1"
                self.write(self.release, r)
                self.resolve(success=False)

    def test_explicit_inactive_does_not_accept_live_catalog(self):
        self.write(self.policy, {"schemaVersion": 1, "historyEnabledSinceTag": None})
        self.assertIn("inactive", self.resolve(success=False).stderr)
        self.set_release(catalog=False)
        self.resolve()
        self.assertFalse((self.work / "parent-envelope.json").exists())

    def bootstrap(self):
        b = {"schemaVersion": 1, "historyNeverEnabled": True, "liveParent": self.parent_tag, "entries": [self.entry]}
        path = self.repo / "bootstrap.json"
        self.write(path, b)
        self.write(self.policy, {"schemaVersion": 1, "historyEnabledSinceTag": self.tag, "bootstrapEvidenceFile": "bootstrap.json", "bootstrapEvidenceSha256": hashlib.sha256(history.canonical(b)).hexdigest()})
        return path

    def test_bootstrap_binds_latest_and_never_resets_after_activation(self):
        bootstrap = self.bootstrap()
        self.set_release(catalog=False)
        self.resolve()
        command = f'tip_history_require_bootstrap_parent {shlex.quote(str(bootstrap))} {shlex.quote(str(self.work / "resolved-release.json"))}'
        self.shell(command)
        self.env["TIP_TAG"] = "tip-" + "f" * 12
        self.assertIn("never bootstrap", self.shell(command, success=False).stderr)
        self.env["TIP_TAG"] = self.tag
        self.write(self.work / "resolved-release.json", None)
        self.assertIn("superseded", self.shell(command, success=False).stderr)

    def generate(self, package=False):
        app = self.root / "App.app"
        app.mkdir(exist_ok=True)
        (app / "binary").write_bytes(b"fixture executable")
        self.env["REPOPROMPT_APPROVED_SOURCE_ROOT"] = str(self.repo)
        self.env["SPARKLE_PRIVATE_KEY"] = "fixture-not-a-private-key"
        self.env["GH_TOKEN"] = "fixture-ambient-token-must-be-removed"
        self.env["HOOK_PACKAGE"] = "1" if package else "0"
        manifest = json.loads(self.manifest.read_text())
        manifest["appcastItems"][0]["installationType"] = "package" if package else "application"
        self.write(self.manifest, manifest)
        values = dict(APPROVED_SOURCE_ROOT=self.repo, TMP_DIR=self.root / "sign-work", APP_BUNDLE=app,
                      ROLLOUT_MANIFEST=self.manifest, FINAL_ARTIFACT_MANIFEST=self.artifact,
                      FINAL_METADATA=self.metadata, HISTORY_ENVELOPE=self.dist / "tip-history.json",
                      SIGN_UPDATE=self.bin / "sign_update", UPDATE_ZIP=self.archive,
                      ROLLOUT_INSTALLATION_TYPE="package" if package else "application")
        assignments = "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in values.items())
        self.shell(assignments + "\ngenerate_tip_history_catalog", full=True)
        return history.page_from_envelope((self.dist / "tip-history.json").read_bytes())

    def test_signing_both_installation_paths_and_metadata_binding(self):
        for package in (False, True):
            with self.subTest(package=package):
                page = self.generate(package)
                self.assertEqual(page["entries"][0]["tag"], self.tag)
                self.assertEqual(page["entries"][1]["historyCatalogSha256"], hashlib.sha256(self.parent.read_bytes()).hexdigest())
                self.assertEqual(page["entries"][0]["download"] is None, package)
        metadata = json.loads(self.metadata.read_text())
        metadata["commit"] = "f" * 40
        self.write(self.metadata, metadata)
        # Exercise actual shell metadata check, independently of stub admission.
        result = self.shell(f'tip_history_verify_candidate "{self.dist}/tip-history.json" "{self.manifest}" "{self.artifact}" "{self.metadata}" "{self.repo}" "{self.root}/sign-work/history"', success=False)
        self.assertIn("metadata binding mismatch", result.stderr)

    def test_catalogless_bootstrap_argument_and_stale_parent_rederivation(self):
        self.bootstrap()
        self.set_release(catalog=False)
        self.generate()
        calls = [json.loads(line) for line in Path(self.env["HOOK_LOG"]).read_text().splitlines()]
        self.assertTrue(any(c[0] == "verify-candidate" and "--bootstrap" in c for c in calls))
        # Moving the observed parent after signing must change full re-derivation.
        self.set_release(catalog=True)
        self.resolve()
        result = self.shell(f'tip_history_verify_candidate "{self.dist}/tip-history.json" "{self.manifest}" "{self.artifact}" "{self.metadata}" "{self.repo}" "{self.work}"', success=False)
        self.assertIn("superseded", result.stderr)

    def test_workflow_and_inventory_hooks(self):
        text = (ROOT / ".github/workflows/main-tip.yml").read_text()
        sign = text.split("  sign:\n", 1)[1].split("  smoke-no-secrets:\n", 1)[0]
        self.assertRegex(sign, r"path: approved-source\n(?:[^\n]*\n)*?          fetch-depth: 0")
        package = sign.split("      - name: Validate package", 1)[1].split("      - name:", 1)[0]
        self.assertIn("REPOPROMPT_APPROVED_SOURCE_ROOT:", package)
        publisher = (SCRIPTS / "publish_tip_release.sh").read_text()
        self.assertIn('audit_live_rollout_progression "publication setup"', publisher)
        self.assertIn('audit_live_rollout_progression "final pre-publication"', publisher)
        self.assertIn('audit_tip_history_parent "$phase"', publisher)
        main = (SCRIPTS / "main_tip_release.sh").read_text()
        self.assertEqual(main.count("    generate_tip_history_catalog\n"), 2)
        self.assertEqual(main.count('checksum_assets+=("$(basename "$HISTORY_ENVELOPE")")'), 2)
        for active in (True, False):
            self.write(self.policy, {"schemaVersion": 1, "historyEnabledSinceTag": self.tag if active else None})
            result = self.shell('tip_publish_assets; printf "%s\\n" "${TIP_PUBLISH_ASSETS[@]}"', full=True)
            self.assertEqual("tip-history.json" in result.stdout, active)

    def test_expanded_bytes_come_from_final_archive_and_layout_is_bounded(self):
        result = self.shell(f'tip_history_archive_expanded_size "{self.archive}"')
        self.assertEqual(int(result.stdout), len(b"fixture executable"))
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("RepoPrompt CE.app/../escaped", b"bad")
        self.assertIn("layout", self.shell(f'tip_history_archive_expanded_size "{self.archive}"', success=False).stderr)

    def test_publisher_setup_and_final_audit_execute_same_parent_fence(self):
        self.generate()
        publisher = (SCRIPTS / "publish_tip_release.sh").read_text()
        function = publisher.split("audit_tip_history_parent() {", 1)[1].split("\n# Returns 0", 1)[0]
        function = "audit_tip_history_parent() {" + function
        # Execute the production boundary without its remote mutation driver.
        variables = f'''
fail() {{ echo "ERROR: $*" >&2; exit 1; }}
asset_path_for_name() {{
  case "$1" in
    tip-history.json) printf '%s\\n' "{self.dist}/tip-history.json" ;;
    fixture-artifact-manifest.json) printf '%s\\n' "{self.artifact}" ;;
    fixture-metadata.json) printf '%s\\n' "{self.metadata}" ;;
    *) return 1 ;;
  esac
}}
TMP_DIR="{self.root}/publisher"
mkdir -p "$TMP_DIR"
APPROVED_SOURCE_ROOT="{self.repo}"
CANDIDATE_MANIFEST="{self.manifest}"
LIVE_AUDIT_INDEX=1
LIVE_RELEASE_PATH="{self.release}"
'''
        changed = copy.deepcopy(self.entry)
        changed["title"] = "Changed authenticated parent bytes"
        raw = history.wrap(history.canonical(history.assemble_page(changed, REPOSITORY, None)), SIGNATURE)
        replacement = self.root / "replacement-parent.json"
        replacement.write_bytes(raw)
        release = json.loads(self.release.read_text())
        release["assets"][0]["size"] = len(raw)
        release["assets"][0]["digest"] = "sha256:" + hashlib.sha256(raw).hexdigest()
        changed_release = self.root / "changed-release.json"
        self.write(changed_release, release)
        command = variables + function + f'''
audit_tip_history_parent "publication setup"
echo SETUP_FENCE_PASSED
cp "{replacement}" "{self.parent}"
LIVE_RELEASE_PATH="{changed_release}"
LIVE_AUDIT_INDEX=2
audit_tip_history_parent "final pre-publication"
echo MUST_NOT_PUBLISH
'''
        result = self.shell(command, success=False)
        self.assertIn("SETUP_FENCE_PASSED", result.stdout)
        self.assertNotIn("MUST_NOT_PUBLISH", result.stdout)
        self.assertIn("parent superseded", result.stderr)

    def test_already_public_exact_retry_reaudits_original_hash_pinned_parent(self):
        self.generate()
        original_parent = self.root / "original-parent.json"
        original_parent.write_bytes(self.parent.read_bytes())
        original_release = self.root / "original-release.json"
        original_release.write_bytes(self.release.read_bytes())
        catalog = self.dist / "tip-history.json"
        self.parent.write_bytes(catalog.read_bytes())
        release = json.loads(self.release.read_text())
        release["tag_name"] = self.tag
        asset = release["assets"][0]
        asset["browser_download_url"] = f"https://github.com/{REPOSITORY}/releases/download/{self.tag}/tip-history.json"
        asset["size"] = self.parent.stat().st_size
        asset["digest"] = "sha256:" + hashlib.sha256(self.parent.read_bytes()).hexdigest()
        self.write(self.release, release)
        self.env.update(HOOK_ORIGINAL_RELEASE=str(original_release), HOOK_ORIGINAL_PARENT=str(original_parent), HOOK_ORIGINAL_TAG=self.parent_tag)
        self.resolve()
        self.shell(f'tip_history_reaudit_parent "{catalog}" "{self.repo}" "{self.work}"; tip_history_verify_candidate "{catalog}" "{self.manifest}" "{self.artifact}" "{self.metadata}" "{self.repo}" "{self.work}"')
        self.assertEqual((self.work / "parent-envelope.json").read_bytes(), original_parent.read_bytes())


if __name__ == "__main__":
    unittest.main()
