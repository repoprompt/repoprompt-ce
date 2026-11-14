# Host-aware resource admission

## Ownership and invariant

`HostResourceCapacity` is the shared policy for host-derived fan-out and physical-work admission. `HostResourceBudget.shared` is process-wide, not per window, connection, root, search, or Git service. It is in DomainRuntime because all physical consumers already depend on that target; it introduces no dependency cycle or lifecycle/writer authority.

All physical classes share a total ceiling. Search/CodeMap CPU work and Git subprocesses additionally share one CPU ceiling. I/O and Git also share a weighted descriptor envelope, rather than each spending the same free descriptors independently. Existing fair content-read and weighted/deadline Git schedulers remain outer owners; host admission cannot release their physical ownership early.

Acquire physical work only at leaves. Never hold a CPU/I/O/process token while awaiting a child that acquires another. There is no TaskLocal reentrancy bypass: task groups inherit task locals. Search uses this explicit hierarchy:

1. Reserve memory before fetching content.
2. Fetch through content-read/physical I/O admission; release physical I/O.
3. Acquire CPU admission for matching/materialization.
4. Return compact match/context strings, not full `SearchDocument` text behind the ordered drain frontier; release CPU and the memory reservation.

CodeMap admission covers synchronous parse/extract with an already-captured source snapshot. It does not wrap discovery, source fetching, or Git work. Git driver queries finish before acquiring the next physical process token.

## Policy

The pure policy takes logical/performance cores, physical RAM, memory/thermal pressure, soft descriptor limit, and populated open-fd count. Performance cores fall back to active logical cores on machines without the perf-level sysctl.

- Total physical work normally leaves one logical processor for the OS/UI. CPU-heavy work is capped by performance cores.
- Physical-read working envelopes are 64 MiB (a bounded 10 MB file can coexist as raw data and decoded representations), with at most 1/16 of RAM allocated to these envelopes.
- Search pipelines reserve separate 512 MiB envelopes: newline-heavy 10 MB files can create about 320 MB of line-index arrays (NSRange plus UTF-16/UTF-8 starts). This is a conservative reservation, not a measured RSS claim. Search-result snippets and existing caches have their own bounded owners; this is not a global limit on all retained app/model output.
- Descriptor slack reserves `max(64, softLimit/8)`. I/O budgets four descriptors (a headless slot plus path-walk/read handles); processes budget six (pipe ends during spawn). The sum of active estimated descriptor units is bounded, not just each class count. Real free headroom can permit one foreground operation within the slack reserve. Descriptor classes suspend only when their minimum physical headroom is absent.
- Warning pressure halves new-work ceilings. Critical pressure permits one foreground operation and pauses new background work. Active leases are never revoked.
- Recovery uses the minimum observed envelope over a two-second window. Unrelated fd jitter cannot reset CPU/memory recovery indefinitely.
- Memory-pressure events apply directly. A two-second descriptor/thermal refresh runs only while physical work, reservations, or waiters exist; it stops when idle. Initial memory pressure is sampled, not assumed normal.
- Lifetime fan-out defaults ignore transient open-fd counts and memory/thermal pressure; pressure is enforced at physical leaves. Otherwise opening a connection during pressure would freeze a reduced limit for its lifetime.
- The shared waiter queue remains bounded at 1,024 requests as flood/retention protection. Queue overflow is overload, not pressure backoff; Git maps it to its existing bounded-queue error and content search throws instead of silently omitting files. Pressure alone queues rather than returning overload errors.

The memory envelopes are conservative scheduling estimates, not hard memory accounting. External applications, subprocess-internal threads, provider/runtime processes, result retention, and all unrelated app work are outside this process-wide budget. Do not claim machine-wide safe saturation or an end-to-end responsiveness improvement without production-path measurement.

## Cap inventory and rationale

