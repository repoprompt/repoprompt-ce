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
                    "seed_candidate": "bad candidate",
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
                    "skip_perfect_score": True,
                    "perfect_score": 1.0,
                    "max_evaluations": 20,
                    "stop_at_score": 1.0,
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
                        response = {
                            "type": "host_response",
                            "id": message["id"],
                            "ok": True,
                            "output": "```\nimproved candidate\n```",
                            "prompt_tokens": 11,
                            "completion_tokens": 5,
                        }
                    else:
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
            self.assertGreaterEqual(host_operations.count("evaluate"), 2)
            self.assertIn("prompt_tokens=", completed["proposer_usage"])
            self.assertIn("unavailable_callbacks=0", completed["proposer_usage"])

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
            self.assertEqual(diagnostic["schema_version"], 1)
            self.assertEqual(diagnostic["exception_type"], "InfrastructureFailure")
            self.assertEqual(diagnostic["source_frame"]["module"], "__main__")
            self.assertEqual(diagnostic["source_frame"]["function"], "host_call")
            self.assertGreater(diagnostic["source_frame"]["line"], 0)


if __name__ == "__main__":
    unittest.main()
