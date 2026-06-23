#!/usr/bin/env python3
from __future__ import annotations

from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT_PATH = Path(__file__).with_name("generate_xcode_workspace.py")
SPEC = importlib.util.spec_from_file_location("generate_xcode_workspace", SCRIPT_PATH)
assert SPEC and SPEC.loader
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class XcodeWorkspaceGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = generator.load_package_manifest(generator.REPO_ROOT)
        cls.outputs = generator.render_outputs(generator.REPO_ROOT, cls.manifest)

    def generate_in_temporary_directory(self) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        destination = root / "xcode"
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        return temporary, destination

    def test_generation_is_byte_identical(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        first = {path.relative_to(destination): path.read_bytes() for path in destination.rglob("*") if path.is_file()}
        root = Path(temporary.name)
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        second = {path.relative_to(destination): path.read_bytes() for path in destination.rglob("*") if path.is_file()}
        self.assertEqual(first, second)

    def test_outputs_do_not_embed_checkout_path_or_timestamps(self) -> None:
        checkout = str(generator.REPO_ROOT).encode()
        for path, content in self.outputs.items():
            content_without_working_directory = content.replace(
                f'customWorkingDirectory = "{generator.REPO_ROOT}"'.encode(),
                b"",
            )
            self.assertNotIn(checkout, content_without_working_directory, str(path))
            self.assertNotRegex(content.decode(errors="ignore"), r"20\d\d-\d\d-\d\d[T ]")

    def test_workspace_references_project_and_root_package(self) -> None:
        workspace = self.outputs[Path(generator.WORKSPACE_NAME) / "contents.xcworkspacedata"].decode()
        self.assertIn("group:RepoPromptCE.xcodeproj", workspace)
        self.assertIn("group:../..", workspace)

    def test_custom_destination_uses_correct_relative_repository_path(self) -> None:
        destination = generator.REPO_ROOT / ".build/xcode-custom/team/workspace"
        outputs = generator.render_outputs(generator.REPO_ROOT, self.manifest, destination)
        workspace = outputs[Path(generator.WORKSPACE_NAME) / "contents.xcworkspacedata"].decode()
        self.assertIn("group:../../../..", workspace)
        metadata = json.loads(outputs[Path("generation.json")])
        self.assertEqual(metadata["repositoryRelativePath"], "../../../..")

    def test_project_has_delegated_test_scheme(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.TEST_SCHEME}.xcscheme"
        scheme = self.outputs[path].decode()
        self.assertIn(f'BlueprintName = "{generator.TEST_SCHEME}"', scheme)
        self.assertIn(f'ReferencedContainer = "container:{generator.PROJECT_NAME}"', scheme)

    def test_workspace_lockfile_is_exact_copy(self) -> None:
        copied = self.outputs[Path(generator.WORKSPACE_NAME) / "xcshareddata/swiftpm/Package.resolved"]
        self.assertEqual((generator.REPO_ROOT / "Package.resolved").read_bytes(), copied)

    def test_generated_readme_documents_native_xcode_limitations(self) -> None:
        readme = self.outputs[Path("README.md")].decode()
        self.assertIn("not mutate `Vendor/`", readme)
        self.assertIn("RepoPromptMCP", readme)

    def test_project_has_exactly_three_convenience_targets(self) -> None:
        project = self.outputs[Path(generator.PROJECT_NAME) / "project.pbxproj"].decode()
        self.assertEqual(project.count("isa = PBXLegacyTarget;"), 3)
        self.assertIn(generator.APP_SCHEME, project)
        self.assertIn(generator.MCP_SCHEME, project)
        self.assertIn(generator.TEST_SCHEME, project)

    def test_convenience_targets_do_not_pass_xcode_build_settings(self) -> None:
        project = self.outputs[Path(generator.PROJECT_NAME) / "project.pbxproj"].decode()
        self.assertEqual(project.count("passBuildSettingsInEnvironment = 0;"), 3)
        self.assertNotIn("passBuildSettingsInEnvironment = 1;", project)

    def test_app_scheme_has_runnable_markers_and_prepare_action(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.APP_SCHEME}.xcscheme"
        scheme = self.outputs[path].decode()
        self.assertIn(str(generator.DEFAULT_DEBUG_APP_BUNDLE), scheme)
        self.assertIn("REPOPROMPT_LAUNCH_SOURCE", scheme)
        self.assertIn("__XCODE_BUILT_PRODUCTS_DIR_PATHS", scheme)
        self.assertIn("prepare-app-run", scheme)
        self.assertNotIn("{repository_path}", scheme)

        document = ET.fromstring(scheme)
        launch_action = document.find("LaunchAction")
        profile_action = document.find("ProfileAction")
        self.assertIsNotNone(launch_action)
        self.assertIsNotNone(profile_action)
        expected_working_directory = str(generator.REPO_ROOT)
        self.assertEqual(
            launch_action.attrib["customWorkingDirectory"],
            expected_working_directory,
        )
        self.assertEqual(
            profile_action.attrib["customWorkingDirectory"],
            expected_working_directory,
        )
        self.assertTrue(Path(expected_working_directory).is_dir())
        expected_runnable = str(generator.DEFAULT_DEBUG_APP_BUNDLE)
        self.assertEqual(
            launch_action.find("PathRunnable").attrib["FilePath"],
            expected_runnable,
        )
        self.assertEqual(
            profile_action.find("PathRunnable").attrib["FilePath"],
            expected_runnable,
        )

        environment = {
            item.attrib["key"]: item.attrib["value"]
            for item in launch_action.findall("./EnvironmentVariables/EnvironmentVariable")
        }
        self.assertEqual(
            environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"],
            "$(PROJECT_DIR)/../../.build/debug",
        )

    def test_mcp_scheme_points_at_debug_executable(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.MCP_SCHEME}.xcscheme"
        self.assertIn(".build/debug/repoprompt-mcp", self.outputs[path].decode())

    def test_check_detects_corruption(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        generator.check_outputs(destination, self.outputs)
        (destination / "generation.json").write_text("{}\n")
        with self.assertRaisesRegex(generator.GeneratorError, "stale"):
            generator.check_outputs(destination, self.outputs)
        root = Path(temporary.name)
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        generator.check_outputs(destination, self.outputs)

    def test_check_ignores_xcode_user_state(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        user_state = (
            destination
            / generator.WORKSPACE_NAME
            / "xcuserdata/developer.xcuserdatad/UserInterfaceState.xcuserstate"
        )
        user_state.parent.mkdir(parents=True)
        user_state.write_text("local state")
        generator.check_outputs(destination, self.outputs)

    def test_check_remains_strict_for_unmanaged_files(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        unexpected = destination / generator.WORKSPACE_NAME / "unexpected.txt"
        unexpected.write_text("not managed")
        with self.assertRaisesRegex(generator.GeneratorError, "unexpected generated file"):
            generator.check_outputs(destination, self.outputs)

    def test_manifest_errors_are_actionable(self) -> None:
        missing_product = deepcopy(self.manifest)
        missing_product["products"] = [
            product for product in missing_product["products"] if product["name"] != "RepoPrompt"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "executable product 'RepoPrompt'"):
            generator.validate_manifest(missing_product, generator.REPO_ROOT)

        missing_target = deepcopy(self.manifest)
        missing_target["targets"] = [
            target for target in missing_target["targets"] if target["name"] != "RepoPromptShared"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "target 'RepoPromptShared'"):
            generator.validate_manifest(missing_target, generator.REPO_ROOT)

        bad_resources = deepcopy(self.manifest)
        for target in bad_resources["targets"]:
            if target["name"] == "RepoPromptTests":
                target["resources"] = []
        with self.assertRaisesRegex(generator.GeneratorError, "CodeMap/Fixtures"):
            generator.validate_manifest(bad_resources, generator.REPO_ROOT)

    def test_generation_does_not_modify_package_authority(self) -> None:
        before = {name: digest(generator.REPO_ROOT / name) for name in ("Package.swift", "Package.resolved")}
        temporary, _ = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        after = {name: digest(generator.REPO_ROOT / name) for name in ("Package.swift", "Package.resolved")}
        self.assertEqual(before, after)

    def test_destination_rejects_destructive_paths(self) -> None:
        with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
            generator.validate_destination(generator.REPO_ROOT)
        with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
            generator.validate_destination(generator.REPO_ROOT / "Sources")

    def test_custom_destination_is_confined_to_dedicated_subtree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            default = root / "xcode"
            custom = root / "xcode-custom"
            accepted = generator.validate_destination(
                custom / "team/workspace",
                default,
                custom,
                root,
            )
            self.assertEqual(accepted, custom / "team/workspace")
            with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
                generator.validate_destination(root / "other", default, custom, root)
            with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
                generator.validate_destination(custom, default, custom, root)

    def test_existing_unowned_destination_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "xcode"
            destination.mkdir()
            sentinel = destination / "sentinel.txt"
            sentinel.write_text("keep me")
            with self.assertRaisesRegex(generator.GeneratorError, "non-generator-owned"):
                generator.write_outputs(
                    destination,
                    self.outputs,
                    default_destination=destination,
                    custom_root=root / "custom",
                    repository_root=root,
                )
            self.assertEqual(sentinel.read_text(), "keep me")

    def test_destination_rejects_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            destination = root / "xcode"
            destination.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(generator.GeneratorError, "symlinked destination component"):
                generator.validate_destination(
                    destination,
                    destination,
                    root / "custom",
                    root,
                )

    def test_uncoordinated_prepare_run_is_rejected_without_side_effects(self) -> None:
        environment = os.environ.copy()
        environment["CONFIGURATION"] = "Debug"
        environment["REPOPROMPT_XCODE_UNCOORDINATED"] = "1"
        result = subprocess.run(
            [generator.REPO_ROOT / "Scripts/xcode_developer_workflow.sh", "prepare-app-run"],
            cwd=generator.REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build/test-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
