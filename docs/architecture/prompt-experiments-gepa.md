# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-gated optimization lab with Agent and external MCP interfaces. It keeps RepoPrompt's existing session, model catalog, provider, Context Builder, persistence, native approval, and cancellation authorities while delegating candidate search to the real upstream `gepa.optimize_anything` implementation.

## Session-driven user flow

1. Start the **Prompt Experiment** Agent workflow from the normal new-session workflow picker and describe the workflow or prompt behavior to improve.
2. The Agent asks for missing goals or success criteria, drafts useful artifacts and development cases from scratch when needed, and uses the `prompt_experiment` session tool to set up and revise a bounded proposal with reviewed examples, evaluator, exact connected-model selectors, project inputs, permissions, and an evaluation-count budget. New proposals have no experiment-wide wall-clock deadline.
3. Preparation rounds test reviewed candidate batches on development examples, preserving outputs and feedback for revisions before search. The Agent calls `run` with the exact sealed digest. That same tool call remains pending while its native in-session card exposes every serialized field of the immutable authority. The Agent cannot approve itself.
4. **Approve & test this round** / **Approve & run GEPA** authenticates the native user action, validates the digest and owning session again, and starts automatically. **Revise with this feedback** denies that request and returns a new draft revision to the waiting conversation. Closing or cancelling the session cancels its pending request rather than creating ambient approval.
5. The resumed Agent uses bounded `wait` or `status` operations to receive progress and terminal results, then explains the evidence and proposes an iteration. `cancel` is owner- and digest-bound. The card remains the visible progress/results surface; no external console or follow-up user nudge is required.
6. **Build on this result**, **Run again**, and **Clone draft** create reviewable drafts. Any changed data, evaluator, permissions, targets, model, or budget produces a new digest and requires a new approval. Applying a winner remains separate and is never automatic.

Restart recovery preserves immutable records. An approved record can resume execution only through an owner-bound run request, while an interrupted active attempt is quarantined for explicit inspection instead of being silently replayed. Each admitted attempt persists process observations, timestamps, redacted stderr/protocol log locations, recent protocol events, active callback identity, and linked provider/child-session identity when known. A persisted PID is historical evidence only; after restart its liveness is explicitly unknown.

## Bundled, pinned Python runtime

Normal users do not install Python, create a virtual environment, run pip, set environment variables, or download dependencies. Packaging embeds an architecture-specific CPython 3.11.16 runtime and GEPA 0.1.4 at revision `0632cdb5dcc052e690eab439e1b4a7e3e9cfe407` under:

```text
RepoPrompt.app/Contents/Resources/BundledRuntimes/PromptExperimentPython/<arch>/
```

`Vendor/PromptExperimentPython/manifest.json` pins the official `python-build-standalone` 20260901 full distributions and GEPA source archive by URL, byte size, and SHA-256. `Scripts/prompt_experiment_runtime_artifact.py` acquires and verifies developer-side artifacts, installs the dependency-free GEPA source package without PyPI resolution, records source and tree provenance, stages the correct target payloads, and performs a relocated clean-environment smoke. Public universal packaging requires both `arm64` and `x86_64`; host-native debug packaging embeds the host target.

The app executes the bundle-relative interpreter with `-I -B -u`, a minimal fixed `PATH`, app-owned `HOME` and temporary directories, and no inherited Python/provider configuration. `-B` is explicit because isolated mode ignores `PYTHONDONTWRITEBYTECODE`; signed bundle contents must remain immutable. Preflight checks bundle provenance, target architecture, CPython version, GEPA metadata, PEP 610 source revision, empty dependency metadata, worker resource, connected model selections, evaluator shape, and budgets before execution.

The full upstream `PYTHON.json` and license tree are retained beside each runtime target, including `license_paths` selected for extension modules. GEPA's license is retained both in the runtime and under `ThirdPartyLicenses/gepa/`. Packaging signs every nested Mach-O inside-out, verifies each nested signature explicitly, then verifies the outer app and the non-code runtime provenance.

