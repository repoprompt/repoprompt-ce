#!/usr/bin/env python3
"""Project-runner contract tests; DSPy cases execute real pinned DSPy predictors.

Run with a project interpreter containing dspy==3.4.1 for all tests. Set
REPOPROMPT_TEST_GEPA_PYTHON to the approved pinned-GEPA interpreter to also exercise
the actual GEPA -> project DSPy -> host completion -> measured objective pipeline.
All completions are deterministic callbacks; no network/model credentials are used.
"""

from __future__ import annotations

import importlib.metadata
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import unittest
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "AppResources" / "PromptExperiments" / "prompt_program_runner.py"
WORKER = RUNNER.with_name("gepa_worker.py")
try:
    DSPY_AVAILABLE = importlib.metadata.version("dspy") == "3.4.1"
except importlib.metadata.PackageNotFoundError:
    DSPY_AVAILABLE = False

PYTHON_MODULE = '''
import os
print("project print stays on stderr")
os.write(1, b"native print stays on stderr\\n")
SEED_PROMPT = "Answer the question."
EXAMPLES = [{"id": "one", "input": "hello", "expected_output": "OK"}]
CRITERIA = "Return the complete correct answer."
OBJECTIVE = "Preserve correctness and reduce input/output tokens."
def evaluate(candidate, example, context):
    first = context.complete([{"role": "system", "content": candidate}, {"role": "user", "content": example["input"]}])
    second = context.complete([{"role": "user", "content": first["output"]}], settings={"max_tokens": 50})
    context.complete([{"role": "user", "content": second["output"]}], role="judge")
    return {"score": 1.0, "feedback": "correct", "output": second["output"], "prompt_tokens": 1}
'''

DSPY_MODULE = '''
import dspy
EXAMPLES = [{"id": "one", "input": "Explain the result", "expected_output": "OK"}]
CRITERIA = "The final answer must be OK."
OBJECTIVE = "Preserve quality while using fewer tokens."
class Program(dspy.Module):
    def __init__(self):
        super().__init__()
        self.first = dspy.Predict("question -> notes")
        self.second = dspy.Predict("notes -> answer")
    def forward(self, question):
        notes = self.first(question=question).notes
        return self.second(notes=notes)
def build_program(context):
    return Program()
def metric(example, prediction, trace=None, context=None):
    return {"score": float(prediction.answer == example.expected_output), "feedback": f"trace_steps={len(trace or [])}"}
'''

PROJECT_DSPY_MODULE = DSPY_MODULE + '''
import json
from dspy.lm15 import Message, Response, Usage, response_to_events
MODEL_ROUTING = "project"
CALLS = []
class ProjectEngine:
    def __init__(self, temperature, maximum, field):
        self.temperature = temperature
        self.maximum = maximum
        self.field = field
    def complete(self, request):
        assert request.config.temperature == self.temperature, "project temperature was replaced"
        assert request.config.max_tokens == self.maximum, "project output cap was replaced"
        assert [message.role for message in request.messages] == ["user", "assistant", "user"], "demonstrations were lost"
        assert "DEMO_" in request.messages[0].text, "demonstration content changed"
        CALLS.append({"field": self.field, "temperature": request.config.temperature, "max_tokens": request.config.max_tokens})
        return Response(id=None, model="project/model", message=Message.assistant(
            f"[[ ## {self.field} ## ]]\\nOK\\n\\n[[ ## completed ## ]]"), finish_reason="stop",
            usage=Usage(input_tokens=80, output_tokens=20))
    def stream(self, request):
        return response_to_events(self.complete(request))
    def close(self):
        pass
def build_program(context):
    program = Program()
    program.first.lm = dspy.LM("project/first", engine=ProjectEngine(.23, 77, "notes"),
                             temperature=.23, max_tokens=77, cache=False, num_retries=0)
    dspy.configure(lm=dspy.LM("project/global", engine=ProjectEngine(.61, 88, "answer"),
                            temperature=.61, max_tokens=88, cache=False, num_retries=0))
    program.first.demos = [dspy.Example(question="DEMO_QUESTION", notes="DEMO_NOTES").with_inputs("question")]
    program.second.demos = [dspy.Example(notes="DEMO_NOTES", answer="DEMO_ANSWER").with_inputs("notes")]
    return program
def metric(example, prediction, trace=None, context=None):
    return {"score": float(prediction.answer == example.expected_output), "feedback": json.dumps(CALLS),
            "prompt_tokens": 160, "completion_tokens": 40}
'''


class RunnerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="RPCE Project With Spaces ")
        self.root = Path(self.temporary.name)
        self.module = self.root / "experiment.py"
        self.module.write_text(PYTHON_MODULE, encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def launch(self, request: dict[str, Any] | None = None, *, adapter: str = "python", operation: str | None = None, complete=None):
        command = [sys.executable, "-I", "-B", str(RUNNER), "--project-root", str(self.root), "--module", str(self.module.relative_to(self.root)),
                   "--adapter", adapter]
        if operation:
            command.append("--" + operation)
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1, cwd=self.root)
        messages = []
        terminal = None
        assert process.stdin is not None and process.stdout is not None
        try:
            if request is not None:
                process.stdin.write(json.dumps({"protocol_version": 1, **request}) + "\n")
                process.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if not selector.select(timeout=max(0.1, deadline - time.monotonic())):
                        self.fail("program runner timed out")
                    line = process.stdout.readline()
                    if not line:
                        break
                    message = json.loads(line)
                    messages.append(message)
                    self.assertEqual(message["protocol_version"], 1)
                    if message["type"] == "host_request":
                        self.assertIsNotNone(complete, "inspection/export must never request a model")
                        result = complete(message["payload"])
                        process.stdin.write(json.dumps({"protocol_version": 1, "type": "host_response", "id": message["id"],
                                                        "status": "ok", **result}) + "\n")
                        process.stdin.flush()
                    else:
                        terminal = message
                        break
            process.stdin.close()
            code = process.wait(timeout=10)
            stderr = process.stderr.read() if process.stderr else ""
            self.assertIsNotNone(terminal, stderr)
            return terminal, messages, code, stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()


