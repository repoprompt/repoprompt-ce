#!/usr/bin/env python3
"""Unit tests for the build-modularization metrics and ratchet checks."""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import modularization_metrics as mm  # noqa: E402


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_fixture(root: Path) -> None:
    # Foundation-level utility wrongly depends upward on an App-level type.
    write(root, "Sources/RepoPrompt/Infrastructure/Utilities/Helper.swift",
          "struct HelperThing {\n    let font = FontPresetValue()\n}\n")
    write(root, "Sources/RepoPrompt/App/FontPresetValue.swift",
          "struct FontPresetValue {\n    static let shared = FontPresetValue()\n    let helper = HelperThing()\n}\n"
          "// HelperThing.shared in a comment must not count\n"
          "let label = \"UserDefaults.standard\"\n")
    write(root, "Sources/RepoPrompt/Features/Chat/ChatThing.swift",
          "struct ChatThingModel {\n    func run() { _ = FontPresetValue.shared; _ = UserDefaults.standard }\n}\n")
    write(root, "Sources/RepoPromptShared/Shared.swift", "struct SharedValue {}\n")
    write(root, "Tests/RepoPromptTests/ChatTests.swift",
          "@testable import RepoPromptApp\nfunc testIt() async throws { try await Task.sleep(for: .seconds(1)) }\n")


class StripTests(unittest.TestCase):
    def test_strips_comments_and_strings(self) -> None:
        stripped = mm.strip_swift('let a = "x.shared" // Foo.shared\n/* Bar.shared */ let b = 1\n')
        self.assertNotIn("shared", stripped)
        self.assertIn("let b = 1", stripped)


class ComponentTests(unittest.TestCase):
    def test_component_and_rank(self) -> None:
        self.assertEqual(mm.component_for("App/WindowState.swift"), "App")
        self.assertEqual(mm.component_for("App/Sparkle/X.swift"), "App/Sparkle")
        self.assertEqual(mm.component_for("Features/AgentMode/Runtime/Codex/A.swift"), "Features/AgentMode/Runtime")
        self.assertEqual(mm.layer_rank("Infrastructure/Utilities"), 0)
        self.assertEqual(mm.layer_rank("Infrastructure/MCP/ViewModels"), 9)
        self.assertEqual(mm.layer_rank("App"), 12)


class SCCTests(unittest.TestCase):
    def test_finds_cycle(self) -> None:
        graph = {"a": {"b"}, "b": {"c"}, "c": {"a"}, "d": {"a"}}
        components = mm.strongly_connected_components(graph)
        self.assertIn(["a", "b", "c"], components)
        self.assertIn(["d"], components)

    def test_deep_chain_is_iterative(self) -> None:
        graph = {str(i): {str(i + 1)} for i in range(5000)}
        self.assertEqual(len(mm.strongly_connected_components(graph)), 5001)


class CollectTests(unittest.TestCase):
    def test_collects_fixture_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_fixture(root)
            metrics, details = mm.collect(root)
        self.assertEqual(metrics["app_target_swift_files"], 3)
        self.assertEqual(metrics["app_static_shared_declarations"], 1)
        self.assertEqual(metrics["app_shared_accessor_uses"], 1)  # only the real call site; comment excluded
        self.assertEqual(metrics["app_userdefaults_standard_uses"], 1)
        self.assertEqual(metrics["tests_testable_import_app_files"], 1)
        self.assertEqual(metrics["tests_sleep_calls"], 1)
        self.assertEqual(metrics["app_wrong_way_file_edges"], 1)  # Utilities -> App; unranked Features/Chat ignored
        self.assertEqual(metrics["app_largest_cycle_components"], 2)
        self.assertEqual(details["top_wrong_way_targets"][0]["file"], "App/FontPresetValue.swift")


