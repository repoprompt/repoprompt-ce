#!/usr/bin/env python3
"""Regression coverage for the Tip Stable-build floor."""

from __future__ import annotations

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
    ) -> None:
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
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
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def generate_release(
        self,
        root: Path,
        label: str,
        role: str,
        build: str,
        predecessor: dict[str, object] | None = None,
    ) -> dict[str, Path | str]:
        release_root = root / label
        release_root.mkdir()
        tag = f"tip-{label}"
        predecessor_entries: list[dict[str, str]] = []
        predecessor_paths: list[Path] = []
        if predecessor is not None:
            predecessor_manifest = predecessor["manifest"]
            assert isinstance(predecessor_manifest, Path)
            predecessor_entries.append(
                {
                    "role": "preparer",
                    "tag": str(predecessor["tag"]),
                    "rolloutManifestSha256": hashlib.sha256(
                        predecessor_manifest.read_bytes()
                    ).hexdigest(),
                }
            )
            predecessor_paths.append(predecessor_manifest)

        self.declaration(release_root / "tip-rollout.json", role, predecessor_entries)
        is_preparer = role == "preparer"
        version_env = release_root / "version.env"
        version_env.write_text(
            "APP_NAME=RepoPrompt\n"
            "MARKETING_VERSION=1.4.0\n"
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
            str(release_root / "tip-rollout.json"),
            "--policy",
            str(POLICY),
            "--version-env",
            str(version_env),
            "--release-tag",
            tag,
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
            "tag": tag,
            "manifest": manifest,
            "appcast": appcast,
        }

    @staticmethod
    def stable_appcast(path: Path, build: str) -> None:
        path.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    <item>\n"
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
    ) -> subprocess.CompletedProcess[str]:
        return self.rollout(
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
        )

    def test_replacement_preparer_restores_stable_tip_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture_root = Path(temporary_directory)
            stable_appcast = fixture_root / "stable-appcast.xml"
            self.stable_appcast(stable_appcast, "36")

            stale_preparer = self.generate_release(
                fixture_root, "preparer-stale", "preparer", "35.15.18"
            )
            stale_transition = self.generate_release(
                fixture_root,
                "transition-stale",
                "transition",
                "35.15.19",
                stale_preparer,
            )
            stale_floor = self.validate_floor(stable_appcast, stale_transition)
            self.assertNotEqual(stale_floor.returncode, 0)
            self.assertIn("Stable=36 preparer=35.15.18", stale_floor.stderr)

            replacement_preparer = self.generate_release(
                fixture_root, "preparer-replacement", "preparer", "36.0.1"
            )
            same_role = self.validate_progression(replacement_preparer, stale_preparer)
            self.assertEqual(same_role.returncode, 0, same_role.stderr)
            self.assertIn("preparer -> preparer with exact retained history", same_role.stdout)

            replacement_transition = self.generate_release(
                fixture_root,
                "transition-replacement",
                "transition",
                "36.0.2",
                replacement_preparer,
            )
            p_to_t = self.validate_progression(replacement_transition, replacement_preparer)
            self.assertEqual(p_to_t.returncode, 0, p_to_t.stderr)
            self.assertIn("preparer -> transition with exact retained history", p_to_t.stdout)

            replacement_manifest = json.loads(
                Path(replacement_preparer["manifest"]).read_text(encoding="utf-8")
            )
            transition_manifest = json.loads(
                Path(replacement_transition["manifest"]).read_text(encoding="utf-8")
            )
            retained = dict(replacement_manifest["appcastItems"][0])
            retained["rolloutManifestName"] = "identity-rollout.json"
            retained["rolloutManifestSha256"] = hashlib.sha256(
                Path(replacement_preparer["manifest"]).read_bytes()
            ).hexdigest()
            self.assertEqual(transition_manifest["appcastItems"][1], retained)

            replacement_floor = self.validate_floor(stable_appcast, replacement_transition)
            self.assertEqual(replacement_floor.returncode, 0, replacement_floor.stderr)
            self.assertIn("Stable=36 preparer=36.0.1", replacement_floor.stdout)


if __name__ == "__main__":
    unittest.main()
