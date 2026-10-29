# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-only lab for improving RepoPrompt built-ins, prompts from other projects, and Python/DSPy programs. It uses one frozen experiment contract and the same upstream GEPA search pipeline for all of them. RPCE owns preparation, source mapping, execution, grading, accounting, evidence and reviewed application; the Python worker proposes candidates through GEPA. This implementation does not promote an optimized production default automatically or claim a measured improvement from scripted tests.

## Native workflow

Open **Window → Prompt Experiments… → New Experiment** in a DEBUG build. The form asks for the prompt, the desired improvement, representative examples and success checks. It does not require GEPA configuration or hand-written evaluation JSON.

1. Choose an RPCE built-in, a project file, or pasted prompt text. A plain prompt file can be optimized as a whole. For a supported string embedded in source code, select one complete static literal or its exact contents. Import decodes the string for evaluation and retains its original encoding and source hash for application. Dynamic/interpolated expressions that cannot be mapped safely require pasting the resolved prompt and exporting the result.
2. Describe the outcome and choose **Best quality, then shorter prompts** or **Fewer tokens while preserving quality**. Efficiency experiments have an explicit quality tolerance, defaulting to zero. Advanced settings expose input/output weights; these express priorities, not provider prices. There is no default relative prompt-length ceiling for a new definition-backed experiment.
3. Review examples and success checks. **Generate examples and checks** makes one explicit model call, bounded to 60 seconds, to prepare a small draft. Generated examples are labeled and editable; they are provisional task coverage. The native editor exposes requests, private references, variables, frozen files and nested program dataset fields. It labels the three splits as improvement examples, comparison examples and final checks.
4. Choose connected models and a small search budget. Supported targets appear through the shared `PromptExperimentService.promptOptions()` / target catalog. Connect providers under **Settings → CLI Providers**. Advanced settings expose the proposing model, the judge, baseline repeats and search controls. A program may optionally use a judge callback. Generic experiments can use the same model for proposing and judging, with that relationship disclosed.
5. **Review Experiment** creates the definition and opens native approval. Inspect the frozen prompt, examples, checks, source, model routing and maximum work, then choose **Approve & Run**. Creating the draft itself makes no model calls. Example generation and program inspection are separate explicit preparation actions.
6. Inspect retained candidates, actual baseline/candidate answers, per-case scores, feedback and paired token measurements. Copy or save a prompt, review its source diff, or export the complete experiment. A run may retain the baseline as best or report insufficient evidence; completion does not imply improvement.

`PromptExperimentCreateView.swift`, `PromptLabExampleEditor.swift` and `PromptLabRunResultsView.swift` implement this flow. For a program, the form selects its interpreter, project directory and evaluation module, then **Load program examples and checks** executes that module's description entry point. **Save a starter evaluator…** copies a bundled Python or DSPy example into a new file in the user's project. Existing files are not overwritten.

The Agent Mode **Prompt Experiment** workflow reaches the same typed service. Its `prompt_experiment` operations are `targets`, `prepare`, `describe_program`, `create_or_update`, `request_approval`, `run`, `status_or_wait`, `cancel`, `propose_patch` and `export`. `prepare` for pasted or built-in prompts is an explicitly requested model call. `prepare` with `prompt_file` and every `describe_program` request instead return a `preparation_id` and await native preparation approval. No file contents are read, project code imported, or preparation model called while these requests await approval. The assistant polls `status_or_wait` with the preparation ID; the definition is returned only after approval and successful completion. `experiment_id` and `preparation_id` are mutually exclusive in that operation. Neither preparation route grants optimization approval, and MCP cannot approve preparation, approve a run, or apply a source patch. The strict schema accepts the camelCase definition returned by preparation/discovery, preserves source-literal metadata and arbitrary nested dataset payloads, and rejects unknown authority fields.