| Owner | Previous | New protection |
|---|---|---|
| MCP small read / per window | 2 / 2 | Host CPU-derived pending widths; underlying physical leaves share admission. |
| MCP file read | logical cores / window | Host I/O-derived pending width, existing owner-fair content scheduler, shared physical budget. |
| MCP Git read | 2 | Host subprocess-derived pending width; weighted Git process scheduler plus shared CPU/process admission. |
| MCP search | 4 | Host CPU-derived pending width; matching workers no longer multiply unaccounted across calls. |
| MCP control | 8 | At least the existing 8 suspended-control-call headroom; scales with host pending width, not physical CPU grants. Existing long-wait/cancel lane semantics are unchanged. |
| MCP exclusive mutation | 1 | **Preserved correctness serialization**, independent of hardware. |
| MCP Git per repository | 1 | **Preserved same-repository snapshot/integrity exclusion**. |
| MCP global connections | 128 | Retained client/flood ceiling, further constrained by transport descriptors and retained-state envelope. Do not multiply client populations merely because a host has more cores. Explicit user configuration remains supported. |
| MCP Git repository fan-out | 3 | Host subprocess-derived pending width; physical admission is shared across calls. |
| Git processes | 8 global, 2/repository | Host-derived global envelope and half-envelope per-repository fair share. Existing priority ring, absolute first-start deadline and mutation authority stay intact. Subsequent commands under one already-admitted sequence do not get a new/reapplied deadline. |
| Prompt selected-file accounting | 4 | Host I/O-derived pending width; existing physical content-read scheduler. |
| Workspace chat stubs | 4 | Host I/O-derived batch width and physical disk/decode admission. |
| Scoped ingress barriers | 8 | Host I/O-derived coordination width. A barrier awaits producers and must never hold a physical host token. Existing ordering/freshness checks are unchanged. |
| Content bulk/CodeMap | min(3, logical cores-1) | Host background share, existing foreground suppression, global physical admission. |
| Search workers | max(4, logical cores) per search | Host CPU-derived pending width plus global CPU admission. Ordered result windows remain bounded. |
| Directory scans | 2..4 per actor | Host background-derived pending width; physical enumeration shared across actors/roots. |

## CodeMap manifest cache

Current main already retains checksum-validated scan summaries independently of the 64 MiB decoded snapshot cache. Therefore the older installed-app profile and 83 MiB store do **not** justify enlarging that cache. Validate `CodeMapRootManifestTargetCacheTests.testFullScanDoesNotRedecodeStoreLargerThanDecodedCacheBudget` and the same-identity rewrite/checksum regression. Full reread/checksum work remains intentional integrity validation; this change does not replace it with metadata-only trust.

## Observability and validation

Read/search debug capture snapshots include `host_resources`: current total/CPU/I/O/process/background/memory limits, active counts by class, waiters, grants, peak physical concurrency, and cumulative admission wait. These counters are process-lifetime totals, not per-request spans or RSS measurements.

`HostResourceCapacityTests` covers resource scaling, pressure floors, background suspension, descriptor exhaustion/recovery, GUI descriptor headroom, shared CPU/process ceilings, memory-before-I/O-before-CPU progress, queued cancellation, physical settlement, release-once behavior, start-deadline semantics, and deterministic recovery hysteresis. Existing canonical lane tests assert host-derived capacities rather than fixed machine-independent numbers without weakening settlement/cancellation assertions.

`HostResourceBurstEvidenceTests` round-trips all bytes of 24 concurrent physical headless reads, asserts no leaked work/waiters and the shared physical ceiling, and prints timing. Its timing is diagnostic, not a flaky CI performance threshold. Run through Conductor. It is not a live-app, networking, MCP transport burst, or large-repository search benchmark.

Performance PRs should record exact source head, workload/bytes, current pressure envelope, peak concurrency, queue wait and before/after timings. Keep raw operational evidence local. Separate uncontrolled samples from a statistically valid speedup claim. Live measurements must use a compatible binary; an older already-running app cannot validate new source, and visible app lifecycle actions require separate authorization.
