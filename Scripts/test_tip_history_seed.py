#!/usr/bin/env python3
"""Offline seed-bootstrap regressions. Fixtures are NOT production audit evidence.

OS tools and Ed25519 are injected fakes except the darwin-only real
ditto/codesign test, which only inspects an unsigned fixture and never runs it.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import random
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.dont_write_bytecode = True
import stable_rollout as rollout  # noqa: E402
import tip_history as history  # noqa: E402
import tip_history_admission as admission  # noqa: E402
import tip_history_seed as seed  # noqa: E402

SCRIPTS = Path(__file__).resolve().parent
APPLE_PATH = SCRIPTS / "apple_identity_policy.json"
APPLE = rollout.load_policy(APPLE_PATH)
APP = APPLE["identityTransitionPackage"]["appBundleName"]
REPO = rollout.update_repository(APPLE, "tip")
PINNED_KEY = APPLE["sparkle"]["sparklePublicEdDSAValue"]
PROFILE = "tip-identity-dress-rehearsal-v1"


def fixture_signature(data: bytes) -> str:
    """64-byte stand-in bound to the bytes; verified only by FakeVerifier."""
    return base64.b64encode(hashlib.sha512(data).digest()).decode()


def assessment_plist(verdict=True, source="Notarized Developer ID", **extra) -> str:
    authority = {"assessment:authority:source": source}
    authority.update(extra.pop("authority", {}))
    return plistlib.dumps({"assessment:verdict": verdict, "assessment:authority": authority, **extra}).decode()


def raw_zip(path: Path, entries: list) -> Path:
    """Hand-built ZIP so tests can forge sizes, flags, extras and local headers."""
    out, central = bytearray(), bytearray()
    for e in entries:
        name = e["name"].encode()
        data = e.get("data", b"")
        method = e.get("method", 8 if data else 0)
        if method == 8:
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            payload = compressor.compress(data) + compressor.flush()
        else:
            payload = data
        payload += e.get("trailing", b"")
        size, crc = e.get("size", len(data)), e.get("crc", zlib.crc32(data))
        flags, extra = e.get("flags", 0), e.get("extra", b"")
        mode = {"file": 0o100644, "dir": 0o040755, "link": 0o120755}[e.get("kind", "file")]
        local_name = e.get("local_name", e["name"]).encode()
        offset = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, e.get("local_method", method), 0, 0x21, crc, len(payload), e.get("local_size", size), len(local_name), len(extra)) + local_name + extra + payload
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x031E, 20, flags, method, 0, 0x21, crc, len(payload), size, len(name), len(extra), 0, 0, 0, mode << 16, offset) + name + extra
    out += central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), len(out), 0)
    path.write_bytes(bytes(out))
    return path


def extract_zip(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            target = destination / info.filename
            mode = info.external_attr >> 16
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif stat.S_ISLNK(mode):
                target.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(z.read(info).decode(), target)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(info))


class FakeRunner:
    def __init__(self):
        self.calls = []

    def __call__(self, argv, timeout):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        tool = argv[0]
        ok = subprocess.CompletedProcess(argv, 0, "", "")
        if tool == "/usr/bin/ditto":
            extract_zip(Path(argv[3]), Path(argv[4]))
            return ok
        if tool == "/usr/bin/lipo":
            return subprocess.CompletedProcess(argv, 0, "x86_64 arm64\n", "")
        if tool == "/usr/bin/codesign":
            app = Path(argv[-1])
            bad = (app / "Contents/Resources/FIXTURE_UNSIGNED").exists()
            return subprocess.CompletedProcess(argv, 1 if bad else 0, "", "invalid signature" if bad else "valid on disk")
        if tool == "/usr/sbin/spctl":
            assert argv[1:4] == ["--assess", "--type", argv[3]] and argv[4:7] == ["--raw", "--ignore-cache", "--no-cache"], argv
            target = Path(argv[-1])
            if (target / "Contents/Resources/FIXTURE_NOT_NOTARIZED").exists():
                return subprocess.CompletedProcess(argv, 3, assessment_plist(False, "Unnotarized Developer ID"), "")
            return subprocess.CompletedProcess(argv, 0, assessment_plist(), "")
        if tool == "/usr/sbin/pkgutil" and argv[1] == "--check-signature":
            identity = APPLE["identities"]["successor"]
            return subprocess.CompletedProcess(argv, 0, f"Status: signed by a developer certificate issued by Apple for distribution\n   1. {identity['developerIDInstallerIdentityName']}\n", "")
        if tool == "/usr/bin/xcrun" and argv[1:3] == ["stapler", "validate"]:
            return ok
        raise AssertionError(f"unexpected tool call {argv}")


class FakeVerifier:
    def __init__(self):
        self.reject_tags = set()
        self.keys = set()

    def __call__(self, public_key, signature, path):
        self.keys.add(public_key)
        if path.parent.name in self.reject_tags:
            return False
        return signature == fixture_signature(Path(path).read_bytes())


class SeedFixture:
    """Linear source history plus a published-release snapshot."""

    def __init__(self, root: Path, source: Path, commits: list, *, releases: int = 34, options: dict | None = None, side_commit: str | None = None):
        self.root, self.source, self.commits = root, source, commits
        self.snapshot = root / "snapshot"
        self.assets = self.snapshot / "assets"
        self.assets.mkdir(parents=True)
        self.staging = root / "staging"
        self.staging.mkdir()
        self.options = options or {}
        self.side_commit = side_commit
        self.records = []
        self.manifests = {}
        for index in range(releases):
            self.records.append(self.release(index, **self.options.get(index, {})))
        self.write_records()

    def tag(self, index):
        return "tip-" + self.commit(index)[:12]

    def commit(self, index):
        override = self.options.get(index, {}).get("commit")
        return override or self.commits[index]

    def write_records(self, records=None):
        (self.snapshot / "releases.json").write_text(json.dumps(records if records is not None else self.records), encoding="utf-8")

    @staticmethod
    def make_zip(path: Path, *, bundle_id: str, build: str, executable: bytes, markers=(), absolute_link=False, signing_mode="developer-id"):
        def directory(z, name):
            info = zipfile.ZipInfo(name + "/")
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            z.writestr(info, b"")

        def regular(z, name, data, mode=0o644):
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFREG | mode) << 16
            z.writestr(info, data)

        def link(z, name, target):
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o755) << 16
            z.writestr(info, target)

        plist = plistlib.dumps({"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": "1.0", "CFBundleVersion": build, "CFBundleExecutable": "RepoPrompt", "LSMinimumSystemVersion": "14.0", "RepoPromptSigningMode": signing_mode})
        framework = f"{APP}/Contents/Frameworks/Sparkle.framework"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            for name in (APP, f"{APP}/Contents", f"{APP}/Contents/MacOS", f"{APP}/Contents/Resources", f"{APP}/Contents/Frameworks", framework, f"{framework}/Versions", f"{framework}/Versions/B"):
                directory(z, name)
            regular(z, f"{APP}/Contents/Info.plist", plist)
            regular(z, f"{APP}/Contents/MacOS/RepoPrompt", executable, 0o755)
            regular(z, f"{APP}/Contents/MacOS/repoprompt-mcp", b"helper " + executable, 0o755)
            regular(z, f"{framework}/Versions/B/Sparkle", b"framework bytes", 0o755)
            link(z, f"{framework}/Versions/Current", "B")
            link(z, f"{framework}/Sparkle", "Versions/Current/Sparkle")
            for marker in markers:
                regular(z, f"{APP}/Contents/Resources/{marker}", b"fixture marker")
            if absolute_link:
                link(z, f"{APP}/Contents/Resources/escape", "/etc/passwd")

    @staticmethod
    def write(path: Path, value) -> None:
        path.write_bytes(history.canonical(value))

    def release(self, index, *, role="preparer", build=None, markers=(), absolute_link=False, plist_bundle=None, tamper_zip=False, extra_asset=False, drop_manifest=False, bad_url=False, draft=False, history_asset=False, commit=None, predecessor=None, publish=True, signing_mode=None):
        commit = commit or self.commits[index]
        tag = "tip-" + commit[:12]
        build = build or f"37.0.{index}"
        identity = APPLE["identities"][rollout.ROLE_IDENTITY[role]]
        # Valid fixtures use the committed identity mode map; overrides are negatives.
        signing_mode = signing_mode or rollout.SIGNING_MODE_BY_IDENTITY[rollout.ROLE_IDENTITY[role]]
        stem = f"RepoPrompt-tip-{commit[:12]}-{build}"
        work = self.staging / tag
        work.mkdir()
        executable = f"main executable {index}".encode()
        suffix = rollout.ROLE_ENCLOSURE_SUFFIX[role]
        enclosure = work / f"{stem}{suffix}"
        self.make_zip(enclosure, bundle_id=plist_bundle or identity["bundleIdentifier"], build=build, executable=executable, markers=markers, absolute_link=absolute_link, signing_mode=signing_mode)
        artifact = work / f"{stem}-artifact-manifest.json"
        self.write(artifact, {
            "schema_version": 1,
            "bundle": {"identifier": identity["bundleIdentifier"], "marketing_version": "1.0", "build_number": build, "signing_mode": signing_mode, "architectures": ["arm64", "x86_64"]},
            "bundle_signing": {"team_identifier": identity["teamIdentifier"]},
            "executables": [
                {"path": "Contents/MacOS/RepoPrompt", "architectures": ["arm64", "x86_64"], "sha256": hashlib.sha256(executable).hexdigest()},
                {"path": "Contents/MacOS/repoprompt-mcp", "architectures": ["arm64", "x86_64"], "sha256": hashlib.sha256(b"helper " + executable).hexdigest()},
            ],
        })
        predecessors = []
        if predecessor is not None:
            p = history.read_json(predecessor)
            predecessors = [{"role": p["currentRole"], "tag": p["sourceTag"], "rolloutManifestSha256": rollout.sha256_file(predecessor)}]
        declaration = work / "declaration.json"
        self.write(declaration, {"schemaVersion": 1, "channel": "tip", "currentRole": role, "eligibilityProfile": PROFILE, "expectedMigrationPhase": rollout.ROLE_MIGRATION_PHASE[role], "expectedSigningIdentity": rollout.ROLE_IDENTITY[role], "predecessors": predecessors})
        version = work / "version.env"
        version.write_text(f"APP_NAME=RepoPrompt\nMARKETING_VERSION=1.0\nBUILD_NUMBER={build}\nBUNDLE_ID={identity['bundleIdentifier']}\nSIGNING_TEAM_ID={identity['teamIdentifier']}\n")
        args = argparse.Namespace(policy=str(APPLE_PATH), declaration=str(declaration), version_env=str(version), allowed_roles=None, release_tag=tag, release_commit=commit, migration_phase=rollout.ROLE_MIGRATION_PHASE[role], enclosure=str(enclosure), enclosure_basename=stem, enclosure_signature=fixture_signature(enclosure.read_bytes()), app_artifact_manifest=str(artifact), predecessor_manifest=[str(predecessor)] if predecessor else [])
        manifest, appcast = rollout.build_manifest(args)
        manifest_path = work / seed.ROLLOUT_NAME
        self.write(manifest_path, manifest)
        (work / seed.APPCAST_NAME).write_text(appcast)
        self.write(work / f"{stem}-metadata.json", {"commit": commit, "short_sha": commit[:12], "tag": tag, "marketing_version": "1.0", "build_number": build, "rollout_role": role, "signing_identity": rollout.ROLE_IDENTITY[role], "migration_phase": rollout.ROLE_MIGRATION_PHASE[role]})
        names = [seed.ROLLOUT_NAME, seed.APPCAST_NAME, artifact.name, f"{stem}-metadata.json", enclosure.name]
        if suffix == ".zip":
            (work / f"{stem}.dmg").write_bytes(b"fixture dmg, never fetched")
            names.append(f"{stem}.dmg")
        (work / seed.SUMS_NAME).write_text("".join(f"{rollout.sha256_file(work / n)}  {n}\n" for n in sorted(names)))
        names.append(seed.SUMS_NAME)
        self.manifests[index] = manifest_path
        if not publish:
            return work
        if tamper_zip:
            data = bytearray(enclosure.read_bytes())
            data[-1] ^= 0xFF
            enclosure.write_bytes(bytes(data))
        destination = self.assets / tag
        destination.mkdir()
        assets = []
        for name in sorted(names):
            (destination / name).write_bytes((work / name).read_bytes())
            url = rollout.enclosure_url(REPO, tag, name)
            if bad_url and name == enclosure.name:
                url = f"https://example.invalid/{name}"
            assets.append({"name": name, "size": (work / name).stat().st_size, "state": "uploaded", "browser_download_url": url})
        if extra_asset:
            assets.append({"name": "unexpected.txt", "size": 1, "state": "uploaded", "browser_download_url": rollout.enclosure_url(REPO, tag, "unexpected.txt")})
        if history_asset:
            assets.append({"name": seed.HISTORY_ASSET, "size": 10, "state": "uploaded", "browser_download_url": rollout.enclosure_url(REPO, tag, seed.HISTORY_ASSET)})
        if drop_manifest:
            (destination / seed.ROLLOUT_NAME).unlink()
        return {"tag_name": tag, "draft": draft, "published_at": f"2026-10-{(index % 28) + 1:02d}T00:00:00Z", "immutable": False, "assets": assets}


class SeedTestCase(unittest.TestCase):
    RELEASES = 35  # commits 0...34; 34 is the candidate

    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="tip-seed-git-")
        cls.source = Path(cls.shared.name) / "source"
        cls.source.mkdir()

        def git(*args):
            return subprocess.run(["git", *args], cwd=cls.source, check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        cls.commits = []
        for i in range(cls.RELEASES):
            git("commit", "--allow-empty", "-qm", f"Fixture change {i}")
            cls.commits.append(git("rev-parse", "HEAD"))
        git("checkout", "-q", "-b", "side", cls.commits[10])
        git("commit", "--allow-empty", "-qm", "Unmerged side change")
        cls.side_commit = git("rev-parse", "HEAD")
        git("checkout", "-q", "-")
        cls.candidate = cls.commits[34]
        assert git("rev-parse", "HEAD") == cls.candidate

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tip-seed-data-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.policy = {
            "schemaVersion": 1,
            "historyAdmissionFloorBuild": "37.0.2",
            "historyAdmissionFloorCommit": self.commits[2],
            "historyUIFloorBuild": "37.0.30",
            "historyEnabledSinceTag": None,
            "retention": {"schemaLifetime": 1, "owner": None, "reviewedEvidence": None},
        }
        self.policy_path = self.root / "policy.json"
        self.runner = FakeRunner()
        self.verifier = FakeVerifier()

    def tag(self, index):
        return "tip-" + self.commits[index][:12]

    def fixture(self, **kwargs) -> SeedFixture:
        base = self.root / f"fixture-{len(list(self.root.glob('fixture-*')))}"
        base.mkdir()
        return SeedFixture(base, self.source, self.commits, **kwargs)

    def tools(self, fetch=None):
        return seed.Tools(run=self.runner, verify=self.verifier, fetch=fetch)

    def args(self, fixture, **overrides):
        self.policy_path.write_bytes(history.canonical(self.policy))
        values = {
            "command": "seed-bootstrap", "approved_source": self.source, "policy": self.policy_path,
            "apple_policy": APPLE_PATH, "release_snapshot": fixture.snapshot,
            "candidate_tag": self.tag(34), "candidate_commit": self.candidate, "candidate_build": "37.0.34",
            "expect_live_parent": None, "source_audit": None, "fetch": False, "work_dir": self.work,
            "output": self.root / "bootstrap.json", "report": self.root / "report.json",
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def run_seed(self, fixture, **overrides):
        return seed.run_cli(self.args(fixture, **overrides), self.tools())

    def assert_work_clean(self):
        self.assertEqual(list(self.work.iterdir()) if self.work.exists() else [], [])


class CompleteBootstrapTests(SeedTestCase):
    def test_29_audited_seeds_feed_admission_build_payload_deterministically(self):
        fixture = self.fixture(releases=34)
        result = self.run_seed(fixture)
        self.assertEqual(result.exit_code, 0, result.evidence["blockingGates"])
        evidence = result.evidence
        self.assertEqual(evidence["status"], "complete")
        self.assertEqual([e["tag"] for e in evidence["entries"]], [self.tag(i) for i in range(33, 4, -1)])
        self.assertEqual(evidence["liveParent"], self.tag(33))
        self.assertTrue(evidence["historyNeverEnabled"])
        self.assertEqual(evidence["notEvaluatedCount"], 5)
        self.assertEqual(self.verifier.keys, {PINNED_KEY})
        for position, entry in enumerate(evidence["entries"]):
            self.assertEqual(entry["origin"], "seed")
            self.assertIsNone(entry["historyCatalogSha256"])
            self.assertEqual(entry["download"]["url"], rollout.enclosure_url(REPO, entry["tag"], entry["download"]["name"]))
            self.assertGreater(entry["download"]["expandedSize"], 0)
            expected_from = evidence["entries"][position + 1]["releaseCommit"] if position + 1 < 29 else self.commits[4]
            self.assertEqual(entry["commitRange"]["fromCommit"], expected_from)
            # No external persistence verdict: every seed stays blocked.
            self.assertTrue(entry["downgradeBarrier"])
            self.assertIn(seed.PERSISTENCE_PENDING, entry["downgradeBarrierReasons"])
            self.assertEqual(entry["hasHistoryUI"], rollout.parse_build(entry["buildNumber"], "b") >= (37, 0, 30))
        audit = evidence["seedAudits"][0]
        for check in ("sparkle-eddsa", "enclosure-sha256", "zip-layout", "expanded-size", "executable-digests", "codesign-strict-deep-all-architectures-requirement", "gatekeeper-notarized-execute", "source-ancestry"):
            self.assertIn(check, audit["checks"])
        self.assertEqual(audit["unauditedAssets"], [f"RepoPrompt-tip-{self.commits[33][:12]}-37.0.33.dmg"])
        requirement = APPLE["identities"]["legacy"]["developerIDRequirement"]
        codesign = [c for c in self.runner.calls if c[0] == "/usr/bin/codesign"]
        self.assertTrue(codesign and all(c[1:6] == ["--verify", "--strict", "--deep", "--all-architectures", "--verbose=2"] and c[6] == "-R=" + requirement for c in codesign))
        self.assertTrue(all(c[0] in seed.ALLOWED_TOOLS for c in self.runner.calls))
        self.assert_work_clean()

        written = (self.root / "bootstrap.json").read_bytes()
        self.assertEqual(written, result.evidence_bytes)
        self.assertNotIn(str(self.root).encode(), written)
        report = json.loads((self.root / "report.json").read_text())
        self.assertEqual(report["evidenceSha256"], hashlib.sha256(written).hexdigest())
        self.assertTrue(any("Retention" in gate for gate in report["externalReviewGates"]))
        self.assertTrue(any("29 admitted seed(s) carry" in gate for gate in report["externalReviewGates"]))
        self.assertEqual(len(report["persistenceReviewTemplate"]["intervals"]), 29)
        self.assertTrue(all(item["verdict"] is None for item in report["persistenceReviewTemplate"]["intervals"]))

        # API order/page shape is irrelevant; everything but the snapshot digest is byte-identical.
        shuffled = copy.deepcopy(fixture.records)
        random.Random(7).shuffle(shuffled)
        fixture.write_records([shuffled[:17], shuffled[17:]])  # slurped page shape
        rerun = copy.deepcopy(self.run_seed(fixture).evidence)
        self.assertNotEqual(rerun["inputs"].pop("releaseSnapshotSha256"), evidence["inputs"]["releaseSnapshotSha256"])
        expected = copy.deepcopy(evidence)
        expected["inputs"].pop("releaseSnapshotSha256")
        self.assertEqual(history.canonical(rerun), history.canonical(expected))

        # Compatibility with the sibling admission builder.
        candidate_root = self.root / "candidate"
        candidate_root.mkdir()
        candidate = SeedFixture.__new__(SeedFixture)
        candidate.staging, candidate.commits, candidate.options, candidate.manifests = candidate_root, self.commits, {}, {}
        work = candidate.release(34, publish=False)
        manifest = work / seed.ROLLOUT_NAME
        artifact = next(work.glob("*-artifact-manifest.json"))
        expanded = seed.zip_preflight(next(work.glob("*.zip")), APP)
        policy = dict(self.policy, historyEnabledSinceTag=self.tag(34), bootstrapEvidenceSha256=hashlib.sha256(written).hexdigest(), retention={"schemaLifetime": 1, "owner": "fixture only", "reviewedEvidence": "fixture only, not a live review"})
        head = admission.entry_from_manifest(apple_policy=APPLE, policy=policy, source=self.source, manifest_path=manifest, artifact_path=artifact, notes=history.collect_notes(self.source, self.commits[33], self.commits[34]), expanded_size=expanded)
        payload = json.loads(admission.build_payload(entry=head, apple_policy=APPLE, policy=policy, source=self.source, parent_bytes=None, bootstrap=json.loads(written)))
        self.assertEqual(len(payload["entries"]), 30)
        self.assertEqual(payload["entries"][1:], evidence["entries"])
        self.assertIsNone(payload["olderPage"])

    def test_external_persistence_verdicts_bind_to_exact_intervals(self):
        fixture = self.fixture(releases=6)
        audit_path = self.root / "source-audit.json"
        audit_path.write_bytes(history.canonical({"schemaVersion": 1, "provenance": "fixture only", "intervals": [
            {"tag": self.tag(5), "fromCommit": self.commits[4], "releaseCommit": self.commits[5], "verdict": "no-known-downgrade-break", "reasons": []},
            {"tag": self.tag(4), "fromCommit": self.commits[3], "releaseCommit": self.commits[4], "verdict": "downgrade-break", "reasons": ["Workspace catalog format v3"]},
            {"tag": self.tag(3), "fromCommit": self.commits[1], "releaseCommit": self.commits[3], "verdict": "no-known-downgrade-break", "reasons": []},
            {"tag": self.tag(2), "fromCommit": self.commits[1], "releaseCommit": self.commits[2], "verdict": None, "reasons": []},
        ]}))
        result = self.run_seed(fixture, source_audit=audit_path)
        self.assertEqual(result.evidence["shortfall"], 25)
        entries = {e["tag"]: e for e in result.evidence["entries"]}
        self.assertFalse(entries[self.tag(5)]["downgradeBarrier"])
        self.assertEqual(entries[self.tag(4)]["downgradeBarrierReasons"], ["Workspace catalog format v3"])
        for stale in (3, 2):  # wrong interval / unreviewed template row
            self.assertEqual(entries[self.tag(stale)]["downgradeBarrierReasons"], [seed.PERSISTENCE_PENDING])
        statuses = {a["tag"]: a["persistenceAudit"] for a in result.evidence["seedAudits"]}
        self.assertEqual([statuses[self.tag(i)] for i in (5, 4, 3, 2)], ["reviewed-no-known-break", "reviewed-break", "pending", "pending"])
        self.assertEqual(result.evidence["inputs"]["sourceAuditSha256"], rollout.sha256_file(audit_path))
        self.assertEqual(result.report["persistenceReviewHints"][0], {"tag": self.tag(5), "intervalContinuous": True, "sensitivePathCount": 0, "sensitivePaths": []})
        bad = self.root / "bad-audit.json"
        bad.write_bytes(history.canonical({"schemaVersion": 1, "intervals": [{"tag": self.tag(33), "fromCommit": None, "releaseCommit": self.commits[33], "verdict": "downgrade-break", "reasons": []}]}))
        with self.assertRaisesRegex(history.HistoryError, "require reasons"):
            seed.load_source_audit(bad)


class ExclusionTests(SeedTestCase):
    def test_uncertain_releases_are_excluded_with_exact_shortfall(self):
        options = {
            32: {"tamper_zip": True},
            30: {},  # rejected by the injected Ed25519 verifier
            28: {"markers": ["FIXTURE_UNSIGNED"]},
            26: {"extra_asset": True},
            24: {"drop_manifest": True},
            22: {"absolute_link": True},
            20: {"plist_bundle": "com.attacker.app"},
            18: {"markers": ["FIXTURE_NOT_NOTARIZED"]},
            16: {"bad_url": True},
            14: {"draft": True},
            13: {"build": "37.0.12"},
            11: {"commit": self.side_commit},
            9: {"signing_mode": rollout.SIGNING_MODE_BY_IDENTITY["successor"]},  # wrong mode for a legacy-identity preparer
        }
        fixture = self.fixture(releases=34, options=options)
        self.verifier.reject_tags.add(self.tag(30))
        result = self.run_seed(fixture)
        evidence = result.evidence
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(evidence["status"], "shortfall")
        reasons = {item["tag"]: item["reason"] for item in evidence["excluded"]}
        expected = {
            32: "enclosure SHA-256 differs", 30: "Sparkle EdDSA signature does not verify", 28: "code signature",
            26: "asset inventory mismatch", 24: "unorderable: asset identity-rollout.json is not in the release snapshot",
            22: "absolute or malformed symlink", 20: "app bundle identifier differs", 18: "Gatekeeper assessment",
            16: "download URL is not the exact official URL", 13: "duplicate validated build number",
            12: "duplicate validated build number", 1: "predates the audited history admission floor",
            0: "predates the audited history admission floor",
            9: "signing mode must be developer-id",
        }
        for index, text in expected.items():
            self.assertIn(text, reasons[self.tag(index)], index)
        self.assertIn("not an ancestor", reasons["tip-" + self.side_commit[:12]])
        self.assertNotIn(self.tag(14), reasons)
        admitted = [e["tag"] for e in evidence["entries"]]
        survivors = [i for i in range(33, 1, -1) if i not in expected and i not in (14, 11)]
        self.assertEqual(admitted, [self.tag(i) for i in survivors])
        self.assertEqual(evidence["shortfall"], 29 - len(survivors))
        self.assertTrue(any(f"shortfall {29 - len(survivors)}" in gate for gate in evidence["blockingGates"]))
        by_tag = {e["tag"]: e for e in evidence["entries"]}
        self.assertEqual(by_tag[self.tag(33)]["commitRange"]["fromCommit"], self.commits[31])
        self.assertEqual(by_tag[self.tag(31)]["commitRange"]["fromCommit"], self.commits[29])
        self.assertEqual(by_tag[self.tag(2)]["commitRange"]["fromCommit"], self.commits[1])
        self.assertEqual(result.report["releaseObservations"]["drafts"], 1)
        self.assert_work_clean()
        # A shortfall can never satisfy the admission builder's exact count.
        policy = dict(self.policy, historyEnabledSinceTag=evidence["entries"][0]["tag"], bootstrapEvidenceSha256=hashlib.sha256(result.evidence_bytes).hexdigest())
        with self.assertRaisesRegex(history.HistoryError, f"29 admitted predecessors; found {len(survivors)}"):
            admission.build_payload(entry=evidence["entries"][0], apple_policy=APPLE, policy=dict(policy, retention={"schemaLifetime": 1, "owner": "x", "reviewedEvidence": "x"}), source=self.source, parent_bytes=None, bootstrap=evidence)

    def test_history_activation_candidate_and_live_parent_fences(self):
        fixture = self.fixture(releases=6, options={5: {"history_asset": True}})
        result = self.run_seed(fixture, expect_live_parent=self.tag(4))
        self.assertFalse(result.evidence["historyNeverEnabled"])
        self.assertTrue(any("already carries tip-history.json" in g for g in result.evidence["blockingGates"]))
        self.assertTrue(any("differs from the pinned live parent" in g for g in result.evidence["blockingGates"]))
        self.assertTrue(any("was not admitted" in g for g in result.evidence["blockingGates"]))
        self.assertEqual(result.evidence["status"], "shortfall")
        self.assertEqual(result.exit_code, 2)

        records = copy.deepcopy(fixture.records)
        for record in records:
            record["assets"] = [a for a in record["assets"] if a["name"] != seed.HISTORY_ASSET]
        records[4]["draft"] = True
        records[4]["assets"].append({"name": seed.HISTORY_ASSET, "size": 1, "state": "uploaded", "browser_download_url": rollout.enclosure_url(REPO, records[4]["tag_name"], seed.HISTORY_ASSET)})
        fixture.write_records(records)
        self.policy["historyEnabledSinceTag"] = self.tag(33)
        result = self.run_seed(fixture, candidate_build="37.0.4")
        gates = " | ".join(result.evidence["blockingGates"])
        self.assertTrue(result.evidence["historyNeverEnabled"])
        self.assertEqual(result.report["releaseObservations"]["draftsWithHistory"], 1)
        self.assertIn("37.0.5 >= candidate 37.0.4", gates)
        self.assertIn("historyEnabledSinceTag", gates)

    def test_package_seed_is_provenance_audited_but_never_downloadable(self):
        fixture = self.fixture(releases=3)
        preparer = fixture.manifests[2]
        options = {"role": "transition", "predecessor": preparer, "commit": self.commits[3]}
        fixture.records.append(fixture.release(3, **options))
        fixture.write_records()
        result = self.run_seed(fixture)
        package = result.evidence["entries"][0]
        self.assertEqual((package["tag"], package["role"], package["installationType"], package["download"]), (self.tag(3), "transition", "package", None))
        self.assertEqual(package["bundleIdentifier"], APPLE["identities"]["successor"]["bundleIdentifier"])
        checks = result.evidence["seedAudits"][0]["checks"]
        self.assertEqual(checks[-3:], ["package-installer-signature", "package-stapled", "gatekeeper-notarized-install"])
        package_calls = [c for c in self.runner.calls if c[-1].endswith(".pkg")]
        self.assertEqual(sorted({tuple(c[:2]) for c in package_calls}), [("/usr/bin/xcrun", "stapler"), ("/usr/sbin/pkgutil", "--check-signature"), ("/usr/sbin/spctl", "--assess")])
        self.assertIn("install", [c[3] for c in package_calls if c[0] == "/usr/sbin/spctl"])
        self.assertEqual(result.evidence["shortfall"], 27)
        self.assert_work_clean()


class ArchiveTests(SeedTestCase):
    def make(self, entries):
        path = self.root / f"a{len(list(self.root.glob('a*.zip')))}.zip"
        with zipfile.ZipFile(path, "w") as z:
            for name, data, kind in entries:
                info = zipfile.ZipInfo(name)
                info.external_attr = {"file": stat.S_IFREG | 0o644, "dir": stat.S_IFDIR | 0o755, "link": stat.S_IFLNK | 0o755}[kind] << 16
                z.writestr(info, data)
        return path

    def test_preflight_rejects_escape_layout_and_counts_like_release_script(self):
        good = self.make([(f"{APP}/", b"", "dir"), (f"{APP}/Contents/a", b"12345", "file"), (f"{APP}/Contents/l", b"a", "link")])
        self.assertEqual(seed.zip_preflight(good, APP), 6)
        for entries, message in (
            ([(f"{APP}/../x", b"1", "file")], "layout"),
            ([("/abs", b"1", "file")], "layout"),
            ([("Other.app/x", b"1", "file")], "layout"),
            ([(f"{APP}/x", b"1", "file"), (f"{APP}/x", b"2", "file")], "duplicate"),
            ([(f"{APP}/Contents/l", b"../../../etc", "link")], "escapes"),
            ([(f"{APP}/Contents/l", b"/etc/passwd", "link")], "absolute"),
            ([(f"{APP}/", b"", "dir")], "expanded bounds"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(seed.SeedExclusion, message):
                seed.zip_preflight(self.make(entries), APP)
        not_zip = self.root / "x.zip"
        not_zip.write_bytes(b"not a zip, but at least twenty-two bytes")
        with self.assertRaisesRegex(seed.SeedExclusion, "readable single-disk ZIP"):
            seed.zip_preflight(not_zip, APP)

    def test_adversarial_raw_zip_structures_rejected_before_extraction(self):
        c = f"{APP}/Contents"
        root = [{"name": f"{APP}/", "kind": "dir"}, {"name": f"{c}/", "kind": "dir"}]
        body = b"A" * 5000 + bytes(range(256)) * 40
        good = raw_zip(self.root / "good.zip", root + [{"name": f"{c}/f", "data": body}, {"name": f"{c}/l", "data": b"f", "kind": "link", "method": 0}])
        self.assertEqual(seed.zip_preflight(good, APP), len(body) + 1)
        with zipfile.ZipFile(good) as z:  # sanity: the builder emits standard ZIPs
            self.assertEqual(z.read(f"{c}/f"), body)
        cases = {
            # Forged smaller uncompressed size whose CRC matches the truncated prefix.
            "forged-small-size": ([{"name": f"{c}/f", "data": body, "size": 100, "crc": zlib.crc32(body[:100])}], "exceeds the declared"),
            "forged-large-size": ([{"name": f"{c}/f", "data": body, "size": len(body) + 1}], "shorter than the declared"),
            "crc": ([{"name": f"{c}/f", "data": body, "crc": 1}], "CRC-32"),
            "trailing": ([{"name": f"{c}/f", "data": body, "trailing": b"junk"}], "trailing bytes"),
            "encrypted": ([{"name": f"{c}/f", "data": body, "flags": 1}], "encryption"),
            "method": ([{"name": f"{c}/f", "data": body, "method": 12}], "compression method"),
            "zip64-extra": ([{"name": f"{c}/f", "data": body, "extra": struct.pack("<HHQ", 1, 8, len(body))}], "0x0001"),
            "unicode-path-override": ([{"name": f"{c}/f", "data": body, "extra": struct.pack("<HHB", 0x7075, 1, 1)}], "0x7075"),
            "local-name": ([{"name": f"{c}/f", "data": body, "local_name": f"{c}/g"}], "local path"),
            "local-method": ([{"name": f"{c}/f", "data": body, "local_method": 0}], "local header"),
            "local-size": ([{"name": f"{c}/f", "data": body, "local_size": 7}], "local sizes"),
            "bidi-name": ([{"name": f"{c}/f‮gnp", "data": body}], "layout"),
            "case-alias": ([{"name": f"{c}/Info.plist", "data": b"a"}, {"name": f"{c}/info.plist", "data": b"b"}], "aliased"),
            "nfc-alias": ([{"name": f"{c}/café", "data": b"a"}, {"name": f"{c}/café", "data": b"b"}], "aliased"),
            "graph-escape": ([{"name": f"{c}/m", "data": b"..", "kind": "link"}, {"name": f"{c}/n", "data": b"m/../x", "kind": "link"}], "escapes"),
            "cycle": ([{"name": f"{c}/a", "data": b"b", "kind": "link"}, {"name": f"{c}/b", "data": b"a", "kind": "link"}], "cycle"),
            "physical-alias": ([{"name": f"{c}/Resources/", "kind": "dir"}, {"name": f"{c}/L", "data": b"Resources", "kind": "link"}, {"name": f"{c}/Resources/f", "data": b"a"}, {"name": f"{c}/L/f", "data": b"b"}], "physical path"),
            "file-ancestor": ([{"name": f"{c}/f", "data": b"a"}, {"name": f"{c}/f/g", "data": b"b"}], "ancestor"),
            "link-to-file-parent": ([{"name": f"{c}/f", "data": b"a"}, {"name": f"{c}/L", "data": b"f", "kind": "link"}, {"name": f"{c}/L/g", "data": b"b"}], "beneath a regular file"),
        }
        for label, (entries, message) in cases.items():
            with self.subTest(label), self.assertRaisesRegex(seed.SeedExclusion, message):
                seed.zip_preflight(raw_zip(self.root / f"{label}.zip", root + entries), APP)
        # The real extraction path never hands rejected bytes to ditto.
        fixture = self.fixture(releases=0)
        context = seed.build_context(self.args(fixture), self.tools())
        forged = raw_zip(self.root / "forged.zip", root + cases["forged-small-size"][0])
        with self.assertRaisesRegex(seed.SeedExclusion, "exceeds the declared"):
            context.audit_application(forged, {}, {}, {})
        self.assertEqual(self.runner.calls, [])
        self.assert_work_clean()

    def test_gatekeeper_requires_exact_raw_notarized_verdict(self):
        seed.parse_gatekeeper_assessment(assessment_plist())
        for label, output in {
            "text-only": "accepted\nsource=Notarized Developer ID\n",
            "empty": "",
            "verdict-false": assessment_plist(False),
            "error": assessment_plist(**{"assessment:error": -67050}),
            "override": assessment_plist(authority={"assessment:authority:override": "security disabled"}),
            "weak": assessment_plist(authority={"assessment:authority:weak": True}),
            "other-source": assessment_plist(source="Developer ID"),
            "not-dict": plistlib.dumps([True]).decode(),
        }.items():
            with self.subTest(label), self.assertRaises(seed.SeedExclusion):
                seed.parse_gatekeeper_assessment(output)
        fixture = self.fixture(releases=0)
        context = seed.build_context(self.args(fixture), seed.Tools(run=lambda argv, timeout: subprocess.CompletedProcess(argv, 0, "source=Notarized Developer ID", ""), verify=self.verifier, fetch=None))
        with self.assertRaisesRegex(seed.SeedExclusion, "property list"):
            context.assess(self.root, "execute")

    def test_measure_tree_rejects_escaping_extracted_symlink(self):
        app = self.root / APP
        (app / "Contents").mkdir(parents=True)
        (app / "Contents" / "f").write_bytes(b"abc")
        os.symlink("f", app / "Contents" / "ok")
        self.assertEqual(seed.measure_tree(app), 4)
        os.symlink("../../outside", app / "Contents" / "bad")
        with self.assertRaisesRegex(seed.SeedExclusion, "escapes"):
            seed.measure_tree(app)

    @unittest.skipUnless(sys.platform == "darwin" and os.path.exists("/usr/bin/ditto") and os.path.exists("/usr/bin/codesign"), "requires macOS ditto/codesign")
    def test_real_ditto_and_codesign_reject_unsigned_fixture_without_running_it(self):
        archive = self.root / "fixture.zip"
        identity = APPLE["identities"]["legacy"]
        SeedFixture.make_zip(archive, bundle_id=identity["bundleIdentifier"], build="37.0.5", executable=b"not mach-o")
        manifest = {"bundleIdentifier": identity["bundleIdentifier"], "marketingVersion": "1.0", "buildNumber": "37.0.5", "signingIdentity": "legacy"}
        artifact = {"bundle": {"signing_mode": "developer-id"}, "executables": [
            {"path": "Contents/MacOS/RepoPrompt", "sha256": hashlib.sha256(b"not mach-o").hexdigest()},
            {"path": "Contents/MacOS/repoprompt-mcp", "sha256": hashlib.sha256(b"helper not mach-o").hexdigest()},
        ]}

        def hybrid(argv, timeout):
            if argv[0] in ("/usr/bin/ditto", "/usr/bin/codesign"):
                return seed.run_tool(argv, timeout)
            return self.runner(argv, timeout)
        fixture = self.fixture(releases=0)
        context = seed.build_context(self.args(fixture), seed.Tools(run=hybrid, verify=self.verifier, fetch=None))
        with self.assertRaisesRegex(seed.SeedExclusion, "code signature"):
            context.audit_application(archive, manifest, {"minimumSystemVersion": "14.0"}, artifact)
        self.assert_work_clean()


class FetchAndToolTests(SeedTestCase):
    class Response(io.BytesIO):
        def __init__(self, data, url, status=200, length=None):
            super().__init__(data)
            self.url, self.status = url, status
            self.headers = {} if length is None else {"Content-Length": str(length)}

        def geturl(self):
            return self.url

        def getcode(self):
            return self.status

    class Opener:
        def __init__(self, response):
            self.response, self.requests = response, []

        def open(self, request, timeout):
            self.requests.append(request)
            if isinstance(self.response, Exception):
                raise self.response
            return self.response

    def test_redirect_and_url_policy(self):
        seed.check_redirect_url("https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=x")
        for url in ("http://release-assets.githubusercontent.com/x", "https://objects.githubusercontent.com/x", "https://user@release-assets.githubusercontent.com/x", "https://release-assets.githubusercontent.com:444/x", "https://evil.example/x"):
            with self.subTest(url=url), self.assertRaises(history.HistoryError):
                seed.check_redirect_url(url)
        seed.check_official_url(rollout.enclosure_url(REPO, self.tag(1), "a.zip"), REPO, self.tag(1), "a.zip")
        with self.assertRaises(history.HistoryError):
            seed.check_official_url(rollout.enclosure_url("attacker/repo", self.tag(1), "a.zip"), REPO, self.tag(1), "a.zip")

    def test_bounded_fetcher_exact_size_redirect_and_cleanup(self):
        url = rollout.enclosure_url(REPO, self.tag(1), "a.zip")
        cdn = "https://release-assets.githubusercontent.com/asset?sig=1"
        target = self.root / "a.zip"
        opener = self.Opener(self.Response(b"abcd", cdn, length=4))
        seed.BoundedFetcher(opener=opener, chunk=2)(url, target, 4)
        self.assertEqual(target.read_bytes(), b"abcd")
        self.assertNotIn("Authorization", opener.requests[0].headers)
        for response, error in (
            (self.Response(b"abcdef", url), seed.SeedExclusion),
            (self.Response(b"ab", url), seed.SeedExclusion),
            (self.Response(b"abcd", url, length=5), seed.SeedExclusion),
            (self.Response(b"abcd", "https://evil.example/x"), history.HistoryError),
            (OSError("offline"), seed.AuditEnvironmentError),
        ):
            destination = self.root / "b.zip"
            with self.subTest(error=error), self.assertRaises(error):
                seed.BoundedFetcher(opener=self.Opener(response), chunk=2)(url, destination, 4)
            self.assertFalse(destination.exists())
            self.assertEqual(sorted(p.name for p in self.root.iterdir() if p.name.endswith(".partial")), [])

    def test_snapshot_fetches_only_official_urls_into_owned_cache_and_rejects_symlinks(self):
        fixture = self.fixture(releases=1)
        release = seed._release_from_record(fixture.records[0])
        name = seed.ROLLOUT_NAME
        source_bytes = (fixture.assets / release.tag / name).read_bytes()
        with self.assertRaisesRegex(history.HistoryError, "not owned"):
            seed.Snapshot(fixture.snapshot, REPO, fetcher=lambda *a: None)
        os.rename(fixture.assets, self.root / "moved-assets")
        fetched = []

        def fetcher(url, path, size):
            fetched.append(url)
            path.write_bytes(source_bytes)
        snapshot = seed.Snapshot(fixture.snapshot, REPO, fetcher=fetcher)
        self.assertEqual(snapshot.asset(release, name, seed.SMALL_ASSET_LIMIT).read_bytes(), source_bytes)
        self.assertEqual(fetched, [rollout.enclosure_url(REPO, release.tag, name)])
        self.assertTrue((fixture.snapshot / seed.SNAPSHOT_MARKER).is_file())
        link = fixture.assets / release.tag / seed.APPCAST_NAME
        os.symlink(self.root / "moved-assets" / release.tag / seed.APPCAST_NAME, link)
        with self.assertRaisesRegex(seed.SeedExclusion, "regular non-symlink"):
            seed.Snapshot(fixture.snapshot, REPO).asset(release, seed.APPCAST_NAME, seed.SMALL_ASSET_LIMIT)

    def test_tool_allowlist_and_trusted_verifier_use_pinned_key_and_committed_script(self):
        for argv in (["/tmp/RepoPrompt CE.app/Contents/MacOS/RepoPrompt"], ["/usr/bin/xcrun", "swift", "/tmp/other.swift"], ["/bin/sh", "-c", "true"]):
            with self.subTest(argv=argv), self.assertRaises(history.HistoryError):
                seed.run_tool(argv, 1)
        seen = {}

        def runner(argv, timeout):
            seen["argv"] = argv
            seen["key"] = Path(argv[3]).read_text().strip()
            return subprocess.CompletedProcess(argv, 0, "", "")
        signature = base64.b64encode(b"s" * 64).decode()
        target = self.root / "file.zip"
        target.write_bytes(b"x")
        self.assertTrue(seed.trusted_sparkle_verifier(runner)(PINNED_KEY, signature, target))
        self.assertEqual(seen["argv"][:3], ["/usr/bin/xcrun", "swift", str(seed.VERIFY_SPARKLE_SCRIPT)])
        self.assertEqual(seen["argv"][4:], [signature, str(target)])
        self.assertEqual(seen["key"], PINNED_KEY)
        with self.assertRaises(history.HistoryError):
            seed.trusted_sparkle_verifier(runner)(PINNED_KEY, "bad", target)

    def test_apple_policy_must_equal_committed_binding_before_any_fetch_or_extraction(self):
        fixture = self.fixture(releases=2)
        copy_dir = self.root / "policies"
        copy_dir.mkdir()
        identical = copy_dir / "identical.json"
        identical.write_text(json.dumps(json.loads(APPLE_PATH.read_text()), indent=4))  # same content, different bytes/path
        context = seed.build_context(self.args(fixture, apple_policy=identical), self.tools())
        self.assertEqual(context.apple, APPLE)
        fetched = []
        os.rename(fixture.assets, self.root / "moved-assets")
        tools = self.tools(fetch=lambda url, path, size: fetched.append(url))
        for label, mutate in {
            "sparkle-key": lambda p: p["sparkle"].__setitem__("sparklePublicEdDSAValue", base64.b64encode(b"k" * 32).decode()),
            "requirement": lambda p: p["identities"]["legacy"].__setitem__("developerIDRequirement", "anchor apple generic"),
        }.items():
            with self.subTest(label):
                policy = json.loads(APPLE_PATH.read_text())
                mutate(policy)
                path = copy_dir / f"{label}.json"
                path.write_text(json.dumps(policy))
                rollout.load_policy(path)  # schema-valid copy
                with self.assertRaisesRegex(history.HistoryError, "committed Scripts/apple_identity_policy.json"):
                    seed.run_cli(self.args(fixture, apple_policy=path, fetch=True), tools)
                self.assertFalse((self.root / "bootstrap.json").exists())
        self.assertEqual((fetched, self.runner.calls), ([], []))
        self.assertFalse(fixture.assets.exists() or (fixture.snapshot / seed.SNAPSHOT_MARKER).exists())
        self.assertEqual(self.verifier.keys, set())
        self.assert_work_clean()

    def test_cli_entry_points_fail_closed(self):
        fixture = self.fixture(releases=0)
        self.policy_path.write_bytes(history.canonical(self.policy))
        common = ["seed-bootstrap", "--approved-source", str(self.source), "--policy", str(self.policy_path), "--release-snapshot", str(fixture.snapshot), "--candidate-tag", self.tag(34), "--candidate-build", "37.0.34", "--output", str(self.root / "out.json")]
        self.assertEqual(seed.main(common + ["--candidate-commit", self.candidate, "--work-dir", str(self.work)], tools=self.tools()), 2)
        self.assertEqual(json.loads((self.root / "out.json").read_text())["shortfall"], 29)
        result = subprocess.run([sys.executable, "-B", str(SCRIPTS / "tip_history_seed.py"), *common, "--candidate-commit", self.commits[33]], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("candidate tag", result.stderr)
        self.policy["historyAdmissionFloorCommit"] = None
        self.policy_path.write_bytes(history.canonical(self.policy))
        result = subprocess.run([sys.executable, "-B", str(SCRIPTS / "tip_history_seed.py"), *common, "--candidate-commit", self.candidate], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("admission floor", result.stderr)


if __name__ == "__main__":
    unittest.main()
