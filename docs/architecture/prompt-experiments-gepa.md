# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-only lab for improving RepoPrompt CE's four built-in Oracle prompts. Upstream GEPA searches candidate prompt bodies; the app owns prompt rendering, connected-model calls, grading, budget admission, persistence, approval, and source-patch review. Results are evidence, not automatic promotion. Arbitrary project prompts, DSPy programs and tool-using Engineer agents are not supported by this harness. See [the proposed product path](#product-path-proposed) for those extensions and the remaining evidence-quality work.

## Starting an experiment

In a DEBUG build, open **Window → Prompt Experiments… → New Experiment**. Choose a built-in prompt and execution model, then start with the Small (25) or Medium (50) search budget. Advanced settings expose reflection and judge models, minibatch size, baseline repeats and prompt-length ceilings. The setup screen shows unavailable prompts with their reason and separates search evaluations from calibration. Connect supported providers under **Settings → CLI Providers**. Connected Codex and ACP targets remain excluded because this harness requires an enforced prompt-only completion profile.

**Review Experiment** creates a draft without model calls. Select **Review for approval**, inspect the models and maximum work, then use the native **Approve & Run** action. Subsequent runs resume within that approval's remaining cap. Source patch proposals still require separate native review; starting an experiment never applies a prompt change.

Agent-assisted setup remains available: choose the **Prompt Experiment** workflow in Agent Mode and describe the supported built-in prompt to evaluate. The `rp-prompt-experiment` workflow uses `prompt_experiment` to discover prompts, suites and models, create the same typed draft, and request native approval. Its card opens the same Studio. Neither route requires hand-authored JSON or an external Python checkout to run the packaged lab.

This feature is carried forward from `wt/native-prompt-experiments-20260910` (`d125e8d3a`), with upstream `main` at `c47a23d61` merged into the carry-forward branch. The original worker, bundled runtime, workflow, MCP controls, Studio, calibration, durable budget and patch-review path are retained rather than replaced by the later standalone-worker prototype.

## Registry and suites

`BuiltInPromptRegistry` loads UTF-8 prompt bodies from `AppResources/Prompts/<id>/prompt.md` (packaged under `Contents/Resources/Prompts`). It records a SHA-256 of the file bytes and removes one trailing LF for rendering. Production and `ConnectedModelHarness` share the renderer; an experiment override applies only to its selected prompt ID and evaluation. User-edited stored prompts and custom planning prompts retain their precedence. The lab optimizes the built-in baseline, never a user's edit.

Each eligible prompt has a checked-in `suite.json` and, for model judging, `rubric.md` beside it. Schema 1 declares stable case IDs, training/validation/hidden-test splits, prompt variant, grader and score range. A case's `input` is the user's instructions; optional `file_tree` and `files` carry frozen context. `ConnectedModelHarness` (and the judge) package each case with the production `PromptPackagingService.buildAIMessage` / `AIMessage` builders, so the target sees the same `<file_tree>`, `<file_contents>` and `<user_instructions>` structure as a real Oracle request. The loader rejects malformed or mismatched suites before model spend.

| Prompt | Suite | Training | Validation | Held out |
| --- | --- | ---: | ---: | ---: |
| Oracle Plan | `oracle-plan-v1` | 6 | 3 | 3 |
| Oracle Review | `oracle-review-v1` | 3 | 2 | 1 |
| Oracle Chat | `oracle-chat-v1` | 3 | 2 | 1 |
| Oracle Chat without a workspace | `oracle-chat-no-roots-v1` | 3 | 2 | 1 |

Review includes correct changes to measure false positives as well as concrete regressions. Chat includes grounded explanations, missing-context abstention and an untrusted source comment; no-roots cases contain no frozen repository. Reference answers are judge-only. `PromptSuiteLoaderTests.testEveryRegisteredPromptHasAUsableCheckedInSuite` fails for missing suites instead of silently skipping them. These small starter suites exercise the workflow; they are not sufficient release benchmarks.

