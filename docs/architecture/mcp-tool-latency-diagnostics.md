# MCP tool end-to-end latency diagnostics

This document is the maintained execution contract for the W0-W2 measurement foundation in the local plan `docs/plans/mcp-tool-end-to-end-latency-2026-07-29.md`. It does **not** authorize or implement W3-W7 production optimizations.

The WI-3 investigation at `docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md` remains authoritative for lane capacities, work-count surfaces, and declared concurrency matrices. The committed matrix transcribes that authority; it is not a replacement baseline. A DEBUG run records before/after runtime and admission snapshots, projects counter deltas and gauges, and stamps only WI-3 workload IDs actually executed by that run.

## Executor and behavior invariants

| Stage owner | Executor / authority |
| --- | --- |
| `MCPConnectionManager` | server actor and task-local stable request identity |
| `MCPFileToolProvider` | `@MainActor`; observation only |
| `WorkspaceFileContextStore` | actor-isolated snapshot and catalog authority |
| `StoreBackedWorkspaceSearchLane` | actor-isolated FIFO admission |
| path-scope filtering | existing detached immutable work and cancellation checks |
| `ToolOutputFormatter` | synchronous caller executor |
| `UnixSocketMCPTransport` | transport actor and delivery gate |
| client recorder | DEBUG or explicit `MCP_LATENCY_TRACE` diagnostic build only |

Instrumentation must preserve the original await order, actor hops, cancellation checks, branch-local validation/error precedence, formatter nesting, text/resources/images/audio behavior, and thrown errors. Inclusive stages are validation envelopes. Only explicitly listed non-overlapping leaf stages and measured boundary intervals are ranked.

## Stable request identity and boundaries

Each runner invocation receives a fresh `_latencyTraceID` UUID. `MCPToolArgsNormalizer` removes this hidden field before provider argument validation while the DEBUG server request task and delivery transport retain the same identity. The runner joins client trace, stage buckets, lifecycle phases, and delivery phases by this UUID—never by tool name or event order.

The diagnostic client recorder measures C0 immediately before `session.callTool`, C1 when it returns or throws, and C2 after rendering/output writing. Ordinary `-c/-j` calls route through `InteractiveREPL.callToolSingleShot`; the persistent `-e` execution path routes through `MCPCommandRunner`/`ExecMCPService`. Both call the same recorder and formatter path. The internal `--latency-concurrent-batch` diagnostic command uses one shared `ClientSession` and concurrently dispatches declared requests; it is unavailable from ordinary production artifacts.

`RP_MCP_LATENCY_TRACE_PATH` must be an absolute, process-unique path. The recorder opens it append-only with `O_NOFOLLOW`, forces mode `0600`, and writes JSONL after C2. It records only invocation UUID, tool, diagnostic configuration, output format, timestamps/durations, content-block/text-byte counts, coarse outcome, and `is_error`. It never records arguments, paths, patterns, payload text, resources, images, or audio. Trace I/O failures do not alter the tool result.

A successful DEBUG or optimized-diagnostic sample must have exactly one request-identity event for every S0-S1, S1-S2, S2-S3, S3-S4, S4-S5, S5-S6, S6-S7, S7-S8, and S8-S9 endpoint, plus one C0-C2 trace. The selector's 15% server denominator is the inclusive `MCP.ToolCall.Received` through `transport_write_completed` S0→S9 interval. S7→S9 remains separately reported. Missing or duplicated identities/boundaries invalidate the cohort.

Repeated spans and dimension buckets are summed per request before percentiles are computed. `Search.ProviderTotal`, `Search.ProviderWorkspaceSearchAwait`, readiness-acquire, root-scope, and the physical search-tree span are inclusive envelopes. The runner derives a search core-scan remainder by subtracting the non-overlapping admission, freshness, readiness-acquire, and root-scope envelopes from `ProviderWorkspaceSearchAwait`; readiness-validation is already nested in the latter two. It separately derives combined readiness/scope-exclusive cost by subtracting validation and derives tree-exclusive cost by subtracting nested snippet spans. Only derived exclusive quantities—not their ancestor envelopes—may enter leaf selection. The static parent/child inventory forbids a physical ancestor from appearing in `LEAF_STAGES`.

Every retained leaf/inclusive bucket must carry an app invocation ID, including work created from detached tasks. Aggregation reports identified/unidentified counts per stage and rejects any unidentified bucket or any successful recorded request with no relevant stage bucket.

## Truly distinct formatted and raw calls

Every row is called twice with different request UUIDs:

- formatted: `_rawJSON` is absent and the ordinary CLI has no global `--raw-json` flag;
- raw: `_rawJSON=true` is supplied for that request and the redirected result must be exactly one text block containing valid JSON.

