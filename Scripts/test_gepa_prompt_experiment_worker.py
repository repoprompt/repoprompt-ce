#!/usr/bin/env python3
"""Deterministic integration tests for the real pinned GEPA worker (protocol v2).

Run with the bundled interpreter so the pinned GEPA revision is importable, e.g.
  .build/prompt-experiment-python/<runtime>/arm64/python/bin/python3.11 Scripts/test_gepa_prompt_experiment_worker.py
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
WORKER = Path(os.environ.get(
    "REPOPROMPT_TEST_GEPA_WORKER",
    ROOT / "AppResources" / "PromptExperiments" / "gepa_worker.py",
)).resolve()
sys.path.insert(0, str(WORKER.parent))

from gepa_worker import (  # noqa: E402
    REFLECTION_BEGIN,
    REFLECTION_END,
    QualityThenBrevityAcceptance,
    brevity_score,
    build_reflection_prompt,
    delimit_for_gepa,
    extract_reflection_candidate,
    fenced,
    full_iteration_cost,
    preferred_best_index,
)

FENCE_HEAVY = """Instructions:
Answer with a plan.

```swift
struct Example {
    let value: Int
}
```

Then show the shell step:

```bash
make dev-build
```
Close with a summary."""


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def envelope(candidate: str) -> str:
    return f"Here is the revision.\n{REFLECTION_BEGIN}\n{candidate}\n{REFLECTION_END}\nThanks."


class FakeHost:
    """Scripted host with a durable-ledger-like memo: a repeated (candidate, split, example)
    replays its recorded outcome without consuming a new admission."""

    def __init__(
        self,
        *,
        reflect: Callable[[str, int], str],
        score: Callable[[str, dict[str, Any]], float],
        search_cap: int = 1000,
        held_out_cap: int = 1000,
        memo: dict[str, dict[str, Any]] | None = None,
        feedback: Callable[[str], str] | None = None,
        output_excerpt: Callable[[str], str] | None = None,
        report_remaining: bool = True,
        output_characters: Callable[[str], int] | None = None,
    ) -> None:
        self.report_remaining = report_remaining
        self.output_characters_fn = output_characters
        self.reflect_prompts: list[str] = []
        self.reflect_fn = reflect
        self.score_fn = score
        self.search_cap = search_cap
        self.held_out_cap = held_out_cap
        self.memo = memo if memo is not None else {}
        self.feedback_fn = feedback
        self.output_excerpt_fn = output_excerpt
        self.operations: list[str] = []
        self.evaluate_payloads: list[dict[str, Any]] = []
        self.search_admitted = 0
        self.held_out_admitted = 0
        self.replays = 0
        self.budget_refusals = 0
        self.reflections = 0

    def handle(self, message: dict[str, Any]) -> dict[str, Any]:
        operation = message["operation"]
        self.operations.append(operation)
        payload = message["payload"]
        if operation == "reflect":
            self.reflections += 1
            self.reflect_prompts.append(payload["prompt"])
            return {"status": "ok", "output": self.reflect_fn(payload["prompt"], self.reflections),
                    "prompt_tokens": 11, "completion_tokens": 5}
        assert operation == "evaluate"
        self.evaluate_payloads.append(payload)
        assert set(payload) == {"candidate", "candidate_sha256", "example_id", "split"}, payload
        assert payload["candidate_sha256"] == sha(payload["candidate"])
        key = f"{payload['candidate_sha256']}\0{payload['split']}\0{payload['example_id']}"
        if key in self.memo:
            self.replays += 1
            return self.with_remaining(dict(self.memo[key], replayed=True), payload)
        held_out = payload["split"] == "hidden_test"
        if held_out and self.held_out_admitted >= self.held_out_cap:
            self.budget_refusals += 1
            return {"status": "budget_exhausted"}
        if not held_out and self.search_admitted >= self.search_cap:
            self.budget_refusals += 1
            return {"status": "budget_exhausted"}
        if held_out:
            self.held_out_admitted += 1
        else:
            self.search_admitted += 1
        candidate = payload["candidate"]
        score = self.score_fn(candidate, payload)
        response = {
            "status": "ok",
            "evaluation_id": key,
            "score": score,
            "feedback": self.feedback_fn(candidate) if self.feedback_fn else f"score={score}",
            "prompt_tokens": 7,
            "completion_tokens": 3,
        }
        if self.output_excerpt_fn:
            response["output_excerpt"] = self.output_excerpt_fn(candidate)
        if self.output_characters_fn:
            response["output_characters"] = self.output_characters_fn(candidate)
        self.memo[key] = response
        return self.with_remaining(dict(response), payload)

    def with_remaining(self, response: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
        if self.report_remaining and payload["split"] != "hidden_test":
            response["search_remaining"] = max(0, self.search_cap - self.search_admitted)
        return response


def run_worker(
    root: Path,
    host: FakeHost,
    *,
    seed: str | None = "bad candidate",
    examples: list[dict[str, Any]] | None = None,
    held_out: list[dict[str, Any]] | None = None,
    search_max_evaluations: int = 20,
    stop_at_score: float | None = 1.0,
    skip_perfect_score: bool = True,
    minibatch: int = 2,
    interrupt_on_first_request: bool = False,
    max_messages: int = 400,
    extra: dict[str, Any] | None = None,
) -> tuple[dict[str, Any] | None, list[dict[str, Any]], int, str]:
    process = subprocess.Popen(
        [sys.executable, "-I", "-B", str(WORKER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env={"HOME": str(root), "PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1", "TMPDIR": str(root)},
    )
    assert process.stdin is not None and process.stdout is not None
    messages: list[dict[str, Any]] = []
    terminal = None
    try:
        process.stdin.write(json.dumps({
            "protocol_version": 2,
            "type": "run",
            "request": {
                "run_name": "deterministic-worker-test",
                "seed_candidate": seed,
                "objective": "Produce the exact words improved candidate.",
                "background": "This is a deterministic integration test.",
                "examples": examples if examples is not None else [
                    {"id": "example-1", "split": "training", "input": "Return the required words."},
                ],
                "held_out_examples": held_out or [],
                "reflection_minibatch_size": minibatch,
                "use_merge": False,
                "max_merge_invocations": 0,
                "skip_perfect_score": skip_perfect_score,
                "perfect_score": 1.0,
                "search_max_evaluations": search_max_evaluations,
                "stop_at_score": stop_at_score,
                "random_seed": 0,
                "run_dir": str(root / "gepa-run"),
                "output_dir": str(root / "gepa-output"),
                # Most scenarios propose texts longer than their short seed; the ceiling
                # itself is exercised by dedicated tests.
                "prompt_character_ceiling_ratio": 100.0,
                # The host always sends the ledger's count; evaluation replies refresh it.
                "search_remaining": search_max_evaluations,
                **(extra or {}),
            },
        }) + "\n")
        process.stdin.flush()
        for _ in range(max_messages):
            raw = process.stdout.readline()
            if not raw:
                break
            message = json.loads(raw)
            assert message["protocol_version"] == 2
            messages.append(message)
            if message["type"] == "host_request":
                if interrupt_on_first_request:
                    process.send_signal(signal.SIGINT)
                    continue
                response = host.handle(message)
                response.update({"type": "host_response", "id": message["id"]})
                process.stdin.write(json.dumps(response) + "\n")
                process.stdin.flush()
            elif message["type"] in ("completed", "failed", "cancelled"):
                terminal = message
                break
    finally:
        if process.stdin and not process.stdin.closed:
            process.stdin.close()
        return_code = process.wait(timeout=30)
        stderr = process.stderr.read() if process.stderr is not None else ""
        for pipe in (process.stdout, process.stderr):
            if pipe is not None and not pipe.closed:
                pipe.close()
    return terminal, messages, return_code, stderr


def always(text: str) -> Callable[[str, int], str]:
    return lambda prompt, count: envelope(text)


def exact(target: str) -> Callable[[str, dict[str, Any]], float]:
    return lambda candidate, payload: 1.0 if candidate.strip() == target else 0.0


class ReflectionContractTests(unittest.TestCase):
    def test_pinned_extractor_corrupts_raw_fence_heavy_candidates(self) -> None:
        from gepa.strategies.instruction_proposal import InstructionProposalSignature
        extracted = InstructionProposalSignature.output_extractor(FENCE_HEAVY.strip())["new_instruction"]
        self.assertNotEqual(extracted, FENCE_HEAVY, "regression pin: raw fenced text is cut at inner fences")

    def test_delimited_candidate_round_trips_through_pinned_extractor(self) -> None:
        from gepa.strategies.instruction_proposal import InstructionProposalSignature
        for candidate in [FENCE_HEAVY, "plain", "Word\nsecond line", "```\nonly a block\n```", "x ``` y"]:
            wrapped = delimit_for_gepa(candidate)
            self.assertEqual(
                InstructionProposalSignature.output_extractor(wrapped.strip())["new_instruction"],
                candidate.strip(),
                candidate,
            )

    def test_extraction_contracts(self) -> None:
        self.assertEqual(extract_reflection_candidate(envelope(FENCE_HEAVY)), (FENCE_HEAVY, "envelope"))
        self.assertEqual(
            extract_reflection_candidate(f"```markdown\n{FENCE_HEAVY}\n```"),
            (FENCE_HEAVY, "fenced_block"),
        )
        self.assertEqual(extract_reflection_candidate(FENCE_HEAVY), (None, "missing_envelope"))
        self.assertEqual(
            extract_reflection_candidate("Here is the improved prompt:\nimproved candidate"),
            (None, "missing_envelope"),
            "prose without the envelope is never a candidate",
        )
        self.assertEqual(
            extract_reflection_candidate(f"{REFLECTION_BEGIN}\n   \n{REFLECTION_END}"),
            ("", "envelope"),
            "an empty envelope yields empty text; the worker rejects it",
        )


class ReflectionPromptTests(unittest.TestCase):
    def test_fenced_outlasts_embedded_backtick_runs(self) -> None:
        block = fenced("a\n````\nb\n```")
        self.assertTrue(block.startswith("`````\n"), block)
        self.assertTrue(block.endswith("\n`````"), block)
        self.assertTrue(fenced("plain").startswith("```\n"))

    def test_prompt_carries_request_score_feedback_and_output_but_not_bookkeeping(self) -> None:
        prompt = build_reflection_prompt(
            objective="OBJECTIVE_MARKER",
            background="BACKGROUND_MARKER",
            current=FENCE_HEAVY,
            records=[{
                "request": "REQUEST_MARKER",
                "score": 0.25,
                "feedback": "FEEDBACK_MARKER",
                "output": "HEAD_MARKER [… omitted …] TAIL_MARKER",
                "_budget": {"used": 3, "BUDGET_MARKER": True},
                "Scores (Higher is Better)": {"quality": 0.25, "brevity": 0.5},
            }],
        )
        for marker in ("OBJECTIVE_MARKER", "BACKGROUND_MARKER", "REQUEST_MARKER", "FEEDBACK_MARKER",
                       "HEAD_MARKER", "TAIL_MARKER", "score 0.250", "brevity 0.500", REFLECTION_BEGIN, REFLECTION_END):
            self.assertIn(marker, prompt)
        self.assertNotIn("BUDGET_MARKER", prompt)
        self.assertNotIn("_budget", prompt)
        self.assertIn(f"({len(FENCE_HEAVY)} characters)", prompt)
        self.assertIn("````\n" + FENCE_HEAVY + "\n````", prompt, "the candidate is fenced safely")

    def test_task_asks_for_root_causes_then_an_edit_under_the_ceiling(self) -> None:
        prompt = build_reflection_prompt(objective="o", background="", current="x" * 40, records=[], character_ceiling=30)
        self.assertIn("Root causes first", prompt)
        self.assertIn("Edit, do not append", prompt)
        self.assertIn("at most 30 characters (the current prompt has 40)", prompt)
        self.assertLess(prompt.index("Root causes first"), prompt.index(REFLECTION_BEGIN))

    def test_brevity_is_higher_for_shorter_prompts_and_answers(self) -> None:
        same = brevity_score(prompt_characters=100, seed_prompt_characters=100, output_characters=50, reference_output_characters=50)
        shorter = brevity_score(prompt_characters=50, seed_prompt_characters=100, output_characters=25, reference_output_characters=50)
        longer = brevity_score(prompt_characters=200, seed_prompt_characters=100, output_characters=100, reference_output_characters=50)
        self.assertEqual(same, 0.5)
        self.assertEqual(shorter, 1.0)
        self.assertEqual(longer, 0.25)
        self.assertEqual(
            brevity_score(prompt_characters=100, seed_prompt_characters=100, output_characters=0, reference_output_characters=50),
            0.25, "an empty answer earns no brevity credit",
        )

    def test_acceptance_is_quality_first_and_only_shorter_on_ties(self) -> None:
        class Evaluation:
            def __init__(self, length: int) -> None:
                self.trajectories = [{"_prompt_characters": length}]

        class Proposal:
            def __init__(self, before: list[float], after: list[float], child: str, parent_length: int) -> None:
                self.subsample_scores_before = before
                self.subsample_scores_after = after
                self.candidate = {"current_candidate": child}
                self.eval_before = Evaluation(parent_length)

        accept = QualityThenBrevityAcceptance().should_accept
        self.assertTrue(accept(Proposal([0.5, 0.5], [0.6, 0.5], "x" * 50, 10), None), "better quality wins even if longer")
        self.assertFalse(accept(Proposal([0.5, 0.5], [0.4, 0.5], "x", 10), None))
        self.assertTrue(accept(Proposal([0.5, 0.5], [0.5, 0.5], "x" * 9, 10), None), "a tie accepts a shorter prompt")
        self.assertFalse(accept(Proposal([0.5, 0.5], [0.5, 0.5], "x" * 10, 10), None), "a tie never accepts equal length")
        self.assertFalse(accept(Proposal([0.5, 0.5], [0.5, 0.5], "x" * 11, 10), None), "a tie never accepts longer")

    def test_best_prefers_the_shortest_among_validation_ties(self) -> None:
        self.assertEqual(preferred_best_index(["long seed", "mid", "s"], [0.5, 0.8, 0.8], 1), 2)
        self.assertEqual(preferred_best_index(["a", "bb"], [0.9, 0.8], 0), 0)
        self.assertEqual(preferred_best_index(["a"], [None], 0), 0)

    def test_full_iteration_cost(self) -> None:
        self.assertEqual(full_iteration_cost(minibatch=2, training=6, validation=3), 7)
        self.assertEqual(full_iteration_cost(minibatch=3, training=1, validation=0), 3)


class WorkerReadinessTests(unittest.TestCase):
    def test_real_worker_preflight_is_independent_of_cwd_and_never_requests_host_calls(self) -> None:
        with tempfile.TemporaryDirectory(prefix="RPCE Worker Ready ") as temporary:
            completed = subprocess.run(
                [sys.executable, "-I", "-B", str(WORKER), "--preflight"],
                cwd=temporary,
                env={"HOME": temporary, "PATH": "/usr/bin:/bin", "TMPDIR": temporary},
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=15,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        messages = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0], {
            "protocol_version": 2,
            "type": "ready",
            "python_version": list(sys.version_info[:3]),
            "gepa_version": "0.1.4",
            "upstream_revision": "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407",
        })


class GEPAWorkerRunTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def assert_completed(self, terminal, code, stderr) -> dict[str, Any]:
        self.assertIsNotNone(terminal, stderr)
        self.assertEqual(terminal["type"], "completed", (terminal, stderr))
        self.assertEqual(code, 0, stderr)
        return terminal["result"]

    def registered(self, messages) -> dict[int, str]:
        texts: dict[int, str] = {}
        for message in messages:
            if message["type"] == "candidate":
                self.assertEqual(message["candidate_sha256"], sha(message["candidate"]))
                texts[message["candidate_index"]] = message["candidate"]
        return texts

    def test_seeded_search_mutates_evaluates_and_streams_candidates(self) -> None:
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host)
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(host.operations[0], "evaluate", "a supplied seed is evaluated before mutation")
        self.assertIn("reflect", host.operations)
        self.assertEqual(result["stop_reason"], "completed")
        self.assertTrue(result["has_incumbent"])
        texts = self.registered(messages)
        best = result["best_candidate_index"]
        self.assertEqual(texts[best], "improved candidate")
        self.assertEqual(texts[0], "bad candidate")
        self.assertEqual(result["best_score"], 1.0)
        for candidate in result["candidates"]:
            self.assertEqual(candidate["sha256"], sha(texts[candidate["index"]]))
        final_line = json.dumps(terminal)
        self.assertNotIn("improved candidate", final_line, "final line carries hashes, not text")
        self.assertNotIn("evaluations", result)

    def test_fence_heavy_reflection_reaches_evaluation_verbatim(self) -> None:
        host = FakeHost(reflect=always(FENCE_HEAVY), score=exact(FENCE_HEAVY))
        terminal, messages, code, stderr = run_worker(self.root, host)
        result = self.assert_completed(terminal, code, stderr)
        evaluated = {payload["candidate"] for payload in host.evaluate_payloads}
        self.assertIn(FENCE_HEAVY, evaluated)
        self.assertEqual(self.registered(messages)[result["best_candidate_index"]], FENCE_HEAVY)
        contracts = [m["contract"] for m in messages if m["type"] == "reflection"]
        self.assertTrue(contracts and set(contracts) == {"envelope"}, contracts)

    BUDGET_EXAMPLES = [
        {"id": "t1", "split": "training", "input": "one"},
        {"id": "t2", "split": "training", "input": "two"},
        {"id": "v1", "split": "validation", "input": "three"},
    ]

    @staticmethod
    def revising_reflect() -> Callable[[str, int], str]:
        counter = {"n": 0}

        def reflect(prompt: str, count: int) -> str:
            counter["n"] += 1
            return envelope(f"candidate revision {counter['n']}")

        return reflect

    @staticmethod
    def rising_score(candidate: str, payload: dict[str, Any]) -> float:
        return 0.0 if candidate == "bad candidate" else min(0.9, 0.1 * len(candidate.split()))

    def test_ledger_stopper_never_starts_an_iteration_it_cannot_finish(self) -> None:
        # Iteration cost = 2 * 2 + 1 = 5. Seed validation takes 1 of 7, leaving 6: one
        # iteration runs, then 1-2 remain and the stopper ends the search at the boundary.
        host = FakeHost(reflect=self.revising_reflect(), score=self.rising_score, search_cap=7)
        terminal, messages, code, stderr = run_worker(
            self.root, host, examples=self.BUDGET_EXAMPLES,
            search_max_evaluations=7, stop_at_score=None, skip_perfect_score=False,
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["stop_reason"], "budget_exhausted")
        self.assertTrue(result["stopped_before_unfinishable_iteration"])
        self.assertEqual(result["iteration_cost"], 5)
        self.assertEqual(host.budget_refusals, 0, "no iteration was abandoned mid-way")
        self.assertLess(result["search_remaining"], 5)
        self.assertEqual(host.reflections, 1)
        self.assertTrue(result["has_incumbent"])
        self.assertEqual(self.registered(messages)[0], "bad candidate")

    def test_ledger_remaining_not_gepa_counts_drives_the_stopper(self) -> None:
        # The host says only 4 search admissions remain (e.g. earlier runs spent the rest):
        # after the seed pass 3 remain, below one iteration, so GEPA proposes nothing.
        host = FakeHost(reflect=self.revising_reflect(), score=self.rising_score, search_cap=4)
        terminal, messages, code, stderr = run_worker(
            self.root, host, examples=self.BUDGET_EXAMPLES,
            search_max_evaluations=100, stop_at_score=None, skip_perfect_score=False,
            extra={"search_remaining": 4},
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(host.reflections, 0)
        self.assertEqual(host.search_admitted, 1)
        self.assertTrue(result["stopped_before_unfinishable_iteration"])

    def test_perfect_training_replays_stop_without_reflection_or_a_score_threshold(self) -> None:
        # The app defaults to skip_perfect_score=True and stop_at_score=None. A perfect
        # training minibatch skips reflection even when validation is imperfect; once its
        # parent outcomes are cached, neither paid evaluations nor reflections can end the
        # loop. The iteration bound must still return the saved incumbent and held-out score.
        host = FakeHost(
            reflect=always("unexpected proposal"),
            score=lambda c, p: 0.5 if p["split"] == "validation" else 1.0,
            search_cap=12,
        )
        terminal, messages, code, stderr = run_worker(
            self.root, host, examples=self.BUDGET_EXAMPLES,
            held_out=[{"id": "h1", "split": "hidden_test"}],
            search_max_evaluations=12, stop_at_score=None, skip_perfect_score=True,
            max_messages=100,
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["stop_reason"], "iteration_limit")
        self.assertTrue(result["iteration_limit_reached"])
        self.assertEqual(result["iterations_started"], 12)
        self.assertEqual(host.reflections, 0)
        self.assertGreater(host.replays, 0)
        self.assertEqual(host.search_admitted, 3, "only the seed's distinct development cases cost evaluations")
        self.assertEqual(host.budget_refusals, 0)
        self.assertEqual(result["best_candidate_index"], 0)
        self.assertEqual(result["best_score"], 0.5, "a perfect training minibatch is not a validation win")
        self.assertEqual(result["held_out"]["best"]["scores"], {"h1": 1.0})

    def test_host_budget_refusal_still_stops_cleanly_with_incumbent(self) -> None:
        # Without remaining counts the stopper cannot see the ceiling; the ledger's hard
        # refusal remains the backstop and the saved incumbent is reported.
        host = FakeHost(reflect=self.revising_reflect(), score=self.rising_score, search_cap=7, report_remaining=False)
        terminal, messages, code, stderr = run_worker(
            self.root, host, examples=self.BUDGET_EXAMPLES,
            search_max_evaluations=100, stop_at_score=None, skip_perfect_score=False,
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["stop_reason"], "budget_exhausted")
        self.assertGreaterEqual(host.budget_refusals, 1)
        self.assertEqual(host.search_admitted, 7, "the host ceiling is never exceeded")
        self.assertTrue(result["has_incumbent"])
        self.assertIsNotNone(result["best_candidate_index"])
        texts = self.registered(messages)
        self.assertTrue(all(c["index"] in texts for c in result["candidates"]))
        self.assertEqual(texts[0], "bad candidate")

    def test_reflection_prompt_sees_case_request_and_head_tail_output(self) -> None:
        host = FakeHost(
            reflect=always("improved candidate"),
            score=exact("improved candidate"),
            output_excerpt=lambda candidate: "HEAD_PART [… omitted …] TAIL_PART",
        )
        terminal, messages, code, stderr = run_worker(self.root, host)
        self.assert_completed(terminal, code, stderr)
        prompt = host.reflect_prompts[0]
        self.assertIn("Return the required words.", prompt, "the case request reaches reflection")
        self.assertIn("TAIL_PART", prompt)
        self.assertIn("score 0.000", prompt)
        self.assertNotIn("_budget", prompt)
        self.assertIn("Produce the exact words improved candidate.", prompt, "objective survives the custom proposer")

    def test_over_ceiling_proposal_gets_one_repair_then_is_skipped(self) -> None:
        def reflect(prompt: str, count: int) -> str:
            if "over the hard limit" in prompt:
                return envelope("still far too long a candidate" if count == 2 else "tiny")
            return envelope("a candidate that is far too long")

        host = FakeHost(reflect=reflect, score=exact("tiny"))
        terminal, messages, code, stderr = run_worker(
            self.root, host, extra={"prompt_character_ceiling_ratio": 1.0},
        )
        result = self.assert_completed(terminal, code, stderr)
        usage = dict(item.split("=") for item in result["proposer_usage"].split(","))
        self.assertEqual(int(usage["skipped_over_ceiling"]), 1)
        self.assertGreaterEqual(int(usage["ceiling_repairs"]), 2)
        self.assertIn("over_ceiling", [m["contract"] for m in messages if m["type"] == "reflection"])
        evaluated = {payload["candidate"] for payload in host.evaluate_payloads}
        self.assertNotIn("still far too long a candidate", evaluated, "an over-ceiling text is never evaluated")
        self.assertEqual(self.registered(messages)[result["best_candidate_index"]], "tiny")
        self.assertTrue(all(len(p["candidate"]) <= len("bad candidate") for p in host.evaluate_payloads))

    def test_equal_quality_shorter_prompt_is_accepted_and_reported_best(self) -> None:
        host = FakeHost(reflect=always("short"), score=lambda candidate, payload: 0.5, search_cap=6)
        terminal, messages, code, stderr = run_worker(
            self.root, host, stop_at_score=None, skip_perfect_score=False,
            search_max_evaluations=6, extra={"prompt_character_ceiling_ratio": 1.0},
        )
        result = self.assert_completed(terminal, code, stderr)
        texts = self.registered(messages)
        self.assertIn("short", texts.values(), "a tie at a shorter length is accepted into the pool")
        self.assertEqual(texts[result["best_candidate_index"]], "short", "the shortest tied candidate is best")

    def test_scores_carry_quality_and_brevity_for_the_frontier(self) -> None:
        host = FakeHost(
            reflect=always("improved candidate"), score=exact("improved candidate"),
            output_characters=lambda candidate: 100 if candidate == "bad candidate" else 50,
        )
        terminal, messages, code, stderr = run_worker(self.root, host)
        self.assert_completed(terminal, code, stderr)
        prompt = host.reflect_prompts[0]
        # GEPA renames side_info "scores" to its objective field; the proposer renders it.
        self.assertIn("Objective scores (higher is better): brevity 0.500, quality 0.000", prompt)
        self.assertIn("answer length 100 characters", prompt)
        self.assertNotIn("_prompt_characters", prompt)

    def test_missing_search_remaining_fails_fast_before_any_evaluation(self) -> None:
        for value in (None, -1, "7", True):
            root = self.root / f"missing-{value}"
            root.mkdir()
            host = FakeHost(reflect=always("x"), score=exact("x"))
            terminal, messages, code, stderr = run_worker(root, host, extra={"search_remaining": value})
            self.assertEqual(terminal["type"], "failed", (value, stderr))
            self.assertEqual(terminal["diagnostic"]["exception_type"], "InfrastructureFailure")
            self.assertEqual(host.operations, [], "no evaluation or reflection before the check")

    def test_supplied_seed_answer_lengths_are_the_brevity_reference(self) -> None:
        # The ledger recorded a 200-character seed answer; this process sees it at 100.
        # With the supplied reference the seed's answer brevity is 1.0 (half the reference),
        # not the 0.5 a self-referenced length would give.
        host = FakeHost(
            reflect=always("improved candidate"), score=exact("improved candidate"),
            output_characters=lambda candidate: 100,
        )
        terminal, messages, code, stderr = run_worker(
            self.root, host, extra={"seed_output_characters": {"example-1": 200, "bad": "x"}},
        )
        self.assert_completed(terminal, code, stderr)
        self.assertIn("brevity 0.750, quality 0.000", host.reflect_prompts[0])

    def test_completion_reports_paired_per_case_validation_scores(self) -> None:
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(
            self.root, host,
            examples=[
                {"id": "t1", "split": "training", "input": "one"},
                {"id": "v1", "split": "validation", "input": "two"},
                {"id": "v2", "split": "validation", "input": "three"},
            ],
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["validation_scores"], {
            "baseline": {"v1": 0.0, "v2": 0.0},
            "best": {"v1": 1.0, "v2": 1.0},
        }, "keyed by suite case ID, for the seed (replicate 0) and the reported best")

    def test_identical_proposal_is_skipped_without_spending_a_child_pass(self) -> None:
        def reflect(prompt: str, count: int) -> str:
            return envelope("bad candidate" if count == 1 else "improved candidate")

        host = FakeHost(reflect=reflect, score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host)
        result = self.assert_completed(terminal, code, stderr)
        usage = dict(item.split("=") for item in result["proposer_usage"].split(","))
        self.assertEqual(int(usage["skipped_identical_proposals"]), 1)
        self.assertEqual(result["best_score"], 1.0)

    def test_budget_exhaustion_before_any_saved_state_reports_no_incumbent(self) -> None:
        host = FakeHost(reflect=always("x"), score=exact("x"), search_cap=1)
        terminal, messages, code, stderr = run_worker(
            self.root, host,
            examples=[
                {"id": "t1", "split": "training", "input": "one"},
                {"id": "v1", "split": "validation", "input": "two"},
                {"id": "v2", "split": "validation", "input": "three"},
            ],
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["stop_reason"], "budget_exhausted")
        self.assertFalse(result["has_incumbent"])
        self.assertEqual(result["candidates"], [])
        self.assertIsNone(result["best_candidate_index"])

    def test_large_evidence_stays_host_side(self) -> None:
        # The host keeps full outputs (here 2 MiB each) as private evidence and sends
        # GEPA only bounded proposer excerpts; GEPA embeds feedback in reflection prompts,
        # so bounding is a host responsibility. Nothing large crosses the protocol.
        private_outputs: dict[str, str] = {}

        def excerpt(candidate: str) -> str:
            private_outputs[candidate] = "E" * (2 * 1024 * 1024)
            return private_outputs[candidate][:8 * 1024]

        host = FakeHost(
            reflect=always("improved candidate"),
            score=exact("improved candidate"),
            output_excerpt=excerpt,
        )
        terminal, messages, code, stderr = run_worker(self.root, host)
        self.assert_completed(terminal, code, stderr)
        self.assertTrue(private_outputs)
        self.assertLess(len(json.dumps(terminal)), 64 * 1024)
        self.assertTrue(all(len(json.dumps(m)) < 1024 * 1024 for m in messages))

    def test_resume_reuses_run_dir_and_replays_recorded_evaluations(self) -> None:
        counter = {"n": 0}

        def reflect(prompt: str, count: int) -> str:
            counter["n"] += 1
            return envelope(f"candidate revision {counter['n']}")

        def score(candidate: str, payload: dict[str, Any]) -> float:
            return 0.0 if candidate == "bad candidate" else 0.5

        examples = [
            {"id": "t1", "split": "training", "input": "one"},
            {"id": "v1", "split": "validation", "input": "two"},
        ]
        memo: dict[str, dict[str, Any]] = {}
        first = FakeHost(reflect=reflect, score=score, search_cap=4, memo=memo)
        terminal, messages, code, stderr = run_worker(
            self.root, first, examples=examples, search_max_evaluations=10,
            stop_at_score=None, skip_perfect_score=False,
        )
        first_result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(first_result["stop_reason"], "budget_exhausted")
        self.assertTrue((self.root / "gepa-run" / "gepa_state.bin").is_file())

        second = FakeHost(reflect=reflect, score=score, search_cap=10 - first.search_admitted, memo=memo)
        terminal, messages, code, stderr = run_worker(
            self.root, second, examples=examples, search_max_evaluations=10,
            stop_at_score=None, skip_perfect_score=False,
        )
        second_result = self.assert_completed(terminal, code, stderr)
        self.assertGreaterEqual(second.replays, 1, "the resumed seed valset pass is replayed, not re-spent")
        self.assertLessEqual(first.search_admitted + second.search_admitted, 10)
        self.assertEqual(self.registered(messages)[0], "bad candidate")
        self.assertTrue(second_result["has_incumbent"])

    def test_seedless_search_generates_the_initial_candidate_through_host(self) -> None:
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host, seed=None)
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(host.operations[0], "reflect")
        self.assertEqual(result["best_score"], 1.0)

    def assert_reflection_skipped(self, first_reply: str, contract: str) -> None:
        def reflect(prompt: str, count: int) -> str:
            return first_reply if count == 1 else envelope("improved candidate")

        host = FakeHost(reflect=reflect, score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host)
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["best_score"], 1.0, "a later valid reflection still improves the seed")
        evaluated = {payload["candidate"] for payload in host.evaluate_payloads}
        self.assertLessEqual(evaluated, {"bad candidate", "improved candidate"}, evaluated)
        self.assertTrue(all(text.strip() for text in self.registered(messages).values()))
        contracts = [m["contract"] for m in messages if m["type"] == "reflection"]
        self.assertEqual(contracts[0], contract)
        self.assertIn("envelope", contracts)

    def test_missing_envelope_reflection_is_skipped_not_accepted_as_prose(self) -> None:
        self.assert_reflection_skipped("Here is the improved prompt:\n\nimproved candidate", "missing_envelope")

    def test_empty_envelope_reflection_is_skipped_not_fatal(self) -> None:
        self.assert_reflection_skipped(f"{REFLECTION_BEGIN}\n  \n{REFLECTION_END}", "empty_candidate")

    def test_proposer_usage_counts_only_reflection_replies(self) -> None:
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host)
        result = self.assert_completed(terminal, code, stderr)
        usage = dict(item.split("=") for item in result["proposer_usage"].split(","))
        self.assertEqual(int(usage["reflection_calls"]), host.reflections)
        self.assertEqual(int(usage["reported_callbacks"]), host.reflections)
        self.assertEqual(int(usage["unavailable_callbacks"]), 0, "evaluate replies are not proposer usage")
        self.assertEqual(int(usage["prompt_tokens"]), 11 * host.reflections)

    def test_held_out_provider_or_judge_failure_keeps_the_completed_search(self) -> None:
        held_out = [{"id": "h1", "split": "hidden_test"}]

        class HeldOutFailingHost(FakeHost):
            def __init__(self, code: str, **kwargs) -> None:
                super().__init__(**kwargs)
                self.code = code
                self.held_out_calls = 0

            def handle(self, message):
                if message["operation"] == "evaluate" and message["payload"]["split"] == "hidden_test":
                    self.held_out_calls += 1
                    if self.held_out_calls == 1:
                        return {"status": "failed", "failure_code": self.code, "error": "private"}
                return super().handle(message)

        for index, code in enumerate(["provider_rate_limited", "judge_invalid_response"]):
            root = self.root / f"run-{index}"
            root.mkdir()
            host = HeldOutFailingHost(code, reflect=always("improved candidate"), score=exact("improved candidate"))
            terminal, messages, code_value, stderr = run_worker(root, host, held_out=held_out)
            result = self.assert_completed(terminal, code_value, stderr)
            self.assertEqual(result["stop_reason"], "completed")
            self.assertTrue(result["has_incumbent"])
            self.assertIsNone(result["held_out"]["best"], "a failed held-out score is unavailable, never zero")
            self.assertIsNone(result["held_out"]["baseline"], "no calibration baseline was supplied")
            self.assertEqual(self.registered(messages)[result["best_candidate_index"]], "improved candidate")

    def test_held_out_ledger_failure_still_fails_the_run(self) -> None:
        class LedgerFailingHost(FakeHost):
            def handle(self, message):
                if message["operation"] == "evaluate" and message["payload"]["split"] == "hidden_test":
                    return {"status": "failed", "failure_code": "ledger_failure", "error": "private"}
                return super().handle(message)

        host = LedgerFailingHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(
            self.root, host, held_out=[{"id": "h1", "split": "hidden_test"}]
        )
        self.assertEqual(terminal["type"], "failed", stderr)
        self.assertEqual(terminal["diagnostic"]["failure_code"], "ledger_failure")

    def test_supplied_held_out_baseline_is_reused_and_only_the_incumbent_is_scored(self) -> None:
        held_out = [{"id": "h1", "split": "hidden_test"}, {"id": "h2", "split": "hidden_test"}]
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"), held_out_cap=2)
        terminal, messages, code, stderr = run_worker(
            self.root, host, held_out=held_out,
            extra={"held_out_baseline": {"scores": {"h1": 0.25, "h2": 0.75}, "average": 0.5}},
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["held_out"]["baseline"], {"scores": {"h1": 0.25, "h2": 0.75}, "average": 0.5})
        self.assertEqual(result["held_out"]["best"]["scores"], {"h1": 1.0, "h2": 1.0})
        hidden = [p for p in host.evaluate_payloads if p["split"] == "hidden_test"]
        self.assertEqual({p["candidate"] for p in hidden}, {"improved candidate"}, "the seed is never re-scored")
        self.assertEqual(host.held_out_admitted, 2, "a |hidden| reserve suffices")

    def test_mismatched_held_out_baseline_is_ignored(self) -> None:
        held_out = [{"id": "h1", "split": "hidden_test"}]
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(
            self.root, host, held_out=held_out,
            extra={"held_out_baseline": {"scores": {"other": 1.0}, "average": 1.0}},
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertIsNone(result["held_out"]["baseline"], "no fabricated or mismatched baseline")
        self.assertEqual(result["held_out"]["best"]["scores"], {"h1": 1.0})

    def test_held_out_without_supplied_baseline_scores_only_the_best(self) -> None:
        held_out = [{"id": "h1", "split": "hidden_test"}]
        host = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"))
        terminal, messages, code, stderr = run_worker(self.root, host, held_out=held_out)
        result = self.assert_completed(terminal, code, stderr)
        self.assertIsNone(result["held_out"]["baseline"], "without calibration the baseline is unavailable")
        self.assertEqual(result["held_out"]["best"]["scores"], {"h1": 1.0})
        visible = [p for p in host.evaluate_payloads if p["split"] != "hidden_test"]
        self.assertTrue(visible and all(p["example_id"] != "h1" for p in visible))

        other = Path(self.root / "second")
        other.mkdir()
        limited = FakeHost(reflect=always("improved candidate"), score=exact("improved candidate"), held_out_cap=0)
        terminal, messages, code, stderr = run_worker(other, limited, held_out=held_out)
        result = self.assert_completed(terminal, code, stderr)
        self.assertIsNone(result["held_out"]["best"], "an unadmitted held-out pass is unavailable, never zero")
        self.assertEqual(result["stop_reason"], "completed", "a spent held-out reserve never relabels the search")
        self.assertEqual(limited.budget_refusals, 1, "only the held-out reserve refused an admission")

    def test_seed_still_best_scores_the_seed_once_when_no_baseline_was_supplied(self) -> None:
        # The reflector keeps re-proposing one rejected text. Its replays are free, so only
        # the repeat skip and the reflection ceiling end the loop; the seed stays best.
        held_out = [{"id": "h1", "split": "hidden_test"}]
        host = FakeHost(
            reflect=always("worse"), score=lambda c, p: 0.5 if c == "bad candidate" else 0.0, search_cap=12,
        )
        terminal, messages, code, stderr = run_worker(
            self.root, host, held_out=held_out, search_max_evaluations=12, stop_at_score=None,
            skip_perfect_score=False,
        )
        result = self.assert_completed(terminal, code, stderr)
        self.assertEqual(result["best_candidate_index"], 0)
        self.assertTrue(result["reflection_limit_reached"])
        self.assertEqual(host.reflections, 12)
        usage = dict(item.split("=") for item in result["proposer_usage"].split(","))
        self.assertEqual(int(usage["skipped_repeated_proposals"]), 11)
        self.assertEqual(host.search_admitted, 2, "seed pass plus the single distinct child")
        self.assertEqual(result["held_out"]["baseline"], result["held_out"]["best"])
        self.assertEqual(host.held_out_admitted, 1)

    def test_failure_envelope_exposes_safe_class_and_frame_without_exception_text(self) -> None:
        secret = "HOST_PRIVATE_INFRASTRUCTURE_SECRET_CANARY"

        class FailingHost(FakeHost):
            def handle(self, message):
                return {"status": "failed", "failure_code": "provider_rejected", "error": secret}

        host = FailingHost(reflect=always("x"), score=exact("x"))
        terminal, messages, code, stderr = run_worker(self.root, host)
        self.assertEqual(code, 2, stderr)
        self.assertEqual(terminal["type"], "failed")
        self.assertNotIn(secret, json.dumps(terminal))
        diagnostic = terminal["diagnostic"]
        self.assertEqual(diagnostic["failure_code"], "provider_rejected")
        self.assertEqual(diagnostic["exception_type"], "InfrastructureFailure")
        self.assertEqual(diagnostic["source_frame"]["function"], "host_call")

    def test_interrupt_while_awaiting_host_reports_cancelled(self) -> None:
        host = FakeHost(reflect=always("x"), score=exact("x"))
        terminal, messages, code, stderr = run_worker(self.root, host, interrupt_on_first_request=True)
        self.assertIsNotNone(terminal, stderr)
        self.assertEqual(terminal["type"], "cancelled")
        self.assertEqual(code, 130)


if __name__ == "__main__":
    unittest.main()
