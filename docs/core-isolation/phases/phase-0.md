# Phase 0 — Characterize Current Behavior and Freeze Inventories

**Date:** 2026-06-21
**Base:** `8e42951159c9f1d6973a4538a309908baacdb371`
**Scope:** Phase 0 only
**Production behavior changes:** none
**Phase 1 target/runtime scaffolding:** none
**Close disposition:** GO — Phase 0 closed; Phase 1 package/control-plane scaffolding may begin separately

## Objective and completed work

- Created the prescribed `docs/core-isolation/` packet and explicitly
  allowlisted its durable paths plus the authoritative investigation in the
  tracked-doc guardrail.
- Froze current and historical revisions plus source-document, manifest, resolved
  graph, test-list, ledger, and evidence hashes.
- Accepted the acyclic final target graph and `rpce_` C-symbol namespace.
- Inventoried Phase 1–2 package identities, dependency edges, boundary
  declarations, call-site classes, persisted fields, bridge declarations, and
  live exact test IDs in `migration-ledger.tsv`.
- Froze persistence filenames, fields, defaults, ordering, normalization, dates,
  dirty/saved generations, selection revisions, and stale-write reconciliation.
- Froze standalone headless v1 identity, NDJSON, lifecycle, tools, errors, state,
  root, secret, permission, limits, and shutdown behavior from reviewed immutable
  reference commits.
- Characterized P0-01 through P0-12 in
  `contracts/behavior-and-performance.md`.
- Added one discriminating characterization method and no other tests.
- Captured five normal search/catalog samples, five normal selection/prompt
  samples, and four comparable warm packaged-smoke samples plus one cold
  lifecycle sample.

## Characterization test decision

### Added

`root/RepoPromptTests.WorkspaceRootSyncTests/testWorkspacePersistenceLegacyDecodeCurrentEncodeAndCurrentReaderRoundTripContract`

- **Protected contract:** representative legacy workspace bytes decode into the
  current model; canonical JSON has the asserted schema/value/array-order subset;
  current bytes remain stable through the unchanged current app reader.
- **Plausible defect:** Phase 2 could rename/drop characterized persisted fields,
  reorder roots or selection arrays, change date/slice encoding, emit
  `contextBuilder` instead of `discover`, preserve removed fields, or break the
  current-reader round trip before an independent rollback reader exists.
- **Lowest faithful layer:** root SwiftPM because the current concrete persisted
  type still belongs to `RepoPrompt`.
- **Oracle:** canonicalize object keys only, compare exact current JSON values and
  arrays, re-decode, assert model equality/no normalization, and canonical
  re-encode equality.
- **Scenario count:** 3 — representative legacy decode, characterized current
  schema emission, and unchanged current-reader decode/re-encode.
- **ID changes:** one added ID; no rename, consolidation, removal, or replacement.
- **Ledger:** one surgical reviewed `retain` row; no generated overwrite.

### Deliberately not added

- P0-01 backend exclusivity: no inactive backend exists until Phase 5.
- P0-08 late CoreMacOS callback/exactly-once adapter stop: no adapter exists until
  Phase 3.
- P0-09/P0-10 dependency and symbol ownership: compiler/source/`nm` guards are
  the lower-cost faithful layer in Phases 1/3, not XCTest.
- P0-11 isolated headless process: no executable exists until Phase 8.
- Same-value numeric selection-revision and newer-peer ABA methods: current
  no-publication and A→B→A outcomes already discriminate those regressions.

## Exact evidence

### Revision and document freeze

`git rev-parse HEAD`, `git rev-parse origin/main`, `git rev-parse dev` and
`shasum -a 256` over the plan, investigation, `Package.swift`, and
`Package.resolved` all succeeded. Values are recorded in `README.md`.

The required investigation was initially absent. The user copied the
authoritative 469-line file into this worktree; its SHA-256
`e70138f9c73cd9d4e8e4f70e58bb91ef2ca2a59bb1c18b8547a030c350432a92`
matches the supplied provenance. This is resolved and not a blocker. The plan is
also explicitly unignored and both source documents are narrowly allowlisted so
the orchestrator can include them in the reversible checkpoint.

