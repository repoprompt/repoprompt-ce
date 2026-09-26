#!/usr/bin/env python3
"""Versioned NDJSON bridge from RepoPrompt CE to upstream GEPA optimize_anything.

Protocol v2. The worker owns no credentials and never calls a provider directly:
reflection and every evaluation synchronously round-trip to the host over stdio.
The host owns the durable evaluation ledger, provider retries, grading, and all
evidence. The worker streams small identity events and a final summary that carries
only GEPA indices, lineage, aggregate scores, and content hashes; candidate text is
sent once per candidate in its own `candidate` event, never inside the final line.

Budget contract (pinned GEPA 0.1.4 / 0632cdb5):
- The host ledger is the only hard admission authority. When it refuses an
  evaluation it replies `status=budget_exhausted`; the evaluator raises
  `gepa.oa.budget.BudgetExhausted`, which `GepaEngine.run` catches and answers by
  reloading the incumbent Pareto pool from `run_dir/gepa_state.bin` (saved at every
  iteration boundary). If no state was saved yet there is no incumbent and the
  worker reports none instead of the eval server's per-example argmax.
- `raise_on_exception` stays True: with False, upstream `EvaluatorWrapper`
  converts *any* evaluator exception, including `BudgetExhausted`, into a 0.0
  score. Candidate-level failures are scored replies from the host, not exceptions.
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.metadata
import json
import math
import os
import pathlib
import signal
import sys
import time
import uuid
from typing import Any

PROTOCOL_VERSION = 2
PROTOCOL_OUT = sys.stdout
EXPECTED_GEPA_VERSION = "0.1.4"
EXPECTED_GEPA_REVISION = "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407"

REFLECTION_BEGIN = "<<<REPOPROMPT_CANDIDATE_BEGIN>>>"
REFLECTION_END = "<<<REPOPROMPT_CANDIDATE_END>>>"
REFLECTION_OUTPUT_CONTRACT = f"""