`PromptLabPreparationApprovals.swift` keeps agent-requested preparations in a bounded, in-memory queue. The native review shows the requested file/model or interpreter, project root, module, timeout and inherited environment variable names. Approving a file request reads the current file and permits its one bounded preparation call. Approving a program request seals the current project inputs and imports the module with the selected interpreter's normal project access; arbitrary import-time code can access files, start processes or contact services. The user approves that execution explicitly. This is separate from the restricted Engineer fixture harness.

Each preparation authorization is one-shot and bound to an immutable request. Approval changes state before execution, so repeated clicks or status polls cannot rerun it. Native rejection and cancellation settle the request; changing any requested input requires a new request. Pending permissions are not persisted or automatically restored on restart. The native New Experiment form's **Generate examples** and **Load program** buttons remain explicit user preparation actions, and an approved experiment still runs within its whole budget without per-evaluation prompts.

## Shared definition and runners

`Sources/RepoPrompt/Features/PromptExperiments/PromptLabDefinition.swift` separates the candidate source from the task runner. Its versioned definition freezes:

- Source kind, title, decoded prompt, optional built-in ID, file path, original file hash, selected region and literal encoding.
- The user's goal, quality/efficiency policy, quality tolerance, usage weights and optional prompt-length limit.
- Stable example IDs, training/validation/final splits, input, private reference, variables, frozen context and original program dataset payload.
- Success criteria, runner kind, and any program configuration, source/dependency declaration hashes, model routing and explicitly inherited environment variable names.

The service validates the definition, builds its suite and seals it into the existing experiment authority. All three splits must be present. A new experiment is required when approved execution inputs change. `PromptHarness.swift` remains the execution seam; source selection does not force an Oracle rendering path.

| Runner | Actual task execution | Quality measurement |
| --- | --- | --- |
| `plainPrompt` | Render the prompt template and run the supplied request with frozen context. Variables support `{{name}}`, `${name}` and `{name}`. | Reviewed weighted checklist with a model judge and supported deterministic checks. |
| `oracle` | Render the selected built-in through the production Oracle renderer and package its context with the production message builders. | Checked-in rubric and case references. |
| `engineer` | Render the real Engineer system prompt and run a tool-using task in a fresh isolated fixture. | Host-owned executable acceptance checks and file-preservation checks. |
| `program` | Invoke the selected project's Python evaluator with the candidate and original dataset fields. | The evaluator's score and feedback. |
| `dspy` | Run an actual DSPy module after replacing its named predictors' instructions. | The project's metric over actual predictions. |

References and hidden-case outcomes are not supplied as task instructions or proposer feedback. Program authors control their evaluator contract and therefore must keep private labels out of the inputs sent to their own model clients. RPCE preserves opaque payloads rather than guessing how an application's data should be flattened.

## Built-in rendering and suites

`BuiltInPromptRegistry.swift` loads `AppResources/Prompts/<id>/prompt.md`, records its exact file hash and removes one trailing LF for rendering. Oracle execution uses `ConnectedModelHarness.swift`, `OracleSystemPromptRenderer` and the production `PromptPackagingService` / `AIMessage` builders. Experiment overrides do not replace user-edited stored prompts or custom planning prompts.

The Engineer body is now a registered resource used by `AgentModePrompts.engineerPrompt`. Reserved `{{rpce.*}}` placeholders preserve code-owned provider/tool fragments and must appear exactly once. Resource extraction makes that production prompt addressable; it is not a hand-tuned improvement or a measured replacement default.

| Built-in | Training | Validation | Final checks | Grader |
| --- | ---: | ---: | ---: | --- |
| Oracle Plan | 6 | 3 | 3 | Model checklist |
| Oracle Review | 3 | 2 | 1 | Model checklist |
| Oracle Chat | 3 | 2 | 1 | Model checklist |
| Oracle Chat without a workspace | 3 | 2 | 1 | Model checklist |
| Engineer | 3 | 2 | 2 | Executable task acceptance |

These are starter suites, not production release benchmarks. Review includes correct changes to expose false positives. Chat exercises grounded answers and missing context. `PromptSuiteLoaderTests` requires every registered target to have a valid suite.

