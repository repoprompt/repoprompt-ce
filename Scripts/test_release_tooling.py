#!/usr/bin/env python3
"""Regression coverage for the Tip Stable-build floor and reset authority."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
ROLLOUT_TOOL = SCRIPT_DIR / "stable_rollout.py"
POLICY = SCRIPT_DIR / "apple_identity_policy.json"


class StableTipFloorTests(unittest.TestCase):
    def rollout(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROLLOUT_TOOL), *arguments],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            timeout=30,
        )

    @staticmethod
    def declaration(
        path: Path,
        role: str,
        predecessors: list[dict[str, str]] | None = None,
        reset_authority: dict[str, object] | None = None,
    ) -> None:
        declaration = {
            "schemaVersion": 2 if reset_authority is not None else 1,
            "channel": "tip",
            "currentRole": role,
            "eligibilityProfile": "tip-identity-dress-rehearsal-v1",
            "expectedMigrationPhase": (
                "legacy-preparer" if role == "preparer" else "disabled"
            ),
            "expectedSigningIdentity": (
                "legacy" if role == "preparer" else "successor"
            ),
            "predecessors": predecessors or [],
        }
        if reset_authority is not None:
            declaration["resetAuthority"] = reset_authority
        path.write_text(json.dumps(declaration, indent=2) + "\n", encoding="utf-8")

    def generate_release(
        self,
        root: Path,
        label: str,
        role: str,
        build: str,
        predecessor: dict[str, object] | None = None,
        tag: str | None = None,
        marketing_version: str = "1.4.0",
        reset_authority: dict[str, object] | None = None,
    ) -> dict[str, Path | str]:
        release_root = root / label
        release_root.mkdir()
        release_tag = tag or f"tip-{label}"
        predecessor_entries: list[dict[str, str]] = []
        predecessor_paths: list[Path] = []
        if predecessor is not None:
            predecessor_manifest = predecessor["manifest"]
            assert isinstance(predecessor_manifest, Path)
            predecessor_entries.append(
                {
                    "role": str(predecessor["role"]),
                    "tag": str(predecessor["tag"]),
                    "rolloutManifestSha256": hashlib.sha256(
                        predecessor_manifest.read_bytes()
                    ).hexdigest(),
                }
            )
            predecessor_paths.append(predecessor_manifest)

        declaration_path = release_root / "tip-rollout.json"
        self.declaration(
            declaration_path,
            role,
            predecessor_entries,
            reset_authority,
        )
        is_preparer = role == "preparer"
        version_env = release_root / "version.env"
        version_env.write_text(
            "APP_NAME=RepoPrompt\n"
            f"MARKETING_VERSION={marketing_version}\n"
            f"BUILD_NUMBER={build}\n"
            f"BUNDLE_ID={'com.pvncher.repoprompt.ce' if is_preparer else 'com.repoprompt.ce'}\n"
            f"SIGNING_TEAM_ID={'648A27MST5' if is_preparer else '69N6K965SF'}\n",
            encoding="utf-8",
        )
        enclosure_basename = f"RepoPrompt-{label}-{build}"
        enclosure = release_root / (
            enclosure_basename + (".zip" if is_preparer else ".pkg")
        )
        enclosure.write_text(f"fixture enclosure {label}\n", encoding="utf-8")
        artifact_manifest = release_root / "artifact-manifest.json"
        artifact_manifest.write_text('{"schema_version":1}\n', encoding="utf-8")
        appcast = release_root / "appcast.xml"
        manifest = release_root / "identity-rollout.json"
        arguments = [
            "generate",
            "--declaration",
            str(declaration_path),
            "--policy",
            str(POLICY),
            "--version-env",
            str(version_env),
            "--release-tag",
            release_tag,
            "--release-commit",
            hashlib.sha1(label.encode("utf-8")).hexdigest(),
            "--migration-phase",
            "legacy-preparer" if is_preparer else "disabled",
            "--enclosure",
            str(enclosure),
            "--enclosure-basename",
            enclosure_basename,
            "--enclosure-signature",
            f"fixture-signature-{label}",
            "--app-artifact-manifest",
            str(artifact_manifest),
            "--appcast-output",
            str(appcast),
            "--manifest-output",
            str(manifest),
        ]
        for predecessor_path in predecessor_paths:
            arguments.extend(("--predecessor-manifest", str(predecessor_path)))
        result = self.rollout(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {
            "role": role,
            "tag": release_tag,
            "manifest": manifest,
            "appcast": appcast,
            "declaration": declaration_path,
        }

    @staticmethod
    def stable_appcast(path: Path, build: str, marketing_version: str) -> None:
        path.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    <item>\n"
            f"      <sparkle:shortVersionString>{marketing_version}</sparkle:shortVersionString>\n"
            f"      <sparkle:version>{build}</sparkle:version>\n"
            "    </item>\n"
            "  </channel>\n"
            "</rss>\n",
            encoding="utf-8",
        )

    def validate_floor(
        self,
        stable_appcast: Path,
        tip_release: dict[str, Path | str],
    ) -> subprocess.CompletedProcess[str]:
        return self.rollout(
            "validate-stable-tip-floor",
            "--policy",
            str(POLICY),
            "--stable-appcast",
            str(stable_appcast),
            "--tip-manifest",
            str(tip_release["manifest"]),
            "--tip-appcast",
            str(tip_release["appcast"]),
        )

    def validate_progression(
        self,
        candidate: dict[str, Path | str],
        live: dict[str, Path | str],
        declaration: Path | None = None,
        stable_appcast: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            "validate-live-tip-progression",
            "--policy",
            str(POLICY),
            "--candidate-manifest",
            str(candidate["manifest"]),
            "--candidate-appcast",
            str(candidate["appcast"]),
            "--live-manifest",
            str(live["manifest"]),
            "--live-appcast",
            str(live["appcast"]),
        ]
        if declaration is not None:
            assert stable_appcast is not None
            arguments.extend(
                (
                    "--declaration",
                    str(declaration),
                    "--stable-appcast",
                    str(stable_appcast),
                )
            )
        return self.rollout(*arguments)

    def test_transition_to_replacement_preparer_requires_exact_reset_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture_root = Path(temporary_directory)
            stable_appcast = fixture_root / "stable-appcast.xml"
            self.stable_appcast(stable_appcast, "36", "1.4.0")

            stale_preparer = self.generate_release(
                fixture_root,
                "preparer-stale",
                "preparer",
                "35.15.18",
                tag="tip-2f94412e6ab5",
            )
            live_transition = self.generate_release(
                fixture_root,
                "transition-live",
                "transition",
                "35.15.39",
                predecessor=stale_preparer,
                tag="tip-57b572038048",
            )
            stale_floor = self.validate_floor(stable_appcast, live_transition)
            self.assertNotEqual(stale_floor.returncode, 0)
            self.assertIn("Stable=36 preparer=35.15.18", stale_floor.stderr)

            live_manifest_digest = hashlib.sha256(
                Path(live_transition["manifest"]).read_bytes()
            ).hexdigest()
            stale_preparer_digest = hashlib.sha256(
                Path(stale_preparer["manifest"]).read_bytes()
            ).hexdigest()
            reset_authority = {
                "type": "transition-to-replacement-preparer-v1",
                "liveTip": {
                    "role": "transition",
                    "tag": "tip-57b572038048",
                    "buildNumber": "35.15.39",
                    "rolloutManifestSha256": live_manifest_digest,
                },
                "stableEpoch": {
                    "marketingVersion": "1.4.0",
                    "buildNumber": "36",
                },
                "retainedPreparer": {
                    "role": "preparer",
                    "tag": "tip-2f94412e6ab5",
                    "buildNumber": "35.15.18",
                    "rolloutManifestSha256": stale_preparer_digest,
                },
            }
            replacement_preparer = self.generate_release(
                fixture_root,
                "preparer-replacement",
                "preparer",
                "36.0.1",
                tag="tip-aaaaaaaaaaaa",
                reset_authority=reset_authority,
            )

            without_reset = self.validate_progression(replacement_preparer, live_transition)
            self.assertNotEqual(without_reset.returncode, 0)
            self.assertIn(
                "candidate Tip rollout role would regress or skip the live rollout state",
                without_reset.stderr,
            )

            with_reset = self.validate_progression(
                replacement_preparer,
                live_transition,
                Path(replacement_preparer["declaration"]),
                stable_appcast,
            )
            self.assertEqual(with_reset.returncode, 0, with_reset.stderr)
            self.assertIn("explicit Tip reset authorized", with_reset.stdout)
            self.assertIn("tip-57b572038048 (35.15.39)", with_reset.stdout)
            self.assertIn("tip-2f94412e6ab5 (35.15.18)", with_reset.stdout)

            low_replacement = self.generate_release(
                fixture_root,
                "preparer-too-low",
                "preparer",
                "35.15.40",
                tag="tip-bbbbbbbbbbbb",
                reset_authority=reset_authority,
            )
            too_low = self.validate_progression(
                low_replacement,
                live_transition,
                Path(low_replacement["declaration"]),
                stable_appcast,
            )
            self.assertNotEqual(too_low.returncode, 0)
            self.assertIn("newer than both live Tip and Stable", too_low.stderr)

            valid_declaration = json.loads(
                Path(replacement_preparer["declaration"]).read_text(encoding="utf-8")
            )
            tampered_cases = [
                ("missing reset", "missing", "explicit checked-in resetAuthority"),
                ("wrong type", "type", "resetAuthority type must be"),
                ("live tag", "live-tag", "live Tip tag mismatch"),
                ("live build", "live-build", "live Tip buildNumber mismatch"),
                ("live digest", "live-digest", "live Tip manifest digest mismatch"),
                ("Stable marketing", "stable-marketing", "Stable epoch marketingVersion mismatch"),
                ("Stable build", "stable-build", "Stable epoch buildNumber mismatch"),
                ("retained tag", "retained-tag", "retained preparer tag mismatch"),
                ("retained build", "retained-build", "retained preparer buildNumber mismatch"),
                ("retained digest", "retained-digest", "retained preparer rolloutManifestSha256 mismatch"),
            ]
            for label, mutation, diagnostic in tampered_cases:
                declaration = copy.deepcopy(valid_declaration)
                if mutation == "missing":
                    declaration["schemaVersion"] = 1
                    del declaration["resetAuthority"]
                elif mutation == "type":
                    declaration["resetAuthority"]["type"] = "not-a-reset"
                elif mutation == "live-tag":
                    declaration["resetAuthority"]["liveTip"]["tag"] = "tip-cccccccccccc"
                elif mutation == "live-build":
                    declaration["resetAuthority"]["liveTip"]["buildNumber"] = "35.15.38"
                elif mutation == "live-digest":
                    declaration["resetAuthority"]["liveTip"]["rolloutManifestSha256"] = "0" * 64
                elif mutation == "stable-marketing":
                    declaration["resetAuthority"]["stableEpoch"]["marketingVersion"] = "1.3.0"
                elif mutation == "stable-build":
                    declaration["resetAuthority"]["stableEpoch"]["buildNumber"] = "35"
                elif mutation == "retained-tag":
                    declaration["resetAuthority"]["retainedPreparer"]["tag"] = "tip-dddddddddddd"
                elif mutation == "retained-build":
                    declaration["resetAuthority"]["retainedPreparer"]["buildNumber"] = "35.15.17"
                elif mutation == "retained-digest":
                    declaration["resetAuthority"]["retainedPreparer"]["rolloutManifestSha256"] = "1" * 64
                else:
                    self.fail(f"unhandled mutation: {mutation}")
                tampered_declaration = fixture_root / f"tampered-{mutation}.json"
                tampered_declaration.write_text(
                    json.dumps(declaration, indent=2) + "\n", encoding="utf-8"
                )
                result = self.validate_progression(
                    replacement_preparer,
                    live_transition,
                    tampered_declaration,
                    stable_appcast,
                )
                with self.subTest(case=label):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(diagnostic, result.stderr)


if __name__ == "__main__":
    unittest.main()