`REPOPROMPT_GEPA_PYTHON` remains a DEBUG/developer diagnostic override only. It is never part of normal setup or a prerequisite for a user run.

## Ownership, adapters, and protocol

- `PromptExperimentService` is the single writer for scheduling, immutable plan revisions, approvals, evidence references, pending interaction continuations, execution waits, and cancellation observations.
- Existing Agent Mode and Context Builder runtime code remains the authority for sessions and connected-model requests. Exact resolved catalog targets are sealed without changing global role defaults.
- Implemented execution adapters are `connected_model` for a prompt-only connected Agent provider completion, `context_builder` for a native Context Builder run in the isolated environment, and `sandboxed_command` for a reviewed command under Seatbelt.
- Evaluators are host-side exact match, a prompt-only connected-model judge with a sealed rubric and target, or the paired sandboxed-command evaluator.
- `PromptExperimentGEPAWorker` runs the packaged, versioned NDJSON bridge. It calls upstream `optimize_anything`; reflection and model-backed execution/evaluation synchronously round-trip to app-owned provider routes.
- Provider credentials, authentication configuration, workspace bindings, source paths, shell profiles, `PYTHONHOME`, and `PYTHONPATH` are not passed to Python.
- Canonical experiment JSON and content-addressed artifacts live under Application Support. Human-readable Markdown/CSV views are derived projections; projection failure degrades export state without rolling back a successful canonical commit.

The Python request/result protocol is version 1 and the current sealed optimization plan schema is version 6. Existing comparison schema v1 and optimization schema v2/v3/v4/v5 records remain readable, retain their exact digest-bound configuration (including deadlines only where historically present), are never rescored or rewritten during migration, and must be cloned or continued into a schema-v6 draft before execution. Creating that new draft intentionally omits the historic deadline while leaving the source plan untouched.

## Reviewed inputs and isolation

A proposal may combine reviewed inline examples with a bounded project snapshot. Snapshot paths are relative, traversal-free regular files selected from an authorized loaded root; at most the schema-defined file count and byte limits are copied into a fresh app-owned immutable environment. The source root, included path list, copied-file sizes and SHA-256 digests, and aggregate environment digest are sealed for native review. Later source changes do not change the run copy, and evaluation never writes the original project.

Execution models receive the current input and candidate, including reporting-only hidden-test inputs when that stage runs. Reflection receives development feedback, not hidden-test results. Hidden-test expected output and reviewer notes remain host-side grader data. Context Builder binds only the isolated materialized root and uses the existing native-tool restrictions. Direct loaded-workspace execution is rejected rather than described as isolated.

The command adapter receives the sealed project copy plus the current example inside an app-created evaluation workspace and requires `/usr/bin/sandbox-exec`. Its Seatbelt profile denies by default, admits required system reads and that workspace, denies network, strips ambient credentials, and does not admit the user's source checkout. Hosts without the sandbox fail closed.

## Failure and cancellation semantics

Candidate failures are reviewable feedback and may receive an evaluator-defined score. Transport, worker, provider, sandbox, or other infrastructure failures are inconclusive and are never silently converted to score zero or automatically retried. New runs end through their evaluation budget, an evaluator stop score, user/session cancellation, or runtime settlement—not an experiment-wide silence timer. Individual connected-model and sandbox-command operations retain separate bounded guards. Denied or stale approvals cannot start. Stop requests cancel and drain app-owned provider requests before the Python worker is interrupted; requested and settled states remain distinct, and bounded wait operations return durable progress or terminal status without imposing a run lifetime.

## Current capability limits

