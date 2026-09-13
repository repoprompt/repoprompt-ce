#!/usr/bin/env python3
"""Versioned NDJSON bridge from RepoPrompt CE to upstream GEPA optimize_anything.

The worker owns no credentials and never calls a provider directly. Reflection and
all evaluations synchronously round-trip to the host application over stdio.
"""

from __future__ import annotations

import contextlib
import importlib.metadata
import json
import os
import pathlib
import signal
import sys
import time
import uuid
from typing import Any

PROTOCOL_VERSION = 1
PROTOCOL_OUT = sys.stdout
EXPECTED_GEPA_VERSION = "0.1.4"
EXPECTED_GEPA_REVISION = "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407"
PROVIDER_RETRY_CODES = frozenset({
    "provider_rate_limited",
    "provider_temporarily_unavailable",
    "provider_transport_interrupted",
    "provider_incomplete_response",
    "provider_empty_response",
    "provider_routing_unavailable",
})
PROVIDER_RETRY_OPERATIONS = frozenset({"reflect", "mcp_model"})
MAX_PROVIDER_RETRIES = 0


class WorkerCancelled(BaseException):
    pass


class InfrastructureFailure(BaseException):
    """Escapes GEPA's candidate-error handling so infrastructure is never score zero."""

    def __init__(self, message, *, failure_code=None, operation=None):
        super().__init__(message)
        self.failure_code = failure_code if failure_code in (
            "judge_invalid_response", "judge_provider_failed",
            "provider_rate_limited", "provider_temporarily_unavailable",
            "provider_transport_interrupted", "provider_incomplete_response",
            "provider_empty_response", "provider_routing_unavailable",
            "provider_rejected", "provider_invalid_response",
            "provider_tool_violation", "provider_unknown",
        ) else None
        self.operation = operation if operation in (
            "reflect", "evaluate", "mcp_begin", "mcp_model", "mcp_grade"
        ) else None


def emit(payload: dict[str, Any]) -> None:
    PROTOCOL_OUT.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    PROTOCOL_OUT.flush()


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

    source_frame: dict[str, Any] = {
        "module": "unavailable",
        "function": "unavailable",
        "line": None,
    }
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
        "protocol_version": PROTOCOL_VERSION,
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
    logical_callback_id = str(uuid.uuid4())
    for attempt in range(MAX_PROVIDER_RETRIES + 1):
        request_id = str(uuid.uuid4())
        emit({
            "protocol_version": PROTOCOL_VERSION,
            "type": "host_request",
            "id": request_id,
            "logical_callback_id": logical_callback_id,
            "attempt": attempt + 1,
            "operation": operation,
            "payload": payload,
        })
        response = receive()
        if response.get("type") != "host_response" or response.get("id") != request_id:
            raise InfrastructureFailure("host response identity mismatch")
        if response.get("ok", False):
            return response
        message = str(response.get("error") or "host operation failed")
        if response.get("failure_kind") == "candidate":
            return {
                "score": response.get("score", 0.0),
                "feedback": message,
                "failure_kind": "candidate",
                "output": response.get("output"),
                "elapsed_seconds": response.get("elapsed_seconds"),
            }
        failure_code = response.get("failure_code")
        can_retry = (
            operation in PROVIDER_RETRY_OPERATIONS
            and failure_code in PROVIDER_RETRY_CODES
            and attempt < MAX_PROVIDER_RETRIES
        )
        if can_retry:
            emit({
                "protocol_version": PROTOCOL_VERSION,
                "type": "provider_retry",
                "logical_callback_id": logical_callback_id,
                "operation": operation,
                "failure_code": failure_code,
                "completed_attempts": attempt + 1,
                "next_attempt": attempt + 2,
                "max_attempts": MAX_PROVIDER_RETRIES + 1,
            })
            continue
        raise InfrastructureFailure(
            message, failure_code=failure_code, operation=operation
        )
    raise InfrastructureFailure("provider retry loop exhausted", operation=operation)


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
        raise InfrastructureFailure(
            f"GEPA version mismatch: expected {EXPECTED_GEPA_VERSION}, found {version}"
        )
    if revision != EXPECTED_GEPA_REVISION:
        raise InfrastructureFailure(
            "GEPA must be installed from the approved pinned git revision; "
            f"expected {EXPECTED_GEPA_REVISION}, found {revision or 'unavailable'}"
        )


