# Streaming-tail baseline (M0)

This record is for contributors deciding whether to authorize a transcript rendering optimization. Authorization currently covers M0 measurement. M1 requires a separate decision.

## Protocol fixed before execution

- Source base: `c70e13541`, branch `perf/streaming-tail-invalidation-20261106`.
- Host: production `AgentModeDetailWithSidebarView` containing `AgentModeChatDetailView`, observing the VM's `ui.transcript` store. Install the root once in an unordered 1000 × 800 pt window. No visible window, app lifecycle, or live provider calls.
- Synthetic workload: 10/40/200 logical turns. Each turn has a rich user request, settled assistant opener, synthetic `read_file` call/result, and assistant conclusion. User requests contain a closed 48-line Swift fence and a three-column, 12-row Markdown table. The final conclusion starts with the same rich content and an open prose paragraph. IDs, sequence indices, dates and invocation IDs are deterministic.
- Use the production IO/presentation builder and expanded-history setting. Preserve normal grouping and retention. Report actual presented and mounted populations as the denominators for rendering counts.
- Readiness gate: observe body calls for rows in older history and the active turn. Require attached, row-scoped native storage with code/table markers and `NSTextTableBlock`, positive native measurement size, host layouts and native `ensureLayout` activity. Deadline: 60 seconds.
- Native calibration gate: mutate a mounted rich user marker through the bound store. Require an actual native update and changed attached storage, then restore and verify. No direct native mutation or forced drawing.
- After calibration: unmeasured chunk 00, then eight 128-byte tail chunks with unique markers and status, one revision/publication each. Require tail-body/status consumption and rendered marker. Wait for two quiet main-loop turns spanning the production coalescer interval. Deadline: five seconds per chunk.
- Three fresh-host repeats in orders 10/40/200, 40/200/10, 200/10/40 (72 measured chunks if all gates pass). Record body/native counts for stable older rows, stable active-turn rows and the tail. Also record host layouts, native draws, synchronous main-actor drive time, main-thread CPU time, and settling wall time. Preserve repeat means and median/min–max across repeats. No latency pass threshold.
- Stop at the first failed validity gate. Missing offscreen renderer evidence means **baseline unavailable**. Do not implement a new hosting mechanism or visible-window workaround without a design decision.

## Maintainer-guidance check

Streaming can make settled transcript rows do repeated work while a user reads. The store owns the presented snapshot. The frequency and cost of settled-leaf invalidation remain unknown. DEBUG hooks have a nil sink by default and an immutable diagnostic row scope. Main risks are offscreen suppression, bounded production history and probe overhead. The validation boundary is publication reaching the mounted production renderer.

## Execution record

**Baseline unavailable.** The native renderer calibrated successfully, but the production presentation converted the synthetic streaming tail to a non-streaming conclusion. The diagnostic rejected that input before chunk 00. There are **0 valid measured chunks, 0 completed repeats**, and no per-chunk timing or variance estimate. An unavailable result cannot establish zero stable-row work.

### Environment and validity findings

