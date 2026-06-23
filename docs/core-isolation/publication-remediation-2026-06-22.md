# Core-isolation publication remediation — 2026-06-22

**Status:** Publication remediation committed in integration merge `73302551`.
Final disposition: **GO**.

## Fixed provenance

- Completed Phase 0–8 checkpoint: `8046078ffe59f4130dc38dbecbb31b3485c9f735`.
- Upstream correctness source: `3b3384ba1006ed4771ac38d1132b8a7db6a78efc`.
- Integration mechanism: `git merge --no-commit --no-ff origin/main` with semantic
  conflict resolution against the extracted Core boundary.
- Final integration merge: `73302551` (`core isolation: reconcile upstream publication blockers`).

The app remains `RepoPrompt`, the compatibility proxy remains `repoprompt-mcp`,
and standalone direct-stdio v1 remains `repoprompt-headless`. No remediation may
reuse or collapse these identities.

## Blocker closure register

| Blocker | Classification | Required closure | Status / evidence |
| --- | --- | --- | --- |
| Strict Context Builder final-review authority and freshness | Production correctness | Preserve upstream deferred election, exact session-root authorization, strict artifact/diff validation and canonical selection freshness through Phase 5/6 seams | **Closed.** Upstream final-review election and finalized-authority checks now consume the extracted Core query facade. Focused worktree inheritance, automatic review, preassembly, policy, and exact-candidate suites pass. |
| Direct app POSIX/SyntaxCBridge/RepoPromptC dependencies | Structural isolation | Route behavior through reviewed Core/CoreMacOS value adapters with parity coverage, then remove target edges/imports | **Closed.** `RepoPrompt` has no direct target edge or import for the three implementation modules. Core owns string primitives; CoreMacOS owns descriptor/writer facades. Six string and two POSIX adapter parity tests pass. |
| Runtime-capable file tools after weak adapter loss | Production correctness | Use the exact admitted runtime/query snapshot for safe modes; UI-only modes fail closed without retargeting | **Closed.** Admission freezes the exact ticket, session query, lookup context, display policy, and codemap policy. Runtime-safe path/tree modes no longer dereference `promptVM`; admitted requests fail closed if the frozen context is absent. Legacy routing remains store-backed only when no runtime admission occurred. |
| Phase 6 path-leak guard | Guard/test | Correct regex semantics and retain negative physical-path fixtures | **Closed.** Regex escaping was corrected and the fixture set includes twelve physical-path negatives plus a logical-path positive. |
| Headless conductor/configuration failures | Control-plane / production correctness | Serialize status on `headlessArtifact`; propagate configuration failure from `tools/list` | **Closed.** `headless-status` claims `headlessArtifact`; descriptor loading throws and `tools/list` returns redacted `-32603` for corrupt, schema-incompatible, symlinked, or unreadable configuration. |
| Linked Tree-sitter ownership | Structural isolation / control-plane | Inspect every architecture slice of required binaries; app/headless export exactly fourteen unique definitions and proxy exports none | **Closed in debug products.** The coordinated all-product build verified exact fourteen app/headless entrypoints and zero proxy entrypoints. Universal/package evidence follows below. |
| Phase 8 status and publication evidence | Documentation/evidence | Record committed checkpoint and preserve append-only remediation evidence | **Closed.** Phase 8 names `8046078f` as the committed checkpoint; this addendum records the upstream merge and remediation evidence without rewriting the historical GO decision. |

## Linked Tree-sitter verification

`Scripts/verify_tree_sitter_symbols.py` parses defined-global `nm` output after
splitting universal Mach-O files by architecture. It normalizes the Mach-O
leading underscore and enforces these entrypoints exactly once in `RepoPrompt`
and `repoprompt-headless`:

