# Apple Identity Migration

RepoPrompt CE cannot treat a Developer ID and bundle-identifier replacement as an ordinary in-place
Sparkle update. The rollout must preserve the legacy signing anchor long enough to prepare secure
storage, use a notarized installer to cross the application identity boundary, and only then return to
ordinary ZIP updates.

## Current public state and no-go decision

Stable has not started the identity transition and must remain untouched until the Tip sequence is
proven. The only public Tip migration release is the preparer:

- tag: `tip-2f94412e6ab5`;
- build: `35.15.18`;
- `identity-rollout.json` SHA-256:
  `3c69703fa7582105633b36e8874fe2a28e1832aabb776351e68dbf3367e122db`.

The live Tip appcast contains that P ZIP item only. No public T tag, release, or transition package
exists. Source changes that select the transition role do not mean the transition has occurred.

T is **NO-GO** because a missing journal after a committed migration can currently start a new bridge
from stale legacy source data. N is also **NO-GO** because a genuinely fresh successor installation is
not distinguishable from an unsafe installation that skipped P. These are runtime design blockers, not
release-script failures; they are detailed below.

## Fixed identities

| Identity | Bundle identifier | Team identifier |
| --- | --- | --- |
| Legacy and P | `com.pvncher.repoprompt.ce` | `648A27MST5` |
| T and N | `com.repoprompt.ce` | `69N6K965SF` |

The existing Sparkle EdDSA key and the Stable and Tip feed URLs remain unchanged. Stable and Tip are
separate channels, but P, T, and N within one channel are accumulated items in that channel's single
`appcast.xml`; they are not sibling transition feeds.

## Tip release authority and ownership

Tip setup resolves release intent exactly once from the approved source commit, trusted tooling commit,
committed policy, rollout declaration, `version.env`, and the bounded Stable appcast downloaded as a
GitHub release asset over HTTPS. That GitHub asset/HTTPS delivery is the setup trust root for the
Stable input; the appcast is not independently authenticated. Setup records its exact hash in the
canonical context, whose detached digest authenticates byte-for-byte carriage downstream.
`Scripts/tip_release_context.py` writes canonical `tip-release-context.json` plus the detached
`tip-release-context.json.sha256`. The context has a closed schema, input digests, exact source/tooling
commits, and self-contained semantic invariants. Every later job and child boundary verifies those exact
bytes and expected commits; it must not reload or re-project policy, declaration, or version data.

`Scripts/stable_rollout.py` remains the shared manifest/appcast algorithm, but its historical
`packaging-context` command is not Tip authority. Protected credentials supply private material only.
A P12, profile, notary key, Sparkle seed, or repository token cannot select a role or change the
expected public identity.

Stable retains its separate reviewed declaration, but follows the same single-resolution rule at
each stage and publish boundary. `stable_rollout.py packaging-context` validates the requested phase
against `release-rollout.json`, selects the policy-owned application identity and conditional P
migration anchor, and exports those immutable values once. `package_app.sh` and
`sign_staged_release.sh` compare staged metadata, the provisioning profile, imported certificate,
signed app, and migration anchor against that export; they do not carry Apple identity literals or
silently reselect an identity from `version.env`.

