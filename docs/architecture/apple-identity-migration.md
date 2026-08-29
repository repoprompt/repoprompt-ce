# Apple Identity Migration

RepoPrompt CE cannot treat a Developer ID and bundle-identifier replacement as an ordinary in-place
Sparkle update. The migration must preserve the legacy signing anchor long enough to prepare secure
storage, then use a notarized transition installer to cross the application identity boundary.

## Fixed identities

| Phase | Bundle identifier | Team identifier |
| --- | --- | --- |
| Legacy and preparer | `com.pvncher.repoprompt.ce` | `648A27MST5` |
| Successor | `com.repoprompt.ce` | `69N6K965SF` |

The existing Sparkle EdDSA key and the Stable and Tip feed URLs remain unchanged. Each channel may
contain multiple update items during the transition; this does not require extra feeds. The application
and installer identity labels are policy data in `Scripts/apple_identity_policy.json`; protected
workflows use `Scripts/stable_rollout.py packaging-context` and do not require duplicated GitHub
Actions identity-name variables.

## Tip rehearsal

The checked-in Tip declaration is the controlled `P → T → S` rehearsal:

- **P (preparer)** is a legacy-identity ZIP with `legacy-preparer` migration phase and no
  predecessors. It carries the successor-signed anchor needed to prove the future identity, but its
  application, profile, and notary credentials remain legacy-selected.
- **T (transition)** is a successor-identity, successor-Installer-signed and notarized `.pkg`. Its
  appcast retains P as the immediately older top-level item.
- **S (successor)** is a successor-identity ZIP/DMG. Its appcast retains both T and P as top-level
  items and supplies the normal rollback window.

All three roles use the same Tip feed and `appcast.xml`; the rollout manifest is the same
`identity-rollout.json` asset name. No sibling feed or Sparkle key is introduced. A successful `CI`
run for protected `main` automatically continues into the complete `Publish Tip` pipeline for the
exact passing commit, regardless of the checked-in rollout role. A role changes the artifact and
identity policy; it never suppresses publication or produces a successful no-publication run.

Manual dispatch is a recovery path and takes no operator-supplied release inputs. The checked-in
declaration on protected `main` supplies the rollout role and identity policy. There is no
operator-supplied commit field. GitHub's selected `main` SHA is the candidate, and setup
requires that SHA, the workflow definition, the release-tooling checkout, and freshly fetched
protected `origin/main` to be the same commit.

Automatic and manual runs use one queue without cancelling in-flight release work, and publication
is serialized. Before any draft mutation and again immediately before publication, the publisher
rechecks protected `main`, validates the authenticated public Tip appcast/manifest, enforces the
monotonic `P → T → S` state machine while allowing newer same-role builds with exact retained
manifest bytes, and verifies retained enclosure size/SHA-256 from immutable release assets.
For T and S, setup and publication also require the greatest Stable build to remain strictly below
P's retained Tip build; otherwise an unprepared later Stable build could satisfy T's Sparkle floor.
Draft creation, asset upload, and publication are reconciled by observation after ambiguous network
outcomes; existing bytes are never overwritten. A completed release is then audited anonymously,
asset by asset, before it is accepted as the latest Tip release.

## Release ladder

1. Ship a legacy-signed preparer (`P`) through the existing Sparkle path.
2. Before mutating bridge records, `P` writes a `preparing` journal to a dedicated Keychain service
   using the same validated dual-identity ACL as the bridge. The journal contains a random attempt
   identifier and the exact closed account catalog, allowing the successor to discover the committed
   bridge without relying on mutable preferences.
3. `P` copies every present account in the frozen version-2 migration catalog from the current
   Developer ID Keychain service into a bridge service whose name includes that attempt identifier.
   Service and account are generic-password primary-key attributes, so an orphaned earlier attempt
   cannot collide with a later attempt. New records use create-only writes so an unproven
   pre-existing ACL cannot be retained.
4. Each new bridge item receives a classic macOS Keychain ACL derived from the running legacy-signed
   executable and an embedded executable signed for the successor identity. Before creating that ACL,
   runtime code validates both executables against their exact identifiers, Team IDs, and Developer ID
   certificate requirements.
5. `P` reads back every copied value byte-for-byte. It never deletes or rewrites source items. If an
   attempt is interrupted, the next launch resumes the same journal: the source remains authoritative,
   changed source values are recopied, and attempt-scoped bridge values whose source disappeared are
   removed.
6. Only after every source and bridge value matches does `P` create and verify a committed bridge
   manifest, commit the dual-identity Keychain journal, and select the bridge as the canonical backend.
7. Later launches authenticate the journal and bridge manifest by inspecting their decrypt ACLs and
   requiring exactly the legacy and successor designated requirements before accepting the JSON.
   Later builds validate that ACL again before copying it to a new bridge item. The version-2 catalog
   remains frozen; accounts added to the app later are created in the already-authoritative bridge.
