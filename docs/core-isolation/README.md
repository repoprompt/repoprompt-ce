# Core Isolation Execution Packet

**Created:** 2026-06-21
**Current phase:** Phase 0 — closed, see [phase-0.md](phases/phase-0.md)
**Disposition:** GO for Phase 1, subject to the frozen graph and contracts in this packet
**Production behavior change:** none
**Phase 1 scaffolding present:** no

This directory is the compact execution record for
[Core Isolation Reconstruction](../plans/core-isolation-reconstruction-2026-06-20.md).
It is not a second issue tracker. Later phases append newly discovered boundary rows
with provenance rather than rewriting the Phase 0 census.

## Frozen provenance

| Item | Revision / SHA-256 |
| --- | --- |
| Phase 0 implementation base (`dev`, `main`, `origin/main`) | `8e42951159c9f1d6973a4538a309908baacdb371` |
| Execution plan | `d3af73d32ae00d27fd8b09240986a579605b7d01245dea45c4e31533e3956464` |
| Source investigation | `e70138f9c73cd9d4e8e4f70e58bb91ef2ca2a59bb1c18b8547a030c350432a92` |
| Current `Package.swift` | `f8aee0f3d6b2f4397f1827f763b92ff58814b1611f15e33c27ef19a5b83586fd` |
| Current `Package.resolved` | `619a752f9015f1544aa4d8438e5ebad106b8402aba4d6b7febe5bdb4b518dacc` |
| Reference feature snapshot | `f86746c8007a2dc95faf40d78cd5467e59792086` |
| Rebased reviewed snapshot | `444c599cb63d9a5439c5db961f819a3a74a2722b` |
| Review hardening follow-up / `pr/118-rebase` | `21b5603f5a333454aee899dd39ff38d860a5b716` |
| Reference feature branch tip | `3dd01a3efe1326e4774cd677e1f6773323ad65ae` |
| Reference linear history tip | `f4b8d59839fc389074168f1d3dfc4760f8131cb7` |

The parallel reference checkout was dirty during Phase 0 in three unrelated MCP/Codex
files. It was used only through immutable Git objects; no working-tree bytes were
accepted as contract evidence.

The currently fetchable reference tips are `origin/feature/core-isolation-headless-foundation`
at `3dd01a3efe1326e4774cd677e1f6773323ad65ae` and `origin/core_split` at
`f4b8d59839fc389074168f1d3dfc4760f8131cb7`. Snapshot `f86746c` is reachable
from the former and security hardening `487cd71d` is reachable from the latter.
The reviewed rebase snapshots `444c599c` and `21b5603f` existed only on the local
`pr/118-rebase` archaeology branch and are not ancestors of either current remote
tip. Their contracts were transcribed and spot-checked during Phase 0; this packet,
not continued availability of those local objects, is the canonical execution
contract. No later phase may depend on fetching those two objects.

## Packet index

- [ADR-001 — Target graph and CE C-symbol namespace](decisions/ADR-001-target-graph-and-c-symbol-namespace.md)
- [ADR-002 — Headless version and transport identity](decisions/ADR-002-headless-version-and-transport-identity.md)
- [Behavior, hazards, tests, and performance](contracts/behavior-and-performance.md)
- [Persistence schema and compatibility](contracts/persistence-schema.md)
- [Standalone headless v1 contract](contracts/headless-v1.md)
- [Phase 1–2 migration ledger](migration-ledger.tsv)
- [Phase 0 evidence and disposition](phases/phase-0.md)
- [Deferred Phase 9+ work](deferred-work.md)

## Mutation policy

- Accepted ADRs are immutable; supersede them with a new ADR.
- Contract files are frozen at Phase 0 close. Later corrections are append-only and
  must name the correcting phase and evidence.
- `migration-ledger.tsv` is append-only after Phase 0 close. Do not delete or
  rewrite a row; append a superseding row with provenance.
- Phase records have mutable work/risk/evidence sections until close and an
  append-only close disposition thereafter.
- Deferred work is append-only.

## Gate summary

Phase 0 freezes:

- one acyclic target/product graph and one owner/destination for every inventoried
  Phase 1–2 boundary;
- current persistence locations, fields, defaults, ordering, dates, generations,
  revisions, and stale-write behavior;
- exact authoritative root/provider test censuses and scenario totals;
- current or reviewed-reference oracles for P0-01 through P0-12;
- the standalone headless v1 CLI, NDJSON, tool, error, state, root, secret,
  permission, and shutdown contract;
- five normal search/catalog samples, five normal selection/prompt samples,
  four comparable warm packaged app-proxy smoke samples, and one cold lifecycle
  smoke sample.

Phase 1 may add package/control-plane scaffolding only. Runtime ownership and
behavior remain out of scope until their owning phases.