A successful pair must have distinct response digests. The formatted trace must report rendered non-empty text and the redirected formatted output must not itself be a JSON document. The raw trace must report exactly one text content block. These checks prevent a raw-only cohort from being mislabeled as formatted/raw evidence.

## Deterministic external fixtures

Python 3 is required. Generate fixtures outside this checkout; the generator rejects repository-local output and existing destinations.

```bash
make dev-mcp-latency MCP_LATENCY_ARGS='fixture --profile small --output /tmp/rpce-mcp-latency-small'
make dev-mcp-latency MCP_LATENCY_ARGS='fixture --profile medium --output /tmp/rpce-mcp-latency-medium'
make dev-mcp-latency MCP_LATENCY_ARGS='fixture --profile large --output /tmp/rpce-mcp-latency-large'
```

Profiles contain approximately 500 files/one root, 10,000 files/two roots, and 50,000 files/four roots. Each manifest pins the seed, root/file counts, byte count, maximum depth, expected search counts, and SHA-256 over sorted relative path/content pairs. Generated fixtures must not be committed.

The committed matrix is `Scripts/Fixtures/mcp-tool-latency/v1/matrix.json`. It covers tree roots/auto/full/folders/selected/subtree, path/content/regex/both/count-only/context/cap cases, workspace envelopes/raw controls, a read control, and gated worktree/readiness/timeout/large-full rows. Every executable row declares an expected outcome.

## Coordinated no-lifecycle entry points

`./conductor mcp-latency -- ...` is authoritative; `make dev-mcp-latency MCP_LATENCY_ARGS='...'` is its Make alias.

- `fixture` and `analyze` claim no daemon lanes.
- DEBUG `run` claims `debugArtifact` and `liveApp`; optimized `run` claims `mcpLatencyArtifact` and `liveApp`.
- None of these commands builds, launches, relaunches, or stops the app.
- `make dev-mcp-latency-debug-server-build` packages the DEBUG attribution app at `.build/mcp-latency/debug-server/RepoPrompt.app` without touching shared DebugApps.
- `make dev-mcp-latency-server-build` packages the isolated release-optimized diagnostic app and its matching client under the `build` + `mcpLatencyArtifact` lanes. Both builders perform no lifecycle action.
- `make dev-mcp-latency-client-build` remains a legacy client-only diagnostic builder and cannot satisfy the optimized-server gate.

Example warm DEBUG cohort after the fixture is open and ready:

```bash
make dev-mcp-latency MCP_LATENCY_ARGS='run \
  --configuration debug --cohort warm --profile small \
  --client-mode fresh --client-mode persistent \
  --window-id 1 \
  --fixture-root /tmp/rpce-mcp-latency-small \
  --fixture-manifest /tmp/rpce-mcp-latency-small.manifest.json \
  --output /tmp/rpce-mcp-latency-runs/debug-small-1 \
  --baseline /tmp/rpce-mcp-latency-runs/small-response-baseline.json \
  --update-baseline'
```

The matrix-declared warm discipline is authoritative: at least 3 discarded warmups, 3 repeats, and 30 recorded samples per repeat. Lower overrides are rejected. Persistent warmups and recorded calls use the same connection generation. A broken/closed/timed-out unexpected generation is discarded in full, a new connection is established, its warmups are rerun, and only the replacement generation may become evidence.

Server evidence uses `segmented_canonical_matrix_v1`: one bounded capture epoch for every deterministic ordinary `(row, client mode)` pair and one epoch for every enabled WI-3 workload. Each epoch begins from a reset recorder, executes no unrelated control calls, snapshots with `finish=true`, and writes a separately hashed artifact under `server-capture-segments/`. The manifest pins the complete ordered plan and its hash; every plan entry pins row, mode, format, phase, repeat/sample coordinate multiset, expected invocation count, artifact hash, and exact invocation IDs. The index must contain every entry once in order, and both manifests in a paired run must reconstruct to the same plan hash.

Each segment is validated independently for the capture contract, zero stage/lifecycle/delivery drops, exact request membership, exact sample coordinates, expected outcomes, terminal rules, connection integrity, and complete C0-C2/S0-S9 joins. Persistent CLI startup's real `bind_context` request is the sole classified setup exception: it must have a complete one-of-each S0-S7 lifecycle, `tool=bind_context` on every lifecycle/stage record, MCPToolCall-only stages, and its exact identity is retained in the segment index but excluded from workload evidence. Fresh connection protocol handshake delivery records and capture-begin delivery are likewise never joined as workload phases. A rejected connection generation may be retried only after its capture accounting and zero-drop checks pass; rejected raw evidence remains quarantined and never enters aggregates. Expected-timeout rows require exactly one correlated server terminal event. Missing, extra, duplicated, reordered, unclassified-foreign, hash-mismatched, active, dropped, or unfinished segments invalidate the entire campaign.

