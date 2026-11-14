# Host-aware resource admission

## Current-main correctness fix

Current main `5feaf80ae` still wraps already-captured CodeMap parsing in `FileSystemService.withCodeMapArtifactBuildPermit`. Foreground content search suppresses that bulk **I/O** permit, so a demand parse that needs no I/O cannot finish until the unrelated search ends; deadline-bound structure queries can omit signatures. This incorrect dependency predates #1717 and remains present after its merge. The fix removes that I/O ownership from captured CPU parsing and classifies demand work as foreground CPU work.

Causal check: temporarily restored the entire coordinator file byte-for-byte from current main (verified by `cmp` and `git diff --exit-code origin/main -- <file>`), leaving the new regression test and other follow-up code unchanged. `HostResourceCodeMapAdmissionTests.testCapturedSourceDemandBuildProgressesDuringForegroundSearch` failed with `blockedBehindUnrelatedReadActivity` (Conductor `7019a577-f1d0-40e2-acbe-a3bcb64a07c1`). The fixed coordinator had already passed the full 35-test WorkspaceContext target; it was restored byte-for-byte after the negative control and the identical test passed in 0.222 seconds (Conductor `4472e8da-14b0-4c77-b0ff-ec8ce5af82bc`). This isolates the current-main coordinator dependency, not a complete main-build performance comparison. No negative-control source is committed.

## Ownership and invariant

`HostResourceCapacity` is the shared policy for host-derived fan-out and physical-work admission. `HostResourceBudget.shared` is process-wide, not per window, connection, root, search, or Git service. It is in DomainRuntime because all physical consumers already depend on that target; it introduces no dependency cycle or lifecycle/writer authority.

All physical classes share a total ceiling. Search/CodeMap CPU work and Git subprocesses additionally share one CPU ceiling. I/O and Git also share a weighted descriptor envelope, rather than each spending the same free descriptors independently. Existing fair content-read and weighted/deadline Git schedulers remain outer owners; host admission cannot release their physical ownership early.

Acquire physical work only at leaves. Never hold a CPU/I/O/process token while awaiting a child that acquires another. There is no TaskLocal reentrancy bypass: task groups inherit task locals. Search uses this explicit hierarchy:

1. Reserve memory before fetching content.
2. Fetch through content-read/physical I/O admission; release physical I/O.
3. Acquire CPU admission for matching/materialization.
4. Return compact match/context strings, not full `SearchDocument` text behind the ordered drain frontier; release CPU and the memory reservation.

CodeMap admission covers synchronous parse/extract with an already-captured source snapshot. It does not wrap discovery, source fetching, or Git work. Captured-source demand parsing no longer consumes the legacy bulk I/O permit: foreground searches suppressed that permit even though the parser needed no I/O, delaying structure queries until unrelated searches finished. Background source fetching still uses the existing bulk I/O ceiling. Per-file matching/materialization drains Cocoa autorelease temporaries before releasing its memory lease. A speculative ASCII literal count-only implementation was dropped after the controlled runs showed higher search CPU cost; the existing Foundation comparison semantics remain unchanged. Git driver queries finish before acquiring the next physical process token.

## Policy

The pure policy takes logical/performance cores, physical RAM, free/inactive memory estimates, recent compression/swapout growth, memory/thermal pressure, soft descriptor limit, populated open-fd count. Performance cores fall back to active logical cores on machines without the perf-level sysctl.