A model-judge rubric is a weighted binary checklist (CheckEval-style): lines of the form ``- `id` (weight W): question`` are answered by the judge, and ``- `id` (weight W, host: kind params): description`` lines are computed deterministically by the host (`required_sections sections=A|B`, `no_code_patch max_block_lines=N`, `paths_in_context`). The loader rejects holistic or malformed checklists. The judge returns, for every judge check exactly once, a boolean `pass` plus, for a failure, a verbatim failing `span` (empty for an omission) and a concrete `fix`; one format repair is allowed. The score is the weighted pass fraction mapped into the suite range, and the proposer-facing feedback lists failing checks (span and fix) before the passing ids. Oracle Plan's checklist covers grounded current state, seam reuse, resolved decisions, invariants, file-by-file impact, ordering, focused tests, explicit assumptions, no fabrication and proportion, plus host checks for the prompt's required sections, no code patches, and paths grounded in the case context. The default judge differs from the reflection model. `judgmentModelIdentity` removes effort suffixes for that comparison: choosing another effort on the same provider/model is still rejected, including at run admission. The full selection identity remains in authority and cache keys. This reduces one source of self-preference; it does not establish statistical independence or unbiased judging. Held-out feedback is redacted at the proposer boundary while host-side reviewer evidence remains stored.

## Approval, execution and recovery

The `prompt_experiment` MCP tool exposes `targets`, `create_or_update`, `request_approval`, `run`, `status_or_wait`, `cancel` and `propose_patch`. It cannot approve spend or apply a patch. One native approval binds prompt/resource and suite/rubric hashes, resolved execution/reflection/judge targets, GEPA settings, runtime pin, a cumulative search cap and a separate baseline-calibration line. Changing an approved authority creates a new experiment requiring approval. Approval starts the first run; later explicit `run` calls resume within the remaining cap.

Before a run is recorded or calibration spends anything, `PromptExperimentGEPAWorker.preflight` resolves the actual worker and interpreter and launches `gepa_worker.py --preflight` in the isolated worker environment. It imports the GEPA entry points and verifies Python, package and upstream revision readiness; a working interpreter alone is insufficient. Packaging performs the same worker check. A broken packaged worker fails with a rebuild instruction instead of falling back to checkout files; source fallback is reserved for unbundled DEBUG development.

## Budget shape

The search cap pays for GEPA's seed validation pass, proposals, and a held-out reserve of |hidden| that scores only the incumbent. Defaults are minibatch 2, merge off, `current_best` parent selection and perfect-score skipping, so a rejected proposal costs 2m and an accepted one 2m+|V|. GEPA's own metric-call stopper is not used (it restarts per process and counts ledger replays); the worker's `LedgerBudgetStopper` starts from the ledger's remaining count in the run request (the worker fails fast without it) and refreshes it from every evaluation reply and never starts an iteration that could not finish (remaining < 2m+|V|). Because replays are free, the worker also skips proposals identical to the parent or to an earlier proposal and caps reflection calls at the search cap. Every loop iteration is bounded too, including perfect-score skips that never invoke reflection. Reaching this per-run iteration bound reports `iteration_limit`, preserves the incumbent, and can leave evaluations unused; it is not reported as budget exhaustion. For oracle-plan-v1 (6/3/3) a cap of 25 leaves 19 after the reserve and seed pass: about four proposals (three if one is accepted). `targets` reports this as `budget_guide`.

Baseline calibration is a separately approved line, |hidden| + k·|V| (k = `noise_floor_replicates`, default 2), spent before search: the seed's held-out scores and k extra seed passes over the validation cases (ledger replicates 1…k; GEPA's own seed pass is replicate 0). They are cached across experiments under `calibration/<key>.json` in the store root, keyed by the rendered seed system prompt, suite and rubric SHAs, execution and judge selection IDs, `max_provider_retries`, judge repair allowance, and code-owned judge prompt template. A cache hit spends nothing and a partial cache is topped up. A calibration provider/judge failure leaves that evidence unavailable without failing the search, and only completed passes are cached.

