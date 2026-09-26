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
- GEPA's own metric-call counter is not used as a stopper: it restarts per process and
  counts ledger replays, so it drifts from real spend on resume. `LedgerBudgetStopper`
  reads the host ledger's remaining search admissions (sent with every evaluation reply)
  and never starts an iteration it could not finish (a full iteration costs
  2 * minibatch + |valset| when the child is accepted).
- `raise_on_exception` stays True: with False, upstream `EvaluatorWrapper`
  converts *any* evaluator exception, including `BudgetExhausted`, into a 0.0
  score. Candidate-level failures are scored replies from the host, not exceptions.

Reflection: the worker owns the reflection prompt through GEPA's
`custom_candidate_proposer`, so the reflection model sees the objective, the case
request, the score, the grader feedback, and a head+tail output excerpt per case, and
never GEPA's internal `_budget` bookkeeping.
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.metadata
import json
import math
import os
import pathlib
import re
import signal
import sys
import time
import uuid
import warnings
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

# side_info keys the proposer renders explicitly, in this order; any other key that does
# not start with "_" is rendered generically. "_"-prefixed keys (GEPA's `_budget`, and
# upstream transient markers) are bookkeeping and never reach the reflection model.
SIDE_INFO_REQUEST = "request"
SIDE_INFO_SCORE = "score"
SIDE_INFO_FEEDBACK = "feedback"
SIDE_INFO_OUTPUT = "output"
SIDE_INFO_OBJECTIVES = "Scores (Higher is Better)"


def fenced(text: str, info: str = "") -> str:
    """Fence `text` with a backtick run longer than any run inside it, so embedded code
    fences in prompts, requests, or outputs can never close the block early."""
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}{info}\n{text}\n{fence}"