- Foreground physical and CPU bursts may use the active logical cores, matching existing read/search widths without multiplying pools. Background share is at most half that width and at most the performance-core count, preserving foreground headroom on multicore hosts. The OS still schedules the UI; this is not a dedicated-core affinity guarantee.
- Working memory is bounded by the smaller of RAM/4 and estimated available headroom: free + inactive pages, minus RAM/32 host reserve and two seconds of recent compression/swapout growth. Inactive includes compressible anonymous pages, so this is an estimate, not guaranteed free memory. Speculative pages are already included in free_count and are not counted twice. Growth is normalized over at least one second; closely spaced events reuse the prior rate rather than magnifying a short spike. Gaps over five seconds reset the trend baseline. Unused reservations are never credited as resident memory: doing so would defeat backoff while busy. The estimate is intentionally conservative about our own allocations.
- Half that working budget backs 64 MiB physical-worker envelopes (a bounded 10 MB file can coexist as bytes and decoded representations). Half backs search memory. Each search file initially reserves 512 MiB before capture: newline-heavy 10 MB files can create about 320 MB of line-index arrays. After capture, shrink-only accounting returns unused 64 MiB units using a conservative 35x UTF-8-byte estimate (text/bridging plus worst-case line indexes). No upgrade can wait while holding a reservation. Small files return unused reservation units during matching. A limitation remains: on a one-envelope host a second worst-case capture still waits until eight units are free; shrinking alone does not guarantee capture overlap on low-RAM hosts. A one-envelope foreground floor retains progress on low-memory hosts. These are scheduling estimates, not measured RSS claims or hard bounds for arbitrarily oversized configured inputs. Search-result snippets and existing caches have their own owners.
- Descriptor slack reserves `max(64, softLimit/8)`. I/O budgets four descriptors (a headless slot plus path-walk/read handles); processes budget six (pipe ends during spawn). The sum of active estimated descriptor units is bounded, not just each class count. Real free headroom can permit one foreground operation within the slack reserve. Descriptor classes suspend only when their minimum physical headroom is absent.
- Memory warning alone does **not** reduce capacity. Low measured headroom and compression/swapout growth scale the memory-derived width continuously in 64 MiB worker units. Thermal serious halves CPU/process width but does not halve I/O; critical memory or thermal pressure permits one foreground operation and pauses new background work. Noncritical one-slot hosts retain background progress; hard background pauses are reserved for critical pressure. A queued foreground request has scheduler precedence, but an already-active background lease is not preempted. Active leases are never revoked.
- Recovery uses the minimum observed envelope over a two-second window. Unrelated fd jitter cannot reset CPU/memory recovery indefinitely.
- Memory-pressure events apply directly, including while idle. A two-second timer performs only a cheap activity check while idle; expensive memory/fd/thermal probes skip idle periods. Busy/idle edges no longer enqueue GCD callbacks or re-arm an immediate probe. Stale reactivation coalesces with the next tick (at most two seconds); its first burst uses the cached, bounded envelope. Initial pressure/headroom are sampled, not assumed normal. Uncontended acquisition avoids continuation/cancellation-handler registration, with cancellation checked before and after the grant.
- Lifetime fan-out defaults ignore transient available-memory/open-fd counts and memory/thermal pressure; pressure is enforced at physical leaves. Otherwise opening a connection during pressure would freeze a reduced limit for its lifetime.
- The shared waiter queue remains bounded at 1,024 requests as flood/retention protection. Queue overflow is overload, not pressure backoff; Git maps it to its existing bounded-queue error and content search throws instead of silently omitting files. Pressure alone queues rather than returning overload errors.

Example policy outputs, exercised by deterministic tests (8 logical / 4 performance cores, 24 GiB RAM, ample descriptors):

| Signal | Total | CPU/process | I/O | Background |
|---|---:|---:|---:|---:|
| 4 GiB available, normal | 8 | 8 | 8 | 4 |
| Same headroom, memory warning | 8 | 8 | 8 | 4 |
| 1 GiB available | 2 | 2 | 2 | 1 |
| 512 MiB available | 1 | 1 | 1 | 1 |
| 4 GiB available, compression/swapout growth 1.5 GiB/s | 2 | 2 | 2 | 1 |
| 4 GiB available, serious thermal state | 8 | 4 | 8 | 2 |
| Critical memory/thermal | 1 | 1 | 1 | 0 |
| Exhausted descriptors, otherwise normal | 8 | CPU 8 / process 0 | 0 | 4 |

