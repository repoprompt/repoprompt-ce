# Prompt Experiments and upstream GEPA

Prompt Experiments is a DEBUG-gated, Agent-first optimization workflow. It keeps RepoPrompt's existing session, model catalog, provider, Context Builder, persistence, and native approval authorities while delegating candidate search to the real upstream `gepa.optimize_anything` implementation.

## User flow

1. Start the **Prompt Experiment** Agent workflow from the normal new-session workflow picker.
2. Describe the workflow or prompt behavior to improve. The Agent inspects only already-authorized context, asks for missing success criteria, and proposes reviewed examples, an evaluator, exact connected-model selectors, and budgets through the `prompt_experiment` tool.
3. Review the in-session native Prompt Experiment card. Approval is bound to the displayed immutable plan digest; the Agent tool cannot approve, start, stop, or apply a winner.
4. Start the run from that card. Progress, baseline and candidate scores, per-example feedback, failures, usage availability, and stop settlement remain visible and durable.
5. Reopen a past result or create the next revision from a stored candidate. Changed data, evaluator, permissions, targets, or budgets produce a new digest and require new native approval. Applying a winner is a separate explicit operation and is not automatic.

The former title-bar flask entry and modal form are intentionally not the primary workflow. The read-only experiment library remains available from the result card for reopening history.

## External pinned environment

RepoPrompt does not bundle Python, install packages, or own provider credentials in the worker. Configure an external virtual environment explicitly:

```bash
python3 -m venv "$HOME/Library/Application Support/RepoPrompt CE/GEPA/0.1.4-0632cdb5"
"$HOME/Library/Application Support/RepoPrompt CE/GEPA/0.1.4-0632cdb5/bin/python" -m pip install \
  'gepa @ git+https://github.com/gepa-ai/gepa.git@0632cdb5dcc052e690eab439e1b4a7e3e9cfe407'
```

Provide that environment's Python executable in the proposed optimization specification. `REPOPROMPT_GEPA_PYTHON` may supply the default when the app process is launched from a developer environment, but the sealed specification always records the exact executable path. Preflight checks the executable, package version `0.1.4`, PEP 610 installed git revision, worker resource, model catalog selections, evaluator shape, and budgets before a plan can be approved. Preflight neither installs dependencies nor makes model calls.

## Ownership and protocol

- `PromptExperimentService` is the single writer for experiment scheduling, immutable plan revisions, approvals, evidence references, and cancellation observations.
- Existing Agent Mode and Context Builder runtime code remains the authority for sessions and connected-model requests. Exact resolved catalog targets are sealed without changing global role defaults.
- `PromptExperimentGEPAWorker` runs the packaged, versioned NDJSON bridge with the configured external interpreter. The worker calls upstream `optimize_anything`; reflection and evaluation model requests synchronously round-trip to the app.
- The worker receives an allowlisted process environment only. Provider credentials, authentication configuration, workspace bindings, and source paths are not passed to Python.
- Canonical experiment JSON and content-addressed artifacts live under Application Support. Human-readable Markdown/CSV views are derived projections; projection failure degrades export state without rolling back a successful canonical commit.

The Python request/result protocol is version 1 and the sealed plan schema is version 2. Existing version 1 comparison records remain readable and are never rescored during migration.

## Isolation and failure semantics

Reviewed examples are materialized into a fresh app-owned environment. Context Builder trials bind only that isolated root and use the existing native-tool restrictions. Direct loaded-workspace optimization is rejected rather than described as isolated.

The command adapter writes only into an app-created evaluation workspace and requires `/usr/bin/sandbox-exec`. Its Seatbelt profile denies by default, admits required system reads and that workspace, and does not admit network or the user's source checkout. Hosts without the sandbox fail closed.

Candidate failures are reviewable feedback and may receive an evaluator-defined score. Transport, worker, provider, sandbox, or other infrastructure failures are inconclusive and are never silently converted to score zero or automatically retried. Stop requests cancel and drain app-owned provider requests before the Python worker is interrupted; requested and settled states remain distinct.

## Current capability limits

- Context Builder and the generic sandboxed-command adapter are implemented. Investigate and multi-agent adapters are schema-compatible extension points, not currently implemented capabilities.
- Reviewed inline examples are supported; automatic source-workspace snapshot authoring is not.
- GEPA-reported candidate lineage, scores, feedback, wall time, and app-exposed timing are retained. Connected-provider token usage is labeled unavailable when the completion contract does not expose it; unavailable never means zero.
- Deterministic fake-provider and pinned-worker tests validate integration and authority boundaries. They do not establish live provider quality or visible UI behavior.