| Value | Source owner | Immutable context field / final owner |
| --- | --- | --- |
| Role, eligibility profile, migration phase, installation form, predecessor pins | `tip-rollout.json` validated by the reviewed role tuple | `rollout` |
| Approved source, trusted tooling, and authority-input hashes | Exact setup checkouts; Stable appcast from a GitHub release asset over HTTPS as the setup trust root | `provenance` and the detached context digest authenticate exact downstream carriage |
| Application bundle ID, Team ID, designated requirement, certificate label, profile application identifier | `Scripts/apple_identity_policy.json` selected by role | `applicationSigning`; imported P12/profile bytes are only validated material |
| P's successor migration anchor | Successor application identity in policy, required only for P | `migrationAnchorSigning`; the extra successor P12 is material, not authority |
| Installer Team ID and certificate label | Successor Installer identity in policy, required only for T | `installerSigning`; the Installer P12 is material, not authority |
| Sparkle public identity, feed, repository, and minimum macOS | Policy | `sparkle`; `SPARKLE_PRIVATE_KEY` is signing material only |
| Package identifier and component schema | `identityTransitionPackage` policy, validated only when the selected role is T/package | `package`, non-null only for T |
| Marketing version and app/display names | `version.env` at the approved commit | `release` |
| Build number | Authenticated Stable maximum plus approved-source commit sequence | `release.buildNumber` |
| Commit, short SHA, tag, archive basename | Exact approved source commit | `release.commit`, `shortSha`, `tag`, and `archiveBasename` |
| Publication repository, flags, and exact asset names | Selected Tip feed/repository and installation form | `publication` |
| P/T/N appcast items and predecessor floor | Context predecessor pins plus authenticated predecessor manifests | `identity-rollout.json`; `stable_rollout.py` renders `appcast.xml` |

The Tip build is `<Stable maximum>.<source sequence / 100>.<source sequence % 100>`, the tag is
`tip-<first-12-source-SHA>`, and the archive basename is
`RepoPrompt-tip-<first-12-source-SHA>-<build>`. The exact public inventory is context-derived:

- every role: `appcast.xml`, `SHA256SUMS`, the artifact manifest, metadata,
  `identity-rollout.json`, `tip-release-context.json`, and its detached digest;
- P and N: ZIP and DMG assets, with the ZIP as the Sparkle enclosure;
- T: the transition PKG as the Sparkle enclosure.

## Current single-P P to T to N feed model (not release-ready)

| Role | Application identity | Runtime migration phase | Installation / enclosure | Manifest eligibility floor |
| --- | --- | --- | --- | --- |
| P / `preparer` | Legacy | `legacy-preparer` | Application / ZIP | None |
| T / `transition` | Successor | `disabled` | Package / PKG | Exact retained P build |
| N / `successor` | Successor | `disabled` | Application / ZIP | Exact retained T build |

This table describes only the currently implemented **single-P** declaration/appcast state machine;
the public P is P1. It cannot be read as support for publishing an original P1, then a hardened P2,
then T. Without some other durable provenance, P2 cannot distinguish a journal that was never created
from a committed journal that was lost before P2 observed it. An ungated P1-to-newer-P2 update is
therefore unsafe. A coherent blocker-A follow-up must either provide another durable provenance
mechanism, or retain P1, gate P2 on P1, make a nil journal fail closed in P2, and retain both preparer
stages through T and N. The current declaration, appcast, and publication transition graph implements
only P-to-T, T-to-N, and later N-to-N; it does not implement P1-to-P2-to-T. T remains **NO-GO**.

`identity-rollout.json` has one predecessor-floor authority: `minimumUpdateVersion`. For each gated
item it equals the immediately older retained build. The current single P is ungated. Appcast rendering
projects a gated value into both `sparkle:minimumUpdateVersion` and
`sparkle:minimumAutoupdateVersion`, with exact equality. Only `minimumUpdateVersion` is an exclusion
boundary, and relying on it requires every supported source client to embed Sparkle 2.9 or later.
`minimumAutoupdateVersion` affects automatic-update behavior; it is not an exclusion gate and cannot
substitute for `minimumUpdateVersion`.

The repository's `AppcastParser` XCTest exercises passive UI eligibility only. Update discovery,
selection, and installation belong to Sparkle, so parser mocks do not prove the real client will take
the intended step. Before T, authenticate every supported predecessor artifact, verify that its
embedded Sparkle is at least 2.9, and exercise generated P1/P2/T/N appcasts through real Sparkle. The
acceptance matrix must cover fresh P1-to-P2 routing, P1-to-P2-to-T, delayed P1 and P2 clients after N,
and retention of both P1 and P2 history, in addition to committed-journal loss before and after P2.

