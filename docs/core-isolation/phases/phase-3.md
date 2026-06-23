# Phase 3 — Platform Contracts and Adapters

**Date:** 2026-06-21
**Implementation base:** `f131b7892023d06b9d3861bafd395c64a7f8a371` (clean Phase 2 checkpoint)
**Status:** closed
**Disposition:** **GO** for Phase 4 planning; Phase 4 implementation has not begun

## Scope

Phase 3 establishes neutral platform contracts and moves only low-level platform
ownership into `RepoPromptCoreMacOS`, `RepoPromptPOSIXSupport`, and
`RepoPromptSyntaxCBridge`.

The following intentionally remain in `RepoPrompt` for Phase 4 or later:

- `WorkspaceFileContextStore` and root/readiness lifetime;
- event ingress, mailbox ordering, watermarks, coalescing, recovery, and root
  generation policy;
- Combine publication and all app-facing observation;
- crawl/ignore policy, content scheduling/caches/telemetry, mutation validation
  and reconciliation, provider orchestration, secure-storage selection, and
  signing requirements.

No Phase 4 engine extraction or Phase 5 composition/authority work is included.

## Implemented ownership

1. `Sources/RepoPromptCore/Platform` owns neutral watcher events/protocols plus
   directory, content, mutation, process, secure-storage, signing, diagnostics,
   and runtime-path contracts.
2. `RepoPromptPOSIXSupport` owns descriptor and write helpers.
   `RepoPromptSyntaxCBridge` owns exactly fourteen upstream
   `tree_sitter_*` declarations. The app bridging header and its unsafe Swift
   flags are removed.
3. Keychain/Security and code-signing inspection live in
   `RepoPromptCoreMacOS`; app storage selection and signing requirements remain
   explicit app policy.
4. FSEvents translation, directory access, content snapshot/decoding, mutation
   primitives, and POSIX process launch live in `RepoPromptCoreMacOS`.
5. `CoreCompatibilityAliases.swift` contains the classified temporary Phase 3
   app aliases; it contains no concrete duplicate implementation.

## Behavioral invariants

- Native FSEvent flags are translated only in the macOS adapter; synthetic app
  tests construct semantic flags directly.
- Callback paths, flags, and IDs are copied before neutral delivery. External
  stop is a delivery barrier, disposal is exact-once, and late callbacks are
  rejected while callback context remains valid through native disposal.
- Existing app ingress, recovery, root lifetime, accepted watermarks, and
  Combine publication remain above the neutral callback seam.
- Directory-open error text and partial-read behavior, injected DEBUG metadata
  access, Keychain policy/errors, and process descriptor failure stage are
  preserved.
- App and MCP callers import their POSIX/syntax/C owners explicitly.

## Tests and control plane

- Nine existing `KeychainServiceTests` methods moved intact from root to
  `RepoPromptCoreMacOSTests`.
- Four direct `MacOSFSEventsWatcherTests` cover ordered deep-copy delivery,
  memory-safe late-callback rejection/exact-once disposal, external-stop
  delivery fencing, and start-failure cleanup.
- Three direct `POSIXDescriptorSupportTests` cover descriptor flag
  preservation, typed invalid-fd failure, and negative socket shutdown.
- Coordinated CoreMacOS/POSIX test and authoritative list lanes, Make aliases,
  CI steps, optimizer mappings, and curated ledger rows are active.
- Final method census: root 1,854; Core 6; CoreMacOS 13; POSIX 3; provider 7;
  total 1,883. Reserved syntax/headless prefixes remain zero.
- Final scenario census: root 2,384; Core 12; CoreMacOS 13; POSIX 3; provider
  16; total 2,428.

## Single independent review

One independent review was run in review chat `phase-3-review-C877F4`.
It found four bounded issues: native constants entering semantic flags, unsafe
late-callback test context plus a missing external-stop delivery barrier,
metadata lookup bypassing the DEBUG filesystem override, and loss of the
descriptor get/set failure stage. All four were corrected before the final
gate. No second review was run.

