#!/usr/bin/env python3
"""Focused behavioral coverage for the reviewed headless baseline guardrail."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from shared_runtime_headless_baseline import (
    DEFAULT_MANIFEST,
    HEADLESS_ROOTS,
    ROOT,
    ReviewedHeadlessBaselineError,
    render_manifest,
    verify_reviewed_headless_baseline,
    write_reviewed_headless_baseline,
)


class ReviewedHeadlessBaselineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.source_file = self.root / HEADLESS_ROOTS[0] / "Configuration/State.swift"
        self.test_file = self.root / HEADLESS_ROOTS[1] / "StateTests.swift"
        self.source_file.parent.mkdir(parents=True)
        self.test_file.parent.mkdir(parents=True)
        self.source_file.write_text("source\n", encoding="utf-8")
        self.test_file.write_text("tests\n", encoding="utf-8")
        self.manifest = self.root / "baseline.sha256"
        write_reviewed_headless_baseline(self.root, self.manifest)

    def test_repository_manifest_matches_complete_reviewed_headless_trees(self) -> None:
        verify_reviewed_headless_baseline(ROOT, DEFAULT_MANIFEST)

    def test_manifest_generation_is_deterministic_and_sorted(self) -> None:
        first = self.manifest.read_text(encoding="utf-8")
        write_reviewed_headless_baseline(self.root, self.manifest)
        second = self.manifest.read_text(encoding="utf-8")

        self.assertEqual(first, second)
        data_lines = [line for line in second.splitlines() if line and not line.startswith("#")]
        paths = [line.split("  ", 1)[1] for line in data_lines]
        self.assertEqual(paths, sorted(paths))

    def test_round_trips_a_path_with_trailing_whitespace(self) -> None:
        trailing = self.source_file.parent / "Trailing.swift "
        trailing.write_text("trailing\n", encoding="utf-8")
        write_reviewed_headless_baseline(self.root, self.manifest)

        verify_reviewed_headless_baseline(self.root, self.manifest)
        self.assertIn("Trailing.swift ", self.manifest.read_text(encoding="utf-8"))

    def test_rejects_a_path_with_a_newline(self) -> None:
        newline = self.source_file.parent / "Newline\n.swift"
        newline.write_text("newline\n", encoding="utf-8")

        with self.assertRaisesRegex(ReviewedHeadlessBaselineError, "cannot encode a newline"):
            write_reviewed_headless_baseline(self.root, self.manifest)

    def test_rejects_content_drift(self) -> None:
        self.source_file.write_text("changed\n", encoding="utf-8")

        with self.assertRaisesRegex(ReviewedHeadlessBaselineError, "content drifted"):
            verify_reviewed_headless_baseline(self.root, self.manifest)

    def test_rejects_added_file(self) -> None:
        added = self.source_file.parent / "Added.swift"
        added.write_text("added\n", encoding="utf-8")

        with self.assertRaisesRegex(ReviewedHeadlessBaselineError, "path set drifted"):
            verify_reviewed_headless_baseline(self.root, self.manifest)

    def test_rejects_removed_file(self) -> None:
        self.test_file.unlink()

        with self.assertRaisesRegex(ReviewedHeadlessBaselineError, "path set drifted"):
            verify_reviewed_headless_baseline(self.root, self.manifest)

    def test_rejects_manifest_entries_outside_the_locked_trees(self) -> None:
        self.manifest.write_text(
            render_manifest({"Sources/RepoPromptCore/Unexpected.swift": "0" * 64}),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ReviewedHeadlessBaselineError, "outside the locked trees"):
            verify_reviewed_headless_baseline(self.root, self.manifest)


if __name__ == "__main__":
    unittest.main()