The public P manifest predates the manifest authority and represents its null floor as
`minimumAutoupdateVersion: null`. Tooling may normalize only that exact authenticated, digest-bound,
single-P legacy form to `minimumUpdateVersion: null`; it does not accept an unauthenticated or gated
legacy variant and does not create a second authority. This normalization remains valid only while the
rollout has no P2. If blocker A adopts P1/P2, the manifest policy, transition graph, and retention rules
must expand explicitly rather than treating the existing single-P exception as P1/P2 support.

Under this current single-P contract, the Stable maximum obtained through that setup trust root must
remain strictly below retained Tip P.
For example, Stable build `35` is below P `35.15.18`, while Stable `36` blocks T/N feed generation.
This prevents a non-P build from satisfying T merely because it has a newer channel build number.

The release-capable workflow and `main-tip-publish` job both queue rather than cancel. Under that lock,
the publisher performs a fresh bounded check of live source `main`, the live rollout manifest, and the
live appcast before any mutation. For the currently implemented single-P graph, the candidate must still be exact current main, have a
strictly newer build, advance P to T, T to N, or N to a newer N, and retain exact digest-pinned history
without role regression or skipping. This graph is not proof that T is safe while blocker A remains. It then creates or resumes one exact draft, uploads only absent assets, and
byte-audits the complete draft. Immediately before the publication PATCH it repeats the source-main and
live rollout checks and retained-enclosure audit, then repeats the complete release audit anonymously.
A stale late run fails; only a fully byte-audited existing public tag is accepted as success.

## Upgrade populations

| Population | Required behavior |
| --- | --- |
| 1. Legacy Stable user who never installed P | Stable remains legacy today. The later Stable rollout must first deliver a legacy Stable P. T's hard floor must exclude the original legacy build, and N's floor must exclude P. Tip evidence cannot substitute for an independently verified Stable ladder. |
| 2. Tip user currently on public P | Public P1 remains on the legacy identity, but the current pipeline cannot safely route it through a hypothetical hardened P2. T stays blocked until blocker A has a durable provenance design and, if that design uses P2, the declaration/appcast/publication graph gates and retains P1 and P2. |
| 3. Tip user who waits until after N exists | Under the conditional single-P design, the accumulated N/T/P feed is intended to filter N out and offer T from P, but that selection still requires the real-Sparkle proof above. If blocker A adopts P1/P2, N feed regeneration must retain both preparers and T, and real Sparkle must route delayed P1 and P2 clients without skipping a required stage. |
| 4. User who installs T but does not launch it | The package may replace `/Applications/RepoPrompt CE.app`, but runtime bridge activation has not occurred until launch. The official proof sequence must launch and verify T before N is published; installing T is not migration completion. |
| 5. Fresh successor user | Current runtime cannot distinguish this valid case from skipped P and therefore requires a bridge and falls back to nonpersistent/blocked behavior. N must not ship until explicit release-role/provenance and a successor-only persistent-storage initialization design make the distinction safely. |
| 6. User with a partial migration | A readable `preparing` journal resumes the same attempt idempotently; unreadable, malformed, or ACL-invalid authority fails closed. A missing journal after commit is the blocker described below and must not be treated as an ordinary fresh attempt. |
| 7. User who manually replaces or moves the app | T targets `/Applications`; a manually moved legacy copy can remain alongside it and the installer does not delete arbitrary copies. A successor ZIP that bypasses P/T has no authenticated bridge and fails closed. Manual copies are outside duplicate-app reconciliation and require explicit operator cleanup. |

## SecureStorageIdentityMigration audit

### Implemented behavior

The version-2 migration catalog is frozen at exactly 24 accounts: provider and CLI credentials, two
Claude-compatible keys, and six agent-permission documents. P reads each generic-password value from
the legacy Developer ID service and copies the exact string value to an attempt-scoped bridge service.
Values are not rewrapped, reconstructed, or transformed. New accounts must not expand this catalog;
after commit they are created in the authoritative bridge backend.

Before bridge mutation, P creates a version-2 Keychain journal containing `preparing`, a random attempt
identifier, and the sorted 24-account catalog. The journal, bridge values, and committed bridge manifest
use a classic Keychain ACL whose accepted applications are validated against the exact legacy and
successor designated requirements. The bridge-manifest value must equal the committed journal encoding
byte-for-byte. JSON shape is considered only after the Keychain item ACL is authenticated.