- Source base: `c70e135417d3d7de35a4738dd5f3d7c965f2b2ae`; DEBUG build, Apple M3 Max, arm64, macOS 27.2 (26B123).
- Compiler: Apple Swift 6.3.2 (`swiftlang-6.3.2.1.108`, clang `2100.1.1.101`), Xcode default toolchain. Explicit SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`. The implicit Command Line Tools SDK was incompatible with this compiler.
- The font was `normal`, the window content area was 1000 × 800 pt, and the focus environment was false. Each repeat installs the production parent once. No `rootView` reassignment, window ordering, forced drawing, visible-app lifecycle, live providers, or Oracle calls occurred.
- The 10-turn host presented 40 blocks and 46 rows. All 9 older rich-user witnesses and the active-turn rich-user witness passed attachment, code/table storage, `NSTextTableBlock`, positive-size and layout gates. The tail had one attached native view.
- The independent native control changed a rich active-turn user row through the bound store, then restored it. It observed **6 native update callbacks and exactly 2 publications**, with the changed and restored markers in attached native storage.
- The control-only run had 46 distinct evaluated bubble IDs, 30 attached scoped native instances, 13 host layouts, and 42 native draws across setup/calibration. These counts cover setup and calibration. Its 90 recorded native identities include replaced or detached instances.
- An earlier 40-turn readiness attempt presented 160 blocks and 136 rows with 48 attached scoped native instances. Requiring the very first historical row was too strict for the production presentation. The diagnostic now accepts any mounted rich user witness from an older turn. Repeat collection stopped at the streaming gate in the subsequent 10-turn run, before the 200-turn host.
- The canonical source tail has `isStreaming == true`. The production-projected tail has `isStreaming == false`. In `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift`, `classify(activity:in:)` selects the conclusion by ID and `conclusionBlock` calls `activity.toItem(isStreaming: false)`. The fixture's run-interaction state is idle. No flag was forced after projection, and no production routing was changed.

### Commands, jobs and retained evidence

All jobs used the checkout's `./conductor`. Test command filter:

```text
RepoPromptTests.AgentTranscriptTailInvalidationDiagnostics/testStreamingTailInvalidationAcrossSessionSizes
```

The initial test command was:

```bash
RPCE_RUN_SCALE_TESTS=1 ./conductor test --filter RepoPromptTests.AgentTranscriptTailInvalidationDiagnostics/testStreamingTailInvalidationAcrossSessionSizes --async --request-key transcript-tail-m0-host-gate
```

Every subsequent test used this exact command with the request key and scale value from the table:

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RPCE_RUN_SCALE_TESTS=1 ./conductor test --filter RepoPromptTests.AgentTranscriptTailInvalidationDiagnostics/testStreamingTailInvalidationAcrossSessionSizes --async --request-key transcript-tail-m0-host-gate-sdk
```

| Request key | Ticket | Result |
| --- | --- | --- |
| `transcript-tail-m0-host-gate` | `03deeaa8-c637-4c1c-acd0-bd54be8f089c` | Failed manifest compilation: compiler/implicit SDK mismatch; 8.2 s execution. |
| `transcript-tail-m0-host-gate-sdk` | `d44fc675-ee34-4c44-bf8d-8f97292abe14` | Production hooks compiled. New fixture failed compilation (settings import, private precedent error type and main-actor accessor); corrected locally. 6 m 36 s execution. |
| `transcript-tail-m0-host-gate-fixed` | `abe51adb-742c-4e35-862d-9af565dac2d5` | 1 test executed, failed the 40-turn oldest-row witness gate after the 10-turn mount gate passed. 2 m 52 s execution, 7 m 22 s global admission wait. |
| `transcript-tail-m0-native-control` | `ae43d262-d38b-40f3-9cd6-238bd820ecea` | 1 test executed; native control passed, then deliberately failed at the then-unimplemented chunk driver. 25.8 s execution, 14 m 9 s global wait. |
| `transcript-tail-baseline` | `ac190d75-17b8-4840-8723-af6365f9bedf` | Full driver compiled. 1 test executed; rejected the non-streaming projected tail before warm-up. 24.1 s execution, 2 m 51 s global wait. |
| `transcript-tail-m0-final-gate` | `a96953ff-ee2e-45fd-b8c3-c7880ed5aff6` | 1 test executed, failed the explicit `production-projected tail has isStreaming=false` gate. Source flag true/projected flag false confirmed. 24.2 s execution, 1 m 47 s global wait. |
| `transcript-tail-m0-opt-out` (scale value `0`) | `68f72ad1-59f5-4955-8b81-e8a3e5713ccc` | Passed: 1 test executed, 1 skipped, 0 failures with scale value 0. 14.3 s execution. |

Each job was collected with `./conductor job wait --request-key <key>`. Raw logs are retained locally at:

```text
/Users/cristian/Library/Application Support/RepoPrompt CE/Conductor/91950a7903f7c179c7f1f804cd19aa7540d0fc7d1b94c0512def5eb2f72c8da4/jobs/<ticket>.log
```

Style commands used `./conductor <operation> --async --request-key <key>`, followed by the same `job wait` command:

