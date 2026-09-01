#!/usr/bin/env python3
"""Hermetic process-level regression coverage for Tip release publication."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
PUBLISHER = SCRIPT_DIR / "publish_tip_release.sh"
ROLLOUT_TOOL = SCRIPT_DIR / "stable_rollout.py"
POLICY = SCRIPT_DIR / "apple_identity_policy.json"

COMMIT = "a" * 40
TAG = "tip-aaaaaaaaaaaa"
SOURCE_REPOSITORY = "repoprompt/repoprompt-ce"
UPDATE_REPOSITORY = "repoprompt/repoprompt-ce-tip-updates"
TITLE = "RepoPrompt CE Tip fixture"
NOTES = "Hermetic publisher regression fixture."

GH_STUB = r'''#!/usr/bin/env python3
import hashlib
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["PUBLISHER_STUB_STATE"])
asset_dir = Path(os.environ["PUBLISHER_ASSET_DIR"])
state = json.loads(state_path.read_text(encoding="utf-8"))
args = sys.argv[1:]


def save():
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def option(name):
    return args[args.index(name) + 1]


def asset_record(path):
    data = path.read_bytes()
    name = path.name
    index = len(state["release"]["assets"]) + 1
    return {
        "name": name,
        "state": "uploaded",
        "url": f"https://api.github.com/repos/{os.environ['TIP_UPDATE_REPOSITORY']}/releases/assets/{index}",
        "browser_download_url": (
            f"https://github.com/{os.environ['TIP_UPDATE_REPOSITORY']}"
            f"/releases/download/{os.environ['TIP_TAG']}/{name}"
        ),
        "size": len(data),
        "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
    }


if not os.environ.get("GH_TOKEN"):
    raise SystemExit("missing GH_TOKEN")

if args[:2] == ["api", "--paginate"]:
    state["lookup_args"].append(args)
    save()
    if state["scenario"] == "lookup-error":
        print("fixture lookup failure", file=sys.stderr)
        raise SystemExit(42)
    release = state.get("release")
    first_page = [{"tag_name": "tip-bbbbbbbbbbbb"}]
    if state["scenario"] == "duplicate":
        print(json.dumps([release]))
        print(json.dumps([release]))
    elif release is None:
        print(json.dumps(first_page))
        print("[]")
    else:
        print(json.dumps(first_page))
        print(json.dumps([release]))
    raise SystemExit(0)

if args and args[0] == "api" and "Accept: application/octet-stream" in args:
    api_url = args[-1]
    for asset in state["release"]["assets"]:
        if asset["url"] == api_url:
            sys.stdout.buffer.write((asset_dir / asset["name"]).read_bytes())
            raise SystemExit(0)
    raise SystemExit(f"unknown fixture asset API URL: {api_url}")

if args[:2] == ["release", "create"]:
    if state.get("release") is not None:
        raise SystemExit("fixture release already exists")
    state["mutations"].append("create")
    state["release"] = {
        "id": 101,
        "tag_name": args[2],
        "target_commitish": option("--target"),
        "name": option("--title"),
        "body": option("--notes"),
        "draft": True,
        "prerelease": False,
        "assets": [],
    }
    save()
    print("fixture draft created")
    raise SystemExit(0)

if args[:2] == ["release", "upload"]:
    path = Path(args[3])
    state["mutations"].append(f"upload:{path.name}")
    state["release"]["assets"].append(asset_record(path))
    save()
    print("fixture asset uploaded")
    raise SystemExit(0)

if args[:3] == ["api", "--method", "PATCH"]:
    state["mutations"].append("publish")
    state["release"]["draft"] = False
    save()
    print(json.dumps(state["release"]))
    raise SystemExit(0)

raise SystemExit(f"unsupported gh invocation: {args!r}")
'''

CURL_STUB = r'''#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

args = sys.argv[1:]
state = json.loads(Path(os.environ["PUBLISHER_STUB_STATE"]).read_text(encoding="utf-8"))
asset_dir = Path(os.environ["PUBLISHER_ASSET_DIR"])
output = Path(args[args.index("--output") + 1])
urls = [argument for argument in args if argument.startswith("https://")]
if not urls:
    raise SystemExit(f"missing fixture URL: {args!r}")
url = urls[-1]
status = "200"

if url.endswith("/commits/main"):
    output.write_text(json.dumps({"sha": os.environ["TIP_COMMIT"]}), encoding="utf-8")
elif url == os.environ["PUBLISHER_STABLE_FEED_URL"]:
    shutil.copyfile(os.environ["PUBLISHER_STABLE_APPCAST"], output)
elif url.endswith("/releases/latest"):
    release = state.get("release")
    if release is None or release.get("draft") is not False:
        output.write_text("{}\n", encoding="utf-8")
        status = "404"
    else:
        output.write_text(json.dumps(release) + "\n", encoding="utf-8")
elif "/releases/tags/" in url:
    release = state.get("release")
    if release is None or release.get("draft") is not False:
        output.write_text("{}\n", encoding="utf-8")
        status = "404"
    else:
        output.write_text(json.dumps(release) + "\n", encoding="utf-8")
elif "/releases/download/" in url:
    shutil.copyfile(asset_dir / url.rsplit("/", 1)[-1], output)
else:
    raise SystemExit(f"unsupported curl fixture URL: {url}")

if "--write-out" in args:
    print(status, end="")
'''


class PublishTipReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.asset_dir = self.root / "assets"
        self.asset_dir.mkdir()
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.state_path = self.root / "state.json"
        self.stable_appcast = self.root / "stable-appcast.xml"
        self._write_executable(self.bin_dir / "gh", GH_STUB)
        self._write_executable(self.bin_dir / "curl", CURL_STUB)
        self.assets, self.declaration = self._generate_candidate()
        self.stable_appcast.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    <item>\n"
            "      <sparkle:shortVersionString>1.4.0</sparkle:shortVersionString>\n"
            "      <sparkle:version>36</sparkle:version>\n"
            "    </item>\n"
            "  </channel>\n"
            "</rss>\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _write_executable(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _generate_candidate(self) -> tuple[list[Path], Path]:
        declaration = self.asset_dir / "tip-rollout.json"
        declaration.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "channel": "tip",
                    "currentRole": "preparer",
                    "eligibilityProfile": "tip-identity-dress-rehearsal-v1",
                    "expectedMigrationPhase": "legacy-preparer",
                    "expectedSigningIdentity": "legacy",
                    "predecessors": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        version_env = self.asset_dir / "version.env"
        version_env.write_text(
            "APP_NAME=RepoPrompt\n"
            "MARKETING_VERSION=1.4.1\n"
            "BUILD_NUMBER=37\n"
            "BUNDLE_ID=com.pvncher.repoprompt.ce\n"
            "SIGNING_TEAM_ID=648A27MST5\n",
            encoding="utf-8",
        )
        enclosure = self.asset_dir / "RepoPrompt-fixture-37.zip"
        enclosure.write_bytes(b"fixture enclosure bytes\n")
        artifact_manifest = self.asset_dir / "artifact-manifest.json"
        artifact_manifest.write_text('{"schema_version":1}\n', encoding="utf-8")
        appcast = self.asset_dir / "appcast.xml"
        rollout_manifest = self.asset_dir / "identity-rollout.json"
        result = subprocess.run(
            [
                sys.executable,
                str(ROLLOUT_TOOL),
                "generate",
                "--declaration",
                str(declaration),
                "--policy",
                str(POLICY),
                "--version-env",
                str(version_env),
                "--release-tag",
                TAG,
                "--release-commit",
                COMMIT,
                "--migration-phase",
                "legacy-preparer",
                "--enclosure",
                str(enclosure),
                "--enclosure-basename",
                "RepoPrompt-fixture-37",
                "--enclosure-signature",
                "fixture-signature",
                "--app-artifact-manifest",
                str(artifact_manifest),
                "--appcast-output",
                str(appcast),
                "--manifest-output",
                str(rollout_manifest),
            ],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [artifact_manifest, appcast, rollout_manifest, enclosure], declaration

    def _release(self, *, draft: bool = False) -> dict[str, object]:
        release: dict[str, object] = {
            "id": 101,
            "tag_name": TAG,
            "target_commitish": "main",
            "name": TITLE,
            "body": NOTES,
            "draft": draft,
            "prerelease": False,
            "assets": [],
        }
        records = []
        for index, path in enumerate(self.assets, start=1):
            data = path.read_bytes()
            records.append(
                {
                    "name": path.name,
                    "state": "uploaded",
                    "url": f"https://api.github.com/repos/{UPDATE_REPOSITORY}/releases/assets/{index}",
                    "browser_download_url": (
                        f"https://github.com/{UPDATE_REPOSITORY}/releases/download/{TAG}/{path.name}"
                    ),
                    "size": len(data),
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                }
            )
        release["assets"] = records
        return release

    def _run(self, scenario: str, release: dict[str, object] | None) -> subprocess.CompletedProcess[str]:
        self.state_path.write_text(
            json.dumps(
                {
                    "scenario": scenario,
                    "release": release,
                    "lookup_args": [],
                    "mutations": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin_dir}:{environment['PATH']}",
                "PUBLISHER_STUB_STATE": str(self.state_path),
                "PUBLISHER_ASSET_DIR": str(self.asset_dir),
                "PUBLISHER_STABLE_APPCAST": str(self.stable_appcast),
                "PUBLISHER_STABLE_FEED_URL": policy["sparkle"]["stableFeedURL"],
                "TIP_GH_TOKEN": "fixture-token",
                "TIP_UPDATE_REPOSITORY": UPDATE_REPOSITORY,
                "TIP_SOURCE_REPOSITORY": SOURCE_REPOSITORY,
                "TIP_SOURCE_BRANCH": "main",
                "TIP_COMMIT": COMMIT,
                "TIP_TAG": TAG,
                "TIP_BUILD_NUMBER": "37",
                "TIP_PUBLISH_INSTALLATION_TYPE": "application",
                "TIP_EXPECTED_ROLLOUT_ROLE": "preparer",
                "TIP_EXPECTED_SIGNING_IDENTITY": "legacy",
                "TIP_EXPECTED_MIGRATION_PHASE": "legacy-preparer",
                "TIP_RELEASE_TITLE": TITLE,
                "TIP_RELEASE_NOTES": NOTES,
            }
        )
        return subprocess.run(
            [
                "bash",
                str(PUBLISHER),
                "--rollout-declaration",
                str(self.declaration),
                *(str(path) for path in self.assets),
            ],
            cwd=ROOT_DIR,
            env=environment,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def _state(self) -> dict[str, object]:
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def assert_compatible_lookup(self, state: dict[str, object]) -> None:
        lookups = state["lookup_args"]
        self.assertTrue(lookups)
        for arguments in lookups:
            self.assertIn("--paginate", arguments)
            self.assertNotIn("--slurp", arguments)
            self.assertNotIn("--jq", arguments)

    def test_existing_release_on_later_page_is_reused_without_mutation(self) -> None:
        result = self._run("existing", self._release())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("was already public and is byte-exact", result.stdout)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assert_compatible_lookup(state)

    def test_absent_release_creates_empty_draft_then_reobserves_and_publishes(self) -> None:
        result = self._run("absent", None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("published and audited Tip release", result.stdout)
        state = self._state()
        self.assertEqual(state["mutations"][0], "create")
        self.assertEqual(
            sorted(value for value in state["mutations"] if value.startswith("upload:")),
            sorted(f"upload:{path.name}" for path in self.assets),
        )
        self.assertEqual(state["mutations"][-1], "publish")
        self.assertFalse(state["release"]["draft"])
        self.assert_compatible_lookup(state)

    def test_lookup_command_failure_fails_closed_before_draft_creation(self) -> None:
        result = self._run("lookup-error", None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Authenticated Tip release lookup failed", result.stderr)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assert_compatible_lookup(state)

    def test_duplicate_tag_across_pages_fails_closed_without_mutation(self) -> None:
        result = self._run("duplicate", self._release())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate release tag", result.stderr)
        self.assertIn("Authenticated Tip release lookup failed", result.stderr)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assert_compatible_lookup(state)


if __name__ == "__main__":
    unittest.main()
