#!/usr/bin/env python3
"""Tests for the structured Codex update workflow contract validator."""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

import validate_codex_update_workflow as validator


class CodexUpdateWorkflowValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="codex-update-workflow-test-"))
        self.addCleanup(lambda: shutil.rmtree(self.temp, ignore_errors=True))
        self.baseline = validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8")

    def validate_text(self, text: str) -> None:
        path = self.temp / "workflow.yml"
        path.write_text(text, encoding="utf-8")
        validator.validate_workflow(path)

    def test_repository_workflow_satisfies_structured_contract(self) -> None:
        validator.validate_workflow()

    def test_security_and_trigger_mutations_fail_closed(self) -> None:
        mutations = {
            "automatic push trigger": self.baseline.replace(
                "  workflow_dispatch:\n",
                "  workflow_dispatch:\n  push:\n    branches: [main]\n",
                1,
            ),
            "write permission": self.baseline.replace("contents: read", "contents: write", 1),
            "job permission override": self.baseline.replace(
                "    runs-on: macos-26\n",
                "    runs-on: macos-26\n    permissions:\n      contents: write\n",
                1,
            ),
            "non-main gate": self.baseline.replace("refs/heads/main", "refs/heads/candidate", 1),
            "persisted checkout credentials": self.baseline.replace(
                "persist-credentials: false",
                "persist-credentials: true",
                1,
            ),
            "candidate tool substitution": self.baseline.replace(
                "python3 Scripts/codex_update_candidate.py",
                "python3 Scripts/other_candidate.py",
                1,
            ),
            "fixture input in official lane": self.baseline.replace(
                "--output-dir .build/codex-update-candidate/evidence",
                "--fixture-mode --output-dir .build/codex-update-candidate/evidence",
                1,
            ),
            "upload action substitution": self.baseline.replace(
                validator.UPLOAD_ACTION,
                "actions/upload-artifact@v4",
                1,
            ),
            "upload path substitution": self.baseline.replace(
                "path: .build/codex-update-candidate/evidence",
                "path: .build",
                1,
            ),
        }
        for label, mutated in mutations.items():
            with self.subTest(label=label):
                self.assertNotEqual(mutated, self.baseline)
                with self.assertRaises(validator.WorkflowContractError):
                    self.validate_text(mutated)


if __name__ == "__main__":
    unittest.main()
