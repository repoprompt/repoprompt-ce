#!/usr/bin/env python3
"""Focused behavioral coverage for the Core/Shared boundary guardrail."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARDRAIL = ROOT / "Scripts/core_boundary_guardrails.sh"


class CoreBoundaryGuardrailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy2(GUARDRAIL, scripts / GUARDRAIL.name)
        (scripts / "package_app.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")

        core_root = self.root / "Sources/RepoPromptCore"
        core_root.mkdir(parents=True)
        (core_root / "Core.swift").write_text("import Foundation\n", encoding="utf-8")
        native_importers = {
            "RepoPromptC": (
                "FileSystem/GitignoreCompiler.swift",
                "Utilities/StringFNV.swift",
                "Utilities/StringLineEndingUtilities.swift",
                "WorkspaceContext/Search/PathSearchIndex.swift",
                "WorkspaceContext/Search/RepoSearchBatchScorer.swift",
                "WorkspaceContext/Search/SearchMatch.swift",
                "WorkspaceContext/Search/SearchPathFiltering.swift",
            ),
            "CSwiftPCRE2": (
                "Regex/PCRE2Error.swift",
                "Regex/PCRE2JIT.swift",
                "Regex/PCRE2Options.swift",
                "Regex/PCRE2Regex.swift",
            ),
            "RepoPromptSyntaxCBridge": ("SyntaxParsing/SyntaxManager.swift",),
            "SwiftTreeSitter": (
                "CodeMap/CodeMapCaptureIndex.swift",
                "CodeMap/CodeMapGenerator.swift",
                "CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift",
                "CodeMap/LanguageStrategies/TypeScriptCodeMapStrategy.swift",
                "SyntaxParsing/SyntaxManager.swift",
            ),
            "Cuchardet": ("FileSystem/FileSystemService+ContentLoading.swift",),
            "UniversalCharsetDetection": ("FileSystem/FileSystemService+ContentLoading.swift",),
        }
        source_imports: dict[str, list[str]] = {}
        for module, paths in native_importers.items():
            for path in paths:
                source_imports.setdefault(path, []).append(module)
        for path, modules in source_imports.items():
            source = core_root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("".join(f"import {module}\n" for module in modules), encoding="utf-8")

        (self.root / "Sources/RepoPromptCoreMacOS").mkdir(parents=True)
        (self.root / "Sources/RepoPromptPOSIXSupport/Descriptors").mkdir(parents=True)
        (self.root / "Sources/RepoPromptPOSIXSupport/Descriptors/POSIXDescriptorSupport.swift").write_text(
            "import Foundation\n",
            encoding="utf-8",
        )
        (self.root / "Sources/RepoPromptSyntaxCBridge").mkdir(parents=True)
        self.shared_mcp = self.root / "Sources/RepoPromptShared/MCP"
        self.shared_mcp.mkdir(parents=True)
        (self.shared_mcp / "JSONRPCBridgeLedger.swift").write_text(
            "import CryptoKit\nimport Foundation\n",
            encoding="utf-8",
        )
        (self.shared_mcp / "Other.swift").write_text("import Foundation\n", encoding="utf-8")

    def run_guardrail(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "Scripts/core_boundary_guardrails.sh"],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_allows_cryptokit_only_in_jsonrpc_bridge_ledger(self) -> None:
        result = self.run_guardrail()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_cryptokit_in_other_shared_file(self) -> None:
        (self.shared_mcp / "Other.swift").write_text("import CryptoKit\n", encoding="utf-8")

        result = self.run_guardrail()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Other.swift:1:import CryptoKit", result.stderr)

    def test_rejects_all_darwin_and_posix_imports_in_shared(self) -> None:
        cases = (
            ("Other.swift", "Darwin"),
            ("JSONRPCBridgeLedger.swift", "Darwin"),
            ("Other.swift", "Glibc"),
            ("Other.swift", "SystemPackage"),
            ("Other.swift", "RepoPromptPOSIXSupport"),
        )
        for filename, module in cases:
            with self.subTest(filename=filename, module=module):
                (self.shared_mcp / "JSONRPCBridgeLedger.swift").write_text(
                    "import CryptoKit\nimport Foundation\n",
                    encoding="utf-8",
                )
                (self.shared_mcp / "Other.swift").write_text("import Foundation\n", encoding="utf-8")
                (self.shared_mcp / filename).write_text(f"import {module}\n", encoding="utf-8")

                result = self.run_guardrail()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{filename}:1:import {module}", result.stderr)


if __name__ == "__main__":
    unittest.main()