Setup and native consent show the combined maximum: Oracle Plan at default settings permits **25 search + 9 calibration = 34 evaluations**; the other starter suites permit **25 + 5 = 30**. Evaluations are not model calls or dollars: target execution, model judging, reflection, repairs and retries contribute separate calls. The cache currently has no expiry or provider-revision freshness check; a stable model selector does not guarantee unchanged hosted model behavior. See the product path for the proposed freshness and runtime-seal work.

## Noise floor

At settlement the worker reports GEPA's per-case validation scores for the seed and the reported best. The host pairs them per case: the seed contributes k+1 samples (its GEPA pass plus the calibrated replicates), the per-case spread is max − min, and the best's delta is against the seed's mean. The run is flagged *within noise* when the mean paired delta does not exceed the mean spread (or when fewer than two seed samples exist, it is reported as unmeasured); cases improving or regressing by more than their own spread are counted. Held-out deltas (best vs. calibrated seed) are reported against the mean validation spread. This is an exploratory spread comparison, not a statistical confidence test. The UI says **Exceeds observed baseline spread**, identifies held-out regressions, and shows this evidence only for the candidate actually measured. MCP retains the `noise_floor` field with per-case samples, deltas and spreads. No formula or scoring semantics changed in this fixes PR.

## Reflection

The worker owns the reflection prompt through GEPA's `custom_candidate_proposer`. Per minibatch case the reflection model sees the case request (instructions only, not frozen file contents), the score, the grader feedback, and a head+tail output excerpt (3 KB + 3 KB with an omission marker). GEPA's `_budget` and other `_`-prefixed bookkeeping never reach it. Every embedded text is fenced with a backtick run longer than any inside it, and the reply must use the BEGIN/END candidate envelope. The task is ESPO-style: first cluster the minibatch failures into at most three root causes (cause, cases and failed checks it explains, responsible prompt text), then return an edited prompt, not appended rules, under a hard character ceiling (`prompt_character_ceiling_ratio` × the edited prompt, default 1.0, optionally capped by `max_prompt_characters`). An overrun gets one compression repair and is otherwise skipped without spending evaluations.

## Objectives

The scalar score GEPA sums is quality. Each evaluation's side_info also carries `scores = {quality, brevity}` (higher is better) for GEPA's hybrid frontier; brevity blends prompt length against the seed and answer length against the seed's answer on the same case (the host sends the seed's recorded per-case lengths from the ledger, so a resume keeps the real reference) (0.5 at parity, 1.0 at half, 0.25 at double; an empty answer earns none). Acceptance is quality first: a strictly better minibatch quality sum is accepted, and at an exact tie only a strictly shorter prompt. The reported best is the shortest candidate among validation-score ties. Each evaluation records candidate and output characters plus target token usage when reported; candidates carry per-text averages computed from the whole ledger.

`GEPARunController` runs the pinned upstream GEPA worker over a credential-free NDJSON bridge. `ConnectedModelHarness` makes prompt-only provider calls with no tools. Claude-compatible callbacks require Claude Code 2.1.299 or newer: the experiment-only transport qualifies the runtime before authenticated setup, suppresses file-mention expansion, and sends literal structured input. Structured input alone does not prevent `@file` expansion. Ordinary Agent Mode and discovery transports are unchanged. `BudgetLedger` durably admits each logical evaluation before spend, does not refund admissions, and prevents duplicate IDs from re-spending. Swift owns classified transient retries and records each provider invocation. Budget exhaustion is a soft stop with the saved incumbent (`stopped_budget`), not an invented winner or a fatal evaluation. In-stream provider errors are classified (rate limit, overload/503, transport) so transient failures retry. A malformed judge reply gets one format repair per evaluation; judge JSON may be surrounded by prose. A reflection reply without the candidate envelope, or with an empty candidate, is a skipped proposal, never accepted as prose. Held-out scoring is report-only: its reserve has its own exhaustion flag, and a held-out provider/judge failure reports that score as unavailable without discarding the completed search. Baseline (from calibration, with its source) and best held-out averages appear in the run assessment and review sheet. Runs and content-addressed evidence survive restart. An interrupted run is marked inconclusive, never silently replayed; explicit resume reconciles the checkpoint and ledger and rejects ambiguous in-flight callbacks.

