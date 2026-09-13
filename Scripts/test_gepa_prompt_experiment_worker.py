#!/usr/bin/env python3
"""Deterministic integration test for the real pinned GEPA worker."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKER = Path(os.environ.get(
    "REPOPROMPT_TEST_GEPA_WORKER",
    ROOT / "AppResources" / "PromptExperiments" / "gepa_worker.py",
)).resolve()


class GEPAPromptExperimentWorkerTests(unittest.TestCase):
    def test_real_gepa_uses_host_reflection_and_evaluation(self) -> None:
        self.run_search("bad candidate")

    def test_seedless_gepa_generates_initial_candidate_through_host(self) -> None:
        self.run_search(None)

    def test_retryable_reflection_failure_retries_within_sealed_allowance(self) -> None:
        completed, operations = self.run_search(
            None,
            max_provider_retries=1,
            fail_first_reflection_with="provider_temporarily_unavailable",
        )
        self.assertEqual(completed["best_score"], 1.0)
        self.assertGreaterEqual(operations.count("reflect"), 2)
        self.assertEqual(operations[:2], ["reflect", "reflect"])

    def test_search_reserves_held_out_calls_inside_approved_total_budget(self) -> None:
        completed, host_operations = self.run_search(
            "bad candidate",
            max_evaluations=8,
            stop_at_score=None,
            skip_perfect_score=False,
            enforce_host_ceiling=True,
        )
        self.assertEqual(completed["total_evaluations"], 8)
        self.assertEqual(len(completed["evaluations"]), 8)
        self.assertEqual(
            [evaluation["split"] for evaluation in completed["evaluations"]].count("hidden_test"),
            2,
        )
        self.assertEqual(completed["metadata"]["approved_total_evaluation_ceiling"], 8)
        self.assertEqual(completed["metadata"]["search_evaluation_budget"], 6)
        self.assertEqual(completed["metadata"]["held_out_evaluation_reserve"], 2)
        self.assertEqual(completed["metadata"]["held_out_evaluations_recorded"], 2)
        self.assertEqual(host_operations.count("evaluate"), 8)

    def run_search(
        self,
        seed: str | None,
        *,
        max_evaluations: int = 20,
        stop_at_score: float | None = 1.0,
        skip_perfect_score: bool = True,
        enforce_host_ceiling: bool = False,
        max_provider_retries: int = 0,
        fail_first_reflection_with: str | None = None,
    ) -> tuple[dict, list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(WORKER)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                env={
                    "HOME": str(root),
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "PYTHONUNBUFFERED": "1",
                    "TMPDIR": str(root),
                },
            )
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(json.dumps({
                "protocol_version": 1,
                "type": "run",
                "request": {
                    "run_name": "deterministic-worker-test",
                    "seed_candidate": seed,
                    "objective": "Produce the exact words improved candidate.",
                    "background": "This is a deterministic integration test.",
                    "task_preservation": "Do not change the required words.",
                    "examples": [{
                        "id": "example-1",
                        "split": "training",
                        "input": "Return the required words.",
                        "expected_output": "HOST_PRIVATE_EXPECTED_CANARY",
                        "reviewer_notes": "HOST_PRIVATE_NOTES_CANARY",
                    }, {
                        "id": "hidden-1",
                        "split": "hidden_test",
                        "input": "Final reporting input.",
                        "expected_output": "HOST_PRIVATE_HIDDEN_CANARY",
                        "reviewer_notes": "HOST_PRIVATE_HIDDEN_NOTES_CANARY",
                    }],
                    "reflection_minibatch_size": 2,
                    "use_merge": False,
                    "max_merge_invocations": 0,
                    "skip_perfect_score": skip_perfect_score,
                    "perfect_score": 1.0,
                    "max_evaluations": max_evaluations,
                    "max_provider_retries": max_provider_retries,
                    "stop_at_score": stop_at_score,
                    "random_seed": 0,
                    "run_dir": str(root / "gepa-run"),
                    "run_directory_relative_path": "worker-runs/test",
                    "output_dir": str(root / "gepa-output"),
                },
            }) + "\n")
            process.stdin.flush()

            completed = None
            host_operations: list[str] = []
            for _ in range(50):
                raw = process.stdout.readline()
                self.assertTrue(raw, "worker closed stdout before completion")
                message = json.loads(raw)
                if message["type"] == "host_request":
                    serialized = json.dumps(message, sort_keys=True)
                    self.assertNotIn("HOST_PRIVATE_EXPECTED_CANARY", serialized)
                    self.assertNotIn("HOST_PRIVATE_NOTES_CANARY", serialized)
                    self.assertNotIn("HOST_PRIVATE_HIDDEN_CANARY", serialized)
                    self.assertNotIn("HOST_PRIVATE_HIDDEN_NOTES_CANARY", serialized)
                    operation = message["operation"]
                    host_operations.append(operation)
                    if operation == "reflect":
                        if fail_first_reflection_with and host_operations.count("reflect") == 1:
                            response = {
                                "type": "host_response",
                                "id": message["id"],
                                "ok": False,
                                "failure_kind": "infrastructure",
                                "failure_code": fail_first_reflection_with,
                                "error": "safe provider failure",
                            }
                        else:
                            response = {
                                "type": "host_response",
                                "id": message["id"],
                                "ok": True,
                                "output": "```\nimproved candidate\n```",
                                "prompt_tokens": 11,
                                "completion_tokens": 5,
                            }
                    else:
                        if enforce_host_ceiling and host_operations.count("evaluate") > max_evaluations:
                            response = {
                                "type": "host_response",
                                "id": message["id"],
                                "ok": False,
                                "failure_kind": "infrastructure",
                                "error": "approved evaluation ceiling exceeded",
                            }
                            process.stdin.write(json.dumps(response) + "\n")
                            process.stdin.flush()
                            continue
                        self.assertEqual(
                            set(message["payload"]["example"]),
                            {"id", "split", "input"},
                        )
                        candidate = message["payload"]["candidate"]
                        score = 1.0 if candidate.strip() == "improved candidate" else 0.0
                        response = {
                            "type": "host_response",
                            "id": message["id"],
                            "ok": True,
                            "score": score,
                            "feedback": "exact match" if score == 1 else "must equal improved candidate",
                            "output": candidate,
                            "elapsed_seconds": 0.001,
                            "prompt_tokens": 7,
                            "completion_tokens": 3,
                        }
                    process.stdin.write(json.dumps(response) + "\n")
                    process.stdin.flush()
                elif message["type"] == "completed":
                    completed = message["result"]
                    break
                elif message["type"] == "failed":
                    self.fail(message["error"])

            process.stdin.close()
            return_code = process.wait(timeout=10)
            stderr = process.stderr.read() if process.stderr is not None else ""
            process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            self.assertEqual(return_code, 0, stderr)
            self.assertIsNotNone(completed)
            assert completed is not None
            self.assertEqual(completed["upstream_revision"], "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407")
            self.assertEqual(completed["best_score"], 1.0, (completed, host_operations, stderr))
            self.assertEqual(completed["run_directory_relative_path"], "worker-runs/test")
            self.assertIn("improved candidate", completed["candidates"])
            self.assertIn("reflect", host_operations)
            if seed is None:
                self.assertEqual(host_operations[0], "reflect", "GEPA must generate the initial seed before evaluating")
            else:
                self.assertEqual(host_operations[0], "evaluate", "Supplied seed must be evaluated before mutation")
            self.assertGreaterEqual(host_operations.count("evaluate"), 2)
            self.assertIn("prompt_tokens=", completed["proposer_usage"])
            self.assertIn("unavailable_callbacks=0", completed["proposer_usage"])
            return completed, host_operations

    def test_preparation_evaluates_reviewed_candidates_without_search_or_holdout(self) -> None:
        result, calls = self.run_preparation_batch(4)
        self.assertEqual(result["type"], "completed")
        data = result["result"]
        self.assertEqual(data["engine"], "preparation")
        self.assertEqual(data["total_evaluations"], 4)
        self.assertEqual(data["candidates"], ["reference", "revised"])
        self.assertEqual(data["aggregate_scores"], [0.0, 1.0])
        self.assertEqual(data["best_candidate_index"], 1)
        self.assertEqual([e["candidate_index"] for e in data["evaluations"]], [0, 0, 1, 1])
        self.assertFalse(data["metadata"]["search_performed"])
        self.assertFalse(data["metadata"]["held_out_evaluated"])
        self.assertEqual(calls, ["evaluate"] * 4)

    def test_preparation_rejects_insufficient_budget_before_any_host_call(self) -> None:
        result, calls = self.run_preparation_batch(3)
        self.assertEqual(result["type"], "failed")
        self.assertEqual(calls, [])

    def run_preparation_batch(self, budget: int) -> tuple[dict, list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(WORKER)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1,
                env={"HOME": str(root), "PATH": "/usr/bin:/bin", "TMPDIR": str(root)},
            )
            assert process.stdin is not None and process.stdout is not None
            calls = []
            try:
                process.stdin.write(json.dumps({
                    "protocol_version": 1, "type": "run", "request": {
                        "stage": "preparation", "preparation_candidates": ["reference", "revised"],
                        "max_evaluations": budget,
                        "run_dir": str(root / "run"), "output_dir": str(root / "output"),
                        "examples": [
                            {"id": "dev1", "split": "training", "input": "one"},
                            {"id": "dev2", "split": "training", "input": "two"},
                            {"id": "val", "split": "validation", "input": "VALIDATION_CANARY"},
                            {"id": "hidden", "split": "hidden_test", "input": "HIDDEN_CANARY"},
                        ],
                    },
                }) + "\n")
                process.stdin.flush()
                for _ in range(20):
                    raw = process.stdout.readline()
                    self.assertTrue(raw, "worker exited without a terminal result")
                    message = json.loads(raw)
                    if message["type"] in ("completed", "failed"):
                        process.stdin.close()
                        process.wait(timeout=10)
                        return message, calls
                    if message["type"] != "host_request":
                        continue
                    self.assertNotIn("CANARY", raw)
                    calls.append(message["operation"])
                    self.assertEqual(message["operation"], "evaluate")
                    self.assertEqual(message["payload"]["example"]["split"], "training")
                    score = float(message["payload"]["candidate"] == "revised")
                    process.stdin.write(json.dumps({
                        "type": "host_response", "id": message["id"], "ok": True,
                        "score": score, "feedback": "reviewed feedback", "output": "answer",
                    }) + "\n")
                    process.stdin.flush()
                self.fail("preparation did not settle")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                for pipe in (process.stdin, process.stdout, process.stderr):
                    if pipe is not None and not pipe.closed:
                        pipe.close()

    def test_failure_envelope_exposes_safe_class_and_frame_without_exception_text(self) -> None:
        secret_canary = "HOST_PRIVATE_INFRASTRUCTURE_SECRET_CANARY"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(WORKER)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                env={
                    "HOME": str(root),
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "PYTHONUNBUFFERED": "1",
                    "TMPDIR": str(root),
                },
            )
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(json.dumps({
                "protocol_version": 1,
                "type": "run",
                "request": {
                    "run_name": "infrastructure-failure-test",
                    "seed_candidate": "candidate",
                    "objective": "Keep the candidate.",
                    "background": "Infrastructure failure must remain inconclusive.",
                    "examples": [{"id": "example-1", "split": "training", "input": "input"}],
                    "max_evaluations": 2,
                    "random_seed": 0,
                    "perfect_score": 1.0,
                    "run_dir": str(root / "gepa-run"),
                    "output_dir": str(root / "gepa-output"),
                },
            }) + "\n")
            process.stdin.flush()

            terminal = None
            for _ in range(20):
                raw = process.stdout.readline()
                self.assertTrue(raw, "worker closed stdout before terminal failure")
                message = json.loads(raw)
                if message["type"] == "host_request":
                    process.stdin.write(json.dumps({
                        "type": "host_response",
                        "id": message["id"],
                        "ok": False,
                        "failure_kind": "infrastructure",
                        "error": f"controlled provider transport failure {secret_canary}",
                        "failure_code": "judge_provider_failed",
                    }) + "\n")
                    process.stdin.flush()
                elif message["type"] in {"completed", "failed"}:
                    terminal = message
                    break

            process.stdin.close()
            return_code = process.wait(timeout=10)
            stderr = process.stderr.read() if process.stderr is not None else ""
            process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            self.assertEqual(return_code, 2, stderr)
            self.assertIsNotNone(terminal)
            assert terminal is not None
            self.assertEqual(terminal["type"], "failed")
            self.assertEqual(terminal["failure_kind"], "infrastructure")
            self.assertEqual(terminal["error"], "worker_failure_detail_excluded")
            serialized = json.dumps(terminal, sort_keys=True)
            self.assertNotIn(secret_canary, serialized)
            diagnostic = terminal["diagnostic"]
            self.assertEqual(diagnostic["failure_code"], "judge_provider_failed")
            self.assertEqual(diagnostic["schema_version"], 1)
            self.assertEqual(diagnostic["exception_type"], "InfrastructureFailure")
            self.assertEqual(diagnostic["source_frame"]["module"], "__main__")
            self.assertEqual(diagnostic["source_frame"]["function"], "host_call")
            self.assertGreater(diagnostic["source_frame"]["line"], 0)


if __name__ == "__main__":
    unittest.main()