These are envelopes, not dedicated threads. The weighted descriptor sum can further constrain combinations of I/O and processes. Reduction waits for active physical work to settle; recovery is hysteretic.

The memory envelopes are conservative scheduling estimates, not hard memory accounting. External applications, subprocess-internal threads, provider/runtime processes, result retention, and all unrelated app work are outside this process-wide budget. Do not claim machine-wide safe saturation or an end-to-end responsiveness improvement without production-path measurement.

## Cap inventory and rationale

| Owner | Previous | New protection |
|---|---|---|
| MCP small read / per window | 2 / 2 | Host CPU-derived pending widths; underlying physical leaves share admission. |
| MCP file read | logical cores / window | Host I/O-derived pending width, existing owner-fair content scheduler, shared physical budget. |
| MCP Git read | 2 | Host subprocess-derived pending width; weighted Git process scheduler plus shared CPU/process admission. |
| MCP search | 4 | Host CPU-derived pending width; matching workers no longer multiply unaccounted across calls. |
| Broad workspace searches | 4 active / 4 queued | Host CPU-derived pending/freshness-flight width, with global leaf CPU/memory admission preventing N searches × N workers. Existing bounded queue timeout remains an overload contract, not the live pressure policy. |
| MCP control | 8 | At least the existing 8 suspended-control-call headroom; scales with host pending width, not physical CPU grants. Existing long-wait/cancel lane semantics are unchanged. |
| MCP exclusive mutation | 1 | **Preserved correctness serialization**, independent of hardware. |
| MCP Git per repository | 1 | **Preserved same-repository snapshot/integrity exclusion**. |
| MCP global connections | 128 | Retained client/flood ceiling, further constrained by transport descriptors and retained-state envelope. Do not multiply client populations merely because a host has more cores. Explicit user configuration remains supported. |
| MCP Git repository fan-out | 3 | Host subprocess-derived pending width; physical admission is shared across calls. |
| Git processes | 8 global, 2/repository | Host-derived global envelope; the existing per-repository share of two is retained until separately measured (and can shrink below two). Existing priority ring, absolute first-start deadline and mutation authority stay intact. Subsequent commands under one already-admitted sequence do not get a new/reapplied deadline. |
| Prompt selected-file accounting | 4 | Host I/O-derived pending width; existing physical content-read scheduler. |
| Workspace chat stubs | 4 | Host I/O-derived batch width and physical disk/decode admission. |
| Scoped ingress barriers | 8 | Host I/O-derived coordination width. A barrier awaits producers and must never hold a physical host token. Existing ordering/freshness checks are unchanged. |
| Content bulk I/O | min(3, logical cores-1) | Existing ceiling of three retained pending dedicated bulk measurements; host background share and shared physical admission can reduce it. |
| Captured CodeMap CPU parsing | Same bulk-I/O ceiling and foreground-search suppression | Host CPU-derived pending width and shared CPU admission, with background priority only for actual background builds. Capture/input-byte, queue, fairness and generation/commit fences remain. |
| Search workers | max(4, logical cores) per search | Host CPU-derived pending width plus global CPU admission. Ordered result windows remain bounded. |
| Directory scans | 2..4 per actor | Host background-derived pending width; physical enumeration shared across actors/roots. |

## CodeMap manifest cache

Current main already retains checksum-validated scan summaries independently of the 64 MiB decoded snapshot cache. Therefore the older installed-app profile and 83 MiB store do **not** justify enlarging that cache. Validate `CodeMapRootManifestTargetCacheTests.testFullScanDoesNotRedecodeStoreLargerThanDecodedCacheBudget` and the same-identity rewrite/checksum regression. Full reread/checksum work remains intentional integrity validation; this change does not replace it with metadata-only trust.

## Observability and validation

Read/search debug capture snapshots include `host_resources`: current total/CPU/I/O/process/background/memory limits, active counts by class, waiters, grants, peak physical concurrency, and cumulative admission wait. These counters are process-lifetime totals, not per-request spans or RSS measurements. Retained-content lease counts can exceed the original envelope count after shrinking; `active_content_units` and `retained_content_limit_units` compare the actual accounting units (64 MiB each).