The app packages CPython 3.11 and pinned GEPA 0.1.4 in DEBUG builds. Python receives no provider credentials, workspace authority or source-write access. Release builds do not ship this lab. The existing canonical debug store is schema 10 and the ledger schema 2; earlier lab records are discarded rather than migrated. This fixes PR does not bump either schema. Human-readable views are projections, not authority.

## Reviewed source patch

A completed or stopped-budget run can retain candidate indices. `propose_patch` or the Studio creates a proposal for one index after verifying the explicitly configured source checkout's `AppResources/Prompts/<id>/prompt.md` is a contained regular file without symlink components and still matches the experiment's baseline SHA. Candidate text and a one-file unified diff are stored as artifacts. The packaged app bundle is never edited.

The native card/Studio review sheet shows the full diff and run evidence. Only its **Apply to Source** or **Reject** actions decide a proposal. Apply archives the exact previous prompt under `previous/<sha>.md`, rechecks the source SHA immediately before atomic replacement, and fails with a clean conflict if it changed; it does not merge. Reject preserves the proposal and run evidence. `PromptViewModel` includes validated archived defaults in canonical-upgrade recognition so unedited stored Architect/Review and planning copies upgrade after a reviewed prompt change, while user edits remain untouched. The source checkout defaults to the one the DEBUG build was compiled from (derived from `#filePath`, like `BuiltInPromptRegistry.defaultPromptsDirectory`, because conductor's `open -n` launch does not forward shell environment); `REPOPROMPT_PROMPT_EXPERIMENT_SOURCE_ROOT` overrides it. No bundled-resource fallback is a write target.

Applying updates the source checkout. Rebuild the app to use or evaluate the new built-in default: the running app still has its packaged and cached baseline. The readiness/setup fixes and added suites do not change any production `prompt.md` text or claim an experimentally improved default.

## Add a prompt to the lab

1. Give the plain-text built-in a `BuiltInPromptID`, `prompt.md` resource and production rendering call site, preserving user-override precedence.
2. Add a small `suite.json` with stable training, validation and hidden-test cases plus `rubric.md` for model judging. Keep expected outputs and grading notes host-side.
3. Add resource, rendering, suite-loading and old-default-upgrade tests; verify app packaging and both products.
4. Run a bounded debug experiment, inspect retained evidence, and review the one-file source diff before applying. Commit source changes only through the ordinary contribution workflow.

A future `ContextBuilderHarness` may evaluate repository-aware workflows using a per-evaluation snapshot and headless `repoprompt-mcp`; it is not implemented. Never substitute the active window's workspace authority for that isolation boundary.

## Product path (proposed)

### Current boundary

The carry-forward implementation has useful foundations: a native spend boundary, durable evaluation admissions, a credential-free GEPA worker, retained evidence and reviewed source patches. The immediate usability problems sit around that core: incomplete target coverage, readiness checks that previously missed the actual worker, and an experiment creation flow that required an agent. The fixes make the supported path accessible; they do not complete the larger prompt-optimization product.

Current support remains **DEBUG-only, prompt-only GEPA experiments for four built-in Oracle prompts**. There is no arbitrary project-prompt import, DSPy program execution, or tool-using Engineer evaluation. This PR changes no production prompt bodies and bumps no persistence schema. The existing document schema is 10; the ledger schema is 2. [The runtime architecture](prompt-experiments-gepa.md) records the implemented workflow and budget rules.

### What the source shows

| Boundary | Current implementation | Consequence |
| --- | --- | --- |
| Prompt identity | `Sources/RepoPrompt/Infrastructure/AI/Prompts/BuiltInPromptRegistry.swift`: `BuiltInPromptID` contains four Oracle IDs. | A project path or Engineer prompt cannot be selected by adding a picker label. |
| Rendering | `Sources/RepoPrompt/Features/PromptExperiments/ConnectedModelHarness.swift`: built-in override plus `OracleSystemPromptRenderer`; examples use Oracle message packaging. | An application's templates, message roles and variables need a different rendering contract. |
| Source application | `Sources/RepoPrompt/Features/PromptExperiments/PromptPatchProposer.swift`: one `AppResources/Prompts/<id>/prompt.md` file, baseline hash check and archive. | Inline language strings and project files need their own verified source mapping. |
| Agent behavior | `Sources/RepoPrompt/Infrastructure/AI/Prompts/AgentModePrompts.swift`: `engineerPrompt` composes tool, provider and Code Map guidance. | Tool-free answer quality does not measure successful edits, tool selection or verification. |
| Extension point | `Sources/RepoPrompt/Features/PromptExperiments/PromptHarness.swift`: evaluate candidate and frozen example, returning score and evidence. | Extend this boundary while retaining admission, persistence and review. |

The distinction also applies upstream. [GEPA](https://github.com/gepa-ai/gepa) searches textual parameters through an evaluator/adapter. [DSPy's GEPA implementation](https://github.com/stanfordnlp/dspy/blob/main/dspy/teleprompt/gepa/gepa.py) optimizes a supplied DSPy program against examples and a metric. Bundling GEPA does not make RPCE a DSPy program runner. Treat backend selection separately from the application evaluation contract; follow the [official GEPA adapter documentation](https://gepa-ai.github.io/gepa/guides/adapters/) when designing that contract.

### What the fixes establish

`PromptExperimentCreateView.swift` provides **New Experiment** inside Studio, using the same typed service as MCP. Draft creation makes no model calls. Users select a prompt, execution model and small budget; advanced choices remain available. Availability comes from `PromptExperimentService.promptOptions()` rather than separate UI and MCP assumptions.

All advertised built-ins now have suites under `AppResources/Prompts`: Plan retains 6/3/3 training/validation/held-out cases; Review, Chat and Chat without a workspace each have 3/2/1. Review includes clean changes to expose false positives. Chat includes missing-context and instruction-boundary examples. These are starter suites, with judge-only references, not release benchmarks. `PromptSuiteLoaderTests.swift` now fails when any registered target lacks a usable suite.

`PromptExperimentGEPAWorker.swift` and `Scripts/prompt_experiment_runtime_artifact.py` check the actual worker entry point and GEPA imports before calibration or packaging succeeds. `gepa_worker.py` bounds iterations even when perfect-score skips and cached replays spend neither evaluations nor reflection calls. Native consent includes calibration in the maximum work: default Plan permits 34 evaluations, not merely its 25 search evaluations. This remains an evaluation cap, not a dollar or model-call cap.

Judge selection ignores effort suffixes when rejecting the reflection model as its own judge. Results describe observed baseline spread, and proposal review attaches held-out comparisons only to the candidate actually measured. Applying a patch changes the checkout; rebuilding is required before the running app uses that default.

### Proposed stage 1: a dependable small experiment

Finish the current loop before broadening execution. Acceptance should include a fresh packaged DEBUG app completing a tiny run, cancellation and explicit resume, an unavailable worker failing before spend, a perfect-score run terminating, and a source conflict refusing application. Exercise actual provider callbacks on macOS in addition to mocked and Python tests.

Keep the beginner path to choosing a target, reviewing examples and success criteria, choosing a bounded run, and comparing baseline against candidate. Show per-case answers and failures alongside aggregate scores. A result of “baseline remained best” or “evidence inconclusive” is a successful experiment outcome. Provide intermediate users with editable suites, rubric review and evidence export before adding many optimizer controls.

### Proposed stage 2: standalone project prompt files

Start with explicit `.md` or `.txt` files, not arbitrary source-code extraction. Introduce a typed prompt target containing source identity, original bytes/hash, renderer identity, declared variables and a suite reference. Preserve the built-in target as one implementation of this abstraction. Do not impersonate an Oracle ID for a project prompt.

An import flow should capture examples, expected outputs or reviewed criteria, then preview the exact messages an evaluation will send. Version the template renderer and reject missing variables or changed placeholder contracts. Case inputs and references must remain distinct; keep a final test split outside optimizer feedback. Small exact-match or structured-output tasks should work without requiring a model judge.

Reuse the existing ledger and result review. Add a project patch writer that checks containment and baseline hashes, previews the precise diff and refuses concurrent edits. Its acceptance test is a small real project going from selected prompt file to measured candidate to reviewed patch, with no handwritten transport JSON. Template literals embedded in code can follow once source-region parsing and escaping have explicit tests.

### Proposed stage 3: application and DSPy adapters

An application adapter must execute the application's actual message assembly and output parsing. Define a versioned entry point accepting candidate parameters and frozen input, returning output, task metrics, diagnostic feedback and optional trace artifacts. Include code/dependency revision, runtime parameters and data version in experiment identity. Bound execution time and external effects; a test run must not silently use production side effects.

A DSPy adapter should load an explicitly selected program and metric, identify editable predictors or instructions, retain compiled-program artifacts, and describe how the result is applied. Expose a simple preset initially; keep DSPy-specific settings in advanced controls. The [official DSPy GEPA reference](https://dspy.ai/api/optimizers/GEPA/) and implementation describe that backend's contract. Changing backends must not bypass RPCE's budget, evidence or review boundaries.

### Proposed stage 4: tool-using Engineer experiments

Evaluate Engineer on isolated per-case snapshots or worktrees with run-scoped tools, reset state, turn/time limits and deterministic acceptance tests. Retain tool traces, changed files, test results and failures. Never reuse the active window's mutable workspace authority; `PromptHarness.swift` already records why that approach failed for an earlier context-builder adapter.

Separate optimizable stable guidance from code-owned provider/tool protocol fragments. Test the rendered combinations that production actually uses. A prompt that writes a convincing explanation but edits the wrong file must fail an Engineer task; a prompt-only proxy cannot establish this behavior. Ship this stage only after isolation, cancellation and artifact collection work independently of optimization.

### Evidence requirements before default promotion

Move manual effort into representative cases, reviewed criteria and acceptance thresholds. Freeze these before comparing generated candidates. Keep ordinary correct examples, difficult tasks, negative cases and known regressions; avoid rewarding one preferred writing style. Rerun finalists on fresh paired baseline measurements and a reserved final set, including supported model families and renderer variants. Repeatedly selecting winners against the same visible “held-out” set eventually makes it a selection set, so refresh final evaluation evidence.

Retain the prompt diff, model/runtime identity, per-case results, cost/usage observations and a human promotion decision. Broader regressions override a small aggregate gain. Archive previous defaults and preserve user overrides through the existing source-patch path. No default improvement is claimed by this fixes PR: model-backed experiments and release validation are separate work.

Three evidence gaps need explicit follow-up:

- **Cache freshness and provider revision.** `PromptExperimentBaselineCalibration.swift` hashes rendered seed, suite, rubric, selected execution/judge IDs and judging settings, but loads matching entries without expiry. A hosted model alias or mutable compatible backend may change under the same selector. Add visible calibration age, refresh policy and provider revision/configuration identity when available; use fresh baselines for release comparisons.
- **Host harness seal.** `PromptExperimentAuthority` and `GEPARunController.resolveExecution` do not seal all renderer, host grader and adapter code revisions. Calibration hashes some of these inputs separately, while search ledger replay follows authority identity. Add a shared execution-contract version/hash and explicit invalidation/migration before changing those semantics. This PR does not silently reset stored experiments or change judging formulas.
- **Judge data framing.** `PromptExperimentChecklist.judgePrompt` interpolates candidate output into the evaluator message without collision-safe framing or explicit instruction-boundary guidance. This is a source-established risk of redirected grading; no model exploit was demonstrated in this review. Add data framing, adversarial evaluator cases and deterministic checks where possible. Version the changed grader contract so old scores are not reused as equivalent evidence.