def json_safe(value: Any) -> Any:
    try:
        json.dumps(value)
        return value
    except (TypeError, ValueError):
        if isinstance(value, dict):
            return {str(key): json_safe(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [json_safe(item) for item in value]
        return str(value)


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


def surface_feedback(surface: Any) -> str:
    if not isinstance(surface, dict):
        return ""
    candidate_bytes = surface.get("candidate_utf8_bytes")
    rendered_bytes = surface.get("rendered_system_utf8_bytes")
    fixed_bytes = surface.get("fixed_scaffold_utf8_bytes")
    overlap = surface.get("candidate_fixed_scaffold_fourgram_overlap")
    if not all(isinstance(value, (int, float))
               for value in (candidate_bytes, rendered_bytes, fixed_bytes, overlap)):
        return ""
    return (
        "Deterministic prompt surface: "
        f"candidate={int(candidate_bytes)} UTF-8 bytes; "
        f"fixed scaffold={int(fixed_bytes)} bytes; "
        f"rendered system prompt={int(rendered_bytes)} bytes; "
        f"candidate/scaffold four-gram overlap={float(overlap):.3f}. "
        "The fixed scaffold already supplies tool descriptions, JSON schemas, "
        "and the tool-call protocol; do not duplicate it."
    )


def candidate_prompt_surfaces(
    candidate_count: int, evaluations: list[dict[str, Any]]
) -> list[dict[str, Any] | None]:
    surfaces: list[dict[str, Any] | None] = [None] * candidate_count
    invariant_keys = (
        "schema_version",
        "adapter",
        "component",
        "candidate_utf8_bytes",
        "candidate_characters",
        "candidate_words",
        "candidate_lines",
        "fixed_scaffold_utf8_bytes",
        "rendered_system_utf8_bytes",
        "mutable_insertion_count",
        "fixed_scaffold_sha256",
        "rendered_system_sha256",
        "candidate_fixed_scaffold_fourgram_overlap",
    )
    for evaluation in evaluations:
        index = evaluation.get("candidate_index")
        surface = evaluation.get("prompt_surface")
        if not (isinstance(index, int) and 0 <= index < candidate_count
                and isinstance(surface, dict)):
            continue
        invariant_surface = {key: surface.get(key) for key in invariant_keys}
        if surfaces[index] is None:
            surfaces[index] = invariant_surface
        elif surfaces[index] != invariant_surface:
            raise InfrastructureFailure(
                "prompt surface changed across evaluations of one candidate"
            )
    return surfaces


def pareto_frontier_indices(
    scores: list[float | None], surfaces: list[dict[str, Any] | None]
) -> list[int]:
    """Return candidates not dominated on quality (high) and rendered bytes (low)."""
    comparable = []
    for index, (score, surface) in enumerate(zip(scores, surfaces)):
        rendered_bytes = (
            surface.get("rendered_system_utf8_bytes")
            if isinstance(surface, dict) else None
        )
        if isinstance(score, (int, float)) and isinstance(rendered_bytes, int):
            comparable.append((index, float(score), rendered_bytes))
    frontier = []
    for index, score, rendered_bytes in comparable:
        dominated = any(
            other_score >= score
            and other_bytes <= rendered_bytes
            and (other_score > score or other_bytes < rendered_bytes)
            for other_index, other_score, other_bytes in comparable
            if other_index != index
        )
        if not dominated:
            frontier.append(index)
    return frontier


def require_unique_candidate_texts(candidates: list[str]) -> None:
    if len(set(candidates)) != len(candidates):
        raise InfrastructureFailure(
            "GEPA returned duplicate retained candidate text; "
            "evaluation identity would be ambiguous"
        )


def search_evaluation_budget(body: dict[str, Any]) -> tuple[int, int]:
    """Reserve the held-out calls that upstream GEPA runs outside max_evals.

    RepoPrompt's approved max_evaluations is the ceiling for every target
    evaluation, including reporting-only hidden examples. Upstream GEPA's
    max_evals covers search only, then it scores the seed and winner on the
    test set outside that budget. Reserve the worst-case hidden passes here so
    the upstream contract and the sealed host ceiling cannot disagree.
    """
    total = int(body["max_evaluations"])
    hidden_count = sum(
        1 for example in body.get("examples", [])
        if example.get("split") == "hidden_test"
    )
    held_out_reserve = hidden_count * (1 if body.get("seed_candidate") is None else 2)
    search_budget = total - held_out_reserve
    if search_budget < 1:
        raise InfrastructureFailure(
            "evaluation budget cannot cover search and held-out reporting"
        )
    return search_budget, held_out_reserve


def main() -> int:
    global MAX_PROVIDER_RETRIES
    started = time.monotonic()
    try:
        request = receive()
        if request.get("protocol_version") != PROTOCOL_VERSION or request.get("type") != "run":
            raise InfrastructureFailure("unsupported worker protocol")
        verify_gepa()

        from gepa.optimize_anything import OptimizeAnythingConfig, optimize_anything

        body = request.get("request")
        if not isinstance(body, dict):
            raise InfrastructureFailure("run request is missing")
        max_provider_retries = body.get("max_provider_retries", 0)
        if not isinstance(max_provider_retries, int) or not 0 <= max_provider_retries <= 3:
            raise InfrastructureFailure("invalid provider callback retry allowance")
        MAX_PROVIDER_RETRIES = max_provider_retries
        run_dir = pathlib.Path(str(body["run_dir"])).resolve()
        output_dir = pathlib.Path(str(body["output_dir"])).resolve()
        run_dir.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        if body.get("mcp_adapter") is not None:
            # -I omits script directories; this is the signed resource directory, never project scratch.
            sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
            from mcp_evaluation import composition_contract, stop_children
            rendered_composition_contract = composition_contract(body["mcp_adapter"])
            def cancel_adapter(signum, frame):
                stop_children()
                raise WorkerCancelled(signum)
            signal.signal(signal.SIGTERM, cancel_adapter)
            signal.signal(signal.SIGINT, cancel_adapter)
        else:
            rendered_composition_contract = ""
        evaluations: list[dict[str, Any]] = []
        provisional_candidate_indices: dict[str, int] = {}
        usage = {"prompt_tokens": 0, "completion_tokens": 0, "reported": 0, "unavailable": 0}

        def record_usage(response: dict[str, Any]) -> None:
            prompt_tokens = response.get("prompt_tokens")
            completion_tokens = response.get("completion_tokens")
            if isinstance(prompt_tokens, int) or isinstance(completion_tokens, int):
                usage["prompt_tokens"] += prompt_tokens if isinstance(prompt_tokens, int) else 0
                usage["completion_tokens"] += completion_tokens if isinstance(completion_tokens, int) else 0
                usage["reported"] += 1
            else:
                usage["unavailable"] += 1

        class HostLanguageModel:
            def __call__(self, prompt: str | list[dict[str, Any]]) -> str:
                response = host_call("reflect", {"prompt": prompt})
                record_usage(response)
                output = response.get("output")
                if not isinstance(output, str) or not output.strip():
                    raise InfrastructureFailure("reflection host returned no candidate text")
                return output

        def evaluate(candidate: Any, example: Any = None) -> tuple[float, dict[str, Any]]:
            text = candidate_text(candidate)
            if text not in provisional_candidate_indices:
                provisional_candidate_indices[text] = len(provisional_candidate_indices)
            candidate_index = provisional_candidate_indices[text]
            example_value = example if isinstance(example, dict) else {"id": "single", "input": example}
            split = str(example_value.get("split", "training"))
            if body.get("mcp_adapter") is not None:
                from mcp_evaluation import evaluate_mcp
                response = evaluate_mcp(text, example_value, body, host_call, emit, InfrastructureFailure, record_usage)
            else:
                response = host_call("evaluate", {
                    "candidate": text,
                    "candidate_index": candidate_index,
                    "example": example_value,
                    "split": split,
                })
            record_usage(response)
            score_value = response.get("score")
            if score_value is None:
                raise InfrastructureFailure("evaluation host returned no score")
            score = float(score_value)
            feedback = str(response.get("feedback") or "")
            prompt_surface = response.get("prompt_surface")
            deterministic_surface_feedback = surface_feedback(prompt_surface)
            if deterministic_surface_feedback:
                feedback = (
                    f"{feedback.rstrip()}\n\n{deterministic_surface_feedback}"
                    if feedback.strip() else deterministic_surface_feedback
                )
            evaluation = {
                "candidate_index": candidate_index,
                "candidate_text": text,
                "example_id": str(example_value.get("id", "single")),
                "split": split,
                "score": score,
                "feedback": feedback,
                "failure_kind": response.get("failure_kind"),
                "output": response.get("output"),
                "elapsed_seconds": response.get("elapsed_seconds"),
                "prompt_surface": prompt_surface,
            }
            evaluations.append(evaluation)
            emit({
                "protocol_version": PROTOCOL_VERSION,
                "type": "progress",
                "stage": "evaluating",
                "completed_evaluations": len(evaluations),
                "max_evaluations": int(body["max_evaluations"]),
                "candidate_index": candidate_index,
                "score": score,
            })
            return score, {
                "score": score,
                "feedback": feedback,
                "output": response.get("output"),
                "example_id": evaluation["example_id"],
                "task_preservation": body.get("task_preservation", ""),
                "prompt_surface": prompt_surface,
            }

        def examples_for(split: str) -> list[dict[str, Any]]:
            values = []
            for raw in body.get("examples", []):
                if raw.get("split") == split:
                    values.append({
                        "id": str(raw.get("id", "single")),
                        "input": str(raw.get("input", "")),
                        "split": split,
                    })
            return values

        dataset = examples_for("training")
        valset = examples_for("validation")
        test_set = examples_for("hidden_test")
        stage = body.get("stage", "search")
        if stage not in ("search", "preparation"):
            raise InfrastructureFailure("unsupported experiment stage")
        if stage == "preparation":
            # A deterministic host-evaluation batch. The conversational agent, not a
            # second optimizer in Python, authors/revises these approved candidates.
            candidates = body.get("preparation_candidates")
            if (not isinstance(candidates, list) or not 1 <= len(candidates) <= 20
                    or not all(isinstance(c, str) and c.strip() for c in candidates)
                    or len(set(candidates)) != len(candidates) or not dataset
                    or len(candidates) * len(dataset) > int(body["max_evaluations"])):
                raise InfrastructureFailure("invalid preparation candidates or evaluation budget")
            scores = []
            for candidate in candidates:
                values = [evaluate(candidate, example)[0] for example in dataset]
                scores.append(sum(values) / len(values))
            best_index = max(range(len(candidates)), key=lambda i: scores[i])
            for evaluation in evaluations:
                evaluation.pop("candidate_text", None)
            surfaces = candidate_prompt_surfaces(len(candidates), evaluations)
            frontier = (
                pareto_frontier_indices(scores, surfaces)
                if any(surface is not None for surface in surfaces) else None
            )
            payload = {
                "engine": "preparation",
                "upstream_revision": EXPECTED_GEPA_REVISION,
                "baseline_score": scores[0],
                "best_score": scores[best_index],
                "best_candidate_index": best_index,
                "candidates": candidates,
                "parent_indices": [[] for _ in candidates],
                "aggregate_scores": scores,
                "candidate_prompt_surfaces": surfaces,
                "pareto_frontier_indices": frontier,
                "evaluations": evaluations,
                "total_evaluations": len(evaluations),
                "wall_time_seconds": time.monotonic() - started,
                "proposer_usage": f"reflection_calls=0,reported_callbacks={usage['reported']},unavailable_callbacks={usage['unavailable']}",
                "run_directory_relative_path": body.get("run_directory_relative_path"),
                "metadata": {"stage": "preparation", "search_performed": False,
                             "scoring_split": "training", "held_out_evaluated": False,
                             "selection_semantics": "highest_quality_not_automatic_winner",
                             "comparison_dimensions": (
                                 ["quality", "rendered_system_utf8_bytes"]
                                 if frontier is not None else ["quality"]
                             )},
            }
            emit({"protocol_version": PROTOCOL_VERSION, "type": "completed", "result": payload})
            return 0
        if not dataset and valset:
            dataset, valset = valset, []

        search_budget, held_out_reserve = search_evaluation_budget(body)
        config = OptimizeAnythingConfig(
            engine="gepa",
            name=str(body["run_name"]),
            max_evals=search_budget,
            max_token_cost=None,
            max_concurrency=1,
            output_dir=str(output_dir),
            run_dir=str(run_dir),
            stop_at_score=body.get("stop_at_score"),
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
            },
        )
        with contextlib.redirect_stdout(sys.stderr):
            optimization_background = str(body.get("background") or "")
            if rendered_composition_contract:
                optimization_background = (
                    f"{optimization_background.rstrip()}\n\n"
                    f"{rendered_composition_contract}"
                )
            result = optimize_anything(
                seed_candidate=body.get("seed_candidate"),
                evaluator=evaluate,
                dataset=dataset or None,
                valset=valset or None,
                test_set=test_set or None,
                objective=str(body["objective"]),
                background=optimization_background,
                config=config,
            )
        candidates = [candidate_text(value) for value in result.candidates]
        require_unique_candidate_texts(candidates)
        parents = [
            [int(parent) for parent in (values or []) if parent is not None]
            for values in result.parents
        ]
        scores = [float(value) if value is not None else None for value in result.val_aggregate_scores]
        best_index = int(result.best_idx) if result.best_idx is not None else None
        final_indices = {text: index for index, text in enumerate(candidates)}
        for evaluation in evaluations:
            evaluated_text = str(evaluation.pop("candidate_text", ""))
            evaluation["candidate_index"] = final_indices.get(evaluated_text, -1)
        surfaces = candidate_prompt_surfaces(len(candidates), evaluations)
        frontier = (
            pareto_frontier_indices(scores, surfaces)
            if any(surface is not None for surface in surfaces) else None
        )
        proposer_usage = (
            f"prompt_tokens={usage['prompt_tokens']},completion_tokens={usage['completion_tokens']},"
            f"reported_callbacks={usage['reported']},unavailable_callbacks={usage['unavailable']}"
            if usage["reported"]
            else f"unavailable_callbacks={usage['unavailable']}"
        )
        metadata = json_safe(result.metadata)
        if not isinstance(metadata, dict):
            metadata = {}
        metadata.update({
            "approved_total_evaluation_ceiling": int(body["max_evaluations"]),
            "search_evaluation_budget": search_budget,
            "held_out_evaluation_reserve": held_out_reserve,
            "held_out_evaluations_recorded": sum(
                1 for evaluation in evaluations if evaluation["split"] == "hidden_test"
            ),
            "selection_semantics": "highest_quality_not_automatic_winner",
            "comparison_dimensions": (
                ["quality", "rendered_system_utf8_bytes"]
                if frontier is not None else ["quality"]
            ),
        })
        payload = {
            "engine": "gepa",
            "upstream_revision": EXPECTED_GEPA_REVISION,
            "baseline_score": scores[0] if scores else None,
            "best_score": float(result.best_score) if result.best_score is not None else None,
            "best_candidate_index": best_index,
            "candidates": candidates,
            "parent_indices": parents,
            "aggregate_scores": scores,
            "candidate_prompt_surfaces": surfaces,
            "pareto_frontier_indices": frontier,
            "evaluations": evaluations,
            "total_evaluations": len(evaluations),
            "wall_time_seconds": float(result.metadata.get("wall_time", time.monotonic() - started)),
            "proposer_usage": proposer_usage,
            "run_directory_relative_path": body.get("run_directory_relative_path"),
            "upstream_result": json_safe(result.to_dict()),
            "metadata": metadata,
        }
        emit({"protocol_version": PROTOCOL_VERSION, "type": "completed", "result": payload})
        return 0
    except WorkerCancelled as error:
        emit({"protocol_version": PROTOCOL_VERSION, "type": "cancelled", "signal": error.args[0]})
        return 130
    except InfrastructureFailure as error:
        emit_failure(error)
        return 2
    except BaseException as error:
        emit_failure(error)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