Output contract (this overrides any earlier instruction about ``` blocks):
Return the complete new candidate text exactly once, between a line containing only {REFLECTION_BEGIN} and a line containing only {REFLECTION_END}.
Put nothing else between those two lines. Code fences inside the candidate are allowed and are preserved verbatim; do not wrap the candidate itself in ``` fences."""


class WorkerCancelled(BaseException):
    pass


class ReflectionRejected(Exception):
    """A reflection reply with no usable candidate (missing envelope or empty text).

    Deliberately an ordinary `Exception`: pinned GEPA's `_propose_texts_batch_safe`
    isolates it and skips that proposal instead of failing the run. Prose is never
    accepted as a candidate, because candidates can later be patched into source.
    """


class InfrastructureFailure(BaseException):
    """Escapes GEPA's candidate-error handling so infrastructure is never a score."""

    def __init__(self, message, *, failure_code=None, operation=None):
        super().__init__(message)
        self.failure_code = failure_code if isinstance(failure_code, str) and (
            failure_code.startswith("provider_") or failure_code.startswith("judge_")
            or failure_code in ("ledger_failure", "cancelled")
        ) and len(failure_code) <= 64 else None
        self.operation = operation if operation in ("reflect", "evaluate") else None


def emit(payload: dict[str, Any]) -> None:
    payload = {"protocol_version": PROTOCOL_VERSION, **payload}
    PROTOCOL_OUT.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    PROTOCOL_OUT.flush()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def safe_python_identifier(value: Any, *, dotted: bool = False) -> str:
    if not isinstance(value, str) or not value or len(value) > 256:
        return "unavailable"
    components = value.split(".") if dotted else [value]
    if any(
        not component
        or len(component) > 128
        or not component.isascii()
        or not component.isidentifier()
        for component in components
    ):
        return "unavailable"
    return value


def safe_failure_diagnostic(error: BaseException) -> dict[str, Any]:
    traceback_node = error.__traceback__
    while traceback_node is not None and traceback_node.tb_next is not None:
        traceback_node = traceback_node.tb_next
    source_frame: dict[str, Any] = {"module": "unavailable", "function": "unavailable", "line": None}
    if traceback_node is not None:
        frame = traceback_node.tb_frame
        source_frame = {
            "module": safe_python_identifier(frame.f_globals.get("__name__"), dotted=True),
            "function": safe_python_identifier(frame.f_code.co_name),
            "line": traceback_node.tb_lineno if traceback_node.tb_lineno > 0 else None,
        }
    return {
        "schema_version": 1,
        "exception_type": safe_python_identifier(type(error).__name__),
        "failure_code": error.failure_code if isinstance(error, InfrastructureFailure) else None,
        "operation": error.operation if isinstance(error, InfrastructureFailure) else None,
        "source_frame": source_frame,
    }


def emit_failure(error: BaseException) -> None:
    emit({
        "type": "failed",
        "failure_kind": "infrastructure",
        "error": "worker_failure_detail_excluded",
        "diagnostic": safe_failure_diagnostic(error),
    })


def receive() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise InfrastructureFailure("host transport closed")
    value = json.loads(line)
    if not isinstance(value, dict):
        raise InfrastructureFailure("host response is not an object")
    return value


def host_call(operation: str, payload: dict[str, Any]) -> dict[str, Any]:
    """One synchronous host round trip. Provider retries are the host's responsibility."""
    request_id = str(uuid.uuid4())
    emit({"type": "host_request", "id": request_id, "operation": operation, "payload": payload})
    response = receive()
    if response.get("type") != "host_response" or response.get("id") != request_id:
        raise InfrastructureFailure("host response identity mismatch", operation=operation)
    status = response.get("status")
    if status in ("ok", "budget_exhausted"):
        return response
    raise InfrastructureFailure(
        str(response.get("error") or "host operation failed"),
        failure_code=response.get("failure_code"),
        operation=operation,
    )


def installed_revision() -> str | None:
    distribution = importlib.metadata.distribution("gepa")
    direct_url = distribution.read_text("direct_url.json")
    if not direct_url:
        return None
    try:
        return json.loads(direct_url).get("vcs_info", {}).get("commit_id")
    except (TypeError, ValueError):
        return None


def verify_gepa() -> None:
    version = importlib.metadata.version("gepa")
    revision = installed_revision()
    if version != EXPECTED_GEPA_VERSION:
        raise InfrastructureFailure(f"GEPA version mismatch: expected {EXPECTED_GEPA_VERSION}, found {version}")
    if revision != EXPECTED_GEPA_REVISION:
        raise InfrastructureFailure(
            "GEPA must be installed from the approved pinned git revision; "
            f"expected {EXPECTED_GEPA_REVISION}, found {revision or 'unavailable'}"
        )


def candidate_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if "current_candidate" in value:
            return str(value["current_candidate"])
        if len(value) == 1:
            return str(next(iter(value.values())))
        return json.dumps(value, sort_keys=True)
    return str(value)


def extract_reflection_candidate(output: str) -> tuple[str | None, str]:
    """Return the complete candidate from a reflection reply and the contract that found it.

    `envelope`: the explicit marker lines (first BEGIN, last END). `fenced_block`: the
    whole reply is one fenced block, so GEPA's own first/last-fence rule is exact.
    `missing_envelope`: anything else yields no candidate (`None`); surrounding prose such
    as "Here is the improved prompt:" must never become candidate text.
    """
    lines = output.split("\n")
    begin = next((i for i, line in enumerate(lines) if line.strip() == REFLECTION_BEGIN), None)
    if begin is not None:
        end = next(
            (i for i in range(len(lines) - 1, begin, -1) if lines[i].strip() == REFLECTION_END),
            None,
        )
        if end is not None:
            return "\n".join(lines[begin + 1:end]).strip(), "envelope"
    stripped = output.strip()
    if len(stripped) > 6 and stripped.startswith("```") and stripped.endswith("```"):
        from gepa.strategies.instruction_proposal import InstructionProposalSignature
        return InstructionProposalSignature.output_extractor(stripped)["new_instruction"], "fenced_block"
    return None, "missing_envelope"


def delimit_for_gepa(candidate: str) -> str:
    """Wrap a complete candidate so GEPA's extractor (first/last ``` + strip) returns it exactly.

    Pinned `InstructionProposalSignature.output_extractor(raw.strip())` takes the text
    between the first and last fence, drops one leading line only when it is a bare
    language tag, and strips. A leading newline is that line here, so inner fences survive.
    """
    return f"```\n{candidate}\n```"


def finite_score(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise InfrastructureFailure("evaluation host returned a non-finite score", operation="evaluate")
    return float(value)


class RunState:
    def __init__(self) -> None:
        # Search-pool exhaustion only; it decides `stop_reason`. Held-out reporting has its
        # own reserve and flag so a spent reserve never relabels a normal search.
        self.budget_exhausted = False
        self.held_out_budget_exhausted = False
        self.emitted_candidates: dict[int, str] = {}
        self.reflection_calls = 0
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.usage_reported = 0
        self.usage_unavailable = 0

    def record_usage(self, response: dict[str, Any]) -> None:
        """Proposer usage: called for reflection replies only (evaluate replies carry no tokens)."""
        prompt_tokens = response.get("prompt_tokens")
        completion_tokens = response.get("completion_tokens")
        if isinstance(prompt_tokens, int) or isinstance(completion_tokens, int):
            self.prompt_tokens += prompt_tokens if isinstance(prompt_tokens, int) else 0
            self.completion_tokens += completion_tokens if isinstance(completion_tokens, int) else 0
            self.usage_reported += 1
        else:
            self.usage_unavailable += 1

    def emit_candidate(self, index: int, text: str, parents: list[int], score: float | None) -> None:
        digest = sha256_text(text)
        previous = self.emitted_candidates.get(index)
        if previous == digest:
            return
        if previous is not None:
            raise InfrastructureFailure("GEPA changed the text of an already registered candidate index")
        self.emitted_candidates[index] = digest
        emit({
            "type": "candidate",
            "event_id": f"candidate:{index}:{digest}",
            "candidate_index": index,
            "candidate_sha256": digest,
            "candidate": text,
            "parent_indices": parents,
            "aggregate_score": score if score is None or math.isfinite(score) else None,
        })


def build_callbacks(state: RunState) -> list[Any]:
    class CandidateRegistration:
        """Streams each pool candidate with its upstream index as GEPA registers it."""

        def on_valset_evaluated(self, event: dict[str, Any]) -> None:
            index = event.get("candidate_idx")
            if not isinstance(index, int) or index < 0:
                return
            parents = [int(p) for p in (event.get("parent_ids") or []) if isinstance(p, int) and p >= 0]
            score = event.get("average_score")
            state.emit_candidate(
                index,
                candidate_text(event.get("candidate")),
                parents,
                float(score) if isinstance(score, (int, float)) else None,
            )

    return [CandidateRegistration()]


def main() -> int:
    started = time.monotonic()

    def cancel_worker(signum, frame):
        raise WorkerCancelled(signum)

    signal.signal(signal.SIGTERM, cancel_worker)
    signal.signal(signal.SIGINT, cancel_worker)
    try:
        request = receive()
        if request.get("protocol_version") != PROTOCOL_VERSION or request.get("type") != "run":
            raise InfrastructureFailure("unsupported worker protocol")
        verify_gepa()

        from gepa.oa.budget import BudgetExhausted
        from gepa.optimize_anything import OptimizeAnythingConfig, optimize_anything

        body = request.get("request")
        if not isinstance(body, dict):
            raise InfrastructureFailure("run request is missing")
        run_dir = pathlib.Path(str(body["run_dir"])).resolve()
        output_dir = pathlib.Path(str(body["output_dir"])).resolve()
        run_dir.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        search_max_evaluations = int(body["search_max_evaluations"])
        if search_max_evaluations < 1:
            raise InfrastructureFailure("search evaluation budget must be positive")
        state = RunState()

        class HostLanguageModel:
            def __call__(self, prompt: str | list[dict[str, Any]]) -> str:
                text = prompt if isinstance(prompt, str) else json.dumps(prompt, sort_keys=True)
                response = host_call("reflect", {"prompt": text + REFLECTION_OUTPUT_CONTRACT})
                state.record_usage(response)
                state.reflection_calls += 1
                output = response.get("output")
                if response.get("status") != "ok":
                    raise InfrastructureFailure("reflection host returned no candidate text", operation="reflect")
                candidate, contract = (
                    extract_reflection_candidate(output) if isinstance(output, str) else (None, "missing_envelope")
                )
                if candidate is not None and not candidate.strip():
                    candidate, contract = None, "empty_candidate"
                emit({
                    "type": "reflection",
                    "event_id": f"reflection:{state.reflection_calls}",
                    "contract": contract,
                    "candidate_sha256": sha256_text(candidate) if candidate is not None else "",
                })
                if candidate is None:
                    raise ReflectionRejected(contract)
                return delimit_for_gepa(candidate)

        def host_evaluate(text: str, example: dict[str, Any], *, held_out: bool = False) -> dict[str, Any]:
            response = host_call("evaluate", {
                "candidate": text,
                "candidate_sha256": sha256_text(text),
                "example_id": str(example["id"]),
                "split": str(example["split"]),
            })
            if response.get("status") == "budget_exhausted":
                if held_out:
                    state.held_out_budget_exhausted = True
                else:
                    state.budget_exhausted = True
                raise BudgetExhausted("host evaluation ledger refused admission")
            return response

        def evaluate(candidate: Any, example: Any = None) -> tuple[float, dict[str, Any]]:
            text = candidate_text(candidate)
            example_value = example if isinstance(example, dict) else {"id": "single", "split": "training"}
            response = host_evaluate(text, example_value)
            score = finite_score(response.get("score"))
            emit({
                "type": "evaluation",
                "event_id": str(response.get("evaluation_id") or "unavailable"),
                "candidate_sha256": sha256_text(text),
                "example_id": str(example_value["id"]),
                "split": str(example_value["split"]),
                "score": score,
                "replayed": bool(response.get("replayed", False)),
            })
            side_info: dict[str, Any] = {"feedback": str(response.get("feedback") or "")}
            excerpt = response.get("output_excerpt")
            if isinstance(excerpt, str) and excerpt:
                side_info["output"] = excerpt
            return score, side_info

        def examples(key: str, *, with_input: bool) -> list[dict[str, Any]]:
            values = []
            for item in body.get(key, []):
                value = {"id": str(item["id"]), "split": str(item["split"])}
                if with_input:
                    value["input"] = str(item["input"])
                values.append(value)
            return values

        visible = examples("examples", with_input=True)
        dataset = [e for e in visible if e["split"] == "training"]
        valset = [e for e in visible if e["split"] == "validation"]
        # Held-out cases are scored host-side by identity; their inputs never cross.
        held_out = examples("held_out_examples", with_input=False)
        if any(e["split"] != "hidden_test" for e in held_out) or any(e["split"] == "hidden_test" for e in visible):
            raise InfrastructureFailure("held-out examples must travel only in held_out_examples")
        if not dataset and valset:
            dataset, valset = valset, []
        if not dataset:
            raise InfrastructureFailure("GEPA search requires at least one development example")

        stop_at_score = body.get("stop_at_score")
        config = OptimizeAnythingConfig(
            engine="gepa",
            name=str(body["run_name"]),
            # Cumulative across resumes: GEPA's MaxMetricCallsStopper reads the persisted
            # state.total_num_evals. The host ledger enforces the remaining hard ceiling.
            max_evals=search_max_evaluations,
            max_token_cost=None,
            max_concurrency=1,
            output_dir=str(output_dir),
            run_dir=str(run_dir),
            stop_at_score=float(stop_at_score) if isinstance(stop_at_score, (int, float)) else None,
            sandbox=True,
            engine_config={
                "reflection": {
                    "reflection_lm": HostLanguageModel(),
                    "reflection_minibatch_size": int(body.get("reflection_minibatch_size", 3)),
                    "skip_perfect_score": bool(body.get("skip_perfect_score", True)),
                    "perfect_score": float(body["perfect_score"]),
                },
                "merge": (
                    {"max_merge_invocations": int(body.get("max_merge_invocations", 5))}
                    if bool(body.get("use_merge", False))
                    else None
                ),
                "engine": {
                    "seed": int(body.get("random_seed", 0)),
                    "parallel": False,
                    "max_workers": 1,
                    "write_agent_state": True,
                    "raise_on_exception": True,
                },
                "callbacks": build_callbacks(state),
            },
        )
        with contextlib.redirect_stdout(sys.stderr):
            result = optimize_anything(
                seed_candidate=body.get("seed_candidate"),
                evaluator=evaluate,
                dataset=dataset,
                valset=valset or None,
                test_set=None,
                objective=str(body["objective"]),
                background=str(body.get("background") or ""),
                config=config,
            )

        oa_budget = result.metadata.get("budget") if isinstance(result.metadata, dict) else None
        oa_exhausted = isinstance(oa_budget, dict) and bool(oa_budget.get("exhausted"))
        stop_reason = "budget_exhausted" if state.budget_exhausted or oa_exhausted else "completed"
        # Without gepa_state.bin, upstream falls back to the eval server's per-example
        # argmax; that is not a GEPA incumbent, so no winner is reported.
        has_incumbent = (run_dir / "gepa_state.bin").is_file()
        candidates: list[dict[str, Any]] = []
        best_index = None
        best_score = None
        baseline_score = None
        held_out_result = None
        if has_incumbent:
            texts = [candidate_text(value) for value in result.candidates]
            scores = [
                float(value) if isinstance(value, (int, float)) and math.isfinite(float(value)) else None
                for value in result.val_aggregate_scores
            ]
            parents = [
                [int(p) for p in (values or []) if p is not None]
                for values in result.parents
            ]
            for index, text in enumerate(texts):
                state.emit_candidate(index, text, parents[index], scores[index])
                candidates.append({
                    "index": index,
                    "sha256": sha256_text(text),
                    "parent_indices": parents[index],
                    "aggregate_score": scores[index],
                })
            best_index = int(result.best_idx) if result.best_idx is not None else None
            best_score = scores[best_index] if best_index is not None else None
            baseline_score = scores[0] if scores else None

            def score_held_out(text: str) -> dict[str, Any] | None:
                """Held-out scores are report-only: an exhausted reserve or a provider/judge
                failure makes this score unavailable (`None`) but never discards the finished
                search. Ledger, cancellation and protocol failures still fail the run."""
                per_example: dict[str, float] = {}
                for example in held_out:
                    try:
                        response = host_evaluate(text, example, held_out=True)
                    except BudgetExhausted:
                        return None
                    except InfrastructureFailure as failure:
                        code = failure.failure_code or ""
                        if code.startswith("provider_") or code.startswith("judge_"):
                            return None
                        raise
                    per_example[example["id"]] = finite_score(response.get("score"))
                return {
                    "scores": per_example,
                    "average": sum(per_example.values()) / len(per_example),
                }

            if held_out and best_index is not None:
                baseline_held_out = score_held_out(texts[0])
                best_held_out = (
                    baseline_held_out if texts[best_index] == texts[0] else score_held_out(texts[best_index])
                )
                held_out_result = {"baseline": baseline_held_out, "best": best_held_out}

        emit({
            "type": "completed",
            "event_id": "completed",
            "result": {
                "engine": "gepa",
                "upstream_revision": EXPECTED_GEPA_REVISION,
                "stop_reason": stop_reason,
                "has_incumbent": has_incumbent,
                "candidates": candidates,
                "best_candidate_index": best_index,
                "best_score": best_score,
                "baseline_score": baseline_score,
                "total_metric_calls": result.total_metric_calls if isinstance(result.total_metric_calls, int) else None,
                "wall_time_seconds": time.monotonic() - started,
                "held_out": held_out_result,
                "proposer_usage": (
                    f"reflection_calls={state.reflection_calls},prompt_tokens={state.prompt_tokens},"
                    f"completion_tokens={state.completion_tokens},reported_callbacks={state.usage_reported},"
                    f"unavailable_callbacks={state.usage_unavailable}"
                ),
            },
        })
        return 0
    except WorkerCancelled as error:
        emit({"type": "cancelled", "signal": error.args[0]})
        return 130
    except BaseException as error:
        emit_failure(error)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