## Validation evidence

### Control plane, style, and ledgers

- `make conductor-selftest`: 67 conductor lifecycle tests plus all companion
  selftest suites passed.
- `make xcode-generator-test`: 23 tests passed.
- `make xcode-validate`: generated workspace validated with
  `xcodebuild -list`.
- `make guardrails`: source-layout, contributor allowlist, Core-isolation,
  notice, scanner checksum, target graph, import, and package-separation checks
  passed.
- `test_core_isolation_guardrails.py -v`: 9/9 passed.
- `verify-ledger`: 1,883 exact authoritative IDs reconciled across the five
  declared targets.
- `make dev-format`: ticket
  `6b473086-d733-410c-b0b2-cf8681032ef9`, zero files remained to format.
- `make dev-lint`: ticket `9768e1bd-1795-4a85-9ed6-ae1dc6c95f65`; SwiftFormat reported 0/1,253 files and SwiftLint reported 0 violations.

### Builds

All coordinated builds completed with exit 0:

| Target/product | Ticket |
| --- | --- |
| `RepoPromptCore` | `d222e209-c987-4713-ab23-1012edf1ff5a` |
| `RepoPromptPOSIXSupport` | `b10913a2-2afb-4d61-b8c7-f51d10f5e154` |
| `RepoPromptSyntaxCBridge` | `03989ebf-9071-42a2-8dd5-30fa3d0d8c27` |
| `RepoPromptCoreMacOS` | `5dda0671-9ac0-4259-8374-c116f1640f23` |
| `RepoPromptHeadless` scaffold | `31b3bc51-183b-412e-85a0-a32a1c26f203` |
| all products: app, proxy, headless | `9bff430a-b51e-407c-ae92-a1954c97d84d` |

### Tests

All final coordinated lanes completed with exit 0:

| Lane | Result / ticket |
| --- | --- |
| Core | 6/6, `64d4dbcf-8801-4ef9-b1ea-3bc3caedcd0c` |
| CoreMacOS | 13/13, `d772772d-cfa3-4242-bc48-c7428d1383ea` |
| POSIX | 3/3, `eca063bc-9fb4-4127-b8d6-18b5609324e0` |
| provider | 7/7, `face2824-0002-4cc6-8e1b-40f24928153c` |
| root | 1,854/1,854, `bcb104bf-f63c-44ba-8af0-2655c62a0872` |

Focused retained-app oracles also passed: accepted-ingress barrier 10/10
(`59fca501-c452-4658-8f8d-c7d54fe37854`), process descriptor inheritance
5/5 (`573fdecd-fa74-4fc3-9b31-ab5a9b6eb7ce`), and secure-storage boundary 5/5
(`f32d6c05-5a8c-453a-9579-b036f62be719`).

### Package and binary assertions

- Debug package/sign/architecture/helper smoke passed:
  `784b125e-492a-4947-808b-34519c6b8238`.
- Packaged app contains `RepoPrompt` and `repoprompt-mcp`; standalone
  `repoprompt-headless` remains outside the app bundle.
- Neutral Core forbidden platform imports: 0.
- App Phase 3 direct CoreServices/Security/charset imports: 0.
- Old bridging header, bridging flags, and Shared POSIX duplicate: absent.
- Syntax header declarations: exactly 14.
- Syntax bridge object `tree_sitter_*` definitions: 0.
- Linked app grammar entry points: all 14, each defined exactly once.

## Risks and follow-up

The deliberate boundary leaves app orchestration dependent on temporary aliases
and injected adapters. Phase 4 may move engines only after preserving this
contract. Phase 5 composition work remains unstarted.

## Close disposition

**GO.** All scoped implementation, one-time review corrections, authoritative
tests, builds, package checks, imports, symbol ownership, ledgers, and durable
documentation are complete. Changes remain uncommitted. This close disposition
is append-only.