| Operation / key | Ticket | Result |
| --- | --- | --- |
| `format-check` / `transcript-tail-m0-format-check` | `8871260d-bcdb-4726-b9cf-c3382298ef06` | Pinned SwiftFormat 0.61.1 missing; system 0.63.0 rejected. |
| `install-format-tools` / `transcript-tail-m0-style-tools` | `48f6f6ec-aff6-4ee9-944b-617f4cd3a74a` | Installed pinned SwiftFormat; SwiftLint 0.65.1 present. |
| `format-check` / `transcript-tail-m0-format-installed` | `52fb8774-d116-4951-9320-c4150481657a` | Only the changed AgentModeView and new diagnostic needed formatting. |
| `format` / `transcript-tail-m0-format` | `02d9c522-02a3-4a87-9d07-21e06ac61836` | Passed; only those 2 files formatted. |
| `lint` / `transcript-tail-m0-lint` | `539cb5b6-5ad4-4741-b1b9-a36cfc312e24` | Passed format check and strict SwiftLint. |
| `format` / `transcript-tail-m0-format-driver` | `d5484912-a484-4d73-85db-e26d362a09f1` | Passed; only the new diagnostic formatted. |
| `format` / `transcript-tail-m0-format-final` | `ee762b54-5c99-41dc-b872-eb8481802257` | Passed; final formatter changed 0 files. |
| `lint` / `transcript-tail-m0-lint-final` | `a12781d9-6d39-42da-98ea-bfb3b264f9c6` | Passed format check and strict SwiftLint. |

The conductor formatting entry point scans the configured first-party scope. Non-mutating checks established that drift was confined to these changes, and mutation results showed no unrelated formatting. Live smoke was omitted because visible app work and live providers were prohibited.

### Renderer and timing limitations

The opt-in test contains the full 10/40/200, three-repeat, eight-chunk driver. Execution of its timing/settling code remains unqualified because the production streaming-input gate fails. The 72-record scoreboard, per-repeat means, median/min–max, CPU-clock runtime verification, footer acknowledgment and per-chunk native counters remain unqualified. No tail or status sample has been accepted.

The supported workload stays below the segmented Markdown renderer threshold. The driver rejects larger workloads rather than inventing an accessibility acknowledgment for an untested SwiftUI Text route. It polls attached native tail storage for the exact marker and measures native updates before equality, storage replacement, size requests, cache-miss `ensureLayout`, and draw callbacks separately. Native `make` counts include views that may not subsequently attach.

The 60-second readiness deadline applies after fixture construction, and calibration has a five-second bound per mutation. Setup/calibration inventories and whole-snapshot validation occur outside chunk epochs. The synchronous drive subtotal covers publication and requested update-if-needed layout. The Mach CPU clock includes all work on the main thread, including fixture/framework callbacks and polling, while settling wall time includes scheduler/coalescer waits. DEBUG probes add dictionary and acknowledgment overhead. These timings would describe this unordered host. Visible scrolling latency and Release performance require separate measurement.

XCTest also reported `InvalidTransition { phase: idle, targetPhase: failed(deinit) }` while reporting thrown diagnostic failures. The explicit `TAIL_BASELINE_UNAVAILABLE` records retain the failed gate. The source of the error-reporting discrepancy is unknown.

### Next decision for Helm

Keep M1 closed. First decide whether the baseline should follow another existing production live-stream path that preserves the streaming flag, or whether the intended workload should measure the currently projected immediate conclusion route. Trace `AgentTranscriptServices.swift` and the live presentation caller read-only. The diagnostic owns any fixture correction in `AgentTranscriptTailInvalidationDiagnostics.swift`; reuse the same test ID and positive control. Estimate 20–60 changed test lines if an existing path suffices, plus the results entry here. A product routing change is a separate authorization decision. No optimization boundary or expected saving is justified by this run.

The final gate emitted the same 6-update/2-publication native calibration and the counts above. Final formatting and strict lint passed. The opt-out run passed with one skipped test. The requested streaming baseline remains unavailable.