Preparation is idempotent while the journal remains present:

1. all legacy source and existing attempt-bridge values are read noninteractively;
2. a present source is created or recopied byte-for-byte when different;
3. an attempt-bridge value whose source is now absent is deleted before commit;
4. all 24 source/bridge results are read back and compared;
5. the committed bridge manifest is created and verified; then the journal changes to `committed`;
6. repeated P launches verify the committed projection and activate the same bridge.

An interruption or copy/read-back failure before commit leaves the journal in `preparing`; a later P
launch resumes that same attempt instead of treating the partial bridge as authoritative. The bridge is
selectable only after the committed journal and matching authenticated bridge manifest both verify.

The legacy source items are never rewritten or deleted. There is no implemented legacy-item, bridge,
or journal cleanup. That preserves rollback but also means eventual cleanup requires a separate design.
A committed journal and matching bridge manifest whose 24 records are all absent means **prepared but
empty**. No journal means **not proven prepared**; it is not equivalent to an authenticated empty
migration.

Tests use storage mocks and validate state-machine and ACL-policy plumbing. They are not proof that two
real Developer ID applications from different Team IDs receive the intended macOS Keychain ACL behavior.
That proof still requires an isolated VM/account or repository-documented disposable Keychain harness
with real legacy/successor-signed artifacts and synthetic values. Never probe a maintainer's login
Keychain.

### Blocking runtime defects

**A — post-commit journal loss can rebootstrap stale legacy state (T NO-GO).** If a committed bridge has
become canonical and its journal item is later missing, the current P sees `nil`, reads the original
legacy service, and creates another attempt. Credentials changed only in the bridge can then be replaced
by stale legacy values. A later preparer cannot infer whether `nil` means the journal was never created
or a committed journal was lost before that later build; installing newer code does not manufacture
that missing provenance. A missing journal must not authorize restart.

The blocker-A follow-up must either add another durable provenance mechanism that survives this loss,
or define a real P1/P2 rollout: retain P1, gate P2 on P1, make `nil` fail closed in P2, and retain both
preparer stages through T and N. The current rollout state machine has no P1-to-P2-to-T transition, so
an ungated newer P is not a safe shortcut and T remains **NO-GO**. Acceptance requires explicit tests
for committed-journal loss before P2, committed-journal loss after P2, fresh P1-to-P2 routing,
P1-to-P2-to-T, delayed P1/P2 clients after N, and retained P1/P2 appcast history. Any added marker must
remain non-authorizing: it must not become an alternate bridge pointer or proof that bridge contents are
valid.

**B — fresh successor and skipped P are indistinguishable (N NO-GO).** Runtime currently sees the
successor signing domain and a `disabled` migration phase for both T/N. With no authenticated bridge it
cannot know whether this is a fresh user who should initialize successor storage or an upgrader who
skipped P and must be blocked. N requires explicit runtime release role/provenance plus a reviewed
successor-only persistent-storage design. It must allow safe fresh initialization without weakening the
skipped-P fail-closed boundary.

## Deterministic transition package

`Scripts/build_identity_transition_pkg.sh` never runs `pkgbuild --analyze`. The component plist is a
canonical top-level array with exactly one dictionary:

| Key | Exact value |
| --- | --- |
| `RootRelativeBundlePath` | `RepoPrompt CE.app` |
| `BundleIsRelocatable` | `false` |
| `BundleHasStrictIdentifier` | `false` |
| `BundleIsVersionChecked` | `true` |
| `BundleOverwriteAction` | `upgrade` |

The package is script-free, identifier `com.repoprompt.ce.transition`, installs exactly one app at
`/Applications`, and is assembled with `pkgbuild`, `productbuild --package`, and `productsign` from the
verified context. Real `pkgbuild` output has `pkg-info relocatable="false"` **and** an empty
`<relocate/>`; presence of the element is not relocation permission. It also has:

- one top-level `<bundle path="./RepoPrompt CE.app" ...>` whose identifier, marketing version, and
  build match the verified successor app context;
- exactly one `<bundle>` child in each of `<bundle-version>` and `<upgrade-bundle>`, with the successor
  identifier; `path`, `CFBundleShortVersionString`, and `CFBundleVersion` are optional there and must
  match the verified context only when `pkgbuild` emits them;
- empty `<update-bundle/>`, `<atomic-update-bundle/>`, `<strict-identifier/>`, and `<relocate/>`.

Expansion validation checks those meanings, package ID/version/install location, absence of scripts,
Installer signature and Team ID, stapling, payload app bundle ID and Team ID, universal architectures,
artifact-manifest consistency, and an exact byte-tree comparison with the intended signed app.

Each material command directly execs the process-group supervisor. Bounds are 60 seconds for component
plist generation, 300 seconds for payload copy, component package, product archive, signing, stapling,
signature validation, expansion, and payload comparison, and 1,860 seconds for package notarization.
The supervisor owns a new process group, forwards cancellation, applies TERM then KILL, reaps it, and
unlinks its mode-0600 raw capture before child launch. Failure events include timestamp, phase, command,
elapsed time, caller-computed app/payload sizes, relevant paths, and a bounded redacted output tail.
Successful notary evidence exposes only the normalized submission UUID and `Accepted` status.

GitHub Actions shows application signing, application notarization, component-plist generation,
component package, product archive, package signing/notarization, expansion, payload comparison, and
publication as separate boundaries. A stalled package phase must not be reported as application
notarization.

## Retention and transition-code removal

Normal N generation must retain T and P in newest-first order; it cannot prune them because a newer N
exists or because time passed. Removal from an appcast requires a separate reviewed compatibility change
and all of these conditions:

1. Tip P to T to N and the independent Stable P to T to N sequence have both completed and passed their
   published-package, local-transition, and subsequent-N proofs.
2. The declared minimum supported source build for both channels is above every legacy/preparer build,
   and support policy explicitly ends direct update support for those builds.
3. No supported installation can still require P or T to reach N; the decision is backed by the agreed
   support/adoption evidence, not elapsed time alone.
4. The public P/T tags, packages, manifests, and digests remain immutable and archived even if their
   items leave the active feed.
5. A reviewed PR changes the allowed role chain, fixtures, parser compatibility, and delayed-upgrader
   tests. Ordinary feed regeneration is not that removal mechanism.

Transition package construction, Installer-only secrets, and P/T workflow branches can be removed only
after those conditions hold for both channels. The duplicate minAuto XML projection and passive-parser
compatibility can be removed only after the already-shipped P parser is outside support. Secure-storage
bridge activation cannot be deleted merely because P/T leave the feed: it remains the canonical backend
for migrated users until a separately reviewed successor-only storage migration moves those values or
the product explicitly commits to permanent bridge support.

## Required proof and next action

The runtime follow-up must add regressions for blocker A and B, then use isolated real-signature ACL
testing with synthetic values. Protected validation must also exercise the deterministic package with
real `pkgbuild`/`productbuild`/`productsign`, notarization/stapling, expansion, `/Applications`
replacement, duplicate-app inspection, and P-to-T-to-N Sparkle selection. It must not install or launch
an app without explicit approval.

The next action is **not** another T dispatch. Merge the reviewed release-pipeline PR, obtain its exact
main SHA, require hosted CI and the automatic dispatch guard to pass for that SHA, run the protected
package validation, and complete the blocking runtime follow-up. Only after those results are reviewed
should an operator present exact candidate inputs and request explicit authorization for T.

During this recovery window the automatic Tip `workflow_run` lane is legacy-only. P, T, and N are
manual-capability roles: each requires an exact-role confirmation and protected-environment approval,
but those gates do not authorize a release. P and T remain manual transition operations. Only after
blockers A and B are repaired and the first T and first N are proven may a separate reviewed change
enable ordinary subsequent N automation; that change must preserve the retained P/T appcast history
and delayed-upgrader contract.