`tree_sitter_c`, `tree_sitter_c_sharp`, `tree_sitter_cpp`,
`tree_sitter_dart`, `tree_sitter_go`, `tree_sitter_java`,
`tree_sitter_javascript`, `tree_sitter_php`, `tree_sitter_python`,
`tree_sitter_ruby`, `tree_sitter_rust`, `tree_sitter_swift`,
`tree_sitter_tsx`, and `tree_sitter_typescript`.

The compatibility proxy must export none of these fourteen entrypoints. Other
upstream grammar symbols, such as external-scanner callbacks, are outside this
entrypoint-uniqueness assertion. Verification is
wired into app and headless packaging/provenance, universal SwiftPM release
product construction, staged/signed/reviewed release validation, CI product
validation, and conductor's coordinated all-product build. Source guardrails
require the verifier, its fixtures, and these integration points without reading
stale build artifacts.

Deterministic parser fixtures cover valid, missing, duplicate, undefined-only,
unexpected, and proxy-absent symbol sets. Final evidence must record per-slice
results from the actual debug and universal release binaries.

## Validation and evidence checklist

- [x] Focused remediation tests and structural negative fixtures.
- [x] Authoritative Core/CoreMacOS/POSIX/headless/root/provider lists; final
  post-format suites are recorded below.
- [x] Curated ledger reconciliation from authoritative test IDs: 2,056 total
  (`root=1651`, `core=266`, `core-macos=36`, `posix=3`, `headless=93`,
  `provider=7`). `verify-ledger` passed without regeneration.
- [x] Guardrails, formatting, and strict lint. Formatter ticket
  `4d07664f-ad9d-41d5-9504-0586e34129a7`; zero-violation lint ticket
  `d9e2ded5-c4ba-4759-a87a-df8742437abf`; Python verifier/guard/release
  suites passed 92 tests.
- [x] All debug products, including linked-symbol verification: ticket
  `73f42a98-f54e-4a85-9802-abdf7aede12d`.
- [x] Debug and universal headless package/provenance/direct-stdio smoke.
- [x] Signed non-launching app package and unchanged embedded app-proxy smoke.
- [x] Exact stopped-process proof after approved visible app validation.
- [x] One independent Oracle review in review mode with straightforward findings applied.
- [x] Final GO/NO-GO disposition and exact evidence identifiers appended here.

### Test evidence

- Integrated pre-format root suite: 1,650 tests, ticket
  `4a99a678-7e1a-4d33-b84d-526b2c128778`.
- Focused legacy/worktree compatibility after strict query reconciliation: five
  tests, ticket `07764fa8-8513-4b20-ad68-97f6d3f7ca34`.
- Pre-format isolated suites passed: Core `6ee32b73-0ef7-451a-988e-b47ff5a37018`,
  CoreMacOS `afdbaac0-4fa3-45c8-8cb1-9dcf6b8d78a3`, POSIX
  `b83ca58b-ba88-4e34-9951-c2097d5312cd`, headless
  `016f79c5-0ad7-496b-9499-09ba42c40a41`, and provider
  `909ce718-a249-44ba-a097-79a677875b6a`.
- Final post-format suites all passed: root
  `509b5f5f-97dc-45e1-b792-91e2ea9c8b1e`, Core
  `aaf6c8cd-bb9e-475c-b58e-d8f19997b978`, CoreMacOS
  `5aaa9637-f000-44f0-949c-01952b7a574f`, POSIX
  `2ef9e8b5-23b4-4006-bcc5-2fa35684773a`, headless
  `70bed6fc-ea38-42b7-937c-e14b525b88f1`, and provider
  `66a579b4-ed43-49ac-a850-6c28b5024697`.
- After applying the Oracle findings, the focused runtime lifecycle suite passed
  on `c6b8fa42-1588-4c07-bbc8-a44f2db4b462`, the final 1,651-test root suite
  passed on `6a448535-6aae-429e-8870-18cff48e4e0e`, all debug products and
  strict symbol checks passed on `01604ff0-fff8-4483-bc6c-786cbb9ca599`, and
  the signed non-launching app package passed on
  `625ba81a-9559-401a-a21e-cdd19ad02948`. Final strict lint passed on
  `3d85523f-5f16-499d-90a8-063b0f947d5c`.