class ProgramRunnerTests(RunnerTestCase):
    def test_nested_project_module_can_use_relative_imports_without_writing_bytecode(self) -> None:
        package = self.root / "package"
        package.mkdir()
        (package / "__init__.py").write_text("")
        (package / "shared.py").write_text("SEED_PROMPT = 'project seed'\n")
        self.module = package / "experiment.py"
        self.module.write_text("from .shared import SEED_PROMPT\ndef evaluate(candidate, example, context):\n    return {'score': 1}\n")
        result, _, code, stderr = self.launch(operation="describe")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["seed_candidate"], "project seed")
        self.assertFalse(any(self.root.rglob("*.pyc")))

    def test_packaged_python_example_is_importable_and_evaluates_with_host_model(self) -> None:
        self.module.write_bytes((RUNNER.parent / "examples" / "support_router.py").read_bytes())
        description, _, code, stderr = self.launch(operation="describe")
        self.assertEqual(code, 0, (description, stderr))
        self.assertEqual({example["split"] for example in description["examples"]}, {"training", "validation", "hidden_test"})
        result, _, code, stderr = self.launch(
            {"type": "evaluate", "candidate": description["seed_candidate"], "example": description["examples"][0]},
            complete=lambda payload: {"output": "billing", "prompt_tokens": 100, "completion_tokens": 1},
        )
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["score"], 1)

    def test_description_imports_existing_module_metadata_without_model_calls(self) -> None:
        result, messages, code, stderr = self.launch(operation="describe")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["seed_candidate"], "Answer the question.")
        self.assertEqual(result["examples"][0]["input"], "hello")
        self.assertEqual(len(messages), 1)
        self.assertIn("project print stays on stderr", stderr)
        self.assertIn("native print stays on stderr", stderr)

    def test_python_multistage_usage_sums_execution_and_excludes_judge(self) -> None:
        calls = []
        def complete(payload):
            calls.append(payload)
            return {"output": "OK", "prompt_tokens": 100 if payload["role"] == "judge" else 40, "completion_tokens": 10}
        result, _, code, stderr = self.launch({"type": "evaluate", "candidate": "seed", "example": {"input": "question"}}, complete=complete)
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["score"], 1)
        self.assertEqual(result["prompt_tokens"], 80)
        self.assertEqual(result["completion_tokens"], 20)
        self.assertEqual([call["role"] for call in calls], ["execution", "execution", "judge"])
        self.assertEqual(calls[1]["settings"]["max_tokens"], 50)

    def test_one_missing_stage_usage_keeps_dimension_unknown(self) -> None:
        calls = []
        def complete(payload):
            calls.append(payload)
            return {"output": "OK", "prompt_tokens": None if len(calls) == 1 else 40, "completion_tokens": 10}
        result, _, code, stderr = self.launch({"type": "evaluate", "candidate": "seed", "example": {"input": "question"}}, complete=complete)
        self.assertEqual(code, 0, (result, stderr))
        self.assertIsNone(result["prompt_tokens"])
        self.assertEqual(result["completion_tokens"], 20)

    def test_external_client_can_report_its_own_measured_usage(self) -> None:
        self.module.write_text("def evaluate(candidate, example, context):\n    return {'score': .9, 'output': 'answer', 'prompt_tokens': 80, 'completion_tokens': 20}\n")
        result, _, code, stderr = self.launch({"type": "evaluate", "candidate": "seed", "example": {}})
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["prompt_tokens"], 80)

    def test_build_preflight_rejects_missing_callable(self) -> None:
        self.module.write_text("SEED_PROMPT = 'seed'\n")
        result, _, code, _ = self.launch(operation="preflight")
        self.assertEqual(code, 2)
        self.assertEqual(result["failure_code"], "required_project_callable_missing")

    def test_python_candidate_validation_is_optional_and_model_free(self) -> None:
        self.module.write_text('''
def evaluate(candidate, example, context):
    raise AssertionError("validation must not evaluate the program")
def validate_candidate(candidate, context):
    assert context.allow_calls is False
    return {"valid": candidate.startswith("valid:"), "feedback": "Use the required valid: prefix."}
''')
        ready, messages, code, stderr = self.launch({"type": "validate", "candidate": "valid: seed"}, operation="validate")
        self.assertEqual(code, 0, (ready, stderr))
        self.assertEqual(ready["type"], "ready")
        self.assertTrue(ready["candidate_valid"])
        self.assertEqual(len(messages), 1)
        failed, _, code, _ = self.launch({"type": "validate", "candidate": "wrong"}, operation="validate")
        self.assertEqual(code, 2)
        self.assertEqual(failed["failure_code"], "project_candidate_rejected")
        result, _, code, _ = self.launch({"type": "evaluate", "candidate": "wrong", "example": {}})
        self.assertEqual(code, 0)
        self.assertFalse(result["candidate_valid"])
        self.assertEqual(result["feedback"], "Use the required valid: prefix.")

    def test_validation_without_project_hook_only_checks_readiness(self) -> None:
        ready, messages, code, stderr = self.launch({"type": "validate", "candidate": "seed"}, operation="validate")
        self.assertEqual(code, 0, (ready, stderr))
        self.assertEqual(ready["model_routing"], "connected")
        self.assertTrue(ready["candidate_valid"])
        self.assertEqual(len(messages), 1)

    def test_unknown_model_routing_cannot_be_silently_accepted(self) -> None:
        self.module.write_text(PYTHON_MODULE + '\nMODEL_ROUTING = "typo"\n')
        failed, _, code, _ = self.launch(operation="describe")
        self.assertEqual(code, 2)
        self.assertEqual(failed["failure_code"], "model_routing_must_be_connected_or_project")

    def test_exception_message_cannot_leak_into_protocol(self) -> None:
        self.module.write_text("def evaluate(candidate, example, context):\n    raise ValueError('secret request body')\n")
        result, messages, code, stderr = self.launch({"type": "evaluate", "candidate": "seed", "example": {}})
        self.assertEqual(code, 2)
        self.assertEqual(result["exception_type"], "ValueError")
        self.assertNotIn("secret request body", json.dumps(messages) + stderr)

    def test_async_project_evaluator_uses_async_host_callbacks(self) -> None:
        self.module.write_text('''
import asyncio
async def evaluate(candidate, example, context):
    calls = await asyncio.gather(*(context.acomplete([{"role": "user", "content": candidate}]) for _ in range(2)))
    return {"score": 1.0, "output": calls[-1]["output"]}
''')
        result, _, code, stderr = self.launch(
            {"type": "evaluate", "candidate": "seed", "example": {}},
            complete=lambda payload: {"output": "OK", "prompt_tokens": 40, "completion_tokens": 10},
        )
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["prompt_tokens"], 80)
        self.assertEqual(result["completion_tokens"], 20)


