#!/usr/bin/env python3
"""Regression tests for the packaged macOS runtime import gate."""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import validate_macos_runtime_symbols as validator


class MacOSRuntimeSymbolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / "RepoPrompt CE.app"
        macos = self.app / "Contents/MacOS"
        macos.mkdir(parents=True)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleExecutable": "RepoPromptDebug"}))
        for name in ("RepoPromptDebug", "repoprompt-mcp"):
            (macos / name).write_bytes(b"fixture")

    def inspect(self, app_output: str = "", helper_output: str = "") -> None:
        def nm(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            self.assertEqual(command[:7], ["xcrun", "nm", "-arch", "all", "-u", "-j", command[-1]])
            output = helper_output if Path(command[-1]).name == "repoprompt-mcp" else app_output
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

        with patch.object(validator.subprocess, "run", side_effect=nm):
            validator.validate_app(self.app)

    def test_compatible_oslog_imports_pass(self) -> None:
        self.inspect("_os_log_type_enabled\n_$s2os6LoggerVyACSo03OS_A0CcfC\n", "_os_log_create\n")

    def test_known_unsafe_apis_fail_in_either_executable(self) -> None:
        symbols = {
            "_$s2os6LoggerV9isEnabled4typeSbSo0a5_log_E2_ta_tF": "os.Logger.isEnabled(type:)",
            "_$s2os6LoggerV8disabledACvgZ": "os.Logger.disabled",
        }
        for symbol, api in symbols.items():
            for helper in (False, True):
                with self.subTest(api=api, helper=helper):
                    with self.assertRaises(validator.ValidationError) as raised:
                        self.inspect("" if helper else symbol, symbol if helper else "")
                    self.assertIn(api, str(raised.exception))
                    self.assertIn("repoprompt-mcp:" if helper else "RepoPromptDebug:", str(raised.exception))

    def test_unsafe_import_in_non_host_slice_fails(self) -> None:
        output = (
            "RepoPromptDebug (for architecture arm64):\n_os_log_type_enabled\n"
            "RepoPromptDebug (for architecture x86_64):\n"
            "_$s2os6LoggerV9isEnabled4typeSbSo0a5_log_E2_ta_tF\n"
        )
        with self.assertRaisesRegex(validator.ValidationError, "os.Logger.isEnabled"):
            self.inspect(output)

    def test_nm_failure_is_not_reported_as_compatible(self) -> None:
        with patch.object(validator.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 1, stdout="", stderr="not a Mach-O file",
        )):
            with self.assertRaisesRegex(validator.ValidationError, "could not inspect"):
                validator.validate_app(self.app)

    def test_missing_helper_fails(self) -> None:
        (self.app / "Contents/MacOS/repoprompt-mcp").unlink()
        with self.assertRaisesRegex(validator.ValidationError, "expected non-symlink executable"):
            self.inspect()

    def test_symlink_helper_fails(self) -> None:
        helper = self.app / "Contents/MacOS/repoprompt-mcp"
        helper.unlink()
        helper.symlink_to("RepoPromptDebug")
        with self.assertRaisesRegex(validator.ValidationError, "expected non-symlink executable"):
            self.inspect()

    def test_invalid_executable_metadata_fails(self) -> None:
        for executable in ("", "..", "../outside", 123):
            with self.subTest(executable=executable):
                self.info.write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
                with self.assertRaisesRegex(validator.ValidationError, "invalid CFBundleExecutable"):
                    validator.validate_app(self.app)


if __name__ == "__main__":
    unittest.main()
