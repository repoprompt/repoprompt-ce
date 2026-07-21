# Local-first structured failure diagnostics

`conductor` now writes a small, versioned failure record for every terminal job
and exposes a read-only `conductor diagnostics recent-failures` query.

## Goals

- Keep structured, recent-failure context locally on the worktree.
- Never copy raw log text, source content, prompts/transcripts, credentials, or
  environment dumps into aggregate records.
- Provide a bounded taxonomy and retention so the surface stays stable and
  privacy-safe.

## On-disk record

For each terminal job, `conductor` writes a sibling file next to the job log:

```text
<jobs_dir>/<ticket>.failure.json
<jobs_dir>/<ticket>.summary.json
```

The aggregate record (`<ticket>.failure.json`) is intentionally small and
referential. It contains:

- Schema identity (`schemaVersion`, `schemaLineage`).
- Job identity and timing (`ticket`, `operation`, `lanes`, `createdAt`,
  `startedAt`, `finishedAt`, `queueWaitSeconds`, `executionSeconds`, ...).
- Terminal state and exit code.
- `exitClass` and `failureClass` with a short `failureClassReason`.
- A bounded `toolchainKnownMetadata` object (selected build toolchain env keys
  only: `CC`, `CXX`, `DEVELOPER_DIR`, `SDKROOT`, `SWIFT_EXEC`, `TOOLCHAINS`).
- A `resourceSummary` reference to the persisted summary file, including
  `headline`, `summarySectionTitles`, `errorCount`, `warningCount`,
  `logLineCount`, `truncated`, and `launchLifecycle`.
- The local `localLogPath` and `diagnosticPaths`.

The full output summary is written to `<ticket>.summary.json` and referenced,
not embedded, so the aggregate record stays small.

## Schema versioning

The record format is versioned with a `schemaVersion` and a `schemaLineage`
(`"repoprompt-ce.failure-record"`).

- Backward compatible: a reader may load older records with the same lineage.
- Forward safe: a reader must skip records whose `schemaVersion` is newer than
  it understands, and records whose `schemaLineage` is foreign.

This mirrors the `GlobalSettingsDocument` schema versioning approach in the
Swift codebase.

## Classification

`failureClass` is assigned conservatively from current evidence:

| Class | Evidence |
|-------|----------|
| `none` | `completed` with exit code 0. |
| `cancellation` | Job state `canceled` or exit code 130, including superseded. |
| `timeout` | `timedOut` or exit code 124. |
| `sourceMutatedBuild` | `launchLifecycle.sourceChangedDuringBuild` is true. |
| `compilerFailure` | Summary contains `Swift compiler errors`. |
| `testFailure` | Summary contains `Test failures`. |
| `processCleanupFailure` | Error message contains SIGKILL cleanup failures. |
| `infrastructureOrRPCFailure` | `measurementInvalid`, exit code 70, or `daemon runner error`. |
| `heavyLaneWait` | Waited >= 30s for a global heavy slot before process start. |
| `unknown` | No recognized evidence. |

`exitClass` is a separate, bounded field derived from `state`, `exitCode`, and
`timedOut`/`measurementInvalid`.

## Retention

`FailureRecordStore` enforces the same retention as terminal jobs:

- Maximum `200` records.
- Maximum age `24` hours.

The store deletes expired records and orphaned `.summary.json` files during its
retention pass. `conductor` runs the store's retention pass on daemon startup
and after each record write.

## Query surface

The query is read-only and does not require the daemon:

```bash
./conductor diagnostics recent-failures [--limit <n>] [--operation <op>] [--failure-class <class>] [--hours <n>] [--json]
```

Results are newest-first, filtered by optional operation and failure class, and
limited to the requested window.

## Implementation

- `Scripts/failure_diagnostics.py` — the record, store, classification, and
  rendering logic.
- `Scripts/conductor.py` — writes records in `_refresh_output_summary` and
  serves the `diagnostics recent-failures` command.
- `Scripts/test_conductor_failure_diagnostics.py` — focused unit tests for
  classification, schema, retention, query, and redaction.

## Privacy notes

- `toolchainKnownMetadata` is filtered to a fixed allow-list of build toolchain
  identifiers; no broad `PATH`, `HOME`, `USER`, or signing secrets are captured.
- The aggregate record never contains the raw job log, full source lines, or
  prompt/transcript content. Those remain in the local log and summary files.
