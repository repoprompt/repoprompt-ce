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

    def test_only_lightweight_tip_jobs_have_new_timeouts(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        sections = re.split(r"^  ([A-Za-z_][\w-]*):\n", workflow.split("\njobs:\n", 1)[1], flags=re.M)
        jobs = dict(zip(sections[1::2], sections[2::2]))
        bounded = {name for name, job in jobs.items() if "timeout-minutes:" in job}
        self.assertEqual(bounded, {"setup", "result"})
        for name in bounded:
            self.assertIn("runs-on: ubuntu-latest", jobs[name])
            self.assertIn("timeout-minutes: 10", jobs[name])

    def test_workflow_preflight_and_publisher_share_source_authority_contract(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        credential_preflight = workflow.split("\n  credential-preflight:", 1)[1].split(
            "\n  stage:", 1
        )[0]
        publish = workflow.split("\n  publish:", 1)[1]
        for section in (credential_preflight, publish):
            self.assertIn("TIP_SOURCE_GH_TOKEN: ${{ github.token }}", section)
        self.assertIn(
            './trusted-control-plane/Scripts/verify_tip_source_commit.sh --allow-ancestor "credential preflight"',
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
        self.api_calls = self.root / "api-calls"
        self.ci_runs = self.root / "ci-runs.json"
        self.event_path = self.root / "github event.json"
        self.published_manifest = self.root / "published-tip.json"
        self.latest_manifest = self.root / "latest-tip.json"
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
            "GITHUB_REPOSITORY": SOURCE_REPOSITORY,
            "GITHUB_EVENT_PATH": str(self.event_path),
            "TIP_UPDATE_REPOSITORY": UPDATE_REPOSITORY,
            "ADMISSION_HTTP_CALLS": str(self.http_calls),
            "ADMISSION_APPCAST": str(self.appcast),
            "ADMISSION_STABLE_FEED_URL": json.loads(POLICY.read_text())["sparkle"]["stableFeedURL"],
            "ADMISSION_CURL_STATUS": "0",
            "ADMISSION_CI_RUNS": str(self.ci_runs),
            "ADMISSION_API_CALLS": str(self.api_calls),
            "ADMISSION_API_STATUS": "0",
            "ADMISSION_PUBLISHED_MANIFEST": str(self.published_manifest),
            "ADMISSION_LATEST_MANIFEST": str(self.latest_manifest),
            "ADMISSION_PUBLISHED_STATUS": "404",
            "ADMISSION_LATEST_STATUS": "404",
        }
        curl_stub = r'''#!/usr/bin/env python3
import os
import shutil
import sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["ADMISSION_HTTP_CALLS"]).open("a") as calls:
    calls.write("curl\n")
status = int(os.environ["ADMISSION_CURL_STATUS"])
if status:
    print("fixture HTTP/auth failure", file=sys.stderr)
    raise SystemExit(status)
url = next(arg for arg in args if arg.startswith("https://"))
output = args[args.index("--output") + 1]
if url.endswith("/identity-rollout.json"):
    key = "LATEST" if "/releases/latest/download/" in url else "PUBLISHED"
    status = os.environ[f"ADMISSION_{key}_STATUS"]
    if status == "200":
        shutil.copyfile(os.environ[f"ADMISSION_{key}_MANIFEST"], output)
    else:
        Path(output).write_text("not found\n")
    print(status, end="")
elif os.environ["ADMISSION_STABLE_FEED_URL"] == url and "--fail" in args:
    shutil.copyfile(os.environ["ADMISSION_APPCAST"], output)
else:
    raise SystemExit("unexpected admission HTTP request")
'''
        PublishTipReleaseTests._write_executable(self.bin_dir / "curl", curl_stub)
        gh_stub = r'''#!/usr/bin/env python3
import os
import sys
from pathlib import Path
args = sys.argv[1:]
if len(args) != 2 or args[0] != "api" or "actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=100&page=" not in args[1]:
    raise SystemExit("unexpected admission GitHub API request")
with Path(os.environ["ADMISSION_API_CALLS"]).open("a") as calls:
    calls.write(args[1] + "\n")
status = int(os.environ["ADMISSION_API_STATUS"])
if status:
    raise SystemExit(status)
print(Path(os.environ["ADMISSION_CI_RUNS"]).read_text())
'''
        PublishTipReleaseTests._write_executable(self.bin_dir / "gh", gh_stub)
        self._git(self.root, "init", "-q", "-b", "main", str(self.source))
        (self.source / "Scripts").mkdir()
        for path in (ROLLOUT_TOOL, POLICY, SCRIPT_DIR / "tip_ci_selection.py"):
            shutil.copyfile(path, self.source / "Scripts" / path.name)
        for name in ("tip-rollout.json", "version.env"):
            shutil.copyfile(ROOT_DIR / name, self.source / name)
        self._git(self.source, "add", ".")
        self._git(self.source, "commit", "-qm", "tested candidate")
        self.candidate = self._git(self.source, "rev-parse", "HEAD")
        self.write_ci_runs(self.candidate)
        (self.source / "advance").write_text("new protected main\n", encoding="utf-8")
        self._git(self.source, "add", ".")
        self._git(self.source, "commit", "-qm", "advance main")
        self.advanced = self._git(self.source, "rev-parse", "HEAD")
        self._git(self.root, "clone", "-q", str(self.source), str(self.checkout))
        self._git(self.checkout, "checkout", "-q", "--detach", self.candidate)
        # The checkout starts with an old origin/main: admission must fetch it.
        self._git(self.checkout, "update-ref", "refs/remotes/origin/main", self.candidate)
        self._git(self.source, "update-ref", "refs/heads/main", self.candidate)

    def write_ci_runs(self, *commits: str) -> None:
        runs = [{
            "id": 123 + index,
            "run_attempt": 2,
            "head_sha": commit,
            "head_branch": "main",
            "event": "push",
            "status": "completed",
            "conclusion": "success",
            "path": ".github/workflows/ci.yml",
            "repository": {"full_name": SOURCE_REPOSITORY},
            "head_repository": {"full_name": SOURCE_REPOSITORY},
        } for index, commit in enumerate(commits)]
        self.ci_runs.write_text(json.dumps({"total_count": len(runs), "workflow_runs": runs}))

    def publication(self, commit: str, *, latest: bool = False, **overrides) -> None:
        tag = f"tip-{commit[:12]}"
        manifest = {
            "schemaVersion": 1,
            "channel": "tip",
            "releaseCommit": commit,
            "sourceTag": tag,
            "buildNumber": "36.0.1",
            "updateRepository": UPDATE_REPOSITORY,
            "appcastItems": [{"tag": tag, "buildNumber": "36.0.1"}],
            **overrides,
        }
        (self.latest_manifest if latest else self.published_manifest).write_text(json.dumps(manifest))

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
        self.api_calls.write_text("", encoding="utf-8")
        environment = {
            **self.environment,
            "EVENT_NAME": "workflow_run",
            # Unlike the tested SHA, github.sha can point at newer main.
            "DISPATCH_COMMIT": self.advanced,
            "DISPATCH_REF": "refs/heads/main",
            "WORKFLOW_RUN_COMMIT": self.candidate,
            "WORKFLOW_RUN_EVENT": "push",
            "WORKFLOW_RUN_BRANCH": "main",
            "WORKFLOW_RUN_REPOSITORY": SOURCE_REPOSITORY,
            "WORKFLOW_RUN_PATH": ".github/workflows/ci.yml",
            "WORKFLOW_RUN_CONCLUSION": "success",
            "WORKFLOW_DEFINITION_COMMIT": self.candidate,
            **overrides,
        }
        self.event_path.write_text(json.dumps({
            "action": "completed",
            "repository": {"full_name": SOURCE_REPOSITORY},
            "workflow_run": {
                "id": 100,
                "run_attempt": 2,
                "head_sha": environment["WORKFLOW_RUN_COMMIT"],
                "head_branch": environment["WORKFLOW_RUN_BRANCH"],
                "event": environment["WORKFLOW_RUN_EVENT"],
                "status": "completed",
                "conclusion": environment["WORKFLOW_RUN_CONCLUSION"],
                "path": environment["WORKFLOW_RUN_PATH"],
                "repository": {"full_name": SOURCE_REPOSITORY},
                "head_repository": {"full_name": environment["WORKFLOW_RUN_REPOSITORY"]},
            },
        }))
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
        self.assertEqual(outputs["ci-run"], "123")
        self.assertEqual(outputs["ci-attempt"], "2")
        self.assertEqual(self.http_calls.read_text(), "curl\n" * 3)

    def test_newer_untested_main_keeps_passing_source_and_pins_current_tooling(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        for tooling in (self.candidate, self.advanced):
            with self.subTest(tooling=tooling):
                self._git(self.checkout, "checkout", "-q", "--detach", tooling)
                result, outputs = self._run(WORKFLOW_DEFINITION_COMMIT=tooling)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs["eligible"], "true")
                self.assertEqual(outputs["commit"], self.candidate)
                self.assertEqual(outputs["tooling-commit"], self.advanced)
                self.assertEqual(self.http_calls.read_text(), "curl\n" * 3)
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

    def test_late_old_trigger_selects_newest_successful_main_source_at_setup(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.write_ci_runs(self.advanced, self.candidate)
        result, outputs = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["commit"], self.advanced)
        self.assertEqual(outputs["tooling-commit"], self.advanced)
        self.assertEqual(outputs["ci-run"], "123")
        self.assertEqual(outputs["build-number"], "36.0.2")

    def test_successful_trigger_not_yet_listed_does_not_select_older_source(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        result, outputs = self._run(WORKFLOW_RUN_COMMIT=self.advanced)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "true")
        self.assertEqual(outputs["commit"], self.advanced)
        self.assertEqual(outputs["tooling-commit"], self.advanced)
        self.assertEqual(outputs["ci-run"], "100")
        self.assertEqual(outputs["ci-attempt"], "2")
        self.assertEqual(outputs["build-number"], "36.0.2")

    def test_stale_manual_dispatch_remains_rejected(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.assert_rejected(
            "Manual Tip source and workflow tooling must match",
            EVENT_NAME="workflow_dispatch", DISPATCH_COMMIT=self.candidate,
        )

    def test_automatic_trigger_must_itself_be_successful_source_main_push_ci(self) -> None:
        for overrides in (
            {"WORKFLOW_RUN_EVENT": "pull_request"},
            {"WORKFLOW_RUN_BRANCH": "feature"},
            {"WORKFLOW_RUN_REPOSITORY": "fork/repo"},
            {"WORKFLOW_RUN_PATH": ".github/workflows/release.yml"},
            {"WORKFLOW_RUN_CONCLUSION": "failure"},
        ):
            with self.subTest(overrides=overrides):
                self.assert_rejected("Automatic Tip requires successful", **overrides)
                self.assertEqual(self.api_calls.read_text(), "")
                self.assertEqual(self.http_calls.read_text(), "")

    def test_empty_ci_lookup_keeps_authenticated_trigger_without_selecting_untested_main(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.write_ci_runs()
        result, outputs = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "true")
        self.assertEqual(outputs["commit"], self.candidate)
        self.assertEqual(outputs["tooling-commit"], self.advanced)
        self.assertEqual(outputs["ci-run"], "100")
        self.assertEqual(outputs["ci-attempt"], "2")

    def test_authenticated_trigger_does_not_hide_ci_api_failure(self) -> None:
        self.assert_rejected("GitHub main CI lookup failed", ADMISSION_API_STATUS="1")
        self.assertEqual(self.http_calls.read_text(), "")

    def test_already_public_exact_source_is_not_rebuilt(self) -> None:
        self.publication(self.candidate)
        result, outputs = self._run(ADMISSION_PUBLISHED_STATUS="200")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "false")
        self.assertEqual(outputs["outcome"], "already-published")
        self.assertEqual(outputs["commit"], self.candidate)
        self.assertEqual(self.http_calls.read_text(), "curl\n")
        self.assertIn("no rebuild", self.summary.read_text())

    def test_newer_public_main_source_skips_obsolete_candidate_without_rollback(self) -> None:
        self._git(self.source, "update-ref", "refs/heads/main", self.advanced)
        self.publication(self.advanced, latest=True)
        result, outputs = self._run(ADMISSION_LATEST_STATUS="200")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["eligible"], "false")
        self.assertEqual(outputs["outcome"], "newer-published")
        self.assertEqual(self.http_calls.read_text(), "curl\n" * 2)

    def test_publication_errors_and_mismatched_source_are_not_rebuild_authority(self) -> None:
        self.publication(self.advanced)
        self.assert_rejected("different source commit", ADMISSION_PUBLISHED_STATUS="200")
        self.publication(self.candidate, sourceTag="tip-ffffffffffff")
        self.assert_rejected("invalid source binding", ADMISSION_PUBLISHED_STATUS="200")
        self.assert_rejected("Published Tip lookup failed with HTTP 403", ADMISSION_PUBLISHED_STATUS="403")
        self.assert_rejected("Published Tip lookup failed with HTTP 500", ADMISSION_PUBLISHED_STATUS="500")

    def test_malformed_published_manifest_is_a_failure(self) -> None:
        self.published_manifest.write_text("not JSON")
        self.assert_rejected("JSONDecodeError", ADMISSION_PUBLISHED_STATUS="200")

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
        result_header = sections.pop("result").split("    steps:\n", 1)[0]
        self.assertIn("if: always()", result_header)
        self.assertIn("needs: [setup, credential-preflight, stage, sign, compatibility, smoke-no-secrets, publish]", result_header)
        self.assertIn("      eligible: ${{ steps.tip.outputs.eligible }}", setup_header)
        self.assertEqual(set(sections), {"credential-preflight", "stage", "sign", "compatibility", "smoke-no-secrets", "publish"})
        for name, section in sections.items():
            with self.subTest(job=name):
                header = section.split("    steps:\n", 1)[0]
                self.assertIn("    if: needs.setup.outputs.eligible == 'true'\n", header)
                needs = re.search(r"^    needs:([^\n]*)(\n(?:      - [^\n]+\n)*)", header, re.M)
                self.assertIsNotNone(needs)
                self.assertIn("setup", needs.group(0).split())
                self.assertNotIn("continue-on-error:", section)


class ReleaseWorkflowRecoveryTests(unittest.TestCase):
    def job(self, filename: str, name: str) -> str:
        workflow = (ROOT_DIR / ".github/workflows" / filename).read_text()
        match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:\n|\Z)", workflow, re.M | re.S)
        self.assertIsNotNone(match, name)
        return match[1]

    def test_stable_ref_verification_failure_is_not_masked_by_output_echo(self):
        with tempfile.TemporaryDirectory(prefix="release-ref-contract-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            (root / "bin").mkdir()
            output = root / "outputs"
            PublishTipReleaseTests._write_executable(
                root / "Scripts/verify_release_ref.sh",
                '#!/usr/bin/env bash\nprintf "%s\\n" "$VERIFY_SHA"\nexit "$VERIFY_STATUS"\n',
            )
            PublishTipReleaseTests._write_executable(
                root / "bin/git",
                '#!/usr/bin/env bash\nprintf "%s\\n" "$TOOLING_SHA"\nexit "$GIT_STATUS"\n',
            )
            environment = {
                "PATH": f"{root / 'bin'}:/usr/bin:/bin",
                "HOME": str(root),
                "GITHUB_OUTPUT": str(output),
                "RELEASE_TAG": "v1.2.3",
                "VERIFY_SHA": COMMIT,
                "TOOLING_SHA": ADVANCED_COMMIT,
                "VERIFY_STATUS": "0",
                "GIT_STATUS": "0",
            }
            for filename in ("release.yml", "release-promote.yml"):
                job = self.job(filename, "validate-ref")
                self.assertIn("runs-on: ubuntu-latest", job)
                script = textwrap.dedent(job.split("        run: |\n", 1)[1])
                for override in ({"VERIFY_STATUS": "1"}, {"VERIFY_SHA": ""}, {"VERIFY_SHA": "not-a-sha"}, {"GIT_STATUS": "2"}, {}):
                    with self.subTest(workflow=filename, override=override):
                        output.write_text("")
                        result = subprocess.run(
                            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
                            cwd=root, env={**environment, **override}, text=True, capture_output=True, timeout=10,
                        )
                        if override:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertEqual(output.read_text(), "")
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertEqual(output.read_text(), f"commit={COMMIT}\ntooling-commit={ADVANCED_COMMIT}\n")

    def test_release_producers_use_immutable_attempt_names_and_consumers_reuse_outputs(self):
        cases = (
            ("main-tip.yml", "stage", "RepoPrompt-CE-staged-tip", (("sign", "name"),)),
            ("main-tip.yml", "sign", "RepoPrompt-CE-signed-tip", (("compatibility", "artifact-name"), ("smoke-no-secrets", "name"), ("publish", "name"))),
            ("release.yml", "stage", "RepoPrompt-CE-staged-release", (("publish", "name"),)),
            ("release.yml", "publish", "RepoPrompt-CE-signed-release-zip", (("compatibility", "artifact-name"), ("smoke-signed-helper", "name"))),
            ("release-promote.yml", "smoke-reviewed-helper", "reviewed-release-compatibility", (("compatibility", "artifact-name"),)),
        )
        for filename, producer, prefix, consumers in cases:
            with self.subTest(workflow=filename, producer=producer):
                job = self.job(filename, producer)
                self.assertIn("artifact-name: ${{ steps.archive-name.outputs.name }}", job)
                self.assertIn(f"ARTIFACT_NAME: {prefix}-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}", job)
                self.assertIn("name: ${{ steps.archive-name.outputs.name }}", job)
                self.assertIn("retention-days: 7", job)
                self.assertNotIn("overwrite: true", job)
                for consumer, field in consumers:
                    section = self.job(filename, consumer)
                    self.assertIn(f"{field}: ${{{{ needs.{producer}.outputs.artifact-name }}}}", section)
                    if field == "name":
                        self.assertIn(f"PRODUCER_ARTIFACT: ${{{{ needs.{producer}.outputs.artifact-name }}}}", section)
                        self.assertIn('run: test -n "$PRODUCER_ARTIFACT"', section)

    def test_empty_producer_output_cannot_download_all_artifacts(self):
        compatibility = self.job("macos-compatibility.yml", "smoke")
        self.assertIn("PRODUCER_ARTIFACT: ${{ inputs.artifact-name }}", compatibility)
        guard = compatibility.split("      - name: Require an exact producer artifact\n", 1)[1].split("\n      - name:", 1)[0]
        script = guard.split("        run: ", 1)[1].strip()
        for name in ("", "RepoPrompt-CE-signed-tip-123-1"):
            with self.subTest(name=name):
                result = subprocess.run(["bash", "-c", script], env={"PRODUCER_ARTIFACT": name}, timeout=5)
                self.assertEqual(result.returncode == 0, bool(name))

    def test_tip_uses_source_data_separately_from_pinned_trusted_tooling(self):
        for name in ("smoke-no-secrets", "publish"):
            with self.subTest(job=name):
                job = self.job("main-tip.yml", name)
                self.assertIn("ref: ${{ needs.setup.outputs.tooling-commit }}", job)
                self.assertIn("ref: ${{ needs.setup.outputs.commit }}", job)
                self.assertIn("path: approved-source", job)
                self.assertIn("REPOPROMPT_RELEASE_SOURCE_ROOT: ${{ github.workspace }}/approved-source", job)
                self.assertIn("REPOPROMPT_APPROVED_SOURCE_ROOT: ${{ github.workspace }}/approved-source", job)

    def test_tip_result_reports_each_failed_cancelled_or_skipped_prerequisite(self):
        job = self.job("main-tip.yml", "result")
        script = textwrap.dedent(job.split("        run: |\n", 1)[1])
        names = ("setup", "credential-preflight", "stage", "sign", "compatibility", "smoke-no-secrets", "publish")
        with tempfile.TemporaryDirectory(prefix="tip-result-") as directory:
            summary = Path(directory) / "summary"
            def execute(needs, **overrides):
                summary.write_text("")
                environment = {
                    "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin",
                    "NEEDS_JSON": json.dumps(needs),
                    "EVENT_NAME": "workflow_run",
                    "UPSTREAM_CONCLUSION": "success",
                    "GITHUB_STEP_SUMMARY": str(summary),
                    **overrides,
                }
                return subprocess.run(["bash", "-e", "-c", script], env=environment, text=True, capture_output=True, timeout=10)
            needs = {name: {"result": "success", "outputs": {}} for name in names}
            needs["setup"]["outputs"] = {"eligible": "true", "outcome": "qualified", "commit": COMMIT, "tag": TAG}
            result = execute(needs)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Tip published", summary.read_text())
            for name in names:
                for state in ("failure", "cancelled", "skipped"):
                    with self.subTest(job=name, state=state):
                        needs[name]["result"] = state
                        result = execute(needs)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(f"| {name} | {state} |", summary.read_text())
                        self.assertIn("Re-run failed jobs", summary.read_text())
                        needs[name]["result"] = "success"
            for name in names:
                needs[name]["result"] = "skipped"
            result = execute(needs, UPSTREAM_CONCLUSION="failure")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("blocked by upstream CI", summary.read_text())
            needs["setup"]["result"] = "success"
            for outcome in ("already-published", "newer-published"):
                needs["setup"]["outputs"].update(eligible="false", outcome=outcome)
                result = execute(needs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Tip already published", summary.read_text())
            needs["setup"]["outputs"]["outcome"] = "unknown-skip"
            self.assertNotEqual(execute(needs).returncode, 0)


if __name__ == "__main__":
    unittest.main()
