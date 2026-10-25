#!/usr/bin/env python3
"""Real file/CLI admission regressions; fixtures are NOT production audit evidence."""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import stable_rollout as rollout
import tip_history as history
import tip_history_admission as admission

SCRIPTS = Path(__file__).resolve().parent
APPLE = SCRIPTS / "apple_identity_policy.json"
SIGNATURE = base64.b64encode(b"fixture-not-an-authenticated-signature".ljust(64, b"!")).decode()


class AdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="tip-admission-git-")
        cls.source = Path(cls.shared.name)
        def git(*args):
            return subprocess.run(["git", *args], cwd=cls.source, check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        cls.commits = []
        for i in range(32):
            git("commit", "--allow-empty", "-qm", f"Fixture change {i}")
            cls.commits.append(git("rev-parse", "HEAD"))
        cls.apple = rollout.load_policy(APPLE)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tip-admission-data-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policy = {
            "schemaVersion": 1,
            "historyAdmissionFloorBuild": "37.0.0",
            "historyAdmissionFloorCommit": self.commits[0],
            "historyUIFloorBuild": "37.0.30",
            "historyEnabledSinceTag": self.tag(30),
            "retention": {"schemaLifetime": 1, "owner": "test fixture only", "reviewedEvidence": "fixture, not a live review"},
        }
        self.policy_path = self.root / "policy.json"
        self.write(self.policy_path, self.policy)
        self.parent_entry, _ = self.make_entry(30)
        self.parent = self.root / "parent.json"
        self.parent.write_bytes(history.wrap(history.canonical(history.assemble_page(self.parent_entry, rollout.update_repository(self.apple, "tip"), None)), SIGNATURE))
        self.entry, self.manifest = self.make_entry(31)
        self.artifact = self.manifest.parent / "fixture-artifact-manifest.json"
        self.notes = self.manifest.parent / "notes-input.json"
        self.write(self.notes, history.collect_notes(self.source, self.commits[30], self.commits[31]))
        self.payload = self.root / "payload.json"
        self.envelope = self.root / "tip-history.json"

    def tag(self, index):
        return "tip-" + self.commits[index][:12]

    @staticmethod
    def write(path, value):
        path.write_bytes(history.canonical(value))

    def make_entry(self, index, *, role="preparer", predecessor=None):
        folder = self.root / f"{role}-{index}"
        folder.mkdir(exist_ok=True)
        identity = self.apple["identities"][rollout.ROLE_IDENTITY[role]]
        artifact = folder / "fixture-artifact-manifest.json"
        self.write(artifact, {
            "schema_version": 1,
            "bundle": {"identifier": identity["bundleIdentifier"], "marketing_version": "1.0", "build_number": f"37.0.{index}", "signing_mode": rollout.SIGNING_MODE_BY_IDENTITY[rollout.ROLE_IDENTITY[role]], "architectures": ["arm64", "x86_64"]},
            "bundle_signing": {"team_identifier": identity["teamIdentifier"]},
            "executables": [{"path": "Contents/MacOS/RepoPrompt", "architectures": ["arm64", "x86_64"]}, {"path": "Contents/Helpers/repoprompt-mcp", "architectures": ["arm64", "x86_64"]}],
        })
        declaration = folder / "declaration.json"
        predecessors = []
        predecessor_paths = list(predecessor) if isinstance(predecessor, (list, tuple)) else [predecessor] if predecessor else []
        for path in predecessor_paths:
            p = history.read_json(path)
            predecessors.append({"role": p["currentRole"], "tag": p["sourceTag"], "rolloutManifestSha256": rollout.sha256_file(path)})
        self.write(declaration, {"schemaVersion": 1, "channel": "tip", "currentRole": role, "eligibilityProfile": "tip-identity-dress-rehearsal-v1", "expectedMigrationPhase": rollout.ROLE_MIGRATION_PHASE[role], "expectedSigningIdentity": rollout.ROLE_IDENTITY[role], "predecessors": predecessors})
        version = folder / "version.env"
        version.write_text(f'APP_NAME=RepoPrompt\nMARKETING_VERSION=1.0\nBUILD_NUMBER=37.0.{index}\nBUNDLE_ID={identity["bundleIdentifier"]}\nSIGNING_TEAM_ID={identity["teamIdentifier"]}\n')
        enclosure = folder / ("RepoPrompt-fixture.pkg" if role == "transition" else "RepoPrompt-fixture.zip")
        enclosure.write_bytes(b"fixture bytes, never a distributable binary")
        args = argparse.Namespace(policy=str(APPLE), declaration=str(declaration), version_env=str(version), allowed_roles=None, release_tag=self.tag(index), release_commit=self.commits[index], migration_phase=rollout.ROLE_MIGRATION_PHASE[role], enclosure=str(enclosure), enclosure_basename="RepoPrompt-fixture", enclosure_signature=SIGNATURE, app_artifact_manifest=str(artifact), predecessor_manifest=[str(path) for path in predecessor_paths])
        m, appcast = rollout.build_manifest(args)
        manifest = folder / "identity-rollout.json"
        self.write(manifest, m)
        (folder / "appcast.xml").write_text(appcast)
        notes = history.collect_notes(self.source, self.commits[index - 1] if index else None, self.commits[index])
        entry = admission.entry_from_manifest(apple_policy=self.apple, policy=self.policy, source=self.source, manifest_path=manifest, artifact_path=artifact, notes=notes, expanded_size=123 if role != "transition" else 0)
        return entry, manifest

    def cli(self, command, *args, success=True):
        result = subprocess.run([sys.executable, "-B", str(SCRIPTS / "tip_history_admission.py"), command, *map(str, args)], capture_output=True, text=True, timeout=60)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def common(self):
        return ["--policy", self.policy_path, "--apple-policy", APPLE, "--source", self.source, "--manifest", self.manifest, "--app-artifact-manifest", self.artifact, "--expanded-size", "123"]

    def build(self, *parent):
        self.cli("build-payload", *self.common(), "--notes", self.notes, *parent, "--output", self.payload)
        self.envelope.write_bytes(history.wrap(self.payload.read_bytes(), SIGNATURE))

    def verify(self, *, success=True, parent=None, size=123):
        args = self.common()
        args[-1] = str(size)
        return self.cli("verify-candidate", *args, "--envelope", self.envelope, *(parent or ["--parent-envelope", self.parent]), success=success)

    def test_real_application_cli_without_guessed_notes_or_expanded_manifest_fields(self):
        self.build("--parent-envelope", self.parent)
        self.notes.unlink()
        self.verify()
        page = history.page_from_envelope(self.envelope.read_bytes())
        self.assertEqual(page["entries"][0], self.entry)
        self.assertEqual(page["entries"][1]["historyCatalogSha256"], rollout.sha256_file(self.parent))

    def test_verify_parent_cli_has_no_apple_policy_or_signature_claim(self):
        self.cli("verify-parent", "--envelope", self.parent, "--tag", self.tag(30), "--sha256", rollout.sha256_file(self.parent))
        self.cli("verify-parent", "--envelope", self.parent, "--sha256", "0" * 64, success=False)

    def test_signed_head_mutations_cannot_bypass_manifest_source_or_size_binding(self):
        self.build("--parent-envelope", self.parent)
        original = history.page_from_envelope(self.envelope.read_bytes())
        for field, value in (("bundleIdentifier", "com.attacker.app"), ("role", "successor"), ("architectures", ["arm64"]), ("title", "invented title"), ("hasHistoryUI", False)):
            with self.subTest(field=field):
                page = copy.deepcopy(original)
                page["entries"][0][field] = value
                self.envelope.write_bytes(history.wrap(history.canonical(page), SIGNATURE))
                self.verify(success=False)
        for field, value in (("sha256", "0" * 64), ("edSignature", base64.b64encode(b"x" * 64).decode()), ("url", "https://example.invalid/build.zip"), ("expandedSize", 124)):
            with self.subTest(download=field):
                page = copy.deepcopy(original)
                page["entries"][0]["download"][field] = value
                self.envelope.write_bytes(history.wrap(history.canonical(page), SIGNATURE))
                self.verify(success=False)
        self.envelope.write_bytes(history.wrap(history.canonical(original), SIGNATURE))
        self.verify(success=False, size=124)

    def test_retained_and_page_mutations_rejected(self):
        self.build("--parent-envelope", self.parent)
        original = history.page_from_envelope(self.envelope.read_bytes())
        for target in ("retained", "older", "repository", "range"):
            with self.subTest(target=target):
                page = copy.deepcopy(original)
                if target == "retained": page["entries"][1]["title"] = "tampered retained notes"
                elif target == "older": page["olderPage"] = {"tag": self.tag(29), "sha256": "0" * 64}
                elif target == "repository": page["updateRepository"] = "attacker/repo"
                else: page["entries"][0]["commitRange"]["fromCommit"] = self.commits[29]
                self.envelope.write_bytes(history.wrap(history.canonical(page), SIGNATURE))
                self.verify(success=False)

    def bootstrap_fixture(self):
        seeds = []
        for i in range(30, 1, -1):
            e, _ = self.make_entry(i)
            e["origin"] = "seed"
            seeds.append(e)
        evidence = {"schemaVersion": 1, "historyNeverEnabled": True, "liveParent": self.tag(30), "entries": seeds}
        self.policy["historyEnabledSinceTag"] = self.tag(31)
        self.bootstrap_path = self.root / "bootstrap.json"
        self.write(self.bootstrap_path, evidence)
        self.policy["bootstrapEvidenceSha256"] = rollout.sha256_file(self.bootstrap_path)
        self.write(self.policy_path, self.policy)
        self.entry, self.manifest = self.make_entry(31)
        self.artifact = self.manifest.parent / "fixture-artifact-manifest.json"
        self.notes = self.manifest.parent / "notes-input.json"
        self.write(self.notes, history.collect_notes(self.source, self.commits[30], self.commits[31]))
        return evidence

    def test_bootstrap_exact_quantity_pin_retention_and_source_gate(self):
        evidence = self.bootstrap_fixture()
        self.build("--bootstrap", self.bootstrap_path)
        self.assertEqual(len(json.loads(self.payload.read_bytes())["entries"]), 30)
        self.verify(parent=["--bootstrap", self.bootstrap_path])
        for mutation in ("shortfall", "seed", "retention", "floor", "activation"):
            with self.subTest(mutation=mutation):
                p, b = copy.deepcopy(self.policy), copy.deepcopy(evidence)
                if mutation == "shortfall":
                    b["entries"].pop()
                    p["bootstrapEvidenceSha256"] = hashlib.sha256(history.canonical(b)).hexdigest()
                elif mutation == "seed": b["entries"][0]["title"] = "unreviewed replacement"
                elif mutation == "retention": p["retention"]["reviewedEvidence"] = None
                elif mutation == "floor": p["historyAdmissionFloorBuild"] = "38"
                else: p["historyEnabledSinceTag"] = self.tag(30)
                with self.assertRaises((history.HistoryError, rollout.RolloutError)):
                    admission.build_payload(entry=self.entry, apple_policy=self.apple, policy=p, source=self.source, parent_bytes=None, bootstrap=b)

    def test_cli_requires_exactly_one_parent_input_and_approved_head(self):
        self.cli("build-payload", *self.common(), "--notes", self.notes, "--output", self.payload, success=False)
        self.cli("build-payload", *self.common(), "--notes", self.notes, "--output", self.payload, "--parent-envelope", self.parent, "--bootstrap", self.parent, success=False)
        self.manifest = self.root / "preparer-30" / "identity-rollout.json"
        self.artifact = self.manifest.parent / "fixture-artifact-manifest.json"
        result = self.cli("build-payload", *self.common(), "--notes", self.notes, "--output", self.payload, "--parent-envelope", self.parent, success=False)
        self.assertIn("approved candidate", result.stderr)

    def prepare_candidate_role(self, role):
        if role == "successor":
            _, preparer = self.make_entry(29)
            parent_entry, transition = self.make_entry(30, role="transition", predecessor=preparer)
            self.entry, self.manifest = self.make_entry(31, role=role, predecessor=[transition, preparer])
        else:
            parent_entry, preparer = self.make_entry(30)
            self.entry, self.manifest = self.make_entry(31, role=role, predecessor=preparer if role == "transition" else None)
        self.parent.write_bytes(history.wrap(history.canonical(history.assemble_page(parent_entry, rollout.update_repository(self.apple, "tip"), None)), SIGNATURE))
        self.artifact = self.manifest.parent / "fixture-artifact-manifest.json"
        self.notes = self.manifest.parent / "notes-input.json"
        self.write(self.notes, history.collect_notes(self.source, self.commits[30], self.commits[31]))

    def test_package_cli_never_has_download(self):
        self.prepare_candidate_role("transition")
        self.build("--parent-envelope", self.parent)
        self.verify()
        head = history.page_from_envelope(self.envelope.read_bytes())["entries"][0]
        self.assertIsNone(head["download"])
        self.assertEqual(head["signingIdentity"], "successor")
        self.assertEqual(history.read_json(self.artifact)["bundle"]["signing_mode"], "successor-developer-id")

    def test_successor_application_cli_uses_exact_successor_signing_mode(self):
        self.prepare_candidate_role("successor")
        self.build("--parent-envelope", self.parent)
        self.verify()
        head = history.page_from_envelope(self.envelope.read_bytes())["entries"][0]
        self.assertEqual(head["role"], "successor")
        self.assertEqual(head["installationType"], "application")
        self.assertIsNotNone(head["download"])
        self.assertEqual(history.read_json(self.artifact)["bundle"]["signing_mode"], "successor-developer-id")

    def test_wrong_artifact_signing_modes_are_rejected_for_both_identities(self):
        for role in ("preparer", "transition", "successor"):
            self.prepare_candidate_role(role)
            self.build("--parent-envelope", self.parent)
            artifact = history.read_json(self.artifact)
            wrong_official_mode = "successor-developer-id" if role == "preparer" else "developer-id"
            for mode in (wrong_official_mode, "adhoc"):
                with self.subTest(role=role, mode=mode):
                    artifact["bundle"]["signing_mode"] = mode
                    self.write(self.artifact, artifact)
                    manifest = history.read_json(self.manifest)
                    manifest["appArtifactManifest"]["sha256"] = rollout.sha256_file(self.artifact)
                    self.write(self.manifest, manifest)
                    (self.manifest.parent / "appcast.xml").write_text(rollout.render_appcast(manifest))
                    self.assertIn("signing mode", self.verify(success=False).stderr)

    def test_null_ui_floor_allows_active_publication_without_history_ui_claim(self):
        self.policy["historyUIFloorBuild"] = None
        self.write(self.policy_path, self.policy)
        self.assertIsNone(admission.load_policy(self.policy_path)["historyUIFloorBuild"])
        self.prepare_candidate_role("preparer")
        self.build("--parent-envelope", self.parent)
        self.verify()
        page = history.page_from_envelope(self.envelope.read_bytes())
        self.assertTrue(all(entry["hasHistoryUI"] is False for entry in page["entries"]))

    def test_inactive_nullable_policy_loads_but_cannot_publish(self):
        self.policy["historyUIFloorBuild"] = None
        self.policy["historyEnabledSinceTag"] = None
        self.write(self.policy_path, self.policy)
        policy = admission.load_policy(self.policy_path)
        self.assertIsNone(policy["historyEnabledSinceTag"])
        self.prepare_candidate_role("preparer")
        result = self.cli("build-payload", *self.common(), "--notes", self.notes, "--parent-envelope", self.parent, "--output", self.payload, success=False)
        self.assertIn("activation tag required", result.stderr)
        self.assertFalse(self.payload.exists())
        # Direct callers cannot bypass the gate with a malformed non-null tag.
        for tag in (None, "", "tip-not-a-reviewed-tag"):
            with self.subTest(tag=tag):
                inactive = dict(policy, historyEnabledSinceTag=tag)
                with self.assertRaisesRegex(history.HistoryError, "activation tag required"):
                    admission.build_payload(entry=self.entry, apple_policy=self.apple, policy=inactive, source=self.source, parent_bytes=self.parent.read_bytes())

    def test_actual_artifact_architecture_and_digest_binding(self):
        self.build("--parent-envelope", self.parent)
        artifact = history.read_json(self.artifact)
        artifact["bundle_signing"]["team_identifier"] = "ATTACKER00"
        self.write(self.artifact, artifact)
        self.verify(success=False)
        manifest = history.read_json(self.manifest)
        manifest["appArtifactManifest"]["sha256"] = rollout.sha256_file(self.artifact)
        self.write(self.manifest, manifest)
        (self.manifest.parent / "appcast.xml").write_text(rollout.render_appcast(manifest))
        self.assertIn("Team ID", self.verify(success=False).stderr)

    def test_nullable_policy_fields_must_be_present_and_source_ancestry_is_required(self):
        for key in ("historyUIFloorBuild", "historyEnabledSinceTag"):
            for value in ("missing", 42, "invalid"):
                with self.subTest(key=key, value=value):
                    policy = copy.deepcopy(self.policy)
                    if value == "missing":
                        del policy[key]
                    else:
                        policy[key] = value
                    self.write(self.policy_path, policy)
                    with self.assertRaises((history.HistoryError, rollout.RolloutError)):
                        admission.load_policy(self.policy_path)
        self.policy["historyAdmissionFloorCommit"] = self.commits[31]
        with self.assertRaisesRegex(history.HistoryError, "descend"):
            admission.admit_source(self.policy, self.source, self.commits[30], "37.0.30")

    def test_known_source_barrier_cannot_be_erased_by_an_entry(self):
        source = self.root / "barrier-source"
        subprocess.run(["git", "clone", "-q", "--local", str(self.source), str(source)], check=True, capture_output=True)
        self.source = source
        self.commits = list(self.commits)
        fragment = source / "ReleaseNotes" / "Tip" / "barrier.json"
        fragment.parent.mkdir(parents=True)
        self.write(fragment, {"schemaVersion": 1, "title": "New persistence format", "notes": [], "breaksDowngrade": True, "breaksDowngradeReason": "Old builds cannot read this format"})
        subprocess.run(["git", "-C", str(source), "add", "."], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Persistence barrier"], check=True, capture_output=True)
        self.commits.append(history.git(source, "rev-parse", "HEAD").strip())
        entry, _ = self.make_entry(32)
        self.assertTrue(entry["downgradeBarrier"])
        entry["downgradeBarrier"] = False
        entry["downgradeBarrierReasons"] = []
        with self.assertRaisesRegex(history.HistoryError, "source downgrade barrier"):
            admission.validate_entry(entry, apple_policy=self.apple, policy=self.policy, source=source)


if __name__ == "__main__":
    unittest.main()