`HostResourceCapacityTests` covers resource scaling, pressure floors, background suspension, descriptor exhaustion/recovery, GUI descriptor headroom, shared CPU/process ceilings, memory-before-I/O-before-CPU progress, queued cancellation, physical settlement, release-once behavior, start-deadline semantics, and deterministic recovery hysteresis. Existing canonical lane tests assert host-derived capacities rather than fixed machine-independent numbers without weakening settlement/cancellation assertions.

`HostResourceBurstEvidenceTests` round-trips all bytes of 24 concurrent physical headless reads, asserts no leaked work/waiters and the shared physical ceiling, and prints timing. Its timing is diagnostic, not a flaky CI performance threshold. Run through Conductor. It is not a live-app, networking, MCP transport burst, or large-repository search benchmark.

### Controlled measurement protocol (declared before sampling)

The initial pilots were rejected: broad-search queue expirations and CodeMap setup retry exhaustion (including one-minute system load over 230 while compilation was active). Canonical isolated child HOME/storage and explicit process-wide runtime initialization allowed the baseline engine to run, but a 2,049-Swift-file fixture had processed only 1,088 candidates after the 60-second setup deadline. This is an unresolved initial-indexing cost, not a completed MCP sample. Before any valid samples, the protocol was narrowed to separate the large text-search corpus from 24 real public Swift APIs. This is an explicit deviation from the original all-Swift corpus, not proof of an initial-indexing improvement; that full-source case remains unvalidated. A later triplet trial completed eight pairs, then rejected a candidate sample because a structure query returned pending instead of the required public type. That failed process reached about 2 GiB peak RSS, while the preceding completed candidate processes were about 323–372 MiB. Per-file autorelease draining therefore cannot yet be claimed to resolve every transient-retention path. Those logs are retained; that trial is not a complete ten-pair dataset. Cold/warm client costs, setup cost, production retry counts, and counterbalanced pair order are recorded. Failed pilot logs are retained locally, never converted to successful zero/partial timings.

`HostAdmissionControlledEvidenceTests/testControlledAB` is opt-in via `.build/host-ab/config.json` and must run through Conductor. Compile the byte-identical diagnostic against pinned main and candidate source using the same Debug XCTest/toolchain settings. This is not release-build performance evidence. Run ten interleaved, counterbalanced A/B and B/A pairs, serially, with a fresh XCTest process and isolated HOME/storage for each variant/repetition. Each process runs the same ordered triplet (mixed, search, read), producing ten samples per workload/variant without rebuilding the identical repository three times. Each sample uses a committed repository with 2,048 text corpus files (160 matching lines/file), 24 small public Swift APIs for real CodeMap queries, and 24 read files (229,376 bytes each). Require observable CodeMap worker/batch/writer quiescence before client sampling, and report that index-settle cost separately. Measure the first client pass for each case, then the same workload once warm. The JSON `cold_*` fields mean first client pass after setup or preceding cases, not cold OS caches: later cases inherit earlier cache activity. Record both CPU/wall deltas separately. Honor production search-backpressure and incomplete-CodeMap retries (at most three retries with a one-second delay); include delays in client-observed completion time and require the exact complete final result. The mixed workload sends 24 concurrent socketpair MCP requests through real admission/routing/providers: six each of read_file, file_search, get_code_structure and git status. The search workload counts all 327,680 matching lines; the read workload sends 24 concurrent requests and verifies returned content. No mocked handler or visible app is used.