Commit safety command (run against the intended staged index, with the matching SDK):

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
```

The local commit result and cumulative diff are reported in the handoff. No push or PR is authorized.

## Active-run fixture correction (follow-up M0)

Earlier failed attempts remain in the preceding execution record. An idle session was inconsistent with the requested active-run workload. The corrected fixture sets `session.runState = .running` before installing items, then calls the existing `refreshDerivedTranscriptState(for:reason: .liveMutation)` and `updateBindingsFromSession(_:)`. It requires the published run interaction to be running and unchanged throughout each chunk.

The projected tail flag and block route are observations. In particular, the production conclusion route explicitly projects `isStreaming == false`; the benchmark preserves that value. A growing reply during an active run is the workload. No product routing, rendering cadence, or projected flag is forced. Each accepted chunk still requires consumption of its exact tail marker and footer status, the marker in attached native storage, exactly one publication, and all prior identity, native calibration and settling gates. The same 10/40/200 workload, three fresh-host repeats and eight measured chunks per repeat apply. Per-cohort native counters now print explicit zero entries after calibration.

### Accepted baseline

**72 valid measured chunks across 9 fresh hosts passed**: three repeats each at 10, 40 and 200 logical turns, in the planned interleaved order. All 9 native controls passed with 6 update callbacks and exactly 2 publications each, and all 9 warm-ups passed. Every measured chunk published exactly once, consumed its tail marker and footer status, exposed the marker in attached native storage, and retained the running interaction snapshot. Every fixture retained a streaming source tail while the production projection used `conclusion`, `isStreaming == false`, and Markdown cadence `immediate` throughout.

Measurement source: `ac733c7e8f23c2bb801d701fef372d93aabaf916` plus this fixture-only follow-up. The production hooks are unchanged. Hardware, SDK, DEBUG configuration, normal font and unordered 1000 × 800 pt host match the environment above. The corrected live path applies production retention and materialization. Both 40 and 200 logical turns presented the same bounded population, so **render-tree scaling beyond that population remains unresolved**.

| Logical turns | Presented blocks / rows | Older body IDs / mounted native rows | Active stable body IDs / mounted native rows | Tail body IDs / mounted native rows |
| --- | --- | --- | --- | --- |
| 10 | 40 / 46 | 41 / 27 | 4 / 2 | 1 / 1 |
| 40 | 56 / 64 | 59 / 45 | 4 / 2 | 1 / 1 |
| 200 | 56 / 64 | 59 / 45 | 4 / 2 | 1 / 1 |

Body IDs are the distinct fixture bubble IDs evaluated before measurement. All of those older and active-stable IDs executed their bodies on **every measured chunk**. Counts below are mean per chunk with individual-chunk min–max in brackets, across 24 samples per size. All native `make` counts were zero after warm-up. Storage replacement and cache-miss `ensureLayout` counts matched in this run, so they share a column while remaining separate raw counters.

| Turns / cohort | Body calls | Distinct bodies per chunk | Native updates | Storage replacements / ensureLayout | Native size requests | Native draws |
| --- | --- | --- | --- | --- | --- | --- |
| 10 older | 114.458 [82–123] | 41 | 75.375 [54–81] | 25.125 [18–27] | 276.375 [198–297] | 36 |
| 10 active stable | 11.167 [8–12] | 4 | 5.583 [4–6] | 2.792 [2–3] | 16.750 [12–18] | 2 |
| 10 tail | 2.792 [2–3] | 1 | 3.792 [3–4] | 3.792 [3–4] | 23.958 [20–25] | 2 |
| 40 older | 164.708 [118–177] | 59 | 125.625 [90–135] | 53.042 [38–57] | 415.958 [298–447] | 52 |
| 40 active stable | 11.167 [8–12] | 4 | 5.583 [4–6] | 2.792 [2–3] | 16.750 [12–18] | 2 |
| 40 tail | 2.792 [2–3] | 1 | 3.792 [3–4] | 3.792 [3–4] | 23.958 [20–25] | 2 |
| 200 older | 169.625 [118–177] | 59 | 129.375 [90–135] | 54.625 [38–57] | 428.375 [298–447] | 52 |
| 200 active stable | 11.500 [8–12] | 4 | 5.750 [4–6] | 2.875 [2–3] | 17.250 [12–18] | 2 |
| 200 tail | 2.875 [2–3] | 1 | 3.875 [3–4] | 3.875 [3–4] | 24.375 [20–25] | 2 |

These observations establish stable-row body and native callback fan-out under the diagnostic. The cause of repeated storage replacement on unchanged stable inputs has not been isolated. Expected optimization savings remain unknown.

### Repeat means and variance

Each row below is the mean of that repeat's eight accepted chunks. Times are milliseconds. Layouts count actual host `layout()` entries per chunk. Body columns preserve the per-repeat variation in older, active-stable and tail calls.

| Turns | Repeat | Older / active stable / tail body calls | Main drive ms | Main-thread CPU ms | Settle wall ms | Host layouts |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | 1 | 112.750 / 11.000 / 2.750 | 63.045 | 325.396 | 404.466 | 5.500 |
| 10 | 2 | 112.750 / 11.000 / 2.750 | 66.756 | 331.346 | 413.256 | 5.500 |
| 10 | 3 | 117.875 / 11.500 / 2.875 | 56.144 | 355.404 | 403.952 | 5.500 |
| 40 | 1 | 154.875 / 10.500 / 2.625 | 104.705 | 357.815 | 464.323 | 5.375 |
| 40 | 2 | 162.250 / 11.000 / 2.750 | 97.611 | 402.420 | 486.008 | 5.625 |
| 40 | 3 | 177.000 / 12.000 / 3.000 | 78.744 | 485.865 | 498.687 | 5.750 |
| 200 | 1 | 169.625 / 11.500 / 2.875 | 87.821 | 444.684 | 490.699 | 5.625 |
| 200 | 2 | 177.000 / 12.000 / 3.000 | 76.729 | 485.188 | 494.826 | 5.750 |
| 200 | 3 | 162.250 / 11.000 / 2.750 | 102.491 | 416.092 | 492.664 | 5.375 |

The next table gives the median of the three repeat means, followed by their min–max.

| Turns | Main drive ms | Main-thread CPU ms | Settle wall ms | Host layouts |
| --- | --- | --- | --- | --- |
| 10 | 63.045 [56.144–66.756] | 331.346 [325.396–355.404] | 404.466 [403.952–413.256] | 5.500 [5.500–5.500] |
| 40 | 97.611 [78.744–104.705] | 402.420 [357.815–485.865] | 486.008 [464.323–498.687] | 5.625 [5.375–5.750] |
| 200 | 87.821 [76.729–102.491] | 444.684 [416.092–485.188] | 492.664 [490.699–494.826] | 5.625 [5.375–5.750] |

Individual-chunk ranges were: 10 turns, main drive 48.567–110.265 ms, CPU 118.140–412.119 ms, wall 371.507–432.488 ms; 40 turns, main drive 73.073–160.251 ms, CPU 170.406–500.875 ms, wall 434.309–538.723 ms; 200 turns, main drive 73.686–167.783 ms, CPU 175.833–510.111 ms, wall 441.799–526.422 ms. Host layouts ranged from 5 to 8 at every size.

The Mach clock ran on the main thread for all accepted epochs. CPU totals include framework callbacks and diagnostic polling between synchronous drive intervals. Wall times include the required 220 ms quiet window and scheduler servicing, so they are unsuitable as direct user-visible latency estimates. This baseline exercises the actual immediate conclusion route during an active run. Coverage of the segmented renderer and streaming-coalesced route remains unqualified. Visible scrolling, Release performance and larger rendered populations require separate measurements. M1 remains prohibited.

### Follow-up validation and retained evidence

Exact coordinated commands:

```bash
./conductor format --async --request-key transcript-tail-m0-active-format
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RPCE_RUN_SCALE_TESTS=1 ./conductor test --filter RepoPromptTests.AgentTranscriptTailInvalidationDiagnostics/testStreamingTailInvalidationAcrossSessionSizes --async --request-key transcript-tail-m0-active-baseline
./conductor lint --async --request-key transcript-tail-m0-active-lint
```

Each job was collected with `./conductor job wait --request-key <key>`.

| Request key | Ticket | Result |
| --- | --- | --- |
| `transcript-tail-m0-active-format` | `7c00dc5f-8822-4561-8776-4cc6fea86377` | Passed, 0 files required formatter mutation, 3.9 s execution. |
| `transcript-tail-m0-active-baseline` | `bfd5ec1e-e72a-45f4-acf4-1b764293ccfe` | Passed: 1 test, 0 failures, 69.105 s test duration. Conductor execution 1 m 37 s, queue 3.8 s, global wait 7 ms. |
| `transcript-tail-m0-active-lint` | `069a6c3f-2598-427a-8ec3-6be89cced734` | Passed formatter check and strict SwiftLint, 4.2 s execution. |

All 72 individual `TAIL_SAMPLE` JSON records and all 9 setup, native-control, route and warm-up records are retained in:

```text
/Users/cristian/Library/Application Support/RepoPrompt CE/Conductor/91950a7903f7c179c7f1f804cd19aa7540d0fc7d1b94c0512def5eb2f72c8da4/jobs/bfd5ec1e-e72a-45f4-acf4-1b764293ccfe.log
```

A read-only Python summary checked that the records contain exactly the Cartesian product of sizes 10/40/200, repeats 1/2/3 and chunks 1–8. It also checked that every record reports one publication, running interaction and projected streaming false. The tables use arithmetic means within each repeat, then median/min–max of the three means per size. No failed earlier attempt was included in the accepted statistics. Commit policy requires the same staged contribution preflight command recorded above, followed by a new local commit. Amending and pushing remain unauthorized.
