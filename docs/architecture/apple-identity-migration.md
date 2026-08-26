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
`identity-rollout.json` asset name. No sibling feed or Sparkle key is introduced. Automatic
`workflow_run` notifications skip every nonlegacy role. During migration, an automatic nonlegacy run
intentionally fails visibly in a read-only diagnostic rather than appearing successful; nothing is
built, signed, or published. A complete immutable-release dedupe remains green. This is diagnostic
truthfulness, not publication. Each nonlegacy role requires an explicit `workflow_dispatch` with
`confirm_identity_rollout_role` exactly equal to the checked-in role. Tip workflow uses separate
rolling/superseding lanes: newer runs replace older work only within
the same lane, so automatic successes cannot evict explicit dispatches; failed-CI notifications
use unique groups. Different lanes may build concurrently. The `publish` job is separately
serialized across lanes once it reaches that job, but its job-level `cancel-in-progress: false`
does not override workflow-level cancellation in the source lane. A duplicate immutable
`tip-<shortsha>` tag publish may safely fail rather than corrupt the feed. An older run for a
different commit that publishes late can move the latest pointer backward; this bounded risk is
especially relevant outside migration-role gating, and the existing next publish recovers it.

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

## Manual gates and next operator action

The manual gates are ordered: approve and dispatch P first, inspect its signed/notarized ZIP and
retained `identity-rollout.json`, then update the declaration with P's exact manifest digest before
dispatching T. After T is verified, update the declaration with both exact predecessor digests before
dispatching S. Never publish a nonlegacy role from an automatic `workflow_run` notification.

P was published and independently verified at `tip-2f94412e6ab5`; its retained
`identity-rollout.json` SHA-256 is
`3c69703fa7582105633b36e8874fe2a28e1832aabb776351e68dbf3367e122db`. The checked-in Tip
declaration now pins that immutable predecessor and selects T.

The next operator action after this change is merged to protected `main` and exact-head CI succeeds:
dispatch **Publish Tip** with `commit` set to that exact main SHA and
`confirm_identity_rollout_role=transition`. Do not rely on the automatic CI notification for T. S
still requires a later reviewed declaration change containing both T's and P's exact manifest
digests.

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
