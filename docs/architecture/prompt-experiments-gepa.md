# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-gated, Agent-first optimization workflow. It keeps RepoPrompt's existing session, model catalog, provider, Context Builder, persistence, and native approval authorities while delegating candidate search to the real upstream `gepa.optimize_anything` implementation.

## User flow

1. Start the **Prompt Experiment** Agent workflow from the normal new-session workflow picker.
2. Describe the workflow or prompt behavior to improve. The Agent inspects only already-authorized context, asks for missing success criteria, and uses the `prompt_experiment` tool to create and revise a bounded proposal with reviewed examples, an evaluator, exact connected-model selectors, project inputs, and budgets.
3. Review the in-session native Prompt Experiment card. Its human summary is accompanied by selectable, pretty-printed JSON for every field in the immutable plan. Approval is bound to that plan's displayed digest; the Agent tool cannot approve, start, stop, or apply a winner.
4. Start the run from that card. Progress, baseline and candidate scores, per-example feedback, failures, usage availability, and stop settlement remain visible and durable.
5. Reopen a past result from the card's experiment library. **Continue best** creates a revision seeded by the selected winner, **Run again** creates a revision with the same seed, and **Clone as draft** creates a separate experiment. Any changed data, evaluator, permissions, targets, or budget produces a new digest and requires new native approval. Applying a winner remains a separate explicit action and is not automatic.

The former title-bar flask entry and modal form are intentionally not the primary workflow. The experiment library is available from the result card for reopening history.

## External pinned environment

RepoPrompt does not bundle Python, install packages, or give provider credentials to the worker. GEPA 0.1.4 declares Python `>=3.10,<3.15`; do not assume Apple's or Xcode's `/usr/bin/python3` is compatible. Choose an installed compatible interpreter and check it before explicitly creating the native-configured environment:

```bash
python3.11 -c 'import sys; assert (3, 10) <= sys.version_info < (3, 15), sys.version'
python3.11 -m venv "$HOME/Library/Application Support/RepoPrompt CE/GEPA/venv"
"$HOME/Library/Application Support/RepoPrompt CE/GEPA/venv/bin/pip" install -r \
  AppResources/PromptExperiments/gepa-requirements.txt
```

`gepa-requirements.txt` pins GEPA to upstream revision `0632cdb5dcc052e690eab439e1b4a7e3e9cfe407`, but it is not a complete hash lock: pip resolves transitive dependencies during the explicit install. `REPOPROMPT_GEPA_PYTHON` can select another reviewed environment for the DEBUG app. The sealed specification always records the exact interpreter path. Preflight checks that exact executable, package version `0.1.4`, PEP 610 installed git revision, worker resource, connected model selections, evaluator shape, and budgets before execution. Preflight neither installs dependencies nor makes model calls.

## Ownership, adapters, and protocol

- `PromptExperimentService` is the single writer for experiment scheduling, immutable plan revisions, approvals, evidence references, and cancellation observations.
- Existing Agent Mode and Context Builder runtime code remains the authority for sessions and connected-model requests. Exact resolved catalog targets are sealed without changing global role defaults.
- The execution adapter is explicitly sealed as one of three implemented paths: `connected_model` for a prompt-only connected Agent provider completion, `context_builder` for a native Context Builder run in the isolated environment, or `sandboxed_command` for a reviewed command under Seatbelt.
- Evaluators are likewise explicit: host-side exact match, a prompt-only connected-model judge with a sealed rubric and target, or the paired sandboxed-command evaluator.
- `PromptExperimentGEPAWorker` runs the packaged, versioned NDJSON bridge with the configured external interpreter. The worker calls upstream `optimize_anything`; reflection and model-backed execution/evaluation synchronously round-trip to app-owned provider routes.
- The worker receives an allowlisted process environment only. Provider credentials, authentication configuration, workspace bindings, and source paths are not passed to Python.
- Canonical experiment JSON and content-addressed artifacts live under Application Support. Human-readable Markdown/CSV views are derived projections; projection failure degrades export state without rolling back a successful canonical commit.

The Python request/result protocol is version 1 and the current sealed optimization plan schema is version 3. Existing comparison schema v1 and optimization schema v2 records remain readable, are never rescored during migration, and must be cloned into a current draft before execution.

## Reviewed inputs and isolation

A proposal may combine reviewed inline examples with a bounded project snapshot. Snapshot paths are relative, traversal-free regular files selected from an authorized loaded root; at most the schema-defined file count and byte limits are copied into a fresh app-owned immutable environment. The source root, included path list, copied-file sizes and SHA-256 digests, and aggregate environment digest are sealed for native review. Later source changes do not change the run copy, and evaluation never writes the original project.

Only the current non-hidden input and candidate reach reflection/execution model calls. Hidden-test expected output and reviewer notes remain host-side grader data. Context Builder binds only the isolated materialized root and uses the existing native-tool restrictions. Direct loaded-workspace execution is rejected rather than described as isolated.

The command adapter receives the sealed project copy plus the current example inside an app-created evaluation workspace and requires `/usr/bin/sandbox-exec`. Its Seatbelt profile denies by default, admits required system reads and that workspace, denies network, strips ambient credentials, and does not admit the user's source checkout. Hosts without the sandbox fail closed.

## Failure and cancellation semantics

Candidate failures are reviewable feedback and may receive an evaluator-defined score. Transport, worker, provider, sandbox, or other infrastructure failures are inconclusive and are never silently converted to score zero or automatically retried. Stop requests cancel and drain app-owned provider requests before the Python worker is interrupted; requested and settled states remain distinct.

## Current capability limits

- The connected-model, Context Builder, and generic sandboxed-command execution adapters are implemented. Dedicated Investigate and multi-agent adapters remain explicit follow-ups rather than being simulated by prompt text.
- Project snapshots require an already-authorized loaded root and an explicit reviewed relative-path list; automatic repository-wide discovery, unreviewed glob expansion, and live source editing are not supported.
- The GEPA direct dependency is revision-pinned and runtime-verified, but transitive Python dependencies are not yet reproducibly hash-locked.
- GEPA-reported candidate lineage, scores, feedback, wall time, and app-exposed timing are retained. Connected-provider token usage is labeled unavailable when the completion contract does not expose it; unavailable never means zero.
- Deterministic fake-provider and pinned-worker tests validate integration and authority boundaries. They do not establish live provider quality or visible UI behavior.