### Package and runtime evidence

- Signed non-launching debug app package:
  `2c2f23ad-90bb-489c-bc6d-2675d213848c`. Packaging verified the app's exact
  fourteen Tree-sitter entrypoints, the embedded `repoprompt-mcp` proxy's zero
  entrypoints, matching architectures, signature, helper layout, and helper
  `--version` smoke.
- Debug headless package/provenance/direct-stdio smoke:
  `8b8d1e93-3f24-4856-aa09-e8aecce4b720`,
  `d9db78fe-edf3-4be4-a4b4-f15f80a9f656`, and
  `a370847f-da1a-483a-a885-5f95feb313dc`.
- Universal release headless package/provenance/direct-stdio smoke:
  final post-review tickets `9662defc-19bd-4127-ab3c-dcaa58f07b4a`,
  `65a538d2-56e8-46e2-acb1-0ec20a7e50f6`, and
  `2c47b3b0-6fcb-4741-b153-41e31074058c`. The artifact contains `arm64` and
  `x86_64`, exports the exact fourteen entrypoints in each slice, and has SHA-256
  `fb871ac1f1273f8b276b21abb2b74fb6e1a5e8509fc88acbf34c8f7371ceb5f4`.
- After restarting the daemon onto the remediated control plane,
  `headless-status` advertised `headlessArtifact` on ticket
  `ba2c7c2c-787e-49f7-8e09-0aa74164861c`. An isolated writable-link
  install/status/uninstall cycle passed on tickets
  `6bc491f6-da94-4d21-ae87-891bae331704`,
  `427a28b5-0345-4ef6-89ef-98f4b4af34d7`, and
  `cf647a59-e6f2-40e3-b2da-fc18e921a16d`.

### Live app-proxy and independent-review evidence

- Approved visible debug relaunch/package: ticket
  `ecddadf7-adba-47d2-bd9a-f320311b6932`, exact launched PID `8330`.
- Unchanged live app-proxy smoke: ticket
  `27d5387a-838d-47c2-bf44-784290b86986` (`windows`, workspace switch,
  roots, worktree inventory, and agent catalog).
- Manually curated staged Git snapshot `2026-06-22/0551`: 88 files,
  `MAP.txt` plus `diff/all.patch`, compare `staged`, scope `all`, mode `deep`.
- One completed Oracle review in `review` mode, chat `untitled-chat-8AE523`.
  Export:
  `prompt-exports/oracle-review-2026-06-22-060653-untitled-chat-8ae523-b29d.md`
  (local evidence only; intentionally not staged).
- Oracle P1 findings were applied without a second review:
  1. parser verification now rejects every unexpected `tree_sitter_*` parser
     entrypoint in app/headless and every parser entrypoint in the proxy while
     retaining explicit external-scanner allowance and negative fixtures;
  2. adapter-derived file-tool state is frozen and mapping-checked before Core
     admission, after which runtime-capable work consults no weak adapter; a
     deterministic post-admission adapter-loss regression test was added;
  3. this addendum now contains the final evidence and disposition.
- Approved stop: ticket `2e97f09f-3d3f-4789-9480-ce50951774a8`.
  Exact executable
  `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt`
  was checked with exact `pgrep -f -x` matching and reported absent.

## Final disposition

**GO.** All independent-audit blockers and the straightforward independent
review findings are closed in integration merge `73302551`. The external
identities remain `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless`;
Phase 9 remains deferred.

## Phase 9 boundary

This remediation does not remove compatibility aliases or rollback backends,
converge headless onto Core sessions, share app/proxy/headless state or transport,
or change external identities. Those items remain deferred to a separately
characterized Phase 9+ migration.