A model-judge rubric is a weighted binary checklist. The host can also check required sections, absent code patches and paths grounded in frozen context. Each judge check requires a boolean result and failure feedback; one format repair is allowed. The score is the weighted pass fraction. Effort-normalized `judgmentModelIdentity` identifies the same underlying proposing/judging model. Legacy built-in requests keep their independent-judge restriction; new generic definitions disclose same-model judging instead of requiring two providers.

## Python application contract

`PromptLabProgramHarness.swift` bridges to `AppResources/PromptExperiments/prompt_program_runner.py`. The selected interpreter must already contain the project's dependencies. The project module is a regular `.py` file inside the selected root, with a sealed hash. RPCE does not install arbitrary project dependencies during a run.

A Python evaluator exports an evaluation function (default `evaluate`). Optional `SEED_PROMPT`, `EXAMPLES`, `CRITERIA` and `OBJECTIVE` metadata populate the native form; the prompt, cases and checks can instead be supplied independently. The function receives `(candidate, example, context)` and returns a finite score, feedback and actual output. For external model clients it can also return measured `prompt_tokens` and `completion_tokens`. The bundled `examples/support_router.py` is a complete small example.

```python
def evaluate(candidate, example, context):
    answer = context.complete([
        {"role": "system", "content": candidate},
        {"role": "user", "content": example["input"]},
    ])
    output = answer["output"]
    return {
        "score": float(output.strip() == example["expected_output"]),
        "feedback": "Return the expected routing label.",
        "output": output,
    }
```

`context.complete` and `context.acomplete` route execution or judge calls through RPCE. The current native callback supports a system message and one user message, with no arbitrary provider settings; unsupported message histories/settings fail explicitly. Applications needing other provider semantics can use their actual model SDK/client inside the evaluator. They must report complete measured usage to participate in efficiency comparison. Callback usage includes all execution calls when available; judge overhead is recorded separately.

The environment configuration contains **names**, such as `OPENAI_API_KEY`, of additional variables the process may inherit. Values are not persisted in experiment definitions or approval text. No project credential set is inherited by default. Loading, describing, evaluating and exporting a program execute selected local code with that interpreter's normal access; this runner is not an OS sandbox. The module can also load project configuration itself. Admission and resume seal regular project Python sources and dependency declaration files, with bounded hashing of 10,000 files / 50 MB and exclusions for virtual environments, builds and Git caches. Installed package contents, external data and remote services are not sealed by those hashes.

## DSPy contract and export

The DSPy adapter uses the selected environment's installed **DSPy 3.4.1**, validates that version, and executes real `dspy.Module` / predictor objects. A module exports `build_program(context)`, `metric(example, prediction, trace=None)` and optionally `make_inputs(example)`, alongside its examples. `examples/support_router_dspy.py` demonstrates the contract. Named predictors' instructions become the editable candidate components; their names are validated before installation. RPCE uses its common GEPA search, not a second nested DSPy optimizer lifecycle.

By default, `MODEL_ROUTING = "connected"` installs the RPCE-backed LM for execution and judge callbacks. `MODEL_ROUTING = "project"` preserves the program's configured LM/client and settings instead. Discovery returns this routing, which is frozen and checked at preflight. Project routing requires explicit metric usage measurements; the bridge's visible subset cannot stand in for the whole program's token usage. Configured examples/demonstrations and normal program structure remain part of actual execution.

The evidence export includes a `compiled_program` artifact with format `dspy_state`, version, model routing, predictor names and the program's JSON-compatible state. Recreate the compatible program and load the saved state. The artifact clears predictor model fields, so restore the project's model clients after loading; a separate client for each predictor can be preserved this way:

```python
program = build_program(context)
configured_lms = {
    name: predictor.lm for name, predictor in program.named_predictors()
}
program.load_state(exported_experiment["compiled_program"]["state"])
for name, predictor in program.named_predictors():
    predictor.lm = configured_lms[name]
```