Offline aggregation reloads and re-hashes every segment, revalidates membership and boundaries, then concatenates request-level evidence before computing global percentiles and running the selector. It never averages per-segment percentiles or invents a cross-segment clock. Legacy monolithic snapshots may be retained as recovery evidence, but a paired production-authorizing result requires the complete segmented layout and canonical `fresh` plus `persistent` client modes.

Cold collection is explicitly one independently activated sample per run. This runner performs no activation:

```bash
make dev-mcp-latency MCP_LATENCY_ARGS='run \
  --configuration debug --cohort cold --activation-id activation-01 --cold-sample-index 1 \
  --profile small --client-mode fresh --window-id 1 \
  --fixture-root /tmp/rpce-mcp-latency-small \
  --fixture-manifest /tmp/rpce-mcp-latency-small.manifest.json \
  --output /tmp/rpce-mcp-latency-runs/debug-small-cold-01 \
  --baseline /tmp/rpce-mcp-latency-runs/small-cold-baseline.json'
```

Collect indices 1 through 10 under independently declared activations. Cold and warm samples are never mixed in one analyzed cohort.

Warm DEBUG runs execute the enabled WI-3 same-connection ordinary burst and distinct-connections/one-window cohorts concurrently. Other WI-3 matrices remain declared but are not stamped as executed until an implementation actually runs them. `--skip-wi3` is available for diagnostic iteration, but paired selection hard-fails unless both DEBUG and optimized runs executed the exact enabled WI-3 admission set and DEBUG captured its work-count evidence.

## Optimized diagnostic artifact and paired gate

Build the safe server/client artifact through the coordinated daemon:

```bash
make dev-mcp-latency-server-build
```

It uses Swift's `release` configuration with an isolated scratch path and emits only:

```text
.build/mcp-latency/optimized-server/RepoPrompt.app
.build/mcp-latency/optimized-server/artifact-manifest.json
```

This third packaging mode is neither DEBUG packaging nor ordinary release packaging. It uses the fixed `com.pvncher.repoprompt.ce.mcp-latency-diagnostic` bundle identifier, ad-hoc signing, alternate in-memory secure storage, host architecture, and no provisioning/Sentry/public universal/release-manifest/install/compatibility-link path. It rejects explicit release signing, Sentry, local self-signed release, and ordinary release diagnostic gates. Ordinary release packaging separately rejects either diagnostic compile gate. The builder never copies into the shared `DebugApps` bundle and never launches an app.

The server target defines only `MCP_LATENCY_DIAGNOSTICS`; its embedded client defines only `MCP_LATENCY_TRACE`; shared request identity code receives only the server diagnostic define. The optimized hidden server surface accepts the canonical diagnostics tool and exactly three payload-free/timing-only operations: server identity, capture begin, and capture snapshot. DEBUG aliases, runtime mutation, fault injection, restart/shutdown, fixtures, sleeps, update controls, and all other DEBUG operations are not compiled into this artifact. It records bounded sanitized timing stages, lifecycle boundaries, delivery events, drop counts, and process/artifact identity—never arguments or returned content.

The external manifest and embedded provenance record the artifact UUID, commit/dirty state, deterministic non-ignored source-tree fingerprint, exact target defines, release Swift configuration, fixed bundle/signing/storage identity, server and embedded-client paths/hashes, diagnostic surface, and explicit `ordinary_release_artifact: false`. At optimized collection start and end, the runner requires the running PID/bundle/executables/provenance to match that manifest byte-for-byte. The embedded client is mandatory; a PATH/debug/legacy client is rejected.

### Operator-approved live sequence

Building and analyzing are non-lifecycle operations. Launching or quitting either visible app requires explicit operator approval immediately before the action. Do not install either bundle over shared `DebugApps`.

1. Package the isolated DEBUG bundle (`make dev-mcp-latency-debug-server-build`) and optimized diagnostic bundle (`make dev-mcp-latency-server-build`). Neither command launches or installs an app.
2. With approval, launch the isolated DEBUG build directly (`open -n "$PWD/.build/mcp-latency/debug-server/RepoPrompt.app"`), open the declared workspace/fixture, wait for readiness, and record its window ID. Do not use `make dev-build`/`make dev-run`, because their normal DEBUG package path targets shared `DebugApps`.
3. Collect DEBUG first with the command shown above, adding `--cli "$PWD/.build/mcp-latency/debug-server/RepoPrompt.app/Contents/MacOS/repoprompt-mcp"`. The runner records DEBUG start/end identity and full C0-C2/S0-S9 capture.
4. With approval, quit only the visible DEBUG app (`osascript -e 'tell application id "com.pvncher.repoprompt.ce.debug" to quit'`) and verify its exact executable is gone. Ensure no ordinary release RepoPrompt app is using the release socket; stopping one is a separate operator-approved action.
5. With approval, launch the isolated artifact directly:

   ```bash
   open -n "$PWD/.build/mcp-latency/optimized-server/RepoPrompt.app"
   ```

   Open the identical workspace/fixture, wait for equivalent readiness, and record the optimized app's window ID.