class RatchetCommandTests(unittest.TestCase):
    def test_lexical_collision_and_fake_clock_are_informational(self) -> None:
        self.assertIn("app_largest_cycle_components", mm.TRACKED_METRICS)
        self.assertIn("tests_sleep_calls", mm.TRACKED_METRICS)
        self.assertEqual(len(mm._SLEEP.findall("func sleep(until deadline: Instant) {}")), 1)
        baseline = {name: 0 for name in mm.RATCHETED_METRICS}
        baseline["app_target_swift_lines"] = 0
        current = {**baseline, "app_largest_cycle_components": 68, "tests_sleep_calls": 50}
        self.assertEqual(mm.regressions(current, baseline), [])

    def run_main(self, *args: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return mm.main(list(args))

    def test_update_then_check_and_refuse_regression(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_fixture(root)
            baseline = root / "ratchets.json"
            self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 0)
            self.assertEqual(self.run_main("check", "--root", tmp, "--baseline", str(baseline)), 0)
            document = json.loads(baseline.read_text())
            self.assertEqual(document["ratcheted"], list(mm.RATCHETED_METRICS))

            write(root, "Sources/RepoPrompt/Features/Chat/More.swift",
                  "struct MoreThing { static let shared = MoreThing() }\n")
            self.assertEqual(self.run_main("check", "--root", tmp, "--baseline", str(baseline)), 1)
            self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 1)
            self.assertEqual(
                self.run_main("update", "--root", tmp, "--baseline", str(baseline), "--allow-regression"), 0
            )
            self.assertEqual(self.run_main("check", "--root", tmp, "--baseline", str(baseline)), 0)

    def test_update_refuses_app_lines_growth_within_headroom(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_fixture(root)
            baseline = root / "ratchets.json"
            self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 0)
            before = json.loads(baseline.read_text())["metrics"]["app_target_swift_lines"]
            write(root, "Sources/RepoPrompt/Features/Chat/Growth.swift", "let growth = 0\n" * 1500)
            # Within headroom: `check` passes, but `update` must not raise the baseline.
            self.assertEqual(self.run_main("check", "--root", tmp, "--baseline", str(baseline)), 0)
            self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 1)
            self.assertEqual(json.loads(baseline.read_text())["metrics"]["app_target_swift_lines"], before)
            self.assertEqual(
                self.run_main("update", "--root", tmp, "--baseline", str(baseline), "--allow-regression"), 0
            )
            self.assertEqual(json.loads(baseline.read_text())["metrics"]["app_target_swift_lines"], before + 1500)

    def run_cli(self, root: Path, baseline: Path, command: str = "check") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "modularization_metrics.py"), command,
             "--root", str(root), "--baseline", str(baseline)],
            capture_output=True, text=True, check=False,
        )

    def test_check_reports_app_line_excess_as_advisory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_fixture(root)
            baseline = root / "ratchets.json"
            self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 0)
            original = baseline.read_bytes()
            before = json.loads(original)["metrics"]["app_target_swift_lines"]
            # Separate files keep every per-file mandatory ratchet unchanged.
            write(root, "Sources/RepoPrompt/Features/Chat/GrowthA.swift", "let growth = 0\n" * 1000)
            write(root, "Sources/RepoPrompt/Features/Chat/GrowthB.swift", "let growth = 0\n" * 1000)
            at_reference = self.run_cli(root, baseline)
            self.assertEqual(at_reference.returncode, 0, at_reference.stderr)
            self.assertNotIn("modularization advisory:", at_reference.stdout)

            write(root, "Sources/RepoPrompt/Features/Chat/GrowthB.swift", "let growth = 0\n" * 1001)
            over_reference = self.run_cli(root, baseline)
            self.assertEqual(over_reference.returncode, 0, over_reference.stderr)
            self.assertEqual(over_reference.stderr, "")
            self.assertIn(
                f"modularization advisory: app_target_swift_lines: {before + 2001} > "
                f"reference {before + 2000} (excess 1; not gated)", over_reference.stdout,
            )
            self.assertIn("modularization ratchets: ok", over_reference.stdout)
            self.assertEqual(baseline.read_bytes(), original)
            # Making `check` advisory does not authorize raising recorded baselines.
            update = self.run_cli(root, baseline, "update")
            self.assertEqual(update.returncode, 1)
            self.assertIn("refusing to raise baseline", update.stderr)
            self.assertEqual(baseline.read_bytes(), original)

    def test_check_retains_each_mandatory_ratchet_failure_with_app_advisory(self) -> None:
        cases = (
            ("app_files_over_5000_lines", "Sources/RepoPrompt/Features/Chat/Large.swift",
             "let value = 0\n" * 4999, "let value = 0\n" * 5001),
            ("app_files_over_2000_lines", "Sources/RepoPrompt/Features/Chat/Large.swift",
             "let value = 0\n" * 1999, "let value = 0\n" * 2001),
            ("tests_testable_import_app_files", "Tests/RepoPromptTests/MoreTests.swift",
             "", "@testable import RepoPromptApp\n"),
            ("app_static_shared_declarations", "Sources/RepoPrompt/Features/Chat/More.swift",
             "", "struct MoreThing { static let shared = MoreThing() }\n"),
        )
        for name, path, before_text, after_text in cases:
            with self.subTest(metric=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                make_fixture(root)
                write(root, path, before_text)
                baseline = root / "ratchets.json"
                self.assertEqual(self.run_main("update", "--root", tmp, "--baseline", str(baseline)), 0)
                original = baseline.read_bytes()
                recorded = json.loads(original)["metrics"]
                write(root, "Sources/RepoPrompt/Features/Chat/GrowthA.swift", "let growth = 0\n" * 1000)
                write(root, "Sources/RepoPrompt/Features/Chat/GrowthB.swift", "let growth = 0\n" * 1001)
                write(root, path, after_text)
                result = self.run_cli(root, baseline)
                self.assertEqual(result.returncode, 1)
                self.assertIn("modularization advisory: app_target_swift_lines:", result.stdout)
                self.assertIn("not gated", result.stdout)
                self.assertEqual(
                    result.stderr,
                    f"modularization ratchets regressed:\n  - {name}: "
                    f"{recorded[name] + 1} > baseline {recorded[name]}\n",
                )
                self.assertEqual(baseline.read_bytes(), original)

    def test_check_missing_baseline_keys_remain_cli_failures(self) -> None:
        for name in ("app_target_swift_lines",) + mm.RATCHETED_METRICS:
            with self.subTest(metric=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                make_fixture(root)
                baseline = root / "ratchets.json"
                metrics, _ = mm.collect(root)
                del metrics[name]
                baseline.write_text(json.dumps({"metrics": metrics}), encoding="utf-8")
                original = baseline.read_bytes()
                result = self.run_cli(root, baseline)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    result.stderr,
                    f"modularization ratchets regressed:\n  - {name}: missing from baseline\n",
                )
                self.assertEqual(baseline.read_bytes(), original)

    def test_check_invalid_baseline_documents_remain_cli_failures(self) -> None:
        cases = (
            ("invalid JSON", "{", "JSONDecodeError"),
            ("missing metrics", "{}", "KeyError"),
            ("invalid metric value", '{"metrics": {"app_target_swift_lines": "invalid"}}', "ValueError"),
        )
        for label, document, error in cases:
            with self.subTest(document=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                make_fixture(root)
                baseline = root / "ratchets.json"
                baseline.write_text(document, encoding="utf-8")
                result = self.run_cli(root, baseline)
                self.assertEqual(result.returncode, 1)
                self.assertIn(error, result.stderr)
                self.assertNotIn("modularization ratchets: ok", result.stdout)
                self.assertEqual(baseline.read_text(encoding="utf-8"), document)

    def test_baseline_raises_covers_tracked_metrics(self) -> None:
        baseline = {name: 5 for name in mm.RATCHETED_METRICS + mm.TRACKED_METRICS}
        current = dict(baseline, tests_sleep_calls=6)
        self.assertEqual(mm.baseline_raises(current, baseline), ["tests_sleep_calls: 5 -> 6"])
        self.assertEqual(mm.baseline_raises(dict(baseline, tests_sleep_calls=4), baseline), [])

    def test_check_fails_without_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(Path(tmp))
            self.assertEqual(self.run_main("check", "--root", tmp, "--baseline", str(Path(tmp) / "none.json")), 1)

    def test_regressions_reports_missing_metric(self) -> None:
        problems = mm.regressions({name: 0 for name in mm.RATCHETED_METRICS}, {})
        self.assertEqual(len(problems), len(mm.RATCHETED_METRICS) + 1)


if __name__ == "__main__":
    unittest.main()