Model objects/credentials are not serialized into the exported state. Exporting DSPy state may execute the selected module again. See the [official GEPA project](https://github.com/gepa-ai/gepa), [GEPA adapter documentation](https://gepa-ai.github.io/gepa/guides/adapters/) and [DSPy project](https://github.com/stanfordnlp/dspy) for the upstream contracts.

## Engineer task isolation and acceptance

`PromptExperimentAgentHarness.swift`, `PromptExperimentAgentTaskRunner.swift` and `PromptExperimentAgentAcceptance.swift` implement actual tool tasks. Every admitted evaluation creates a new fixture workspace and private headless profile, installs the candidate through the production Engineer renderer, runs the configured provider, then disposes of that session. The active RPCE window's workspace authority is not reused.

The headless tool profile permits fixture file reads and edits. Shell, web, delegation, Oracle and interactive-user tools are absent. Provider configuration uses the experiment profile and strict MCP configuration. Fixtures have bounded file counts/bytes and reject traversal and provider configuration directories. The supported connected provider transport and installed stable RPCE CLI are checked before use.

Each case's private `expectedOutput` contains a versioned acceptance specification with Python function checks: relative file path, function name, JSON arguments and expected return value or exception. Optional preservation checks detect unwanted file changes. The spec remains in host memory, outside the agent's writable fixture. Its default bounds are **16 turns and 180 seconds**, with validated per-case ranges of 1–64 turns and 10–900 seconds. Native approval derives the maximum from the actual frozen cases.

After the agent stops, the host executes the edited Python functions through a separate fixed interpreter under macOS `sandbox-exec`: the fixture is read-only, network and arbitrary subprocesses are unavailable, and checks have CPU/deadline bounds. The grader scores actual acceptance results; a persuasive final answer cannot substitute for correct edits. Retained evidence includes the agent response, tool trace and check feedback. This is an isolated Python-fixture task harness, not unrestricted evaluation of every real-world repository, language, shell workflow or provider family.

## Runtime readiness, limits and recovery

Before calibration or a run is recorded, `PromptExperimentGEPAWorker.preflight` resolves the actual interpreter/worker and executes `gepa_worker.py --preflight`. It checks GEPA imports and the pinned runtime; packaging performs the same check. A broken packaged resource fails before model spend and does not silently use a checkout worker. Source fallback is limited to unbundled DEBUG development. The DEBUG artifact contains CPython 3.11 and pinned GEPA 0.1.4; Release builds do not ship the lab. The GEPA process receives no provider credentials or source-write authority. Project evaluators are separate explicitly configured processes with the access described above.

The cumulative search cap includes the seed validation pass, candidate evaluations and a final-check reserve. Calibration is a separately admitted pool of `|final| + repeats × |validation|`, defaulting to two baseline repeats. Native approval shows the combined maximum. Default Oracle Plan is **25 search + 9 calibration = 34 evaluations**; the other Oracle suites are **25 + 5 = 30**, and Engineer is **25 + 6 = 31**.

New definition-backed labs also receive a durable RPCE provider-session cap, normally `search cap × 8 + 32`, bounded above by 100,000. It counts calls routed through RPCE across runs, including retries, reflection and judging; an agent session has its own turn/time bounds. Calls inside a project's own client remain governed by that client. RPCE still bounds the number and duration of program evaluations, but neither its evaluation cap nor callback ledger is a dollar cap or a limit on arbitrary external client calls. The one-call preparation action precedes run approval and is presented separately.

`PromptExperimentBudgetLedger` records admission before spend, never refunds an admitted evaluation and reconciles explicit resume with the saved checkpoint. The worker checks remaining budget before a whole iteration, skips duplicate proposals, bounds reflection calls and also bounds iterations that consume no evaluations. `iteration_limit` can therefore leave unused budget without pretending it was exhausted. Provider failures, format repairs, cancellation and uncertain remote settlement remain visible in retained records. An interrupted run is inconclusive until explicit reconciliation; it is not silently restarted.

New definition-backed experiments take a fresh calibration baseline rather than loading a cross-experiment cache. Legacy built-in records can still reuse matching cached calibration. That legacy cache has no expiry or hosted-model revision check. Resumes reuse evidence within the approved experiment; a stable model selector still cannot guarantee that a mutable provider alias has not changed.

## Objective and honest result measurement

In quality mode, raw task quality drives search, with prompt/output brevity as secondary evidence. Efficiency mode uses one policy for parent selection, candidate acceptance, frontier and reported winner. Each compared case must meet its baseline quality minus the explicit tolerance. Among eligible outcomes, measured input/output tokens are combined with the selected weights. A quality-floor violation receives a penalty large enough that savings on other cases cannot outweigh it. Missing positively weighted usage earns no efficiency credit. Perfect quality does not stop an efficiency search, and a slightly longer instruction can win if it produces lower measured total usage without violating quality.

Raw quality is retained separately from the worker's objective utility. Reflection receives task feedback and the declared objective, with private final-case evidence excluded. Optional prompt-length limits remain constraints rather than a substitute for token measurement.

`PromptLabUsageComparison.swift` pairs baseline and selected candidate by case on the final set, falling back explicitly to validation when final evidence is unavailable. It uses one last retained sample per matching case, never training examples or an average over different workloads. Provider input normalization includes reported cache input semantics; only the versioned normalized measurements qualify. Input and output coverage are separate, missing values remain missing, and a percentage is shown only with complete coverage and a positive baseline total. A reported input reduction is not automatically an output reduction or a dollar saving.

The baseline-repeat comparison reports observed spread, not statistical confidence. **Exceeds observed baseline spread** means exactly that; held-out regressions remain visible. Tiny starter suites, generated cases and shared model preferences limit the inference. Scripted transport/objective tests establish mechanics, not live-model gains. This implementation does not claim that an earlier token-saving prototype has been reproduced without its exact prompt, inputs, model configuration and metric.

## Source application, export and promotion

`PromptPatchProposer.swift` prepares a retained candidate's source diff only for a settled run. Built-ins target the configured source checkout's resource, never the running application bundle. Project files retain their original full-file hash and exact selected region; supported source literals are re-encoded before replacement. Source and metadata are rechecked against the original snapshot. A changed file fails with a conflict rather than a merge or silent overwrite.

Only the native proposal review applies or rejects a source patch. Built-in application archives the prior default; existing user overrides retain precedence. Rebuild RPCE to load an applied built-in change. Pasted prompts can be copied or saved to a new file. Save and evidence export refuse existing destinations, keeping reviewed source application as the update path.

`export` writes a new self-contained `rpce-prompt-lab-v1` JSON file containing the frozen experiment, selected run, inline content-addressed evidence, paired usage and DSPy state when applicable. No remote publication or source promotion occurs. Store schema **10** and ledger schema **2** are unchanged; the new optional definition fields have their own contract version. No persistence-schema bump is part of this implementation.

Promoting defaults should move engineering effort into representative cases, deterministic checks, reviewed criteria and explicit thresholds. Run finalists against fresh paired baselines and broader reserved suites across supported renderers/models, retain regressions and usage evidence, and review the generated diff. Repeatedly selecting against the same final set makes it selection data; refresh final evidence before release decisions. This change extracts the Engineer body for addressability but does not hand-tune existing default wording or claim an experimentally improved default.

New definition-backed model judging serializes task inputs, references and target outputs into a JSON data object and explicitly forbids following instructions inside that data. Legacy approved runs retain their original grading contract. Framing reduces accidental instruction/data confusion; deterministic task checks and adversarial evaluation still matter. The execution-contract version must change when renderer or grader semantics change; installed dependencies, external services and mutable provider revisions are not fully frozen by source hashes. Native macOS execution, packaging and real-provider acceptance must be validated on their actual platforms; Linux syntax checks and worker fixtures do not substitute for that evidence.
