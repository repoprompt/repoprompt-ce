#!/usr/bin/env python3
"""Deterministic negative tests for Core-isolation structural guards."""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from core_isolation_guardrails import (
    CORE_DECLARATIONS,
    EXPECTED_DEPENDENCIES,
    RESERVED_TEST_PATHS,
    TARGET_PATHS,
    validate_package,
    validate_sources,
)


def dependency(value: tuple[str, str, str]) -> dict[str, list[str | None]]:
    kind, name, package = value
    if kind == "target":
        return {"byName": [name, None]}
    return {"product": [name, package, None, None]}


def valid_package() -> dict[str, object]:
    targets = [
        {
            "name": name,
            "path": TARGET_PATHS[name],
            "type": "executable" if name == "RepoPromptHeadless" else "regular",
            "dependencies": [dependency(item) for item in sorted(expected)],
        }
        for name, expected in EXPECTED_DEPENDENCIES.items()
    ]
    targets.extend(
        [
            {
                "name": "RepoPrompt",
                "path": "Sources/RepoPrompt",
                "type": "executable",
                "dependencies": [
                    dependency(("target", "RepoPromptShared", "")),
                    dependency(("target", "RepoPromptCore", "")),
                    dependency(("target", "RepoPromptCoreMacOS", "")),
                    dependency(("target", "RepoPromptC", "")),
                    dependency(("target", "CSwiftPCRE2", "")),
                    dependency(("target", "TreeSitterScannerSupport", "")),
                    dependency(("target", "Sparkle", "")),
                ],
            },
            {
                "name": "RepoPromptMCP",
                "path": "Sources/RepoPromptMCP",
                "type": "executable",
                "dependencies": [
                    dependency(("target", "RepoPromptShared", "")),
                    dependency(("target", "RepoPromptPOSIXSupport", "")),
                ],
            },
            {
                "name": "RepoPromptShared",
                "path": "Sources/RepoPromptShared",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "RepoPromptC",
                "path": "Sources/RepoPromptC",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "CSwiftPCRE2",
                "path": "Sources/CSwiftPCRE2",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "TreeSitterScannerSupport",
                "path": "Sources/TreeSitterScannerSupport",
                "type": "regular",
                "dependencies": [],
            },
            {
                "name": "Sparkle",
                "path": "Vendor/Sparkle",
                "type": "binary",
                "dependencies": [],
            },
        ]
    )
    return {
        "products": [
            {"name": "RepoPrompt", "targets": ["RepoPrompt"]},
            {"name": "repoprompt-mcp", "targets": ["RepoPromptMCP"]},
            {"name": "repoprompt-headless", "targets": ["RepoPromptHeadless"]},
        ],
        "targets": targets,
    }


class CoreIsolationGuardrailTests(unittest.TestCase):
    def test_valid_frozen_graph_passes(self) -> None:
        self.assertEqual(validate_package(valid_package()), [])

    def test_reverse_dependency_is_rejected(self) -> None:
        package = copy.deepcopy(valid_package())
        core = next(target for target in package["targets"] if target["name"] == "RepoPromptCore")
        core["dependencies"].append(dependency(("target", "RepoPrompt", "")))
        errors = validate_package(package)
        self.assertTrue(any("RepoPromptCore direct dependencies drifted" in error for error in errors))
        self.assertTrue(any("dependency cycle" in error for error in errors))

    def test_acyclic_forbidden_app_and_mcp_edges_are_rejected(self) -> None:
        package = copy.deepcopy(valid_package())
        app = next(target for target in package["targets"] if target["name"] == "RepoPrompt")
        app["dependencies"].append(dependency(("target", "RepoPromptHeadless", "")))
        mcp = next(target for target in package["targets"] if target["name"] == "RepoPromptMCP")
        mcp["dependencies"].append(dependency(("target", "RepoPromptCore", "")))
        errors = validate_package(package)
        self.assertTrue(any("RepoPrompt local dependencies drifted" in error for error in errors))
        self.assertTrue(any("RepoPromptMCP local dependencies drifted" in error for error in errors))

    def test_forbidden_core_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptCore"] / "Forbidden.swift").write_text("import SwiftUI\n")
            errors = validate_sources(root)
            self.assertTrue(any("imports forbidden module SwiftUI" in error for error in errors))

    def test_attributed_forbidden_core_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptCore"] / "Forbidden.swift").write_text(
                "@_implementationOnly import AppKit\n"
            )
            errors = validate_sources(root)
            self.assertTrue(any("imports forbidden module AppKit" in error for error in errors))

    def test_unprefixed_c_symbol_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            (root / TARGET_PATHS["RepoPromptPOSIXSupport"] / "unsafe.h").write_text(
                "int unsafe_helper(void);\n"
            )
            errors = validate_sources(root)
            self.assertTrue(any("declares unprefixed CE C symbol unsafe_helper" in error for error in errors))

    def test_headless_app_packaging_overlap_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            script = root / "Scripts/package_app.sh"
            script.parent.mkdir(parents=True)
            script.write_text("cp repoprompt-headless RepoPrompt.app/Contents/MacOS/\n")
            errors = validate_sources(root)
            self.assertTrue(any("package_app.sh must remain app/proxy-only" in error for error in errors))

    def test_placeholder_test_target_and_root_are_rejected(self) -> None:
        package = copy.deepcopy(valid_package())
        package["targets"].append(
            {
                "name": "RepoPromptCoreTests",
                "path": RESERVED_TEST_PATHS["RepoPromptCoreTests"],
                "type": "test",
                "dependencies": [dependency(("target", "RepoPromptCore", ""))],
            }
        )
        self.assertTrue(any("must remain undeclared" in error for error in validate_package(package)))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            reserved = root / RESERVED_TEST_PATHS["RepoPromptCoreTests"]
            reserved.mkdir(parents=True)
            (reserved / "PlaceholderTests.swift").write_text("// placeholder\n")
            self.assertTrue(any("must remain absent" in error for error in validate_sources(root)))

    def test_phase_two_declaration_duplicate_in_any_production_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._write_minimal_sources(root)
            duplicate = root / TARGET_PATHS["RepoPromptCoreMacOS"] / "Duplicate.swift"
            duplicate.write_text("struct WorkspaceModel {}\n")
            errors = validate_sources(root)
            self.assertTrue(any("WorkspaceModel must have exactly one" in error for error in errors))

    def _write_minimal_sources(self, root: Path) -> None:
        for relative in TARGET_PATHS.values():
            directory = root / relative
            directory.mkdir(parents=True)
            (directory / "Scaffold.swift").write_text("// scaffold\n")
        app = root / "Sources/RepoPrompt/Frozen.swift"
        app.parent.mkdir(parents=True)
        declarations = "\n".join(f"struct {name} {{}}" for name in sorted(CORE_DECLARATIONS))
        app.write_text(declarations + "\n")


if __name__ == "__main__":
    unittest.main()
