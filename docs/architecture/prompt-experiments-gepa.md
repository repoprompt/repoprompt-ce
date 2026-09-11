# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-gated, Agent-first optimization lab. It keeps RepoPrompt's existing session, model catalog, provider, Context Builder, persistence, native approval, and cancellation authorities while delegating candidate search to the real upstream `gepa.optimize_anything` implementation.

## Session-driven user flow

1. Start the **Prompt Experiment** Agent workflow from the normal new-session workflow picker and describe the workflow or prompt behavior to improve.
2. The Agent asks for missing goals or success criteria and uses the `prompt_experiment` session tool to set up and revise a bounded proposal with reviewed examples, evaluator, exact connected-model selectors, project inputs, permissions, and an evaluation-count budget. New proposals have no experiment-wide wall-clock deadline.
3. The Agent calls `run` with the exact sealed digest. That same tool call remains pending while its native in-session card exposes every serialized field of the immutable authority. The Agent cannot approve itself.
4. **Approve & Run exact proposal** authenticates the native user action, validates the digest and owning session again, and starts automatically. **Request changes** denies that request and returns a new draft revision to the waiting conversation. Closing or cancelling the session cancels its pending request rather than creating ambient approval.
5. The resumed Agent uses bounded `wait` or `status` operations to receive progress and terminal results, then explains the evidence and proposes an iteration. `cancel` is owner- and digest-bound. The card remains the visible progress/results surface; no external console or follow-up user nudge is required.
6. **Continue best**, **Run again**, and **Clone as draft** create reviewable drafts. Any changed data, evaluator, permissions, targets, model, or budget produces a new digest and requires a new native approval. Applying a winner remains separate and is never automatic.

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

The Python request/result protocol is version 1 and the current sealed optimization plan schema is version 4. Existing comparison schema v1 and optimization schema v2/v3 records remain readable, retain their exact digest-bound wall-clock limits, are never rescored or rewritten during migration, and must be cloned or continued into a schema-v4 draft before execution. Creating that new draft intentionally omits the historic deadline while leaving the source plan untouched.

## Reviewed inputs and isolation

A proposal may combine reviewed inline examples with a bounded project snapshot. Snapshot paths are relative, traversal-free regular files selected from an authorized loaded root; at most the schema-defined file count and byte limits are copied into a fresh app-owned immutable environment. The source root, included path list, copied-file sizes and SHA-256 digests, and aggregate environment digest are sealed for native review. Later source changes do not change the run copy, and evaluation never writes the original project.

Only the current non-hidden input and candidate reach reflection/execution model calls. Hidden-test expected output and reviewer notes remain host-side grader data. Context Builder binds only the isolated materialized root and uses the existing native-tool restrictions. Direct loaded-workspace execution is rejected rather than described as isolated.

The command adapter receives the sealed project copy plus the current example inside an app-created evaluation workspace and requires `/usr/bin/sandbox-exec`. Its Seatbelt profile denies by default, admits required system reads and that workspace, denies network, strips ambient credentials, and does not admit the user's source checkout. Hosts without the sandbox fail closed.

## Failure and cancellation semantics

Candidate failures are reviewable feedback and may receive an evaluator-defined score. Transport, worker, provider, sandbox, or other infrastructure failures are inconclusive and are never silently converted to score zero or automatically retried. New runs end through their evaluation budget, an evaluator stop score, user/session cancellation, or runtime settlement—not an experiment-wide silence timer. Individual connected-model and sandbox-command operations retain separate bounded guards. Denied or stale approvals cannot start. Stop requests cancel and drain app-owned provider requests before the Python worker is interrupted; requested and settled states remain distinct, and bounded wait operations return durable progress or terminal status without imposing a run lifetime.

## Current capability limits

- The connected-model, Context Builder, and generic sandboxed-command execution adapters are implemented. Dedicated Investigate and multi-agent adapters remain explicit follow-ups rather than being simulated by prompt text.
- Project snapshots require an already-authorized loaded root and an explicit reviewed relative-path list; automatic repository-wide discovery, unreviewed glob expansion, and live source editing are not supported.
- GEPA declares no required Python dependencies at the pinned revision. Optional provider integrations are deliberately not installed because RepoPrompt owns provider calls.
- GEPA-reported candidate lineage, scores, feedback, elapsed wall time, and app-exposed timing are retained as evidence, not used as a deadline. Connected-provider token usage is labeled unavailable when the completion contract does not expose it; unavailable never means zero.
- Diagnostic protocol logs store event metadata only and exclude request/response payloads. Arbitrary worker stderr is redacted while fixed framework progress lines may be retained; logs are bounded and every run gets a durable diagnostic record before its first evaluation.
- Deterministic fake-provider, handler, interaction, and pinned-worker tests validate integration and authority boundaries. They do not establish live provider quality or visible UI behavior.