6. Collect the optimized cohort with the identical matrix, fixture, client modes, profile, and sample discipline:

   ```bash
   make dev-mcp-latency MCP_LATENCY_ARGS='run \
     --configuration optimized --cohort warm --profile small \
     --client-mode fresh --client-mode persistent \
     --window-id 1 \
     --server-artifact-manifest .build/mcp-latency/optimized-server/artifact-manifest.json \
     --fixture-root /tmp/rpce-mcp-latency-small \
     --fixture-manifest /tmp/rpce-mcp-latency-small.manifest.json \
     --output /tmp/rpce-mcp-latency-runs/optimized-small-1 \
     --baseline /tmp/rpce-mcp-latency-runs/small-response-baseline.json'
   ```

7. Analyze only after both complete:

   ```bash
   make dev-mcp-latency MCP_LATENCY_ARGS='analyze \
     --debug-input /tmp/rpce-mcp-latency-runs/debug-small-1 \
     --optimized-input /tmp/rpce-mcp-latency-runs/optimized-small-1 \
     --output /tmp/rpce-mcp-latency-runs/paired-small.json'
   ```

8. With approval, quit only the diagnostic bundle (`osascript -e 'tell application id "com.pvncher.repoprompt.ce.mcp-latency-diagnostic" to quit'`).

Paired analysis requires the completed DEBUG cohort to predate optimized collection; identical commit/source fingerprint/profile/cohort/matrix/fixture/sample discipline/canonical fresh-plus-persistent modes/WI-3 authority; the same verified complete segmented plan and index contract; stable, distinct, process-authoritative server identities; exact optimized manifest/bundle/executable/client/provenance identity; zero capture drops; matching enabled WI-3 cohorts; DEBUG work-count evidence; and exact response signatures. It runs the strict selector independently on DEBUG and optimized server-stage evidence. Only the same single selected candidate in both configurations can emit `production_authorized: true`. DEBUG-only, legacy client-only, identity-unstable, mismatched, dropped, or disagreeing evidence remains non-authorizing. This authorizes investigation/implementation of exactly one candidate under the plan; it does not turn diagnostics into product authority or waive that candidate's before/after regression gates.

## Reliability, parity, and selector rules

A run is invalid for any of the following:

- unexpected cancellation, timeout, transport closure, or missing/duplicate client trace;
- any sample retained after a terminal event on the same connection;
- active or dropped DEBUG or optimized-diagnostic capture data;
- missing/duplicated request-identity lifecycle or delivery joins;
- unidentified leaf/inclusive stage buckets or a successful request with no relevant stage bucket;
- formatted/raw identity, block-shape, JSON-shape, or digest violations;
- exact response baseline keys, bytes, counts, or DEBUG WI-3 work-count parity drift;
- trace JSON containing forbidden payload field names.

Expected timeout rows are isolated as terminal cohorts. Never interpret a fast transport failure as latency.

`aggregate.json` reports request-level leaf P50/P95; every S0-S9 and C0-C2 boundary; inclusive envelopes; explicit remainders; S5-C2 attribution; the named S0→S9 eligibility denominator plus the separately reported S7→S9 boundary; stage-attribution completeness; and executed WI-3 evidence. A server-observed terminal event correlated to a retained request connection invalidates the capture even if the client appeared successful. The paired selector applies the plan thresholds independently to DEBUG and optimized exclusive request costs with real S0-S9 and optimized persistent C0-C2 denominators. It maps at most one dominant fully-qualified stage and authorizes it only when both configurations agree; analysis never edits production code.

Exact Swift parity covers multi-file search ordering/gaps/omissions, duplicate groups, tree modes/markers, malformed workspace fallback, multi-block edit output, raw JSON, and the precise observer `Value`. Guardrails run `python3 Scripts/test_mcp_tool_latency.py` plus `python3 Scripts/test_mcp_latency_diagnostic_artifact.py`, covering deterministic fixtures, declared sampling, exact keyset parity, formatted/raw separation, connection invalidation, request-identity joins, repeated-span aggregation, selector refusal/authorization, WI-3 stamping, capture-drop rejection, isolated paths, exact target defines, and manifest hashes.
