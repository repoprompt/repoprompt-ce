#!/usr/bin/env python3
"""Focused regression tests for reviewed release promotion."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


class ReleasePromotionTests(unittest.TestCase):
    def test_verify_accepts_reviewed_draft_with_matching_key_and_assets(self) -> None:
        result, _capture, _tools = self.run_promotion("verify")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: reviewed source release assets verified for v1.0.0.", result.stdout)

    def test_promote_mirrors_draft_before_publishing_and_runs_anonymous_smoke(self) -> None:
        result, capture, _tools = self.run_promotion("promote")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: anonymous release smoke passed for v1.0.0.", result.stdout)
        calls = capture.read_text(encoding="utf-8").splitlines()
        create = next(index for index, line in enumerate(calls) if "release create v1.0.0" in line)
        publish_update = next(
            index
            for index, line in enumerate(calls)
            if "release edit v1.0.0 --repo repoprompt/repoprompt-ce-updates" in line
        )
        publish_source = next(
            index
            for index, line in enumerate(calls)
            if "release edit v1.0.0 --repo repoprompt/repoprompt-ce " in line
        )
        self.assertLess(create, publish_update)
        self.assertLess(publish_update, publish_source)

    def test_promote_resumes_matching_updater_draft_without_reupload(self) -> None:
        result, capture, _tools = self.run_promotion("promote", update_state="draft")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = capture.read_text(encoding="utf-8")
        self.assertNotIn("release create v1.0.0", calls)
        self.assertIn("release edit v1.0.0 --repo repoprompt/repoprompt-ce-updates", calls)

    def test_verify_allows_published_source_for_partial_promotion_recovery(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", source_is_draft=False)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_verify_rejects_extra_source_asset(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", extra_source_asset=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain exactly", result.stderr)

    def test_verify_rejects_duplicate_appcast_items(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", duplicate_appcast_item=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("appcast must contain exactly one item", result.stderr)

    def test_verify_rejects_mismatched_dmg_app(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", mismatched_dmg_app=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DMG app contents do not match", result.stderr)

    def test_promote_rejects_non_increasing_build(self) -> None:
        result, _capture, _tools = self.run_promotion("promote", latest_build="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Stable promotion requires BUILD_NUMBER > 1", result.stderr)

    def test_promote_rejects_latest_query_failure_other_than_first_release_404(self) -> None:
        result, _capture, _tools = self.run_promotion("promote", latest_http_status="503")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 503", result.stderr)

    def test_promote_rejects_unreviewed_checksums_digest(self) -> None:
        result, _capture, tool_capture = self.run_promotion("promote", reviewed_checksums_sha256="not-reviewed")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reviewed SHA256SUMS digest mismatch", result.stderr)
        calls = tool_capture.read_text(encoding="utf-8") if tool_capture.exists() else ""
        self.assertEqual(calls, "")

    def test_verify_rejects_sparkle_private_key_mismatch(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", derived_public_key="different-public-key")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Protected Sparkle private key does not match", result.stderr)

    def test_verify_rejects_source_appcast_without_public_updater_url(self) -> None:
        result, _capture, _tools = self.run_promotion(
            "verify",
            enclosure_url="https://github.com/repoprompt/repoprompt-ce/releases/download/v1.0.0/RepoPrompt-1.0.0-1.zip",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Appcast enclosure URL mismatch", result.stderr)

    def test_verify_rejects_tag_that_disagrees_with_release_metadata(self) -> None:
        result, _capture, _tools = self.run_promotion("verify", release_tag="v1.0.1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release tag must match release metadata", result.stderr)

    def run_promotion(
        self,
        mode: str,
        *,
        source_is_draft: bool = True,
        update_state: str = "absent",
        derived_public_key: str = "fixture-public-key",
        enclosure_url: str = (
            "https://github.com/repoprompt/repoprompt-ce-updates/"
            "releases/download/v1.0.0/RepoPrompt-1.0.0-1.zip"
        ),
        duplicate_appcast_item: bool = False,
        extra_source_asset: bool = False,
        mismatched_dmg_app: bool = False,
        latest_build: str = "",
        latest_http_status: str = "404",
        reviewed_checksums_sha256: str = "",
        release_tag: str = "v1.0.0",
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        vendor_bin = root / "Vendor" / "Sparkle" / "bin"
        assets = temp_dir / "assets"
        fake_bin = temp_dir / "bin"
        app = temp_dir / "fixture" / "RepoPrompt CE.app"
        dmg_app = temp_dir / "dmg-fixture" / "RepoPrompt CE.app"
        for directory in (scripts, vendor_bin, assets, fake_bin, app / "Contents" / "MacOS", app / "Contents" / "Resources" / "bin"):
            directory.mkdir(parents=True, exist_ok=True)

        shutil.copy2(SCRIPT_DIR / "promote_release.sh", scripts / "promote_release.sh")
        shutil.copy2(
            SCRIPT_DIR / "validate_embedded_mcp_helper_layout.sh",
            scripts / "validate_embedded_mcp_helper_layout.sh",
        )
        shutil.copy2(SCRIPT_DIR / "validate_packaged_legal.sh", scripts / "validate_packaged_legal.sh")
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        shutil.copy2(SCRIPT_DIR / "verify_sparkle_signature.swift", scripts / "verify_sparkle_signature.swift")
        (scripts / "promote_release.sh").chmod(0o755)
        (scripts / "validate_embedded_mcp_helper_layout.sh").chmod(0o755)
        (scripts / "validate_packaged_legal.sh").chmod(0o755)
        self.write_stub(scripts, "verify_remote_release_commit.sh", "printf 'OK: fixture remote tag remains bound.\\n'\n")
        self.write_stub(scripts, "verify_sparkle_vendor.sh", "printf 'OK: fixture Sparkle payload matches.\\n'\n")
        self.write_stub(scripts, "validate_app_architectures.sh", "printf 'OK: fixture universal architectures.\\n'\n")
        self.write_stub(scripts, "write_app_artifact_manifest.py", "printf 'OK: fixture artifact manifest.\\n'\n")
        (root / "version.env").write_text(
            textwrap.dedent(
                """\
                APP_NAME=RepoPrompt
                DISPLAY_NAME="RepoPrompt CE"
                MARKETING_VERSION=1.0.0
                BUILD_NUMBER=1
                BUNDLE_ID=com.pvncher.repoprompt.ce
                SIGNING_TEAM_ID=648A27MST5
                """
            ),
            encoding="utf-8",
        )
        (app / "Contents" / "Info.plist").write_text("fixture plist\n", encoding="utf-8")
        self.write_stub(
            app / "Contents" / "MacOS",
            "repoprompt-mcp",
            "printf 'ERROR: fixture packaged helper must not execute\\n' >&2\nexit 137\n",
        )
        (app / "Contents" / "Resources" / "repoprompt-mcp").symlink_to("../MacOS/repoprompt-mcp")
        (app / "Contents" / "Resources" / "bin" / "repoprompt-mcp").symlink_to("../../MacOS/repoprompt-mcp")
        self.write_legal_tree(root, app)
        shutil.copytree(app, dmg_app, symlinks=True)
        if mismatched_dmg_app:
            (dmg_app / "Contents" / "dmg-only-drift.txt").write_text("drift\n", encoding="utf-8")

        zip_path = assets / "RepoPrompt-1.0.0-1.zip"
        dmg_path = assets / "RepoPrompt-1.0.0-1.dmg"
        appcast_path = assets / "appcast.xml"
        checksums_path = assets / "SHA256SUMS"
        artifact_manifest_path = assets / "RepoPrompt-1.0.0-1-artifact-manifest.json"
        previous_appcast = assets / "previous-appcast.xml"
        zip_path.write_text("fixture zip\n", encoding="utf-8")
        dmg_path.write_text("fixture dmg\n", encoding="utf-8")
        artifact_manifest_path.write_text('{"schema_version":1}\n', encoding="utf-8")
        item = textwrap.dedent(
            f"""\
            <item>
              <sparkle:version>1</sparkle:version>
              <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
              <enclosure url="{enclosure_url}" length="{zip_path.stat().st_size}" sparkle:edSignature="fixture-signature" />
            </item>
            """
        )
        appcast_path.write_text(
            textwrap.dedent(
                f"""\
                <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
                  <channel>
                    {item}
                    {item if duplicate_appcast_item else ""}
                  </channel>
                </rss>
                """
            ),
            encoding="utf-8",
        )
        previous_appcast.write_text(
            textwrap.dedent(
                f"""\
                <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
                  <channel><item><sparkle:version>{latest_build or "0"}</sparkle:version></item></channel>
                </rss>
                """
            ),
            encoding="utf-8",
        )
        checksums_path.write_text(
            "".join(
                f"{self.sha256(path)}  {path.name}\n"
                for path in (zip_path, dmg_path, appcast_path, artifact_manifest_path)
            ),
            encoding="utf-8",
        )

        capture = temp_dir / "gh-calls.txt"
        tool_capture = temp_dir / "tool-calls.txt"
        self.write_stub(
            fake_bin,
            "gh",
            """\
            printf '%s\\n' "$*" >> "$FAKE_GH_CAPTURE"
            source_assets='[{"name":"RepoPrompt-1.0.0-1.zip"},{"name":"RepoPrompt-1.0.0-1.dmg"},{"name":"appcast.xml"},{"name":"SHA256SUMS"},{"name":"RepoPrompt-1.0.0-1-artifact-manifest.json"}]'
            if [[ "$FAKE_EXTRA_SOURCE_ASSET" == "true" ]]; then
                source_assets='[{"name":"RepoPrompt-1.0.0-1.zip"},{"name":"RepoPrompt-1.0.0-1.dmg"},{"name":"appcast.xml"},{"name":"SHA256SUMS"},{"name":"RepoPrompt-1.0.0-1-artifact-manifest.json"},{"name":"unexpected.txt"}]'
            fi
            update_assets='[{"name":"RepoPrompt-1.0.0-1.zip"},{"name":"appcast.xml"},{"name":"SHA256SUMS"},{"name":"RepoPrompt-1.0.0-1-artifact-manifest.json"}]'
            if [[ "$1" == "release" && "$2" == "view" && "$*" == *"--repo repoprompt/repoprompt-ce "* ]]; then
                printf '{"tagName":"v1.0.0","isDraft":%s,"isPrerelease":false,"assets":%s,"body":"Release-Commit: `fixture-release-commit`"}\\n' "$FAKE_SOURCE_IS_DRAFT" "$source_assets"
            elif [[ "$1" == "release" && "$2" == "view" && "$*" == *"--repo repoprompt/repoprompt-ce-updates "* ]]; then
                if [[ "$FAKE_UPDATE_STATE" == "absent" ]] && ! grep -q 'release create v1.0.0' "$FAKE_GH_CAPTURE"; then
                    exit 1
                fi
                if [[ "$FAKE_UPDATE_STATE" == "draft" || "$FAKE_UPDATE_STATE" == "absent" ]]; then
                    is_draft=true
                else
                    is_draft=false
                fi
                printf '{"tagName":"v1.0.0","isDraft":%s,"isPrerelease":false,"assets":%s}\\n' "$is_draft" "$update_assets"
            elif [[ "$1" == "release" && "$2" == "download" ]]; then
                target=""
                while [[ "$#" -gt 0 ]]; do
                    if [[ "$1" == "--dir" ]]; then
                        shift
                        target="$1"
                    fi
                    shift || true
                done
                cp "$FAKE_ASSET_DIR"/RepoPrompt-1.0.0-1.zip "$target/"
                cp "$FAKE_ASSET_DIR"/appcast.xml "$target/"
                cp "$FAKE_ASSET_DIR"/SHA256SUMS "$target/"
                cp "$FAKE_ASSET_DIR"/RepoPrompt-1.0.0-1-artifact-manifest.json "$target/"
                if [[ "$*" != *"--repo repoprompt/repoprompt-ce-updates "* ]]; then
                    cp "$FAKE_ASSET_DIR"/RepoPrompt-1.0.0-1.dmg "$target/"
                fi
            elif [[ "$1" == "repo" && "$2" == "view" ]]; then
                printf 'PUBLIC\\n'
            fi
            """,
        )
        self.write_stub(
            fake_bin,
            "ditto",
            """\
            printf 'ditto\\n' >> "$FAKE_TOOL_CAPTURE"
            target="${@: -1}"
            mkdir -p "$target"
            cp -R "$FAKE_APP_SOURCE" "$target/RepoPrompt CE.app"
            """,
        )
        self.write_stub(
            fake_bin,
            "hdiutil",
            """\
            printf 'hdiutil\\n' >> "$FAKE_TOOL_CAPTURE"
            if [[ "$1" == "attach" ]]; then
                target="${@: -1}"
                cp -R "$FAKE_DMG_APP_SOURCE" "$target/RepoPrompt CE.app"
            fi
            """,
        )
        self.write_stub(
            fake_bin,
            "codesign",
            """\
            if [[ "$1" == "-dv" ]]; then
                printf 'Authority=Developer ID Application: Fixture (648A27MST5)\\nTeamIdentifier=648A27MST5\\n' >&2
            fi
            """,
        )
        self.write_stub(
            fake_bin,
            "plutil",
            """\
            case "$2" in
                CFBundleIdentifier) printf 'com.pvncher.repoprompt.ce\\n' ;;
                CFBundleShortVersionString) printf '1.0.0\\n' ;;
                CFBundleVersion) printf '1\\n' ;;
                SUFeedURL) printf 'https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml\\n' ;;
                SUPublicEDKey) printf 'fixture-public-key\\n' ;;
                *) exit 1 ;;
            esac
            """,
        )
        self.write_stub(
            fake_bin,
            "xcrun",
            """\
            printf 'xcrun\\n' >> "$FAKE_TOOL_CAPTURE"
            if [[ "$1" == "swift" ]]; then
                printf '%s\\n' "$FAKE_DERIVED_PUBLIC_KEY"
            fi
            """,
        )
        self.write_stub(
            fake_bin,
            "curl",
            """\
            args="$*"
            output=""
            url=""
            write_status=false
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --output) shift; output="$1" ;;
                    --write-out) shift; write_status=true ;;
                    http*) url="$1" ;;
                esac
                shift || true
            done
            case "$url" in
                https://api.github.com/repos/repoprompt/repoprompt-ce-updates/releases/latest)
                    if [[ "$args" != *"Authorization: Bearer update-token"* ]]; then
                        $write_status && printf '403'
                    elif [[ -n "$FAKE_LATEST_BUILD" && ! -f "$FAKE_PROMOTION_PUBLISHED" ]]; then
                        printf '{"tag_name":"v0.9.0"}\\n' > "$output"
                        $write_status && printf '200'
                    elif grep -q 'release edit v1.0.0 --repo repoprompt/repoprompt-ce-updates' "$FAKE_GH_CAPTURE" 2>/dev/null; then
                        if $write_status; then
                            printf '{"tag_name":"v1.0.0"}\\n' > "$output"
                            printf '200'
                        else
                            printf '{"tag_name":"v1.0.0"}\\n'
                        fi
                    else
                        $write_status && printf '%s' "$FAKE_LATEST_HTTP_STATUS"
                    fi
                    ;;
                https://github.com/repoprompt/repoprompt-ce-updates/releases/latest)
                    $write_status && printf 'https://github.com/repoprompt/repoprompt-ce-updates/releases/tag/v1.0.0'
                    ;;
                https://github.com/repoprompt/repoprompt-ce/releases/latest)
                    $write_status && printf 'https://github.com/repoprompt/repoprompt-ce/releases/tag/v1.0.0'
                    ;;
                */v0.9.0/appcast.xml) cp "$FAKE_ASSET_DIR/previous-appcast.xml" "$output" ;;
                */appcast.xml) cp "$FAKE_ASSET_DIR/appcast.xml" "$output" ;;
                */RepoPrompt-1.0.0-1.zip) cp "$FAKE_ASSET_DIR/RepoPrompt-1.0.0-1.zip" "$output" ;;
                */RepoPrompt-1.0.0-1.dmg) cp "$FAKE_ASSET_DIR/RepoPrompt-1.0.0-1.dmg" "$output" ;;
                */SHA256SUMS) cp "$FAKE_ASSET_DIR/SHA256SUMS" "$output" ;;
                */RepoPrompt-1.0.0-1-artifact-manifest.json) cp "$FAKE_ASSET_DIR/RepoPrompt-1.0.0-1-artifact-manifest.json" "$output" ;;
                *) printf 'unexpected curl URL: %s\\n' "$url" >&2; exit 1 ;;
            esac
            """,
        )
        self.write_stub(
            vendor_bin,
            "sign_update",
            "printf 'sign_update\\n' >> \"$FAKE_TOOL_CAPTURE\"\nprintf 'fixture-signature\\n'\n",
        )

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{fake_bin}:{env.get('PATH', '')}",
                "RELEASE_TAG": release_tag,
                "RELEASE_COMMIT": "fixture-release-commit",
                "SOURCE_GH_TOKEN": "source-token",
                "PUBLIC_UPDATE_GH_TOKEN": "update-token",
                "REVIEWED_CHECKSUMS_SHA256": reviewed_checksums_sha256 or self.sha256(checksums_path),
                "SPARKLE_PRIVATE_KEY": "fixture-private-key",
                "FAKE_GH_CAPTURE": str(capture),
                "FAKE_TOOL_CAPTURE": str(tool_capture),
                "FAKE_SOURCE_IS_DRAFT": "true" if source_is_draft else "false",
                "FAKE_UPDATE_STATE": update_state,
                "FAKE_EXTRA_SOURCE_ASSET": "true" if extra_source_asset else "false",
                "FAKE_ASSET_DIR": str(assets),
                "FAKE_APP_SOURCE": str(app),
                "FAKE_DMG_APP_SOURCE": str(dmg_app),
                "FAKE_DERIVED_PUBLIC_KEY": derived_public_key,
                "FAKE_LATEST_BUILD": latest_build,
                "FAKE_LATEST_HTTP_STATUS": latest_http_status,
                "FAKE_PROMOTION_PUBLISHED": str(temp_dir / "promotion-published"),
            }
        )
        result = subprocess.run(
            ["bash", str(scripts / "promote_release.sh"), mode],
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )
        if mode == "promote" and result.returncode == 0:
            (temp_dir / "promotion-published").touch()
        return result, capture, tool_capture

    @staticmethod
    def write_legal_tree(root: Path, app: Path) -> None:
        (root / "ThirdPartyLicenses" / "fixture").mkdir(parents=True)
        (root / "LICENSE").write_text("root license\n", encoding="utf-8")
        (root / "THIRD_PARTY_NOTICES.md").write_text("root notices\n", encoding="utf-8")
        (root / "ThirdPartyLicenses" / "fixture" / "LICENSE").write_text("fixture license\n", encoding="utf-8")
        legal = app / "Contents" / "Resources" / "Legal"
        legal.mkdir(parents=True)
        shutil.copy2(root / "LICENSE", legal / "LICENSE")
        shutil.copy2(root / "THIRD_PARTY_NOTICES.md", legal / "THIRD_PARTY_NOTICES.md")
        shutil.copytree(root / "ThirdPartyLicenses", legal / "ThirdPartyLicenses")

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def write_stub(bin_dir: Path, name: str, body: str) -> None:
        path = bin_dir / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