def format_score(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return "unavailable"
    return f"{float(value):.3f}"


def render_case(position: int, record: dict[str, Any]) -> str:
    parts = [f"### Case {position} — score {format_score(record.get(SIDE_INFO_SCORE))}"]
    objectives = record.get(SIDE_INFO_OBJECTIVES)
    if isinstance(objectives, dict) and objectives:
        rendered = ", ".join(f"{name} {format_score(value)}" for name, value in sorted(objectives.items()))
        parts.append(f"Objective scores (higher is better): {rendered}")
    request = record.get(SIDE_INFO_REQUEST)
    if isinstance(request, str) and request:
        parts.append("User request (the instructions only; the frozen file context the target also received is omitted):\n" + fenced(request))
    feedback = record.get(SIDE_INFO_FEEDBACK)
    if isinstance(feedback, str) and feedback:
        parts.append("Evaluator feedback:\n" + fenced(feedback))
    output = record.get(SIDE_INFO_OUTPUT)
    if isinstance(output, str) and output:
        parts.append("Target output (head and tail excerpt):\n" + fenced(output))
    known = {SIDE_INFO_REQUEST, SIDE_INFO_SCORE, SIDE_INFO_FEEDBACK, SIDE_INFO_OUTPUT, SIDE_INFO_OBJECTIVES}
    for key in sorted(k for k in record if isinstance(k, str) and k not in known and not k.startswith("_")):
        value = record[key]
        text = value if isinstance(value, str) else json.dumps(value, sort_keys=True, default=str)
        parts.append(f"{key}:\n" + fenced(text))
    return "\n\n".join(parts)


def build_reflection_prompt(
    *,
    objective: str,
    background: str,
    current: str,
    records: list[dict[str, Any]],
) -> str:
    """The complete reflection request for one component. `records` are GEPA's reflective
    dataset entries (the evaluator's side_info per minibatch case)."""
    sections = [
        "You are improving a system prompt. Analyze the evaluation evidence and propose a revised prompt.",
        "## Optimization goal\n\n" + objective,
    ]
    if background:
        sections.append("## Domain context and constraints\n\n" + background)
    sections.append(f"## Current prompt ({len(current)} characters)\n\n" + fenced(current))
    cases = [render_case(i + 1, dict(record)) for i, record in enumerate(records)]
    sections.append(
        f"## Evaluation evidence ({len(cases)} case{'s' if len(cases) != 1 else ''})\n\n"
        + ("\n\n".join(cases) if cases else "No per-case evidence was recorded.")
    )
    sections.append(
        "## Your task\n\n"
        "1. Diagnose: explain each low score by what the prompt says, omits, or over-emphasizes. "
        "Look for root causes shared across cases rather than one-off noise.\n"
        "2. Preserve: keep the instructions the high-scoring behavior relied on.\n"
        "3. Revise: edit the current prompt to remove those root causes. Prefer rewriting or "
        "tightening existing text over appending new rules, and never add case-specific content.\n"
        "4. Keep the prompt's role and output contract."
    )
    return "\n\n".join(sections) + REFLECTION_OUTPUT_CONTRACT


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
    def __init__(self, search_remaining: int | None = None) -> None:
        # Search-pool exhaustion only; it decides `stop_reason`. Held-out reporting has its
        # own reserve and flag so a spent reserve never relabels a normal search.
        self.budget_exhausted = False
        self.held_out_budget_exhausted = False
        # Host-ledger search admissions still available; refreshed by every evaluation reply.
        self.search_remaining = search_remaining
        self.stopped_before_unfinishable_iteration = False
        self.reflection_limit_reached = False
        self.skipped_identical_proposals = 0
        self.skipped_repeated_proposals = 0
        # Texts already proposed in this process: re-proposing one would only replay free
        # ledger outcomes, so it can never drain the budget the stopper watches.
        self.proposed_sha256: set[str] = set()
        self.emitted_candidates: dict[int, str] = {}
        self.reflection_calls = 0
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.usage_reported = 0
        self.usage_unavailable = 0

    def record_remaining(self, response: dict[str, Any]) -> None:
        remaining = response.get("search_remaining")
        if isinstance(remaining, int) and not isinstance(remaining, bool) and remaining >= 0:
            self.search_remaining = remaining

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


class LedgerBudgetStopper:
    """GEPA stop callback (checked only at iteration boundaries): stop when the host
    ledger's remaining search admissions cannot pay for a whole iteration, so no
    iteration is abandoned mid-way with its accepted child lost."""

    def __init__(self, state: RunState, iteration_cost: int, max_reflections: int) -> None:
        self.state = state
        self.iteration_cost = iteration_cost
        # Reflection calls are not ledger admissions, and an iteration made only of ledger
        # replays spends nothing, so the admission count alone cannot bound the loop. A real
        # iteration spends at least one admission, so the search cap bounds useful reflections.
        self.max_reflections = max_reflections

    def __call__(self, gepa_state: Any) -> bool:
        remaining = self.state.search_remaining
        if remaining is not None and remaining < self.iteration_cost:
            self.state.budget_exhausted = True
            self.state.stopped_before_unfinishable_iteration = True
            return True
        if self.state.reflection_calls >= self.max_reflections:
            self.state.reflection_limit_reached = True
            return True
        return False


def full_iteration_cost(*, minibatch: int, training: int, validation: int) -> int:
    """Worst-case metric calls for one reflective iteration: parent and child minibatch
    passes plus the accepted child's full validation pass (GEPA validates on the training
    set when there is no valset)."""
    effective_minibatch = min(max(1, minibatch), max(1, training))
    return 2 * effective_minibatch + (validation if validation > 0 else training)


def held_out_baseline_from(value: Any, held_out_ids: list[str]) -> dict[str, Any] | None:
    """A host-supplied seed held-out baseline (calibration cache or pre-search pass),
    accepted only when it scores exactly the held-out cases with finite values."""
    if not isinstance(value, dict) or not isinstance(value.get("scores"), dict):
        return None
    scores = value["scores"]
    if sorted(scores) != sorted(held_out_ids) or not scores:
        return None
    try:
        per_example = {str(key): finite_score(score) for key, score in scores.items()}
    except InfrastructureFailure:
        return None
    return {"scores": per_example, "average": sum(per_example.values()) / len(per_example)}


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
        initial_remaining = body.get("search_remaining")
        state = RunState(
            search_remaining=initial_remaining
            if isinstance(initial_remaining, int) and not isinstance(initial_remaining, bool) and initial_remaining >= 0
            else search_max_evaluations
        )
        objective = str(body["objective"])
        background = str(body.get("background") or "")

        def reflect_candidate(prompt: str) -> str:
            """One host reflection call; returns the enveloped candidate or raises
            `ReflectionRejected` (GEPA skips that proposal)."""
            response = host_call("reflect", {"prompt": prompt})
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
            return candidate

        class HostLanguageModel:
            """GEPA's own reflection-LM path, used only for seedless seed generation; the
            reflective proposer below owns every mutation prompt."""

            def __call__(self, prompt: str | list[dict[str, Any]]) -> str:
                text = prompt if isinstance(prompt, str) else json.dumps(prompt, sort_keys=True)
                return delimit_for_gepa(reflect_candidate(text + REFLECTION_OUTPUT_CONTRACT))

        def propose_candidate(
            candidate: dict[str, str],
            reflective_dataset: dict[str, list[dict[str, Any]]],
            components_to_update: list[str],
        ) -> dict[str, str]:
            proposals: dict[str, str] = {}
            for component in components_to_update:
                current = str(candidate.get(component, ""))
                records = [dict(record) for record in (reflective_dataset.get(component) or [])]
                text = reflect_candidate(build_reflection_prompt(
                    objective=objective, background=background, current=current, records=records,
                ))
                if text == current:
                    # An unchanged proposal would spend a child minibatch pass for nothing.
                    state.skipped_identical_proposals += 1
                    continue
                digest = sha256_text(text)
                if digest in state.proposed_sha256:
                    state.skipped_repeated_proposals += 1
                    continue
                state.proposed_sha256.add(digest)
                proposals[component] = text
            return proposals

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
                    state.search_remaining = 0
                raise BudgetExhausted("host evaluation ledger refused admission")
            if not held_out:
                state.record_remaining(response)
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
            side_info: dict[str, Any] = {}
            request_text = example_value.get("input")
            if isinstance(request_text, str) and request_text:
                side_info[SIDE_INFO_REQUEST] = request_text
            side_info[SIDE_INFO_SCORE] = score
            side_info[SIDE_INFO_FEEDBACK] = str(response.get("feedback") or "")
            excerpt = response.get("output_excerpt")
            if isinstance(excerpt, str) and excerpt:
                side_info[SIDE_INFO_OUTPUT] = excerpt
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

        minibatch = int(body.get("reflection_minibatch_size", 2))
        iteration_cost = full_iteration_cost(
            minibatch=minibatch, training=len(dataset), validation=len(valset),
        )
        stop_at_score = body.get("stop_at_score")
        config = OptimizeAnythingConfig(
            engine="gepa",
            name=str(body["run_name"]),
            # No GEPA eval cap: the host ledger is the hard ceiling and LedgerBudgetStopper
            # stops at iteration boundaries from the ledger's own remaining count.
            max_evals=None,
            max_token_cost=None,
            max_concurrency=1,
            output_dir=str(output_dir),
            run_dir=str(run_dir),
            stop_at_score=float(stop_at_score) if isinstance(stop_at_score, (int, float)) else None,
            sandbox=True,
            engine_config={
                "reflection": {
                    "reflection_lm": HostLanguageModel(),
                    "custom_candidate_proposer": propose_candidate,
                    "reflection_minibatch_size": minibatch,
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
                    "candidate_selection_strategy": str(body.get("candidate_selection_strategy") or "current_best"),
                },
                "stop_callbacks": [LedgerBudgetStopper(state, iteration_cost, max_reflections=search_max_evaluations)],
                "callbacks": build_callbacks(state),
            },
        )
        with contextlib.redirect_stdout(sys.stderr), warnings.catch_warnings():
            # max_evals=None is deliberate (see LedgerBudgetStopper); silence the unbounded-run warning.
            warnings.simplefilter("ignore", UserWarning)
            result = optimize_anything(
                seed_candidate=body.get("seed_candidate"),
                evaluator=evaluate,
                dataset=dataset,
                valset=valset or None,
                test_set=None,
                objective=objective,
                background=background,
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
                # The seed's held-out baseline comes from the host (calibration cache or its
                # pre-search pass); the reserve pays only for the incumbent. Only when no
                # baseline was supplied and the seed is still best is the seed scored here.
                supplied = held_out_baseline_from(body.get("held_out_baseline"), [e["id"] for e in held_out])
                if texts[best_index] == texts[0]:
                    baseline_held_out = supplied or score_held_out(texts[0])
                    held_out_result = {"baseline": baseline_held_out, "best": baseline_held_out}
                else:
                    held_out_result = {"baseline": supplied, "best": score_held_out(texts[best_index])}

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
                "search_remaining": state.search_remaining,
                "iteration_cost": iteration_cost,
                "stopped_before_unfinishable_iteration": state.stopped_before_unfinishable_iteration,
                "reflection_limit_reached": state.reflection_limit_reached,
                "proposer_usage": (
                    f"reflection_calls={state.reflection_calls},prompt_tokens={state.prompt_tokens},"
                    f"completion_tokens={state.completion_tokens},reported_callbacks={state.usage_reported},"
                    f"unavailable_callbacks={state.usage_unavailable},"
                    f"skipped_identical_proposals={state.skipped_identical_proposals},"
                    f"skipped_repeated_proposals={state.skipped_repeated_proposals}"
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