- The connected-model, Context Builder, generic sandboxed-command, and scoped upstream MCP adapters are implemented. The MCP boundary is detailed below; arbitrary MCP servers and cross-agent execution remain explicit follow-ups rather than being simulated by prompt text. Guided generic-project and RepoPrompt-native workflows will use this same lab lifecycle and evidence store, not separate experiment frameworks.
- Project snapshots require an already-authorized loaded root and an explicit reviewed relative-path list; automatic repository-wide discovery, unreviewed glob expansion, and live source editing are not supported.
- GEPA declares no required Python dependencies at the pinned revision. The separately hash-locked MCP dependency closure is bundled for the MCP adapter; optional provider clients are not installed because RepoPrompt owns provider calls.
- GEPA-reported candidate lineage, scores, feedback, elapsed wall time, and app-exposed timing are retained as evidence, not used as a deadline. Connected-provider token usage is labeled unavailable when the completion contract does not expose it; unavailable never means zero.
- Diagnostic protocol logs store event metadata only and exclude request/response payloads. A failed worker may expose only a validated exception class and source frame module/function/line; raw exception text, source snippets, locals, and request bodies remain excluded, and older failure envelopes label that identity unavailable. Arbitrary worker stderr is redacted while fixed framework progress lines may be retained; logs are bounded and every run gets a durable diagnostic record before its first evaluation.
- Deterministic fake-provider, handler, interaction, and pinned-worker tests validate integration and authority boundaries. They do not establish live provider quality or visible UI behavior.

## Guided cold starts and preparation rounds

The workflow separates **preparation** from **GEPA search** and asks whether to use supplied instructions or let GEPA generate the initial candidate. For supplied instructions, the agent can test focused development probes and revise from evidence. For seedless GEPA, the agent reviews the objective, examples and evaluator before proposing search; it does not silently author a replacement seed. Both paths inspect results and choose the next useful action rather than assuming process completion means improvement.

Specification envelope schema 3 adds `stage` and `preparation_candidates`. In `preparation`, the pinned worker executes a fixed candidate × training-example batch through the existing native evaluator/provider callbacks. It makes no reflection calls and does not execute validation or hidden-test examples. Candidate strings, examples, model, evaluator, permissions and evaluation ceiling are sealed together. Both host and worker reject unreviewed preparation candidates/held-out evaluation; this is not a second search optimizer. Each preparation round is approved as one batch, not per example. Revising a batch still requires a new approval.

`continue` selects saved candidate evidence as `seed_candidate`, records `starting_point=supplied`, and preserves the prior stage. Preparation retains only the selected candidate for the next focused probe; moving into search requires an explicit draft change. Search still invokes upstream GEPA. Historical plans/results are not rewritten; legacy deadline-free schema 4 plans remain integrity-verifiable but need a new revision to execute under current semantics.

Cards observe the live service directly, show the readable proposal without an expansion prerequisite, wrap long fields, retain complete JSON disclosure, and return written revision feedback to the waiting owner session. Results distinguish a development batch from a search and explicitly report when only the starting candidate was evaluated. These changes do not constitute live UI or provider-quality proof.

## External MCP lab control (no Agent session required)

The registered `prompt_experiment` tool also supports ordinary authorized app-proxy MCP clients.
It requires the running DEBUG app; it is not a new standalone/headless backend. Bind a loaded
workspace context and call `capabilities` directly. The returned `workspace_id` must be supplied
on every subsequent external operation; a mismatched workspace fails before accessing a record.
Do not infer tool absence from a code runner's partial `ALL_TOOLS` registry.

External records are owned by a stable, namespaced workspace controller, so reconnecting clients
can list/read/clone/continue them without fabricating or starting an Agent Mode session. The legacy
`controllerSessionID` storage field holds that owner key; it is not a provider session ID. Existing
Agent-created records retain their session ownership. Another workspace cannot name an experiment
UUID to acquire it. As with other workspace tools, this is workspace authorization, not per-client
private storage.

The MCP lifecycle is `capabilities → create_draft/update_draft (or setup) → propose_seal → run →
wait/status/read → continue/clone/rerun`. It uses exactly the native experiment store, worker,
model selection, evaluator, immutable results and cancellation machinery. Preparation and search
are both supported. No experiment-wide deadline is introduced.

`run` sends the complete sealed plan and digest through **server-originated MCP form elicitation**.
The client must negotiate form elicitation and return explicit acceptance with `approve=true` in
that interaction response. That is not a `prompt_experiment` argument or an `approve` operation.
Decline, cancellation, stale digests, workspace changes, and late responses after cancellation do
not start execution. Clients without form elicitation receive an actionable unsupported-client
error, not an invisible native-card wait or automatic approval. Agent sessions may explicitly
choose `approval_mode=mcp`; their native-card path remains available. Future revisions require
fresh approval, and accepted runs record approval provenance as `mcpElicitation`.