8. If any read needs interaction, validation or read-back fails, or either manifest cannot be persisted,
   the old secure-storage service remains canonical and Sparkle is paused. Settings surfaces distinguish
   a locked Keychain, cancelled access, authentication failure, and generic verification failure, then
   provide the corresponding relaunch guidance.
9. After the bridge has been proven under both real signing identities, publish a notarized transition
   package (`T`) that installs the successor app. Feeds must keep `P` and `T` available long enough for
   slow-upgrading clients; use Sparkle item eligibility/version constraints instead of new feeds.

## Packaging contract

`REPOPROMPT_IDENTITY_MIGRATION_PHASE` is `disabled` by default. A protected preparer build sets it to
`legacy-preparer` for both staging and validation. The protected signing step must also provide
`REPOPROMPT_IDENTITY_MIGRATION_ANCHOR`, pointing to a regular executable already signed with identifier
`com.repoprompt.ce` and Team ID `69N6K965SF`.

`Scripts/sign_staged_release.sh` validates the exact successor Developer ID requirement before copying
the anchor into `Contents/Resources/IdentityMigration/RepoPromptIdentityAnchor`, then validates the
embedded copy again. It does not re-sign the anchor with the legacy certificate. The outer legacy app
signature then seals the embedded file as a resource.

The protected release job builds a universal anchor from `Scripts/identity_migration_anchor.c` in the
trusted control-plane checkout. The minimal executable is never launched; it avoids embedding a second
copy of the main app binary while still giving Security.framework a successor-signed designated
requirement on both supported architectures.

The Tip workflow performs the rehearsal under the protected `tip-release` environment. Its cheap
role-aware credential preflight runs before the secret-free build and checks the policy projection plus
the role-selected application P12/password, provisioning profile, and notarytool private key/key ID/
issuer. The transition role additionally requires the successor Installer P12/password. The preparer
role separately requires the successor application P12/password only to create and verify the embedded
successor anchor. After every P12 import, the signing job verifies that the policy-derived identity is
present and usable in the ephemeral keychain before any `codesign` or `productbuild` call.

## Rollout gates and next operator action

The checked-in declaration is the rollout authorization boundary. Review and merge P first, inspect
its automatically published signed/notarized ZIP and retained `identity-rollout.json`, then update the
declaration with P's exact manifest digest before merging T. After T is verified, update the
declaration with both exact predecessor digests before merging S. Successful protected-main CI
automatically publishes each reviewed role; no second dispatch approval is required.

P was published and independently verified at `tip-2f94412e6ab5`; its retained
`identity-rollout.json` SHA-256 is
`3c69703fa7582105633b36e8874fe2a28e1832aabb776351e68dbf3367e122db`. The checked-in Tip
declaration now pins that immutable predecessor and selects T.

The workflow capability for T is explicit and deterministic: after a reviewed transition declaration
reaches protected `main` and CI passes, GitHub selects and publishes that exact commit automatically.
The declaration change must not merge until the runtime proof below is complete, including a reviewed
recovery story for a lost committed P journal and a policy that distinguishes a fresh successor
installation from a client that skipped the preparer/transition bridge. S also requires a later
declaration change containing both T's and P's exact manifest digests.

## Required proof gate

Do not exercise the bridge against a maintainer's login Keychain. The final go/no-go proof must run in
an isolated macOS CI runner or disposable VM/account with a disposable Keychain and synthetic values
for the full account catalog. It must demonstrate:

- the legacy app can create, read, and update bridge items without authorization UI;
- the successor app can read and update the same items without authorization UI;
- interrupted writes resume from the dual-identity Keychain journal without losing a newer source value;
- a lost journal starts a collision-free attempt even when orphaned bridge records remain;
- forged journal or bridge-manifest ACLs fail closed and are never propagated to new credentials;
- inaccessible records, forged or missing manifests, invalid runtime anchors, and unknown phase values
  fail closed;
- a locked Keychain pauses updates visibly and a later unlocked relaunch retries successfully;
- originals remain intact after preparation and after a failed transition;
- rollback to the preparer can still read the bridge for the supported rollback window; and
- the preparer, transition package, and successor artifacts pass signature, notarization, and
  Sparkle EdDSA verification.

Certificate files, passwords, temporary Keychains, and synthetic credential values must remain in the
isolated environment and must never be committed, logged, or copied into a developer's login Keychain.

## Rollback

Before the transition package is published, rollback is simply removal of the eligible transition
item: clients remain on the legacy app, source Keychain items remain untouched, and a successfully
prepared client can continue using the bridge. After the successor is published, keep the preparer
and its signing material available until the supported migration window closes.