Retain every valid sample, including regressions. Reject a sample on any protocol/result assertion, process failure, or missing evidence; do not substitute an easier workload. Record cold/pre/post memory-pressure flags, free/inactive/compressor pages, cumulative compression/swapout counters, and thermal state. Report cold/warm wall and self+child CPU deltas, fresh-process peak RSS (including identical setup and preceding cases; RSS is a process-lifetime high-water mark, not attributable to the current case alone), median and nearest-rank p95. Flag critical/thermal changes and competing heavy jobs as comparability limitations rather than silently discarding slow samples. A nominal performance win requires lower median and p95, without materially greater CPU/RSS or unbounded concurrency; otherwise do not declare the performance goal achieved. A separately reproduced current-main correctness fix can be reviewed independently, without certifying nominal performance or host-saturation safety. This is an isolated in-process MCP benchmark, not a visible-app responsiveness or network round-trip measurement.

### Completed controlled trial (2026-11-15)

Pinned main `26db5dd418ae4726f611da9b58e7d28cc68a8b11` versus candidate source patch SHA-256 `5acf8aaf5da11d3d674f1d07de43d4bd4b1f9807c3a4e0e7c37d92c18f6edbc8` (Git diff against that main, `Sources` only). Common harness SHA-256 `58e1aeb167ea49ced4da62eaad67f299ed5c04f43f0014ee200b58c95bde93d0`. Baseline archive verified against all 3,539 tracked Git blobs; it is an archive inside this worktree's ignored build directory, not an additional Git worktree. Conductor ticket `35bf03c9-b788-4936-91d6-596e71b07adf` passed: 20 fresh child processes, 60 valid rows, ten repetitions of every workload/variant, zero retries. No failed/partial result was counted. Host: 8 logical cores, 24 GiB RAM; both variants used read lane 8, small-read lanes 2/8, search lanes 4/8.

Warm client results (median / nearest-rank p95; n=10 means p95 is the maximum):

| Workload | Main wall ms | Candidate wall ms | Main CPU ms | Candidate CPU ms | Main / candidate p95 process RSS MiB |
|---|---:|---:|---:|---:|---:|
| Mixed 24-call burst | 6320 / 8934 | 5830 / 7740 | 25905 / 36934 | 26839 / 38024 | 321.9 / 328.1 |
| Broad content search | 613 / 1031 | 623 / 982 | 2930 / 5072 | 2924 / 5468 | 321.9 / 328.1 |
| 24 full-file reads | 378 / 517 | 456 / 684 | 1247 / 1487 | 1432 / 1634 | 354.8 / 371.1 |

First-client-pass results (not cold OS caches):

| Workload | Main wall median / p95 ms | Candidate wall median / p95 ms | Main / candidate median CPU ms |
|---|---:|---:|---:|
| Mixed | 6414 / 9161 | 6401 / 8361 | 29365 / 29636 |
| Search | 536 / 1278 | 532 / 982 | 2844 / 2858 |
| Reads | 414 / 518 | 456 / 572 | 1489 / 1540 |

The mixed warm burst improved 7.8% median and 13.4% p95 with 3.6% more median CPU. Search median was 1.6% slower (CPU approximately flat). Reads regressed 20.7% median / 32.3% p95 with 14.8% more median CPU; do not call that a win. The physical budget is retained for aggregate safety, not justified by a read speedup. The exact cause of the read regression remains unproven; a separate read-only-process diagnostic checks whether preceding search/structure work contributes, without replacing these results. Lifetime RSS includes setup and preceding cases, so per-case allocations cannot be inferred from its high-water mark. No process in this completed trial exceeded 371.1 MiB, but the earlier rejected ~2 GiB outlier remains an unresolved reliability limitation, not erased by the successful rerun.

Memory pressure flags stayed normal (raw 1), thermal state fair (raw 1), fd soft limit 9,472 with 21–27 descriptors observed. One-minute system load ranged 16.8–97.9 on eight logical cores. Compression/swapout counters and free/inactive pages are retained per row in local evidence. This is a heavily competing-host Debug result, **not nominal-condition, release, or visible-app evidence**. A prior read-only process snapshot showed browser/UI applications consuming roughly six core-equivalents outside the benchmark; nothing was stopped or launched to alter those conditions. Nominal-condition performance qualification, read regression attribution, full-source initial indexing, and the transient CodeMap/RSS outlier remain open. Review readiness for the independently reproduced correctness fix does not certify those performance goals.

