#!/usr/bin/env python3
"""Regression coverage for bounded, topology-ordered Tip source selection."""

from __future__ import annotations

import copy
import subprocess
import unittest
from unittest.mock import patch

import tip_ci_selection as selection


REPOSITORY = "repoprompt/repoprompt-ce"
OLD = "a" * 40
NEW = "b" * 40
MAIN = "c" * 40


def run(commit: str, run_id: int = 123, **overrides) -> dict:
    return {
        "id": run_id,
        "run_attempt": 1,
        "head_sha": commit,
        "event": "push",
        "head_branch": "main",
        "status": "completed",
        "conclusion": "success",
        "path": ".github/workflows/ci.yml",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        **overrides,
    }


def event(workflow_run: object, **overrides) -> dict:
    return {
        "action": "completed",
        "repository": {"full_name": REPOSITORY},
        "workflow_run": workflow_run,
        **overrides,
    }


class TipCISelectionTests(unittest.TestCase):
    def select(self, runs: list[dict], history: list[str] | None = None, **kwargs) -> dict:
        return selection.select(
            REPOSITORY, history or [MAIN, NEW, OLD],
            lambda repository, page: {"total_count": len(runs), "workflow_runs": runs},
            **kwargs,
        )

    def test_late_old_completion_cannot_replace_newer_passing_source(self):
        result = self.select([run(OLD, 300, run_attempt=8), run(NEW, 200)])
        self.assertEqual(result["commit"], NEW)
        self.assertEqual(result["run_id"], 200)
        self.assertEqual(result["run_attempt"], 1)
        self.assertEqual(result["url"], f"https://github.com/{REPOSITORY}/actions/runs/200")

    def test_newer_failed_or_unfinished_main_never_replaces_passing_ancestor(self):
        for status, conclusion in (("completed", "failure"), ("in_progress", None), ("queued", None)):
            with self.subTest(status=status):
                result = self.select([run(MAIN, status=status, conclusion=conclusion), run(NEW)])
                self.assertEqual(result["commit"], NEW)

    def test_only_exact_successful_source_repository_main_push_ci_qualifies(self):
        cases = (
            {"event": "pull_request"},
            {"event": "merge_group"},
            {"head_branch": "feature"},
            {"path": ".github/workflows/main-tip.yml"},
            {"path": ".github/workflows/ci.yml.bad"},
            {"head_repository": {"full_name": "fork/repoprompt-ce"}},
            {"repository": {"full_name": "fork/repoprompt-ce"}},
            {"head_repository": None},
            {"conclusion": "cancelled"},
        )
        for override in cases:
            with self.subTest(override=override):
                with self.assertRaisesRegex(selection.SelectionError, "No successful main-push CI"):
                    self.select([run(MAIN, **override)])

    def test_documented_workflow_path_with_ref_suffix_is_accepted(self):
        self.assertEqual(
            self.select([run(NEW, path=".github/workflows/ci.yml@main")])["commit"], NEW,
        )

    def test_source_outside_current_main_lineage_is_excluded(self):
        result = self.select([run("f" * 40, 999), run(NEW)])
        self.assertEqual(result["commit"], NEW)

    def test_missing_or_malformed_producer_identity_fails_closed(self):
        for override in ({"head_sha": "abc"}, {"id": True}, {"id": 0}, {"run_attempt": 0}, {"run_attempt": "2"}):
            with self.subTest(override=override):
                with self.assertRaises(selection.SelectionError):
                    self.select([run(NEW, **override)])

    def test_successful_partial_rerun_preserves_exact_attempt_identity(self):
        result = self.select([run(NEW, run_attempt=4)])
        self.assertEqual(result["run_attempt"], 4)

    def test_same_commit_prefers_latest_successful_run(self):
        result = self.select([run(NEW, 100), run(NEW, 200, run_attempt=3)])
        self.assertEqual((result["run_id"], result["run_attempt"]), (200, 3))

    def test_trigger_success_is_not_lost_before_it_appears_in_list_runs(self):
        result = self.select([run(OLD, 300)], trigger_event=event(run(NEW, 200, run_attempt=3)))
        self.assertEqual((result["commit"], result["run_id"], result["run_attempt"]), (NEW, 200, 3))

    def test_late_old_trigger_does_not_displace_newer_listed_success(self):
        result = self.select([run(NEW, 200)], trigger_event=event(run(OLD, 300, run_attempt=8)))
        self.assertEqual((result["commit"], result["run_id"]), (NEW, 200))

    def test_empty_successful_lookup_retains_exact_authenticated_trigger(self):
        result = self.select([], trigger_event=event(run(NEW, 200, run_attempt=3)))
        self.assertEqual((result["commit"], result["run_id"], result["run_attempt"]), (NEW, 200, 3))
        self.assertEqual(result["inspected_runs"], 0)
        self.assertTrue(result["search_complete"])

    def test_duplicate_run_identity_preserves_newest_successful_attempt(self):
        for listed_attempt, triggered_attempt in ((1, 3), (3, 1)):
            with self.subTest(listed_attempt=listed_attempt, triggered_attempt=triggered_attempt):
                result = self.select(
                    [run(NEW, 200, run_attempt=listed_attempt)],
                    trigger_event=event(run(NEW, 200, run_attempt=triggered_attempt)),
                )
                self.assertEqual((result["run_id"], result["run_attempt"]), (200, 3))

    def test_trigger_provenance_is_validated_before_any_api_lookup(self):
        invalid_events = [
            None, [], {}, event(run(NEW), action="requested"),
            event(run(NEW), repository={"full_name": "fork/repoprompt-ce"}),
            event(None),
        ]
        invalid_events.extend(event(run(NEW, **overrides)) for overrides in (
            {"event": "pull_request"}, {"event": "merge_group"},
            {"head_branch": "feature"}, {"status": "in_progress"},
            {"conclusion": "failure"}, {"path": ".github/workflows/main-tip.yml"},
            {"path": ".github/workflows/ci.yml.bad"},
            {"repository": {"full_name": "fork/repoprompt-ce"}},
            {"head_repository": {"full_name": "fork/repoprompt-ce"}},
            {"head_sha": "abc"}, {"id": True}, {"run_attempt": 0},
        ))
        def unexpected_lookup(repository, page):
            self.fail("An invalid workflow event must fail before looking for other candidates")
        for trigger in invalid_events:
            with self.subTest(trigger=trigger), self.assertRaises(selection.SelectionError):
                selection.select(REPOSITORY, [MAIN, NEW, OLD], unexpected_lookup, trigger_event=trigger)

    def test_trigger_outside_pinned_main_first_parent_ancestry_fails(self):
        with self.assertRaisesRegex(selection.SelectionError, "outside protected-main first-parent ancestry"):
            self.select([run(NEW)], trigger_event=event(run("f" * 40)))

    def test_valid_trigger_does_not_hide_api_failure_even_at_current_main(self):
        def failed_lookup(repository, page):
            raise selection.SelectionError("API unavailable")
        with self.assertRaisesRegex(selection.SelectionError, "API unavailable"):
            selection.select(REPOSITORY, [MAIN, NEW, OLD], failed_lookup, trigger_event=event(run(MAIN)))

    def test_pagination_is_bounded_and_completions_are_not_source_order(self):
        calls = []
        def reader(repository, page):
            calls.append((repository, page))
            entries = [run(OLD, page * 100 + index) for index in range(100)]
            if page == 2:
                entries[0] = run(NEW, 900)
            return {"total_count": 4000, "workflow_runs": entries}
        result = selection.select(REPOSITORY, [MAIN, NEW, OLD], reader)
        self.assertEqual(result["commit"], NEW)
        self.assertEqual(result["inspected_runs"], 300)
        self.assertFalse(result["search_complete"])
        self.assertEqual(calls, [(REPOSITORY, page) for page in (1, 2, 3)])

    def test_passing_current_head_does_not_scan_irrelevant_older_pages(self):
        calls = []
        def reader(repository, page):
            calls.append(page)
            return {"total_count": 4000, "workflow_runs": [run(MAIN)] + [run(OLD)] * 99}
        result = selection.select(REPOSITORY, [MAIN, NEW, OLD], reader)
        self.assertEqual(result["commit"], MAIN)
        self.assertEqual(calls, [1])

    def test_no_qualified_source_in_bounded_search_is_explicit_failure(self):
        def reader(repository, page):
            return {"total_count": 4000, "workflow_runs": [run("f" * 40)] * 100}
        with self.assertRaisesRegex(selection.SelectionError, "bounded 300-run search"):
            selection.select(REPOSITORY, [MAIN, NEW, OLD], reader)

    def test_incomplete_or_malformed_api_pages_are_not_silently_accepted(self):
        for payload in (
            [], {}, {"total_count": True, "workflow_runs": []},
            {"total_count": 200, "workflow_runs": [run(NEW)]},
            {"total_count": 2, "workflow_runs": [run(NEW), "bad-run"]},
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(selection.SelectionError):
                    selection.select(REPOSITORY, [MAIN, NEW, OLD], lambda repo, page: copy.deepcopy(payload))

    def test_api_request_is_read_only_scoped_and_bounded(self):
        with patch.object(selection.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")) as command:
            selection.fetch_page(REPOSITORY, 2)
        args, kwargs = command.call_args
        self.assertEqual(args[0], [
            "gh", "api", f"/repos/{REPOSITORY}/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=100&page=2",
        ])
        self.assertEqual(kwargs["timeout"], 30)

    def test_api_error_does_not_fall_back_to_untested_main(self):
        for response in (
            subprocess.CompletedProcess([], 1, "", "forbidden"),
            subprocess.CompletedProcess([], 0, "not JSON", ""),
        ):
            with self.subTest(response=response), patch.object(selection.subprocess, "run", return_value=response):
                with self.assertRaises(selection.SelectionError):
                    selection.fetch_page(REPOSITORY, 1)


if __name__ == "__main__":
    unittest.main()
