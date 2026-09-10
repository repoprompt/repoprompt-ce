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
import sys
import time
import uuid
from typing import Any

PROTOCOL_VERSION = 1
PROTOCOL_OUT = sys.stdout
EXPECTED_GEPA_VERSION = "0.1.4"
EXPECTED_GEPA_REVISION = "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407"


class InfrastructureFailure(BaseException):
    """Escapes GEPA's candidate-error handling so infrastructure is never score zero."""


def emit(payload: dict[str, Any]) -> None:
    PROTOCOL_OUT.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    PROTOCOL_OUT.flush()


def receive() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise InfrastructureFailure("host transport closed")
    value = json.loads(line)
    if not isinstance(value, dict):
        raise InfrastructureFailure("host response is not an object")
    return value


def host_call(operation: str, payload: dict[str, Any]) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    emit({
        "protocol_version": PROTOCOL_VERSION,
        "type": "host_request",
        "id": request_id,
        "operation": operation,
        "payload": payload,
    })
    response = receive()
    if response.get("type") != "host_response" or response.get("id") != request_id:
        raise InfrastructureFailure("host response identity mismatch")
    if not response.get("ok", False):
        message = str(response.get("error") or "host operation failed")
        if response.get("failure_kind") == "candidate":
            return {
                "score": response.get("score", 0.0),
                "feedback": message,
                "failure_kind": "candidate",
                "output": response.get("output"),
                "elapsed_seconds": response.get("elapsed_seconds"),
            }
        raise InfrastructureFailure(message)
    return response


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


def main() -> int:
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
        run_dir = pathlib.Path(str(body["run_dir"])).resolve()
        output_dir = pathlib.Path(str(body["output_dir"])).resolve()
        run_dir.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
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
        if not dataset and valset:
            dataset, valset = valset, []

        config = OptimizeAnythingConfig(
            engine="gepa",
            name=str(body["run_name"]),
            max_evals=int(body["max_evaluations"]),
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
            result = optimize_anything(
                seed_candidate=body.get("seed_candidate"),
                evaluator=evaluate,
                dataset=dataset or None,
                valset=valset or None,
                test_set=test_set or None,
                objective=str(body["objective"]),
                background=str(body.get("background") or ""),
                config=config,
            )
        candidates = [candidate_text(value) for value in result.candidates]
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
        proposer_usage = (
            f"prompt_tokens={usage['prompt_tokens']},completion_tokens={usage['completion_tokens']},"
            f"reported_callbacks={usage['reported']},unavailable_callbacks={usage['unavailable']}"
            if usage["reported"]
            else f"unavailable_callbacks={usage['unavailable']}"
        )
        payload = {
            "engine": "gepa",
            "upstream_revision": EXPECTED_GEPA_REVISION,
            "baseline_score": scores[0] if scores else None,
            "best_score": float(result.best_score) if result.best_score is not None else None,
            "best_candidate_index": best_index,
            "candidates": candidates,
            "parent_indices": parents,
            "aggregate_scores": scores,
            "evaluations": evaluations,
            "total_evaluations": int(result.eval_server_calls or len(evaluations)),
            "wall_time_seconds": float(result.metadata.get("wall_time", time.monotonic() - started)),
            "proposer_usage": proposer_usage,
            "run_directory_relative_path": body.get("run_directory_relative_path"),
            "upstream_result": json_safe(result.to_dict()),
            "metadata": json_safe(result.metadata),
        }
        emit({"protocol_version": PROTOCOL_VERSION, "type": "completed", "result": payload})
        return 0
    except InfrastructureFailure as error:
        emit({
            "protocol_version": PROTOCOL_VERSION,
            "type": "failed",
            "failure_kind": "infrastructure",
            "error": str(error),
        })
        return 2
    except BaseException as error:
        emit({
            "protocol_version": PROTOCOL_VERSION,
            "type": "failed",
            "failure_kind": "infrastructure",
            "error": f"{type(error).__name__}: {error}",
        })
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