A separate, predeclared follow-up diagnostic ran ten counterbalanced read-only pairs in fresh processes, with no preceding mixed/search case (same source and common harness; Conductor `16d6e589-c7bc-4d12-a5ee-1375fd4a8bda`, 20/20 exact-result processes passed). Warm read wall median/p95 was 306/332 ms main versus 324/347 ms candidate (+5.9%/+4.4%); median CPU 988/1011 ms (+2.3%), p95 lifetime RSS 325.6/329.4 MiB. First-pass median wall was 369/370 ms. System load was 6.5–8.2 with normal memory flags/fair thermal state. This narrows but does not eliminate the regression when prior cases are absent; it does **not** establish its cause, and does not replace the primary triplet results. The isolated read regression is another reason not to declare the latency goal achieved or attribute the full 20.7% triplet regression to the small uncontended gate cost.

### Bounded investigation of the rejected ~2 GiB process

The rejected process was triplet repetition 8/candidate in the discarded ASCII-counter variant. Mixed first-pass wall/CPU was 11.41 s/53.42 s; the repeat was 29.81 s/64.96 s with five total readiness retries and one final missing `Benchmark_2`. The repeat queried a type that had been returned successfully in the first pass, so initial index incompleteness alone does not explain the readiness loss. Peak RSS was 2,137,751,552 bytes in the mixed row and stayed at that same high-water mark for subsequent search/read rows. Later rows cannot identify the allocating phase. The diagnostic did not record a heap trace or a pre-mixed RSS checkpoint, and the failed worker exited before retrospective sampling was possible.

Source-path review rules out simply blaming the regular line-index cache: this literal count-only request returns from the count-only fast path before constructing `SearchDocument`/line-index arrays. Root text is about 22.5 MB including the read corpus, not a single multi-gigabyte input. The CodeMap coordinator retains an independently bounded 128 MiB of captured input. These facts **do not** account for all Foundation/runtime caches, temporary copies, snapshot/export work or allocator retention, and are not proof of a hard RSS bound. An earlier pre-autorelease-drain pilot also reached roughly 1.8 GiB, so removal of the ASCII experiment alone cannot be credited as the cause/fix. The subsequent complete ten-pair triplet replay (20 fresh processes) and ten-pair read-only diagnostic (20 more) did not reproduce it; maximum observed RSS was 371.1 MiB. That bounded replay effort narrows reproducibility but leaves allocation ownership unexplained. A future reproducer needs phase RSS checkpoints and a heap/allocation trace; the host-choking failure has **not** been ruled out.

### Admission service cost versus queue wait

The earlier 356 ms admission number was the **sum of time spent waiting by 24 requests**, not CPU consumed in the scheduler. A separate opt-in microprofile performs 10,000 uncontended grant/releases with no I/O. The latest run recorded 17.58 ms isolated and 23.48 ms shared (1.76 and 2.35 microseconds/grant, including the async caller and release); internal admission-clock totals were 3.65/4.04 ms. An earlier loaded-host run of the same changed path recorded 37.69/42.01 ms. The latest physical-read check returned all 5,505,024 bytes from 24 files in 95.74 ms, peak eight physical operations, cumulative queued wait 0.129 ms, with no leaked owners/waiters. These are single diagnostic samples, not controlled speedup claims. An earlier shared sample was 54.60 ms, but host conditions differed: this is not a controlled percentage improvement. It bounds the observed uncontended service cost; it does not measure contended-lock CPU attribution or prove an end-to-end gain. The sampler no longer performs refresh syscalls or GCD enqueue work on each acquire/release edge.

Performance PRs should record exact source head, workload/bytes, current pressure envelope, peak concurrency, queue wait and before/after timings. Keep raw operational evidence local. Separate uncontrolled samples from a statistically valid speedup claim. Live measurements must use a compatible binary; an older already-running app cannot validate new source, and visible app lifecycle actions require separate authorization.