Remote reproducibility is bounded: `f86746c` is reachable from the current
feature tip and `487cd71d` from `core_split`, while reviewed rebase objects
`444c599c` and `21b5603f` were local-only archaeology. The complete reviewed
contract is frozen in this packet; later phases must not rely on fetching those
local-only objects. This limitation is documented and is not a Phase 0 blocker.

### Coordinated commands and results

| Command | Ticket | Result |
| --- | --- | --- |
| `make dev-test-list` (pre-change) | `3892b8d4-527b-4a2d-8616-f7954ff0206c` | exit 0; 1,866 exact root IDs |
| `make dev-provider-test-list` | `c19e1250-4d9d-4a77-8d76-9131f6bd2f9a` | exit 0; 7 exact provider IDs |
| environment-only opt-in search benchmark | `f2eb024a-26e1-4288-a16a-6873ed076915` | exit 0 but skipped; invalid timing sample |
| marker-opt-in search benchmark | `b31d6170-7fac-47fb-a659-a5dfb612f718` | exit 0; 5+5 measured samples; correctness passed |
| `make dev-format` (final) | `96048f58-4b20-4c62-99c1-970e16429877` | exit 0; 0/1,219 files reformatted |
| focused persistence characterization (final exact ID) | `c79b7fbe-7283-4c3e-a75f-03aa89d8e899` | exit 0; 1 test passed in 0.002 s |
| `make dev-test-list` (final) | `5fb563a0-1917-4433-aeec-4c85bf31885c` | exit 0; 1,867 IDs; only the new ID added |
| five selection/prompt samples | five tickets named in behavior/performance contract | all exit 0; 0.263–0.281 s |
| `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | internal root/provider list tickets `e68fa9b4-d321-4349-97ed-c48fe948317e` / `ecf0d3d8-7d1c-4c00-8d67-5d48a66b3aef` | exit 0; exact count 1,874 |
| `make dev-swift-build PRODUCT=RepoPrompt` | `f3708f61-c855-4e32-8a81-babd40248b9b` | exit 0; 3.150 s |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | `e2cbda71-e348-48c8-b6d6-d8c319ac80e6` | exit 0; 0.783 s |
| intended tracked-doc allowlist simulation | n/a | 10 tracked + 11 intended untracked = 21 simulated tracked; all allowlisted; zero unexpected |
| `make guardrails` | n/a | final post-allowlist rerun exit 0; layout, allowlist, and 49-package notice inventory pass |
| `make dev-lint` (final) | `97238530-f6a3-4b2a-8762-efde025fb673` | exit 0; strict lint/format check pass |
| `make dev-test` (initial post-addition) | `032f47fe-ddff-43a3-9d9c-23f2ac72ebf5` | exit 0; 1,867 tests, 2 skipped, 0 failures |
| `make dev-test` (final first attempt) | `01845838-97f4-4ccd-9650-da2047bacd4e` | exit 1; unrelated `MCPAskOracleWorktreeTests` `XCTUnwrap` failure |
| exact failing MCP test retry | `fd55a2b4-8f02-461f-bce2-0a0841ad2438` | exit 0; 1 test passed in 2.085 s |
| `make dev-test` (final retry) | `0246020e-0aea-4f22-b382-5478b4915259` | exit 0; 1,867 tests, 2 skipped, 0 failures in 222.096 s |
| `make dev-provider-test` | `6eb59a43-6aa0-4971-81c7-878678abd4a0` | exit 0; 7 tests, 0 failures |
| `make dev-build` | `e47c26de-45cd-41cd-84ac-9573885c576b` | exit 0; signed package/helper/architecture validation pass |
| visible `make dev-run` | `f4126869-c980-417d-9d9d-d04cd53a54d6` | approved; exit 0; packaged helper smoke and launch confirmed |
| five non-disruptive `make dev-smoke` samples | five tickets in behavior/performance contract | all exit 0; all `measurementInvalid == false` |
| `make dev-stop-app` | `5a7c4020-f8fc-45ed-9597-6220ba84a5ee` | approved; exit 0; stop confirmed |
| `./conductor app status` (final) | `aee28686-0248-4051-a761-bd9008d5b09c` | exit 0; running matching debug app PIDs: none |

Generated Xcode validation is not required in Phase 0 because `Package.swift` and
the target graph are unchanged.

### Evidence artifacts outside the packet

These are local validation artifacts, not source-controlled execution-packet
files:

| Artifact | SHA-256 / source |
| --- | --- |
| `/tmp/core-isolation-phase0-root-test-list.txt` | pre-change `d9e2dd3882ecd2e2f0ac8245fc9e733d06f9f58635a5c2aff3c59bef1a74207d` |
| `/tmp/core-isolation-phase0-root-test-list-post.txt` | final `d1217f6703a581562fb47a986bb2c0a8f4ee67b20ff40a41d395856d8c77d9e2` |
| `/tmp/core-isolation-phase0-provider-test-list.txt` | `af8669b714868d718314b12d53a2e4d3980e040a2cd4ede26d28d17d03368948` |
| `/tmp/core-isolation-phase0-search-benchmark.md` | `a46e8147347ef42d5bd2627d6740ba243be0d56e0a4206587204d46dbfd15a91` |
| `/tmp/core-isolation-phase0-selection-prompt-samples.tsv` | `f3b4cb1efe7d4fac5c667d0e87a54a3b9ecfff2af25f8230fb2ec04bea692daf` |
| `/tmp/core-isolation-phase0-packaged-smoke-samples.tsv` | `5ba057baf7c658f1973cc54a943942e51271e0710936e39ebe0ea6244eb43867` |
| Root list daemon log | ticket `3892b8d4-527b-4a2d-8616-f7954ff0206c` |
| Provider list daemon log | ticket `c19e1250-4d9d-4a77-8d76-9131f6bd2f9a` |
| Search benchmark daemon log | ticket `b31d6170-7fac-47fb-a659-a5dfb612f718` |
| Curated test ledger | `79f8f4240ac313f7ae23c0363e0eaeb99ead7d0287a6ea53fb04ab1d5db12404` |
| Phase 1–2 migration ledger | `a0da7280d425f335fdd8a2cef8d6eed57396d877db076048d49cdc6573d1a654` |

## Risks and blockers

- No architecture, contract, test, build, package, or lifecycle blocker is open.
- The historical fixed headless version was resolved by ADR-002: reconstructed
  packages use current release metadata.
- The user approved the narrow visible launch/smoke/stop sequence; the app is
  stopped again.
- An initial `make guardrails` invocation was terminated after it began waiting
  on an active coordinated SwiftPM job. It is invalid evidence. The final rerun
  occurred after all daemon build jobs settled and passed. After review exposed
  the staged-doc blind spot, exact packet/investigation/plan paths were added to
  the allowlist, the intended tracked set was simulated without staging, and
  guardrails passed again.
- The first final-tree full-suite rerun had one unrelated transient
  `MCPAskOracleWorktreeTests` artifact-path unwrap failure. Its exact focused
  retry passed, then the full 1,867-test lane passed. It is retained as lifecycle
  evidence and is not an open Phase 0 blocker.

## Close review checklist

- [x] No Phase 1 package/runtime scaffold.
- [x] Every inventoried Phase 1–2 boundary has destination, owning phase, and
  role owner.
- [x] Frozen graph has a topological order.
- [x] Twelve P0 hazards have current, structural, reviewed-reference, or assigned
  future oracles at the faithful layer.
- [x] Persistence and headless contracts are explicit.
- [x] Characterization test addition is discriminating and ledgered.
- [x] Post-change authoritative list and ledger reconciliation pass.
- [x] Coordinated builds, guards, lint, full tests, and package pass.
- [x] Performance evidence has 3–5 normal comparable samples for every required
  series.
- [x] Explicit Phase 0 GO/NO-GO disposition appended.

## Close disposition — 2026-06-21 (append-only)

**GO.** Phase 0 is complete. The frozen graph is acyclic; every inventoried
Phase 1–2 boundary has an owner/destination; P0-01 through P0-12 have a current,
structural, reviewed-reference, or owning-phase oracle at the faithful layer;
persistence and headless contracts are explicit; authoritative lists and ledger
reconcile; performance evidence is valid; all required build/test/style/package/
smoke lanes pass; and no production runtime or Phase 1 scaffold was introduced.

Phase 1 may begin only as a separate change that follows ADR-001 and preserves
all contracts in this packet. Phase 0 changes remain intentionally uncommitted
for orchestrator verification and the reversible checkpoint commit.
