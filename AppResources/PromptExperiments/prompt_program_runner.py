#!/usr/bin/env python3
"""Project Python/DSPy evaluation bridge for the same GEPA experiment lifecycle.

Run with the project's explicitly selected interpreter. This runner installs nothing.
Generic modules expose evaluate(candidate, example, context) -> a scored mapping.
DSPy modules expose build_program(context), metric(example, prediction, trace=None),
and optionally make_inputs(example). DSPy is pinned to 3.4.1's public engine API.

context.complete(messages, role="execution", settings={}) delegates model calls to
RPCE over NDJSON; execution usage is summed independently from judge usage. Modules
may instead own their evaluator/model client and return measured usage themselves.
SEED_PROMPT, EXAMPLES, CRITERIA and OBJECTIVE provide optional import metadata.
DSPy modules may set MODEL_ROUTING = "project" to preserve their configured model
clients, demonstrations and settings; their metric must report measured execution
tokens explicitly. The default "connected" mode uses RPCE's selected model profile.
--describe/--preflight/--validate/--export never allow context.complete calls.

This executes selected project code, not an OS sandbox. RPCE owns approval, process
timeout/cancellation, provider access and final source/artifact application.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import importlib.metadata
import importlib.util
import inspect
import json
import math
import os
from pathlib import Path
import sys
import threading
import uuid
from typing import Any

PROTOCOL_VERSION = 1
DSPY_VERSION = "3.4.1"
PROTOCOL_OUT = sys.stdout


class ProgramFailure(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class CandidateRejected(ProgramFailure):
    """A generated candidate's format is feedback, not an infrastructure outage."""

    def __init__(self, code: str, feedback: str) -> None:
        super().__init__(code)
        self.feedback = feedback


def emit(value: dict[str, Any]) -> None:
    PROTOCOL_OUT.write(json.dumps({"protocol_version": PROTOCOL_VERSION, **value}, allow_nan=False) + "\n")
    PROTOCOL_OUT.flush()


def receive() -> dict[str, Any]:
    raw = sys.stdin.readline()
    if not raw:
        raise ProgramFailure("host_transport_closed")
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("protocol_version", PROTOCOL_VERSION) != PROTOCOL_VERSION:
        raise ProgramFailure("invalid_protocol_message")
    return value