@unittest.skipUnless(DSPY_AVAILABLE, "requires explicitly installed dspy==3.4.1")
class DSPyProgramRunnerTests(RunnerTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.module.write_text(DSPY_MODULE, encoding="utf-8")

    def complete_program(self, payload):
        self.assertEqual(payload["role"], "execution")
        self.assertEqual(payload["settings"], {}, "the native connected-model profile cannot silently drop sampling settings")
        self.assertEqual([message["role"] for message in payload["messages"]], ["system", "user"])
        system = "\n".join(message["content"] for message in payload["messages"] if message["role"] == "system")
        output = "notes" if "FIRST_INSTRUCTIONS" in system else "answer"
        return {"output": f"[[ ## {output} ## ]]\nOK\n\n[[ ## completed ## ]]",
                "prompt_tokens": 40, "completion_tokens": 10}

    def test_real_dspy_describes_named_predictors_without_calling_model(self) -> None:
        result, _, code, stderr = self.launch(adapter="dspy", operation="describe")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(set(json.loads(result["seed_candidate"])), {"first", "second"})
        self.assertEqual(result["dspy_version"], "3.4.1")
        self.assertEqual(result["model_routing"], "connected")

    def test_real_dspy_validates_named_candidate_before_any_evaluation(self) -> None:
        candidate = json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"})
        result, messages, code, stderr = self.launch({"type": "validate", "candidate": candidate}, adapter="dspy", operation="validate")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["type"], "ready")
        self.assertTrue(result["candidate_valid"])
        self.assertEqual(len(messages), 1)
        failed, messages, code, _ = self.launch({"type": "validate", "candidate": '{"wrong":"instructions"}'},
                                              adapter="dspy", operation="validate")
        self.assertEqual(code, 2)
        self.assertEqual(failed["failure_code"], "dspy_candidate_predictor_names_must_match")
        self.assertEqual(len(messages), 1)

    def test_project_routing_preserves_real_dspy_clients_demonstrations_and_settings(self) -> None:
        self.module.write_text(PROJECT_DSPY_MODULE)
        candidate = json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"})
        description, _, code, stderr = self.launch(adapter="dspy", operation="describe")
        self.assertEqual(code, 0, (description, stderr))
        self.assertEqual(description["model_routing"], "project")
        ready, messages, code, stderr = self.launch({"type": "validate", "candidate": candidate}, adapter="dspy", operation="validate")
        self.assertEqual(code, 0, (ready, stderr))
        self.assertTrue(ready["candidate_valid"])
        self.assertEqual(ready["model_routing"], "project")
        self.assertEqual(len(messages), 1)
        result, messages, code, stderr = self.launch({"type": "evaluate", "candidate": candidate,
            "example": {"input": "question", "expected_output": "OK"}}, adapter="dspy")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["score"], 1)
        self.assertEqual(json.loads(result["feedback"]), [
            {"field": "notes", "temperature": .23, "max_tokens": 77},
            {"field": "answer", "temperature": .61, "max_tokens": 88},
        ])
        self.assertEqual(len(messages), 1, "project clients must not be replaced by RPCE host calls")
        self.assertEqual(result["prompt_tokens"], 160)
        self.assertEqual(result["completion_tokens"], 40)
        self.assertEqual(result["artifact"]["model_routing"], "project")
        self.assertEqual(result["artifact"]["predictors"], json.loads(candidate))
        exported, messages, code, stderr = self.launch({"type": "export", "candidate": candidate}, adapter="dspy", operation="export")
        self.assertEqual(code, 0, (exported, stderr))
        self.assertEqual(exported["model_routing"], "project")
        self.assertEqual(exported["artifact"]["model_routing"], "project")
        self.assertTrue(exported["artifact"]["state"]["first"]["demos"])
        self.assertEqual(len(messages), 1)

    def test_project_routing_never_treats_bridge_subset_as_complete_usage(self) -> None:
        self.module.write_text(PROJECT_DSPY_MODULE + '''
def metric(example, prediction, trace=None, context=None):
    context.complete([{"role": "user", "content": "additional execution stage"}])
    return {"score": 1}
''')
        result, _, code, stderr = self.launch({"type": "evaluate",
            "candidate": json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"}),
            "example": {"input": "question"}}, adapter="dspy",
            complete=lambda payload: {"output": "OK", "prompt_tokens": 5, "completion_tokens": 1})
        self.assertEqual(code, 0, (result, stderr))
        self.assertIsNone(result["prompt_tokens"])
        self.assertIsNone(result["completion_tokens"])

    def test_packaged_dspy_example_imports_and_preserves_custom_label_fields(self) -> None:
        self.module.write_bytes((RUNNER.parent / "examples" / "support_router_dspy.py").read_bytes())
        description, _, code, stderr = self.launch(adapter="dspy", operation="describe")
        self.assertEqual(code, 0, (description, stderr))
        result, _, code, stderr = self.launch(
            {"type": "evaluate", "candidate": description["seed_candidate"], "example": description["examples"][0]},
            adapter="dspy", complete=lambda payload: {"output": "[[ ## category ## ]]\nbilling\n\n[[ ## completed ## ]]",
                                                       "prompt_tokens": 100, "completion_tokens": 1},
        )
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["score"], 1)

    def test_real_two_stage_dspy_executes_candidate_and_exports_reloadable_program(self) -> None:
        candidate = json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"})
        result, messages, code, stderr = self.launch(
            {"type": "evaluate", "candidate": candidate, "example": {"input": "question", "expected_output": "OK"}},
            adapter="dspy", complete=self.complete_program,
        )
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["score"], 1.0)
        self.assertEqual(result["feedback"], "trace_steps=2")
        self.assertEqual(result["prompt_tokens"], 80)
        self.assertEqual(result["completion_tokens"], 20)
        self.assertEqual(sum(message["type"] == "host_request" for message in messages), 2)
        self.assertEqual(result["artifact"]["predictors"], json.loads(candidate))
        import importlib.util
        spec = importlib.util.spec_from_file_location("runner_reload_fixture", self.module)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        restored = module.build_program(None)
        restored.load_state(result["artifact"]["state"])
        self.assertEqual({name: predictor.signature.instructions for name, predictor in restored.named_predictors()}, json.loads(candidate))
        self.assertTrue(all(predictor.lm is None for _, predictor in restored.named_predictors()))

    def test_export_needs_no_provider_and_keeps_named_instructions(self) -> None:
        candidate = json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"})
        result, _, code, stderr = self.launch({"type": "export", "candidate": candidate}, adapter="dspy", operation="export")
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(result["type"], "exported")
        self.assertEqual(result["artifact"]["predictors"], json.loads(candidate))

    def test_wrong_predictor_name_is_candidate_feedback_without_model_calls(self) -> None:
        result, _, code, _ = self.launch({"type": "evaluate", "candidate": '{"wrong":"instructions"}', "example": {}}, adapter="dspy")
        self.assertEqual(code, 0)
        self.assertFalse(result["candidate_valid"])
        self.assertEqual(result["score"], 0)
        self.assertIn("first, second", result["feedback"])
        self.assertIsNone(result["prompt_tokens"])

    def test_invalid_export_is_rejected_without_producing_an_artifact(self) -> None:
        result, _, code, _ = self.launch({"type": "export", "candidate": '{"wrong":"instructions"}'}, adapter="dspy", operation="export")
        self.assertEqual(code, 2)
        self.assertEqual(result["failure_code"], "dspy_candidate_predictor_names_must_match")
        self.assertNotIn("artifact", result)

    def test_dspy_model_judge_uses_judge_role_without_polluting_execution_usage(self) -> None:
        self.module.write_text(DSPY_MODULE + '''
def metric(example, prediction, trace=None):
    judged = dspy.Predict("answer -> score")(answer=prediction.answer)
    return float(judged.score)
''')
        roles = []
        def complete(payload):
            roles.append(payload["role"])
            if payload["role"] == "judge":
                return {"output": "[[ ## score ## ]]\\n1\\n\\n[[ ## completed ## ]]".replace("\\n", "\n"),
                        "prompt_tokens": 999, "completion_tokens": 999}
            return self.complete_program(payload)
        result, _, code, stderr = self.launch(
            {"type": "evaluate", "candidate": json.dumps({"first": "FIRST_INSTRUCTIONS", "second": "SECOND_INSTRUCTIONS"}),
             "example": {"input": "question", "expected_output": "OK"}}, adapter="dspy", complete=complete)
        self.assertEqual(code, 0, (result, stderr))
        self.assertEqual(roles, ["execution", "execution", "judge"])
        self.assertEqual(result["score"], 1)
        self.assertEqual(result["prompt_tokens"], 80)
        self.assertEqual(result["completion_tokens"], 20)

    @unittest.skipUnless(os.environ.get("REPOPROMPT_TEST_GEPA_PYTHON"), "set REPOPROMPT_TEST_GEPA_PYTHON to the pinned worker interpreter")
    def test_real_gepa_optimizes_real_dspy_program_for_measured_twenty_percent_savings(self) -> None:
        seed = json.dumps({"first": "FIRST_INSTRUCTIONS verbose", "second": "SECOND_INSTRUCTIONS verbose"}, sort_keys=True)
        candidate = json.dumps({"first": "FIRST_INSTRUCTIONS COMPACT", "second": "SECOND_INSTRUCTIONS COMPACT"}, sort_keys=True)
        process = subprocess.Popen([os.environ["REPOPROMPT_TEST_GEPA_PYTHON"], "-I", "-B", str(WORKER)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        request = {
            "run_name": "dspy-token-efficiency", "seed_candidate": seed,
            "objective": "Keep named predictor JSON complete and minimize tokens with unchanged correctness.",
            "objective_policy": {"mode": "efficiency"}, "background": "A real two-stage DSPy program.",
            "examples": [{"id": "one", "split": "training", "input": "question"}],
            "held_out_examples": [], "reflection_minibatch_size": 1, "skip_perfect_score": True,
            "perfect_score": 1.0, "stop_at_score": 1.0, "search_max_evaluations": 6, "search_remaining": 6,
            "run_dir": str(self.root / "gepa-run"), "output_dir": str(self.root / "gepa-output"),
        }
        memo = {}
        admitted = 0
        completed = None
        registered = {}
        assert process.stdin is not None and process.stdout is not None
        try:
            process.stdin.write(json.dumps({"protocol_version": 2, "type": "run", "request": request}) + "\n")
            process.stdin.flush()
            for _ in range(100):
                raw = process.stdout.readline()
                if not raw:
                    break
                event = json.loads(raw)
                if event["type"] == "candidate":
                    registered[event["candidate_index"]] = event["candidate"]
                elif event["type"] == "host_request":
                    if event["operation"] == "reflect":
                        reply = {"output": "<<<REPOPROMPT_CANDIDATE_BEGIN>>>\n" + candidate + "\n<<<REPOPROMPT_CANDIDATE_END>>>"}
                    else:
                        text = event["payload"]["candidate"]
                        if text not in memo:
                            def complete(payload):
                                result = self.complete_program(payload)
                                tokens = 40 if "COMPACT" in text else 50
                                return {**result, "prompt_tokens": tokens, "completion_tokens": tokens}
                            result, _, code, stderr = self.launch({"type": "evaluate", "candidate": text,
                                "example": {"input": "question", "expected_output": "OK"}}, adapter="dspy", complete=complete)
                            self.assertEqual(code, 0, (result, stderr))
                            admitted += 1
                            memo[text] = {"score": result["score"], "feedback": result["feedback"],
                                          "prompt_tokens": result["prompt_tokens"], "completion_tokens": result["completion_tokens"],
                                          "output_excerpt": result["output"], "output_characters": len(result["output"]),
                                          "evaluation_id": str(admitted)}
                        reply = {**memo[text], "search_remaining": 6 - admitted}
                    process.stdin.write(json.dumps({"protocol_version": 2, "type": "host_response", "id": event["id"],
                                                    "status": "ok", **reply}) + "\n")
                    process.stdin.flush()
                elif event["type"] in ("completed", "failed"):
                    completed = event
                    break
            process.stdin.close()
            code = process.wait(timeout=15)
            stderr = process.stderr.read() if process.stderr else ""
            self.assertEqual(code, 0, (completed, stderr))
            self.assertEqual(completed["type"], "completed", (completed, stderr))
            result = completed["result"]
            self.assertEqual(registered[result["best_candidate_index"]], candidate)
            self.assertEqual(result["best_score"], result["baseline_score"])
            for field in ("prompt_tokens", "completion_tokens"):
                self.assertEqual(result["paired_usage"]["baseline"][field], 100)
                self.assertEqual(result["paired_usage"]["best"][field], 80)
                self.assertAlmostEqual(result["paired_usage"]["savings"][field], 0.2)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe and not pipe.closed:
                    pipe.close()


if __name__ == "__main__":
    unittest.main()
