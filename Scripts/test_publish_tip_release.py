#!/usr/bin/env python3
"""Hermetic process-level regression coverage for Tip release publication."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
PUBLISHER = SCRIPT_DIR / "publish_tip_release.sh"
ROLLOUT_TOOL = SCRIPT_DIR / "stable_rollout.py"
POLICY = SCRIPT_DIR / "apple_identity_policy.json"
WORKFLOW = ROOT_DIR / ".github" / "workflows" / "main-tip.yml"
TIP_ORCHESTRATOR = SCRIPT_DIR / "main_tip_release.sh"

COMMIT = "a" * 40
ADVANCED_COMMIT = "b" * 40
TAG = "tip-aaaaaaaaaaaa"
SOURCE_REPOSITORY = "repoprompt/repoprompt-ce"
UPDATE_REPOSITORY = "repoprompt/repoprompt-ce-tip-updates"
TITLE = "RepoPrompt CE Tip fixture"
NOTES = "Hermetic publisher regression fixture."

GH_STUB = r'''#!/usr/bin/env python3
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


def form_fields():
    values = {}
    index = 0
    while index < len(args) - 1:
        flag = args[index]
        if flag not in {"-f", "-F"}:
            index += 1
            continue
        key, value = args[index + 1].split("=", 1)
        if flag == "-F" and value in {"true", "false"}:
            value = value == "true"
        values[key] = value
        index += 2
    return values


if not os.environ.get("GH_TOKEN"):
    raise SystemExit("missing GH_TOKEN")

if args[:2] == ["api", "--paginate"]:
    state["lookup_args"].append(args)
    if "create" in state["mutations"]:
        state["tag_list_lookups_after_create"] += 1
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

if args[:3] == ["api", "--method", "POST"]:
    expected_path = f"/repos/{os.environ['TIP_UPDATE_REPOSITORY']}/releases"
    if args[3] != expected_path:
        raise SystemExit(f"unexpected fixture release creation path: {args[3]}")
    if state.get("release") is not None:
        raise SystemExit("fixture release already exists")
    fields = form_fields()
    state["mutations"].append("create")
    state["release"] = {
        "id": 101,
        "tag_name": fields["tag_name"],
        "target_commitish": fields["target_commitish"],
        "name": fields["name"],
        "body": fields["body"],
        "draft": fields["draft"],
        "prerelease": fields["prerelease"],
        "assets": [],
    }
    save()
    print(json.dumps(state["release"]))
    raise SystemExit(0)

if args[:2] == ["api", f"/repos/{os.environ['TIP_UPDATE_REPOSITORY']}/releases/101"]:
    print(json.dumps(state["release"]))
    raise SystemExit(0)

if args and args[0] == "api" and "Accept: application/octet-stream" in args:
    api_url = args[-1]
    for asset in state["release"]["assets"]:
        if asset["url"] == api_url:
            sys.stdout.buffer.write((asset_dir / asset["name"]).read_bytes())
            raise SystemExit(0)
    raise SystemExit(f"unknown fixture asset API URL: {api_url}")

if args[:3] == ["api", "--method", "PATCH"]:
    state["mutations"].append("publish")
    state["release"]["draft"] = False
    save()
    print(json.dumps(state["release"]))
    raise SystemExit(0)

raise SystemExit(f"unsupported gh invocation: {args!r}")
'''

CURL_STUB = r'''#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

args = sys.argv[1:]
state = json.loads(Path(os.environ["PUBLISHER_STUB_STATE"]).read_text(encoding="utf-8"))
asset_dir = Path(os.environ["PUBLISHER_ASSET_DIR"])
# Inspect the actual argv before decoding the private config for fixture auth.
for token_name in ("TIP_GH_TOKEN", "TIP_SOURCE_GH_TOKEN"):
    token = os.environ.get(token_name)
    if token and any(token in argument for argument in args):
        raise SystemExit("bearer token must not appear in curl argv")
if "--config" in args:
    config = Path(args[args.index("--config") + 1])
    if config.stat().st_mode & 0o777 != 0o600 or config.parent.stat().st_mode & 0o777 != 0o700:
        raise SystemExit("curl config must be private")
    state.setdefault("curl_configs", []).append(str(config))
    Path(os.environ["PUBLISHER_STUB_STATE"]).write_text(json.dumps(state))
    import shlex
    args += shlex.split(config.read_text())[2:]
output = Path(args[args.index("--output") + 1])
urls = [argument for argument in args if argument.startswith("https://")]
if not urls:
    raise SystemExit(f"missing fixture URL: {args!r}")
url = urls[-1]
status = "200"

if url.startswith(f"https://api.github.com/repos/{os.environ['TIP_UPDATE_REPOSITORY']}/releases/"):
    expected = f"Authorization: Bearer {os.environ['TIP_GH_TOKEN']}"
    if expected not in args:
        output.write_text('{"message":"API rate limit exceeded"}')
        print("403", end="")
        raise SystemExit(0)
    if state["scenario"] == "metadata-denied":
        output.write_text('{"message":"Forbidden"}')
        print("403", end="")
        raise SystemExit(0)
    if url.endswith("/releases/latest") and "publish" in state["mutations"]:
        state["latest_polls"] = state.get("latest_polls", 0) + 1
        Path(os.environ["PUBLISHER_STUB_STATE"]).write_text(json.dumps(state))
        if state["scenario"] == "latest-stale" or (
            state["scenario"] == "latest-lag" and state["latest_polls"] < 3
        ):
            output.write_text('{"tag_name":"tip-bbbbbbbbbbbb"}')
            print("200", end="")
            raise SystemExit(0)
elif url.startswith("https://github.com/"):
    if any("Authorization:" in argument for argument in args):
        raise SystemExit("public download must remain anonymous")

if url.startswith("https://uploads.github.com/"):
    expected = f"Authorization: Bearer {os.environ['TIP_GH_TOKEN']}"
    if expected not in args:
        raise SystemExit("fixture asset upload was not authenticated")
    path = Path(args[args.index("--data-binary") + 1].removeprefix("@"))
    data = path.read_bytes()
    name = path.name
    index = len(state["release"]["assets"]) + 1
    state["mutations"].append(f"upload:{name}")
    state["release"]["assets"].append(
        {
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
    )
    Path(os.environ["PUBLISHER_STUB_STATE"]).write_text(
        json.dumps(state, indent=2) + "\n", encoding="utf-8"
    )
    output.write_text(json.dumps(state["release"]["assets"][-1]), encoding="utf-8")
    status = "201"
elif url.endswith("/commits/main"):
    expected = f"Authorization: Bearer {os.environ['PUBLISHER_EXPECTED_SOURCE_TOKEN']}"
    authenticated = expected in args
    state.setdefault("source_lookup_auth", []).append(authenticated)
    Path(os.environ["PUBLISHER_STUB_STATE"]).write_text(
        json.dumps(state, indent=2) + "\n", encoding="utf-8"
    )
    if authenticated:
        output.write_text(json.dumps({"sha": os.environ["PUBLISHER_LIVE_MAIN"]}), encoding="utf-8")
    else:
        output.write_text(json.dumps({"message": "fixture authorization denied"}), encoding="utf-8")
        status = "403"
elif "/compare/" in url:
    expected = f"Authorization: Bearer {os.environ['PUBLISHER_EXPECTED_SOURCE_TOKEN']}"
    authenticated = expected in args
    state.setdefault("source_lookup_auth", []).append(authenticated)
    Path(os.environ["PUBLISHER_STUB_STATE"]).write_text(
        json.dumps(state, indent=2) + "\n", encoding="utf-8"
    )
    if not authenticated:
        output.write_text(json.dumps({"message": "fixture authorization denied"}), encoding="utf-8")
        status = "403"
    elif state["scenario"] == "diverged-source":
        output.write_text(
            json.dumps({"status": "diverged", "merge_base_commit": {"sha": "c" * 40}}),
            encoding="utf-8",
        )
    else:
        output.write_text(
            json.dumps({"status": "ahead", "merge_base_commit": {"sha": os.environ["TIP_COMMIT"]}}),
            encoding="utf-8",
        )
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
        self._write_executable(self.bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
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

    def _run(
        self,
        scenario: str,
        release: dict[str, object] | None,
        *,
        source_token: str | None = 'fixture-source"-token\\',
        update_token: str = 'fixture-update"-token\\',
        live_main: str = COMMIT,
    ) -> subprocess.CompletedProcess[str]:
        self.state_path.write_text(
            json.dumps(
                {
                    "scenario": scenario,
                    "release": release,
                    "lookup_args": [],
                    "mutations": [],
                    "source_lookup_auth": [],
                    "tag_list_lookups_after_create": 0,
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
                "TIP_GH_TOKEN": update_token,
                "PUBLISHER_EXPECTED_SOURCE_TOKEN": 'fixture-source"-token\\',
                "PUBLISHER_LIVE_MAIN": live_main,
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
        if source_token is None:
            environment.pop("TIP_SOURCE_GH_TOKEN", None)
        else:
            environment["TIP_SOURCE_GH_TOKEN"] = source_token
        result = subprocess.run(
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
        for config in self._state().get("curl_configs", []):
            self.assertFalse(Path(config).exists(), "curl config survived script exit")
        for token_name in ("TIP_GH_TOKEN", "TIP_SOURCE_GH_TOKEN"):
            token = environment.get(token_name)
            if token:
                self.assertNotIn(token, result.stdout + result.stderr)
        return result

    def _state(self) -> dict[str, object]:
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def assert_compatible_lookup(self, state: dict[str, object]) -> None:
        lookups = state["lookup_args"]
        self.assertTrue(lookups)
        for arguments in lookups:
            self.assertIn("--paginate", arguments)
            self.assertNotIn("--slurp", arguments)
            self.assertNotIn("--jq", arguments)

    def test_config_line_breaks_are_rejected_before_curl(self) -> None:
        for arguments, message in (({"update_token": "fixture\ninvalid"}, "Invalid Tip token"),
                                   ({"source_token": "fixture\rinvalid"}, "Invalid source token")):
            with self.subTest(message=message):
                result = self._run("existing", self._release(), **arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self._state().get("curl_configs", []), [])
                self.assertEqual(self._state()["mutations"], [])

    def test_existing_release_on_later_page_is_reused_without_mutation(self) -> None:
        result = self._run("existing", self._release())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("was already public and is byte-exact", result.stdout)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assertTrue(state["source_lookup_auth"])
        self.assertTrue(all(state["source_lookup_auth"]))
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
        self.assertEqual(state["tag_list_lookups_after_create"], 0)
        self.assert_compatible_lookup(state)

    def test_metadata_authorization_failure_stops_before_mutation(self) -> None:
        result = self._run("metadata-denied", None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Live Tip release lookup failed with HTTP 403", result.stderr)
        self.assertEqual(self._state()["mutations"], [])

    def test_latest_pointer_converges_after_publication(self) -> None:
        result = self._run("latest-lag", None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._state()["latest_polls"], 3)

    def test_latest_pointer_never_converges_fails_after_bounded_reads(self) -> None:
        result = self._run("latest-stale", None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("after bounded convergence", result.stderr)
        self.assertEqual(self._state()["latest_polls"], 7)
        self.assertEqual(self._state()["mutations"].count("publish"), 1)

    def test_existing_empty_draft_resumes_by_release_id_and_publishes(self) -> None:
        release = self._release(draft=True)
        release["assets"] = []
        result = self._run("existing", release)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self._state()
        self.assertNotIn("create", state["mutations"])
        self.assertEqual(
            sorted(value for value in state["mutations"] if value.startswith("upload:")),
            sorted(f"upload:{path.name}" for path in self.assets),
        )
        self.assertEqual(state["mutations"][-1], "publish")
        self.assertFalse(state["release"]["draft"])

    def test_candidate_may_publish_after_main_advances_when_it_remains_an_ancestor(self) -> None:
        result = self._run("absent", None, live_main=ADVANCED_COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("remains an ancestor of protected main", result.stdout)
        state = self._state()
        self.assertEqual(state["mutations"][0], "create")
        self.assertEqual(state["mutations"][-1], "publish")
        self.assertTrue(all(state["source_lookup_auth"]))

    def test_candidate_outside_live_main_ancestry_fails_before_mutation(self) -> None:
        result = self._run("diverged-source", None, live_main=ADVANCED_COMMIT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside protected-main ancestry", result.stderr)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assertTrue(all(state["source_lookup_auth"]))

    def test_lookup_command_failure_fails_closed_before_draft_creation(self) -> None:
        result = self._run("lookup-error", None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Authenticated Tip release lookup failed", result.stderr)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assert_compatible_lookup(state)

    def test_missing_source_token_fails_before_remote_lookup_or_mutation(self) -> None:
        result = self._run("absent", None, source_token=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required environment variable: TIP_SOURCE_GH_TOKEN", result.stderr)
        state = self._state()
        self.assertEqual(state["source_lookup_auth"], [])
        self.assertEqual(state["mutations"], [])

    def test_rejected_source_token_reports_github_error_before_mutation(self) -> None:
        result = self._run("absent", None, source_token="wrong-source-token")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Protected-main lookup failed with HTTP 403: fixture authorization denied",
            result.stderr,
        )
        state = self._state()
        self.assertEqual(state["source_lookup_auth"], [False])
        self.assertEqual(state["mutations"], [])

    def test_tip_workflow_does_not_set_explicit_job_timeouts(self) -> None:
        timeout_lines = [
            line.strip()
            for line in WORKFLOW.read_text(encoding="utf-8").splitlines()
            if line.split("#", 1)[0].partition(":")[0].strip() == "timeout-minutes"
        ]
        self.assertEqual(timeout_lines, [])

    def test_workflow_preflight_and_publisher_share_source_authority_contract(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        credential_preflight = workflow.split("\n  credential-preflight:", 1)[1].split(
            "\n  stage:", 1
        )[0]
        publish = workflow.split("\n  publish:", 1)[1]
        for section in (credential_preflight, publish):
            self.assertIn("TIP_SOURCE_GH_TOKEN: ${{ github.token }}", section)
        self.assertIn(
            './trusted-control-plane/Scripts/verify_tip_source_commit.sh "credential preflight"',
            credential_preflight,
        )

        orchestrator = TIP_ORCHESTRATOR.read_text(encoding="utf-8")
        self.assertIn("require_env TIP_SOURCE_GH_TOKEN", orchestrator)
        self.assertIn('TIP_SOURCE_GH_TOKEN="$TIP_SOURCE_GH_TOKEN"', orchestrator)
        publisher = PUBLISHER.read_text(encoding="utf-8")
        self.assertIn('"$SOURCE_COMMIT_VERIFIER" --allow-ancestor "$1"', publisher)

    def test_duplicate_tag_across_pages_fails_closed_without_mutation(self) -> None:
        result = self._run("duplicate", self._release())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate release tag", result.stderr)
        self.assertIn("Authenticated Tip release lookup failed", result.stderr)
        state = self._state()
        self.assertEqual(state["mutations"], [])
        self.assert_compatible_lookup(state)


class TipAdmissionTests(unittest.TestCase):
    """Execute the workflow's admission Bash, not a duplicate decision helper."""

    @classmethod
    def setUpClass(cls) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        step = workflow.split("      - name: Resolve protected main commit\n", 1)[1]
        script = step.split("        run: |\n", 1)[1].split("\n  credential-preflight:", 1)[0]
        cls.admission_script = textwrap.dedent(script)

    def setUp(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory(prefix="tip-admission-")
        self.addCleanup(temporary_directory.cleanup)
        self.root = Path(temporary_directory.name)
        self.source = self.root / "source"
        self.checkout = self.root / "checkout"
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.runner_temp = self.root / "runner"
        self.runner_temp.mkdir()
        self.output = self.root / "output"
        self.summary = self.root / "summary"
        self.http_calls = self.root / "http-calls"
        self.appcast = self.root / "appcast.xml"
        self.appcast.write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            '<channel><item><sparkle:version>36</sparkle:version>'
            '<sparkle:shortVersionString>1.4.0</sparkle:shortVersionString></item></channel></rss>\n',
            encoding="utf-8",
        )
        # Do not inherit credentials, Git hooks/configuration, or signing setup.
        self.environment = {
            "PATH": f"{self.bin_dir}:{Path(sys.executable).parent}:/usr/bin:/bin",
            "HOME": str(self.root),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Tip fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Tip fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.summary),
            "TIP_UPDATE_REPOSITORY": UPDATE_REPOSITORY,
            "ADMISSION_HTTP_CALLS": str(self.http_calls),
            "ADMISSION_APPCAST": str(self.appcast),
            "ADMISSION_STABLE_FEED_URL": json.loads(POLICY.read_text())["sparkle"]["stableFeedURL"],
            "ADMISSION_CURL_STATUS": "0",
        }
        curl_stub = r'''#!/usr/bin/env python3
import os
import shutil
import sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["ADMISSION_HTTP_CALLS"]).open("a") as calls:
    calls.write("curl\n")
if os.environ["ADMISSION_STABLE_FEED_URL"] not in args or "--fail" not in args:
    raise SystemExit("unexpected admission HTTP request")
status = int(os.environ["ADMISSION_CURL_STATUS"])
if status:
    print("fixture HTTP/auth failure", file=sys.stderr)
    raise SystemExit(status)
shutil.copyfile(os.environ["ADMISSION_APPCAST"], args[args.index("--output") + 1])
'''
        PublishTipReleaseTests._write_executable(self.bin_dir / "curl", curl_stub)
        self._git(self.root, "init", "-q", "-b", "main", str(self.source))
        (self.source / "Scripts").mkdir()
        for path in (ROLLOUT_TOOL, POLICY):
            shutil.copyfile(path, self.source / "Scripts" / path.name)
        for name in ("tip-rollout.json", "version.env"):
            shutil.copyfile(ROOT_DIR / name, self.source / name)
        self._git(self.source, "add", ".")
        self._git(self.source, "commit", "-qm", "tested candidate")
        self.candidate = self._git(self.source, "rev-parse", "HEAD")
        (self.source / "advance").write_text("new protected main\n", encoding="utf-8")
        self._git(self.source, "add", ".")
        self._git(self.source, "commit", "-qm", "advance main")
        self.advanced = self._git(self.source, "rev-parse", "HEAD")
        self._git(self.root, "clone", "-q", str(self.source), str(self.checkout))
        self._git(self.checkout, "checkout", "-q", "--detach", self.candidate)
        # The checkout starts with an old origin/main: admission must fetch it.
        self._git(self.checkout, "update-ref", "refs/remotes/origin/main", self.candidate)
        self._git(self.source, "update-ref", "refs/heads/main", self.candidate)

    def _git(self, cwd: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", *arguments], cwd=cwd, env=self.environment,
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def _run(self, **overrides: str) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        self.output.write_text("", encoding="utf-8")
        self.summary.write_text("", encoding="utf-8")
        self.http_calls.write_text("", encoding="utf-8")
        environment = {
            **self.environment,
            "EVENT_NAME": "workflow_run",
            # Unlike the tested SHA, github.sha can point at newer main.
            "DISPATCH_COMMIT": self.advanced,
            "DISPATCH_REF": "refs/heads/main",
            "WORKFLOW_RUN_COMMIT": self.candidate,
            "WORKFLOW_DEFINITION_COMMIT": self.candidate,
            **overrides,
        }
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", self.admission_script],
            cwd=self.checkout, env=environment, text=True, capture_output=True, timeout=10,
        )
        outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        return result, outputs

    def assert_rejected(self, message: str, **overrides: str) -> None:
        result, outputs = self._run(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(outputs, {})
        self.assertNotIn("::notice::", result.stdout)

    def test_current_tested_commit_is_eligible_without_substituting_dispatch_sha(self) -> None:
        result, outputs = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "true")
        self.assertEqual(outputs["commit"], self.candidate)
        self.assertEqual(outputs["tooling-commit"], self.candidate)
        self.assertEqual(outputs["short-sha"], self.candidate[:12])
        self.assertEqual(outputs["tag"], f"tip-{self.candidate[:12]}")
        self.assertEqual(outputs["build-number"], "36.0.1")
        self.assertEqual(self.http_calls.read_text(), "curl\n")

    def test_superseded_tested_commit_skips_before_http_without_release_outputs(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        for tooling in (self.candidate, self.advanced):
            with self.subTest(tooling=tooling):
                self._git(self.checkout, "checkout", "-q", "--detach", tooling)
                result, outputs = self._run(WORKFLOW_DEFINITION_COMMIT=tooling)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs, {"eligible": "false"})
                self.assertEqual(self.http_calls.read_text(), "")
                self.assertIn("::notice::", result.stdout)
                self.assertIn("superseded", result.stdout)
                for commit in (self.candidate, self.advanced):
                    self.assertIn(commit, self.summary.read_text())
                self.assertEqual(self._git(self.checkout, "rev-parse", "origin/main"), self.advanced)

    def test_current_main_dispatch_is_eligible_and_ignores_workflow_run_sha(self) -> None:
        result, outputs = self._run(
            EVENT_NAME="workflow_dispatch", DISPATCH_COMMIT=self.candidate,
            WORKFLOW_RUN_COMMIT="not-a-sha",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "true")
        self.assertEqual(outputs["commit"], self.candidate)

    def test_malformed_event_and_source_inputs_remain_failures(self) -> None:
        cases = (
            ("Unsupported Tip release event", {"EVENT_NAME": "push"}),
            ("Manual Tip dispatch must run from protected main", {
                "EVENT_NAME": "workflow_dispatch", "DISPATCH_REF": "refs/heads/feature",
            }),
            ("full lowercase source commit SHA", {"WORKFLOW_RUN_COMMIT": "A" * 40}),
            ("full lowercase source commit SHA", {"WORKFLOW_RUN_COMMIT": "abc123"}),
            ("full workflow definition SHA", {"WORKFLOW_DEFINITION_COMMIT": "invalid"}),
        )
        for message, overrides in cases:
            with self.subTest(overrides=overrides):
                self.assert_rejected(message, **overrides)
                self.assertEqual(self.http_calls.read_text(), "")

    def test_missing_source_object_remains_a_failure(self) -> None:
        self.assert_rejected("f" * 40, WORKFLOW_RUN_COMMIT="f" * 40)

    def test_tooling_definition_mismatch_is_not_hidden_by_supersession(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.assert_rejected(
            "Checked-out release tooling differs", WORKFLOW_DEFINITION_COMMIT=self.advanced,
        )
        self.assertEqual(self.http_calls.read_text(), "")

    def test_eligible_source_still_requires_same_commit_tooling(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.assert_rejected(
            "Release tooling and selected protected-main source are not the same commit",
            WORKFLOW_RUN_COMMIT=self.advanced,
        )

    def test_candidate_outside_main_ancestry_is_not_benign_supersession(self) -> None:
        self._git(self.checkout, "checkout", "-qb", "unrelated", self.candidate)
        (self.checkout / "outside-main").write_text("unapproved\n", encoding="utf-8")
        self._git(self.checkout, "add", ".")
        self._git(self.checkout, "commit", "-qm", "outside main")
        unrelated = self._git(self.checkout, "rev-parse", "HEAD")
        self.assert_rejected(
            "outside protected-main ancestry", WORKFLOW_RUN_COMMIT=unrelated,
            WORKFLOW_DEFINITION_COMMIT=unrelated,
        )
        self.assertEqual(self.http_calls.read_text(), "")

    def test_fetch_failure_is_not_benign_supersession(self) -> None:
        self._git(self.checkout, "remote", "set-url", "origin", str(self.root / "missing-origin"))
        self.assert_rejected("does not appear to be a git repository")

    def test_http_failure_remains_a_failure(self) -> None:
        self.assert_rejected("fixture HTTP/auth failure", ADMISSION_CURL_STATUS="22")
        self.assertEqual(self.http_calls.read_text(), "curl\n")

    def test_invalid_appcast_remains_a_failure(self) -> None:
        self.appcast.write_text("not XML", encoding="utf-8")
        self.assert_rejected("ERROR:")

    def test_update_repository_policy_mismatch_remains_a_failure(self) -> None:
        self.assert_rejected(
            "does not match the reviewed identity policy", TIP_UPDATE_REPOSITORY="fixture/wrong",
        )
        self.assertEqual(self.http_calls.read_text(), "")

    def test_every_downstream_job_requires_explicit_eligibility_and_setup_dependency(self) -> None:
        # The external Actions scheduler cannot execute locally. This narrow
        # structural guard complements the executable admission outcome tests.
        workflow = WORKFLOW.read_text(encoding="utf-8")
        jobs = re.split(r"^  ([A-Za-z_][\w-]*):\n", workflow.split("\njobs:\n", 1)[1], flags=re.M)
        sections = dict(zip(jobs[1::2], jobs[2::2]))
        setup_header = sections.pop("setup").split("    steps:\n", 1)[0]
        self.assertIn("      eligible: ${{ steps.tip.outputs.eligible }}", setup_header)
        self.assertEqual(set(sections), {"credential-preflight", "stage", "sign", "smoke-no-secrets", "publish"})
        for name, section in sections.items():
            with self.subTest(job=name):
                header = section.split("    steps:\n", 1)[0]
                self.assertIn("    if: needs.setup.outputs.eligible == 'true'\n", header)
                needs = re.search(r"^    needs:([^\n]*)(\n(?:      - [^\n]+\n)*)", header, re.M)
                self.assertIsNotNone(needs)
                self.assertIn("setup", needs.group(0).split())
                self.assertNotIn("continue-on-error:", section)


if __name__ == "__main__":
    unittest.main()