def token_count(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def finite_number(value: Any) -> float:
    if isinstance(value, bool):
        return float(value)
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ProgramFailure("metric_score_must_be_finite")
    return float(value)


def resolve(value: Any) -> Any:
    if not inspect.isawaitable(value):
        return value
    async def finish() -> Any:
        return await value
    return asyncio.run(finish())


class Context:
    def __init__(self, *, allow_calls: bool, settings: dict[str, Any] | None = None) -> None:
        self.allow_calls = allow_calls
        self.settings = settings or {}
        self.calls: list[dict[str, Any]] = []
        # DSPy programs may run independent predictors in threads. The stdio transport
        # permits one in-flight request; serialization keeps responses correctly paired.
        self.lock = threading.Lock()

    def complete(self, messages: list[dict[str, Any]], *, role: str = "execution", settings: dict[str, Any] | None = None) -> dict[str, Any]:
        if not self.allow_calls:
            raise ProgramFailure("model_calls_disabled_for_inspection")
        if role not in ("execution", "judge"):
            raise ProgramFailure("unsupported_model_role")
        if not isinstance(messages, list) or not messages or any(
            not isinstance(message, dict) or message.get("role") not in ("system", "developer", "user", "assistant")
            or not isinstance(message.get("content"), str) for message in messages
        ):
            raise ProgramFailure("completion_requires_text_messages")
        if settings is not None and not isinstance(settings, dict):
            raise ProgramFailure("invalid_completion_settings")
        with self.lock:
            identity = str(uuid.uuid4())
            emit({"type": "host_request", "id": identity, "operation": "complete", "payload": {
                "role": role, "messages": messages, "settings": {**self.settings, **(settings or {})},
            }})
            response = receive()
            if response.get("type") != "host_response" or response.get("id") != identity:
                raise ProgramFailure("host_response_identity_mismatch")
            if response.get("status") != "ok":
                raise ProgramFailure("host_completion_failed")
            if not isinstance(response.get("output"), str):
                raise ProgramFailure("host_completion_missing_output")
            result = {
                "output": response["output"],
                "prompt_tokens": token_count(response.get("prompt_tokens")),
                "completion_tokens": token_count(response.get("completion_tokens")),
            }
            for field in ("settings_policy", "applied_settings"):
                if field in response:
                    result[field] = response[field]
            self.calls.append({"role": role, **result})
            return result

    def execution_usage(self, field: str) -> int | None:
        calls = [call for call in self.calls if call["role"] == "execution"]
        counts = [token_count(call.get(field)) for call in calls]
        return sum(counts) if counts and all(value is not None for value in counts) else None

    async def acomplete(self, messages: list[dict[str, Any]], *, role: str = "execution", settings: dict[str, Any] | None = None) -> dict[str, Any]:
        return await asyncio.to_thread(self.complete, messages, role=role, settings=settings)


def load_module(project_root: Path, module_path: str) -> Any:
    root = project_root.resolve(strict=True)
    if not root.is_dir():
        raise ProgramFailure("project_root_must_be_directory")
    os.chdir(root)
    path = Path(module_path)
    path = (root / path).resolve(strict=True) if not path.is_absolute() else path.resolve(strict=True)
    if not path.is_relative_to(root) or not path.is_file() or path.suffix != ".py":
        raise ProgramFailure("module_must_be_python_file_inside_project")
    # Support normal sibling/package imports while avoiding the caller's working directory.
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(path.parent))
    relative_parts = path.relative_to(root).with_suffix("").parts
    name = ".".join(relative_parts) if all(part.isidentifier() for part in relative_parts) else "rpce_experiment_project"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ProgramFailure("module_not_loadable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def require_dspy() -> Any:
    try:
        version = importlib.metadata.version("dspy")
    except importlib.metadata.PackageNotFoundError as error:
        raise ProgramFailure("dspy_missing_requires_3_4_1") from error
    if version != DSPY_VERSION:
        raise ProgramFailure("dspy_version_mismatch_requires_3_4_1")
    import dspy
    return dspy


def require_callable(module: Any, name: str) -> Any:
    value = getattr(module, name, None)
    if not callable(value):
        raise ProgramFailure("required_project_callable_missing")
    return value


def model_routing(module: Any) -> str:
    routing = getattr(module, "MODEL_ROUTING", "connected")
    if routing not in ("connected", "project"):
        raise ProgramFailure("model_routing_must_be_connected_or_project")
    return routing


def build_program(module: Any, context: Context) -> tuple[Any, Any]:
    dspy = require_dspy()
    program = resolve(require_callable(module, "build_program")(context))
    if not isinstance(program, dspy.Module) or not program.named_predictors():
        raise ProgramFailure("build_program_requires_dspy_module_with_predictors")
    require_callable(module, "metric")
    return dspy, program


def instructions(program: Any) -> dict[str, str]:
    return {name: predictor.signature.instructions for name, predictor in program.named_predictors()}


def apply_instructions(program: Any, candidate: str) -> None:
    predictors = dict(program.named_predictors())
    try:
        components = json.loads(candidate)
    except (ValueError, TypeError):
        components = None
    if not isinstance(components, dict):
        if len(predictors) != 1:
            raise CandidateRejected("dspy_candidate_requires_named_instructions_json",
                                    "Return a JSON object mapping every DSPy predictor name to its complete instructions: " + ", ".join(predictors))
        components = {next(iter(predictors)): candidate}
    if set(components) != set(predictors) or any(not isinstance(text, str) or not text.strip() for text in components.values()):
        raise CandidateRejected("dspy_candidate_predictor_names_must_match",
                                "The candidate must contain exactly these predictor names, each with nonempty string instructions: " + ", ".join(predictors))
    for name, text in components.items():
        predictors[name].signature = predictors[name].signature.with_instructions(text)


def program_artifact(program: Any, *, routing: str = "connected") -> dict[str, Any]:
    # Export normal DSPy JSON state without the ephemeral host connection or credentials.
    old_lms = [(predictor, predictor.lm) for _, predictor in program.named_predictors()]
    try:
        program.set_lm(None)
        state = program.dump_state(json_mode=True)
    finally:
        for predictor, lm in old_lms:
            predictor.lm = lm
    return {"format": "dspy_state", "dspy_version": DSPY_VERSION, "model_routing": routing,
            "predictors": instructions(program), "state": state}


def host_language_model(dspy: Any, context: Context, *, role: str = "execution") -> Any:
    from dspy.lm15 import Message, Response, TextPart, Usage, response_to_events

    class HostEngine:
        def complete(self, request: Any) -> Any:
            if request.tools:
                raise ProgramFailure("native_model_tools_require_a_project_tool_adapter")
            messages: list[dict[str, str]] = []
            if request.system is not None:
                parts = request.system
                if not isinstance(parts, str):
                    if any(not isinstance(part, TextPart) for part in parts):
                        raise ProgramFailure("nontext_dspy_input_not_supported")
                    parts = "".join(part.text for part in parts)
                messages.append({"role": "system", "content": parts})
            for message in request.messages:
                if any(not isinstance(part, TextPart) for part in message.parts):
                    raise ProgramFailure("nontext_dspy_input_not_supported")
                messages.append({"role": message.role, "content": message.text or ""})
            settings = {key: value for key, value in dataclasses.asdict(request.config).items()
                        if value is not None and value != () and value != {}}
            result = context.complete(messages, role=role, settings=settings)
            return Response(
                id=None, model=f"rpce/{role}", message=Message.assistant(result["output"]), finish_reason="stop",
                usage=Usage(input_tokens=result["prompt_tokens"], output_tokens=result["completion_tokens"]),
            )

        def stream(self, request: Any) -> Any:
            return response_to_events(self.complete(request))

        def close(self) -> None:
            pass

    # Host owns retries/admissions. Disable DSPy's cache so candidate usage corresponds
    # to the actual program execution; durable replay belongs to the experiment ledger.
    return dspy.LM(f"rpce/{role}", engine=HostEngine(), cache=False, num_retries=0)


def normalize_result(value: Any, context: Context, *, output: str | None = None, external_execution: bool = False) -> dict[str, Any]:
    if isinstance(value, tuple) and len(value) == 2:
        value = {"score": value[0], "feedback": value[1]}
    elif isinstance(value, (int, float, bool)):
        value = {"score": value}
    elif not isinstance(value, dict) and hasattr(value, "score"):
        value = {"score": value.score, "feedback": getattr(value, "feedback", "")}
    if not isinstance(value, dict):
        raise ProgramFailure("evaluator_requires_scored_result")
    result = {
        "score": finite_number(value.get("score")), "feedback": str(value.get("feedback", "")),
        "output": str(value.get("output", output or "")),
    }
    bridge_execution = any(call["role"] == "execution" for call in context.calls)
    for field in ("prompt_tokens", "completion_tokens"):
        # A module cannot accidentally undercount a multi-stage bridge execution by
        # returning only its last call's usage. Explicit usage serves external clients.
        # Project-routed DSPy can mix its own clients with explicit bridge calls. Only
        # the evaluator knows the complete execution total; never claim the visible
        # bridge subset is the whole program's cost.
        result[field] = (context.execution_usage(field) if bridge_execution and not external_execution
                         else token_count(value.get(field)))
    if "artifact" in value:
        result["artifact"] = value["artifact"]
    if value.get("candidate_valid") is False:
        result["candidate_valid"] = False
    return result


def evaluate_dspy(module: Any, candidate: str, example: dict[str, Any], context: Context) -> dict[str, Any]:
    dspy, program = build_program(module, context)
    apply_instructions(program, candidate)
    routing = model_routing(module)
    execution_context: dict[str, Any] = {}
    judge_context: dict[str, Any] = {}
    if routing == "connected":
        lm = host_language_model(dspy, context)
        program.set_lm(lm)
        execution_context["lm"] = lm
        judge_context["lm"] = host_language_model(dspy, context, role="judge")
    if callable(getattr(module, "make_inputs", None)):
        inputs = resolve(module.make_inputs(example))
    elif isinstance(example.get("inputs"), dict):
        inputs = example["inputs"]
    else:
        names = [name for name, parameter in inspect.signature(program.forward).parameters.items()
                 if parameter.kind in (parameter.POSITIONAL_OR_KEYWORD, parameter.KEYWORD_ONLY)]
        if not names and len(program.named_predictors()) == 1:
            names = list(program.named_predictors()[0][1].signature.input_fields)
        inputs = {name: example[name] for name in names if name in example}
        if not inputs and len(names) == 1 and isinstance(example.get("input"), str):
            inputs = {names[0]: example["input"]}
    if not isinstance(inputs, dict):
        raise ProgramFailure("dspy_inputs_must_be_mapping")
    trace: list[Any] = []
    with dspy.context(trace=trace, **execution_context):
        prediction = program(**inputs)
    metric = module.metric
    parameters = inspect.signature(metric).parameters
    kwargs = {}
    if "trace" in parameters:
        kwargs["trace"] = trace
    if "context" in parameters:
        kwargs["context"] = context
    with dspy.context(trace=[], **judge_context):
        measured = resolve(metric(dspy.Example(**example), prediction, **kwargs))
    output = json.dumps(prediction.toDict(), ensure_ascii=False, default=str)
    result = normalize_result(measured, context, output=output, external_execution=routing == "project")
    result["artifact"] = program_artifact(program, routing=routing)
    return result


def validate_python_candidate(module: Any, candidate: str, context: Context) -> None:
    validator = getattr(module, "validate_candidate", None)
    if validator is None:
        return
    if not callable(validator):
        raise ProgramFailure("validate_candidate_must_be_callable")
    kwargs = {"context": context} if "context" in inspect.signature(validator).parameters else {}
    result = resolve(validator(candidate, **kwargs))
    if result is None or result is True:
        return
    if result is False:
        raise CandidateRejected("project_candidate_rejected", "The project's validate_candidate rejected this candidate.")
    if isinstance(result, dict) and isinstance(result.get("valid"), bool):
        if not result["valid"]:
            raise CandidateRejected("project_candidate_rejected", str(result.get("feedback", "The candidate is invalid for this project.")))
        return
    raise ProgramFailure("validate_candidate_requires_bool_or_valid_mapping")


def describe(module: Any, adapter: str, callable_name: str, context: Context, *, candidate: str | None = None) -> dict[str, Any]:
    value = {"adapter": adapter, "python_version": list(sys.version_info[:3]), "model_routing": model_routing(module)}
    for attribute, key in (("SEED_PROMPT", "seed_candidate"), ("EXAMPLES", "examples"), ("CRITERIA", "criteria"), ("OBJECTIVE", "objective")):
        if hasattr(module, attribute):
            value[key] = getattr(module, attribute)
    if isinstance(value.get("examples"), list):
        value["examples"] = [example.toDict() if callable(getattr(example, "toDict", None)) else example for example in value["examples"]]
    if adapter == "dspy":
        _, program = build_program(module, context)
        value["predictors"] = instructions(program)
        value["seed_candidate"] = json.dumps(value["predictors"], ensure_ascii=False, sort_keys=True)
        value["dspy_version"] = DSPY_VERSION
        if candidate is not None:
            apply_instructions(program, candidate)
    else:
        require_callable(module, callable_name)
        if candidate is not None:
            validate_python_candidate(module, candidate, context)
    if candidate is not None:
        value["candidate_valid"] = True
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--callable", default="evaluate")
    parser.add_argument("--adapter", choices=("python", "dspy"), default="python")
    operations = parser.add_mutually_exclusive_group()
    operations.add_argument("--preflight", action="store_true")
    operations.add_argument("--describe", action="store_true")
    operations.add_argument("--validate", action="store_true")
    operations.add_argument("--export", action="store_true")
    args = parser.parse_args()
    try:
        # RPCE cancels the entire isolated process group, including evaluator children.
        # Do not join or terminate the app's process group.
        if os.name == "posix" and os.getpgrp() != os.getpid():
            os.setsid()
        sys.dont_write_bytecode = True
        # Preserve a dedicated protocol descriptor. Even subprocesses and native modules
        # that print directly to fd 1 now go to stderr instead of corrupting NDJSON.
        global PROTOCOL_OUT
        PROTOCOL_OUT = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8")
        os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
        sys.stdout = sys.stderr
        if args.adapter == "dspy":
            require_dspy()
        module = load_module(args.project_root, args.module)
        if args.preflight or args.describe:
            value = describe(module, args.adapter, args.callable, Context(allow_calls=False))
            emit({"type": "ready" if args.preflight else "description", **value})
            return 0
        request = receive()
        operation = "export" if args.export else "validate" if args.validate else "evaluate"
        if request.get("type") != operation or not isinstance(request.get("candidate"), str):
            raise ProgramFailure("invalid_program_request")
        context = Context(allow_calls=not (args.export or args.validate), settings=request.get("settings"))
        if args.validate:
            value = describe(module, args.adapter, args.callable, context, candidate=request["candidate"])
            emit({"type": "ready", **value})
        elif args.export:
            if args.adapter != "dspy":
                raise ProgramFailure("program_export_requires_dspy_adapter")
            _, program = build_program(module, context)
            apply_instructions(program, request["candidate"])
            routing = model_routing(module)
            emit({"type": "exported", "model_routing": routing, "artifact": program_artifact(program, routing=routing)})
        else:
            example = request.get("example")
            if not isinstance(example, dict):
                raise ProgramFailure("program_example_must_be_object")
            example = dict(example)
            if "expected_output" not in example and "expectedOutput" in example:
                example["expected_output"] = example["expectedOutput"]
            if args.adapter == "dspy":
                result = evaluate_dspy(module, request["candidate"], example, context)
            else:
                validate_python_candidate(module, request["candidate"], Context(allow_calls=False))
                result = normalize_result(resolve(require_callable(module, args.callable)(request["candidate"], example, context)),
                                          context, external_execution=model_routing(module) == "project")
            emit({"type": "result", **result})
        return 0
    except Exception as error:
        if isinstance(error, CandidateRejected) and not (args.export or args.describe or args.preflight or args.validate):
            emit({"type": "result", "score": 0.0, "feedback": error.feedback, "output": "",
                  "candidate_valid": False, "prompt_tokens": None, "completion_tokens": None})
            return 0
        # Do not serialize exception messages: external clients can include secrets or
        # complete requests. The selected module's normal stderr remains available.
        emit({"type": "failed", "failure_code": error.code if isinstance(error, ProgramFailure) else "project_program_failed",
              "exception_type": type(error).__name__})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