### Upstream MCP optimization: a separate execution boundary

The pinned upstream [MCP example](https://github.com/gepa-ai/gepa/blob/0632cdb5dcc052e690eab439e1b4a7e3e9cfe407/src/gepa/examples/mcp_adapter/mcp_optimization_example.py)
uses `MCPAdapter` with `gepa.optimize`, mutable tool-description/system-prompt components, and
actual MCP server calls. It is a two-pass tool-selection/answer workflow, not RPCE native multi-turn
agent execution. The example's shared `/tmp/mcp_test` fixture and substring grader are teaching
examples, not isolation or quality gates to copy into the app.

The `mcp_adapter` execution path now wraps that actual upstream adapter as the evaluator used by
our existing `optimize_anything` search. It does not replace GEPA's optimizer. The candidate changes
one selected component (`system_prompt` or `tool_description_<tool>`), not schemas, executable,
permissions, model selection, or the grader. Preparation batches use this same real tool path.

The mutable component is not treated as a standalone prompt. Before search, the worker renders the
exact pinned MCPAdapter system-prompt template with a unique mutable-slot marker and adds that
composition contract to GEPA's background. The fixed scaffold already contains tool descriptions,
full JSON schemas, examples, and the call/answer JSON protocol. Each evaluation verifies that the
actual system message equals the deterministic render and records candidate bytes, fixed-scaffold
bytes, rendered-system bytes, digests, insertion count, pass count, total transmitted prompt bytes,
and candidate/scaffold four-gram overlap. This makes duplication and marginal prompt cost visible
without pretending that provider token accounting is available.

The composition contract also discloses both exact message layouts: pass one is the rendered system
prompt plus the example input; after a tool call, pass two repeats both and appends the upstream
assistant tool-result wrapper plus final-answer request. This is the behavior under optimization,
not a claim that the mutable component alone can call tools.

Candidate quality and rendered system size remain separate dimensions. The worker records the
non-dominated quality/size Pareto frontier; `best_candidate_index` is retained as upstream GEPA's
highest-quality index for compatibility, not as an automatic product choice. RPCE does not invent a
hidden scalar weighting or tolerance. Reviewers should inspect regressions and attempt to distill a
verbose improvement before promotion.

### Current executable boundary

- A reviewed project snapshot is mandatory; it can come from any authorized loaded project.
- The server is the packaged `repoprompt-mcp --backend headless`, never the running app's MCP endpoint.
- Choose a nonempty subset of `read_file`, `file_search`, `get_file_tree`, `get_code_structure`,
  and `apply_edits`.
- Sealing captures canonical tool definitions and the executable SHA-256; startup rejects drift.
- Each evaluation has a fresh profile, scratch cwd, and copy of the reviewed project snapshot.
  Reads and optional `apply_edits` mutations are confined to that disposable copy; the reviewed
  source snapshot is re-hashed after execution and must remain unchanged. Network is denied. The
  headless server registers only the sealed allowlist and starts no child-agent endpoint. Remote and
  arbitrary custom MCP servers are not supported yet.
- Target inference remains text-only through connected RPCE providers. Upstream interprets the
  tool-choice JSON and performs at most one real tool call, followed by at most one answer call.
  This is not native provider tool calling or multi-agent execution.
- Host-issued evaluation IDs bind public examples and candidates to the sealed attempt. Host
  admission bounds evaluations and two ordered target-model calls; the evaluation ID remains admitted until grading and scored-evidence persistence succeed.
  Expected answers and reviewer notes are never sent to the task model or tool server. The fixed
  rubric stays with the host grader. Reviewed training/validation feedback may cite reference
  answers to support reflection; hidden-test feedback is withheld and only its score returns.
- PID start/close events are persisted through existing attempt diagnostics. Successful evidence
  includes actual MCP arguments/results, model passes, prompt-surface composition, isolated
  mutations, timings, and exit observation. Partial local
  trajectories live under the attempt's `gepa-output/mcp-eval-*` directory. Stderr is drained and
  counted without including payloads in diagnostics. Infrastructure failures escape upstream's
  exception-to-zero-score fallback; malformed choices and tool-level errors are candidate failures.
- This first path is serial. An experiment's control plane remains separate from candidate tools.

### Example configuration fragment

```json
"execution": {
  "adapter": "mcp_adapter",
  "target_selector": "<exact selector from capabilities>",
  "instructions": "Use the supplied project evidence to answer the question.",
  "mcp": {"tool_names": ["read_file", "file_search"], "component": "system_prompt"}
}
```

Use the normal `project_snapshot`, reviewed examples, evaluator, preparation/search stage and
GEPA settings around this fragment. Read capabilities for the actual model catalog. MCP control
clients still review the complete sealed plan and respond to form elicitation; no tool argument
can approve execution or apply a winner.

### Bundled dependencies and validation

`mcp-dependencies.lock.json` pins MCP **1.30.0** plus all 28 dependency distributions by exact wheel,
size and SHA-256 for each architecture. Packaging extracts verified wheels, never runs pip or
builds dependencies, and preserves each distribution's license/metadata files. Both assembled
runtime trees are pinned by the existing manifest. GEPA itself retains its dependency-free host-
callback package metadata; the complete runtime is no longer dependency-free.

After a coordinated MCP build, run `Scripts/test_mcp_prompt_experiment_worker.py` with the assembled
bundled interpreter. It uses actual upstream MCPAdapter and headless RPCE with deterministic host
model replies; it is transport/isolation evidence, not model-quality evidence. Provider-backed
MCP approval-to-execution and optimization quality require separate live runs.

### Prompt-only callback capability and incremental evidence

Connected Codex prompt-only execution, reflection, and judging are currently rejected before worker/provider launch: its public app-server contract does not provide a blanket native-tool deny control. No model is silently substituted. Ordinary Codex Agent and Context Builder execution remain unchanged. Claude-compatible prompt-only profiles explicitly pass an empty built-in tool allowlist in addition to the run-scoped MCP denial policy; a static blacklist is not the isolation boundary.

Each connected-model invocation is checkpointed as started, then completed or failed. Available input/output usage is stored per invocation; null is unavailable, not zero. Each scored evaluation saves its candidate/output artifacts and feedback before the host releases its result to GEPA. `read`/`wait` expose `model_calls` and `partial_evaluations`, including after later infrastructure failure. Partial evaluations are not optimizer rankings or a fabricated final result; candidate artifacts establish their identity. Canonical save failure stops callback progression rather than acknowledging unsaved evidence. Historical records are not backfilled.


## Guided starting point and evidence-driven continuation

The workflow first asks whether to use supplied instructions or let upstream GEPA
create the initial candidate. `starting_point` records `supplied` or `gepa`; new
interactive drafts use `choose` until that decision is made. Historical records
omit the optional field and retain their original digests. `gepa` requires search
with `seed_candidate` omitted; it must not silently receive an agent-authored seed.
Supplied text may run focused preparation probes (one candidate/case is valid).

`status`/`read` now expose `guidance`: an action, explanation and current-revision
non-hidden evidence IDs. It distinguishes runtime failures, active execution,
cancellation, candidate failures, missing evidence, saturated measurements, and
semantic review. This is deterministic triage, not a quality threshold or an
execution grant. The agent reads the actual traces, diagnoses the responsible
layer, records a revision rationale in the next draft background, and proposes the
smallest useful next probe. It must not treat failure counts as a substitute for
understanding the task or feed hidden-test outcomes into development.

Continuing preparation retains preparation with the selected candidate; it no
longer silently advances to search. Moving to search is an explicit draft change.
Seedless search remains first class and does not require an agent-written baseline.
Model calls, dataset changes and execution remain inside existing digest-approved
revision boundaries. **An approval currently covers one reviewed batch, not an
open-ended multi-revision preparation budget.** New revisions still require approval;
these changes do not introduce an adaptive spending grant.

The September live repair tests exposed two distinct gaps: authentication errors
could be mistaken for model text, and the upstream one-tool/two-pass MCP adapter
was a poor fit for some iterative source-reading answers. Neither is evidence
that a larger GEPA budget is needed. Protocol and provider boundary repairs remain
separate from choosing or optimizing task instructions.


## Bounded grading recovery

`gepa.max_judge_retries` is part of the approved specification/digest. It allows
0–10 additional judge calls across the entire run, **at most one per evaluation**.
New native drafts propose 3; omitted values and historical seals authorize zero.
The allowance repairs only a completed judge response with invalid score JSON.
It does not retry authentication, transport, cancellation, or storage failures,
and never changes models, rubric, target output, or evaluation budgets.

Before invoking the judge, the canonical store saves target output and candidate
artifacts in `gradingEvidence`. Each grading attempt records its state; raw judge
responses are retained in host-private artifact history, not MCP/proposer text.
MCP `grading_evidence`, native cards, and the report expose states and retry counts.
Hidden-test target output is withheld from this development projection.
Cancellation settlement marks pending grades cancelled without inventing scores.
Unknown token usage remains unknown; additional judge invocations are in the same
model-call ledger as original invocations. Storage failures stop spending.

The upstream worker still exits after an unrepaired infrastructure failure.
**Exact post-exit GEPA resume is not implemented by this change.** `continue` is
a new approved revision from retained candidate evidence, not restoration of the
optimizer checkpoint. Do not delete or overwrite interrupted-run artifacts, claim
a final winner from partial scores, or rerun successful target work merely to
repair a missing grade. Faithful resume needs upstream-state compatibility,
durable callback/score reconciliation, remaining-budget accounting, and an
explicit recovery operation. Arbitrary project-provided pickle checkpoints must
never be loaded.

The MCP reflection model now receives the pinned adapter's immutable two-pass
JSON protocol, including seedless generation. Headless `file_search` now honors
`context_lines` (0–1000), returns numbered context lines, and explicitly reports
when its additional-context byte budget is truncated rather than silently
returning only matching lines.

### Opt-in live grading pause and retry

`gepa.pause_on_grading_failure=true` changes the sealed recovery behavior from
an automatic invalid-JSON repair to an explicit live decision. New native drafts
propose this flag; omitted/false retains historical behavior. The run-wide
`max_judge_retries` allowance and at-most-one-extra-call-per-evaluation limit are
unchanged. A pause is offered only while an extra call remains, after the target
output and initial judge failure have been committed. It is not offered for
cancellation or canonical persistence failure.

The live callback stays blocked in the original GEPA worker. `status`/`read`
show `grading_evidence.state=awaiting_retry`; `wait` returns on that decision.
The owner calls `retry_grading` with the exact experiment, plan digest and
`grading_id`, or uses **Retry grading — 1 judge call** in the native card/library.
The action consumes already approved budget; it grants no new budget, provider,
rubric, target execution, or promotion authority. Provider failures require
inspection before an explicit retry; no transport/auth errors are automatically
retried. The saved output and sealed judge/rubric are reused, with a fixed retry
instruction requesting valid evaluator JSON.

Duplicate or stale retry requests fail without another model call. Cancellation
and worker death release the pending callback. The callback watchdog excludes
only deliberately paused time (not provider execution), using a monotonic clock.
There is no recovery deadline and no model spend while paused. The worker retains
the live run slot; cancel it before starting another search.

This is **live callback recovery**, not post-exit checkpoint resume. It never
loads pickle or relaunches an optimizer. Historical failed runs remain unchanged.
App restart marks an in-flight run interrupted and does not reconstruct a retry
lease. If the one allowed retry also fails, evidence remains saved and the normal
failed-attempt path settles the worker; no winner is manufactured.

Pause metadata is additive (`awaitingRetry`) over the existing persisted judge
failure state; no new on-disk enum case prevents older debug builds from reading
the evidence. MCP projects this metadata as `awaiting_retry`. Worker settlement
and app-start reconciliation clear the live flag while retaining the history.
