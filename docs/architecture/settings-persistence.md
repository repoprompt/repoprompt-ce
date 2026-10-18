# Settings Persistence

Current as of 2026-09-19. This document is contributor-facing: use it when changing durable settings, workspace overrides, Agent Models settings, or MCP settings surfaces.

## Durable settings file

RepoPrompt CE stores app settings in the versioned JSON document at:

```text
~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json
```

The file is identified by two fields, not one:

- `schemaLineage` answers **who wrote this settings family**.
- `schemaVersion` answers **whether this build can read that family version**.

`schemaVersion` is meaningful only after the lineage is known. CE inherited numeric
settings versions from classic/internal RepoPrompt builds, and some dev/live installs
already have unlineaged `schemaVersion` 3/4 files in live Application Support folders.
Those numbers must not be treated as CE-native just because CE eventually reaches the
same numeric version.

## Classification matrix

| `schemaLineage` | `schemaVersion` | Behavior |
| --- | --- | --- |
| `repoprompt-ce.global-settings` | `<= currentSchemaVersion` | Load normally without rewriting merely because the schema is older. |
| `repoprompt-ce.global-settings` | `> currentSchemaVersion` | Preserve and block saves as a same-lineage future CE file. The UI does not offer compatible import for this lane. |
| any other non-empty value | any | Preserve and block saves as an incompatible/foreign schema. |
| absent | `<= legacyUnlineagedSchemaVersionCeiling` | Accept as legacy OSS CE. |
| absent | `> legacyUnlineagedSchemaVersionCeiling` | Preserve and block saves as incompatible/foreign, permanently. |
| header is undecodable but bytes are valid JSON | n/a | Preserve and block saves as incompatible/foreign. |
| bytes are not JSON | n/a | Preserve in place and block saves for explicit recovery; startup never replaces it with defaults. |

## Minimum schema stamping

`GlobalSettingsDocument` is the single authority for the lowest schema capable of
representing its content. Schema-requiring features have fixed introduction constants:

- `baselineSchemaVersion = 2`
- `workspaceAgentModelsSchemaVersion = 4`
- `contextBuilderSchemaVersion = 5`
- `oracleRosterSchemaVersion = 7`
- `agentModelParameterPinsSchemaVersion = 8`
- `modelRouterSchemaVersion = 9`
- `scopedModelRouterSchemaVersion = 10`

`requiredSchemaVersion` returns the maximum fixed feature version required by the
document. It must never use `currentSchemaVersion` as the version of an existing feature.
Baseline CE content is stamped v2; a document is stamped v4 only when
`agentModelsSettingsByWorkspaceID` is nonempty; and a document containing the
`scalarPreferences.contextBuilder` group is stamped v5; Oracle roster content is stamped v7;
Agent Models ACP parameter pins are stamped v8; and the optional
`scalarPreferences.modelRouter` group is stamped v9. The router's primary/subagent provider
limits or custom guidance require v10. An existing same-lineage v4 file that already contains
the router group is upgraded through the raw-preserving startup transaction before an ordinary
typed save can occur. Save, compatible import, recovery,
and default creation all use this content-derived minimum. Lineage is still stamped on
every CE write, and future-schema and unlineaged preservation guards remain unchanged.

## False-v4 normalization

One development path stamped baseline-only CE documents with schema v4. On load,
`GlobalSettingsFileStore` repairs such a document only when the lineage is exactly CE,
the version is exactly v4, complete typed decoding succeeds, `requiredSchemaVersion` is
v2, and the raw `agentModelsSettingsByWorkspaceID` key is absent or an empty object.

Before changing the live file, the store copies its original bytes exactly to a
timestamped `Backups/globalSettings.false-v4-*.json`. It then updates only the raw root
`schemaVersion` value to v2 and atomically replaces the live file. Raw JSON is used so
unknown keys and values survive. A successful repair is idempotent.

The repair never applies to nonempty workspace profiles, future versions, foreign or
unlineaged v4 files, wrong-type Agent Models fields, partial/corrupt documents, or typed
decode failures. A present `agentModelsSettingsByWorkspaceID` value of `null` or any
other non-object shape is not equivalent to an absent key: the original bytes are
preserved and persistence is latched closed. If verification, backup, or atomic
replacement fails, the same fail-closed rule applies. Startup default seeding and
ordinary mutations cannot bypass that latch; explicit backup/reset remains available.

The rollback boundary uses two test-only codecs. `FrozenV1028GlobalSettingsCompatibility`
is frozen from annotated tag `v1.0.28`
(`65d473858d7a140dc82364f4b359482d6dc5ce80`), peeled commit
`1b185f74e72af3000550796b3d1d7476d244e546`; it covers the seven-field v2 root contract
and baseline/false-v4 normalization round trips. `FrozenV130GlobalSettingsCompatibility`
is frozen from released v1.3.0 commit `b8042678fac558842ef4bc37027d0cd26246fdd6`.
That typed scalar shape supports through v4 and has no Context Builder group, so it
rejects a v5 file rather than silently dropping that group. Existing same-lineage v4
files containing Context Builder content are upgraded raw-preservingly before a subsequent
ordinary save. Current CE writers serialize this transaction and fence their observed raw
generation; older released binaries remain outside that cooperative contract. Do not treat
this as a lossless v1.3 round-trip guarantee for v4 files; genuine v4 workspace-profile
compatibility remains outside the v1.0.28 rollback guarantee.

## Verified recovery and unknown-field preservation

Schema v5 is supported for Context Builder behavior. Valid v5 documents load
normally; do not reinterpret their marker as an unsupported experimental schema
or downgrade them during load. This includes files written while older builds
still supported only v4.

The existing redundant-v4 repair now verifies its backup byte-for-byte, checks
that the source has not changed during backup, and verifies the atomic replacement
before unblocking persistence. Backup or replacement verification failures keep
saves blocked. Unknown fields remain in the raw repaired document.

Ordinary saves now apply the difference between the last typed projection and the
new projection to the current raw JSON. Unknown fields and unchanged external
fields survive unrelated preference edits, including after restart. Removing a
known setting removes that setting; replacing a scalar or array intentionally
replaces that value. Explicitly removed workspace-setting entries are removed as a
whole. Startup migrations retain their existing targeted raw-JSON migration path.
The on-disk future/foreign header guard still runs before saving.

## Frozen legacy ceiling

`GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling` is intentionally frozen at
`2`: the last schema version OSS CE wrote without `schemaLineage`. Do not raise it when
`currentSchemaVersion` increases.

Classic/internal RepoPrompt wrote unlineaged v3/v4 `globalSettings.json` files before CE
introduced `schemaLineage`. CE therefore skipped numeric schema v3 rather than claiming a
version that existing classic/internal installs had already written without lineage. An
unlineaged version above the frozen ceiling is foreign forever, even after CE reaches v3/v4
numerically. This prevents old live/dev files from being silently adopted and overwritten by
a newer CE build.

The settings persistence guardrail retains this frozen-ceiling behavior; the former timing-sensitive XCTest references were removed during the test cleanup.

## Recovery lanes

When persistence is blocked, the app runs with in-memory settings and refuses to overwrite
the preserved file until the user chooses an action:

- **Same-lineage future CE**: show the file or reset after backing it up. Compatible import
  is intentionally unavailable because an older build cannot know how to preserve future CE
  fields.
- **Incompatible/foreign JSON**: offer compatible import. Import backs up the original
  byte-for-byte, decodes CE-known fields, writes a current-schema CE file, and leaves
  unknown fields only in the backup.
- **Malformed/unreadable settings**: preserve the primary file in place and offer explicit
  backup/reset recovery. Startup never backs it up or replaces it with provisional defaults.
- **Save failure**: offer retry before reset. If a raw-preserving startup migration
  failed, retry repeats that same raw-preserving transaction; it records the typed document
  from the failed attempt and overlays only changed, explicitly owned known fields onto the
  unchanged observed raw JSON, including known optional removals. Unknown root and nested fields remain,
  and ordinary typed saves remain blocked until the preserving retry succeeds or the user
  explicitly chooses backup/reset.

Telemetry enablement has a `UserDefaults` mirror so startup can make a safe decision before
the canonical JSON document is available. A successful settings load synchronizes that
mirror from JSON. When a same-lineage future or incompatible/foreign schema blocks the
load, an existing mirror is preserved; if no mirror exists, telemetry defaults off. Other
load failures, including corrupt input, force the mirror off. Missing settings remove a
stale mirror so the build default applies, and successful user-initiated recovery
resynchronizes the mirror from the replacement current-schema document. None of these
mirror decisions bypass the blocked file's byte-preservation and save latch.

Current CE writers share a nonblocking transaction lock in `globalSettings.json.lock`.
The stable sidecar is never deleted and contains no PID ownership protocol; the kernel
releases the descriptor lock when a transaction finishes or its process exits. All settings
mutation paths, including initialization, normalization, migrations, imports and recovery,
hold that lock from raw read through backup/replacement and generation bookkeeping.
Ordinary saves and migrations compare the exact on-disk bytes with the snapshot from which
the live typed document was loaded. Another writer's change therefore requires reload even
when both files have the same supported schema. Atomic replacement alone does not prevent
lost updates, and a lock without this stale-input check would still permit them.

A busy save offers retry. If a previously observed file is missing, explicit “Save current
settings” can recreate it from retained in-memory values, but only after rechecking absence
under the lock; an intervening replacement is rejected. Changed content or an initial
read/lock failure offers explicit
reload with a warning that unsaved in-memory edits will be replaced. Failed reload retains
the live document. Provisional startup defaults are never authorized to overwrite a file;
only confirmed first-time absence under the lock may create defaults. Successful reload
retires old pending migration intent and computes migration from the newly loaded document.
A failed explicit recovery retains its intended missing-file generation for retry after
moving the original aside, and rejects any intervening replacement by another writer.
Compatible import copies its backup before atomic replacement; a failed write keeps the
original primary file and its preservation block, so retry repeats explicit import instead
of saving provisional defaults.

Close older CE versions before upgrading or using this shared settings location. Older
released binaries and arbitrary external editors do not honor this cooperative protocol;
the sidecar does not make them safe concurrent writers. Current writers within one build
flavor use this cooperative protocol. Debug and release now select separate application
state roots as described below; no lifetime app lock is introduced.

Blocked-persistence warnings may be dismissed in workspace windows for the current app
session. The store owns dismissal across workspace windows and clears it when the reason
changes or persistence unblocks. It is never stored in `UserDefaults`. The Settings
window always shows the active warning and recovery controls.

## Debug session-state boundary

Debug and release builds must not normalize, overwrite, lock, or delete the same
application-owned session metadata. `MCPFilesystemIdentity.current` selects the
compiled build flavor; `applicationStateDirectoryName` selects mutable state.

| State | Release | Debug |
| --- | --- | --- |
| Workspaces, conversations, Agent Mode sessions, catalog/journals, window continuity | `~/Library/Application Support/RepoPrompt CE` | `~/Library/Application Support/RepoPrompt CE Debug` |
| Settings, presets, custom workflows, and persisted slice selections (`Partitions`) | Same release root | Same debug root |
| Saved prompts, including context-builder prompts | `~/Library/Application Support/com.pvncher.repoprompt` | Debug root, `SavedPrompts` |
| Oversight intents, scope continuity, worktree ownership | Same release root | Same debug root |
| One-click recovery archive in Downloads | `RepoPrompt-Backup` | `RepoPrompt-Debug-Backup` |

Release paths and formats are unchanged. Each normal debug **app process launch**
prepares a new independent working snapshot of production state before app stores
open. `--debug-clean-slate` skips the production seed for that launch only; it is
not a preference, and the next normal launch seeds production again. This is
state initialization, not a compiler/cache cold build. Ordinary refresh retains
this debug profile's transactional oversight DB and legacy continuity records.
Workspaces containing saved debug endpoints (or named by a saved workspace scope)
retain their intact debug-owned tabs/conversations, rather than replacing their
identities with the production baseline. Their debug windows are retained too;
settings and unrelated workspaces still refresh. Runtime restoration remains
responsible for profile/identity validation: retaining bytes does not mint authority.
Missing original endpoints stay recorded, not fabricated or silently revoked.
`--debug-clean-slate` intentionally archives rather than carries this debug control
continuity; it is a genuinely clean launch, not an ordinary restart. Existing provider homes,
authentication, Keychain items and harmless runtime caches remain shared; the
bootstrap never copies credentials or requires a new login.

The seed follows the current workspace catalog/index, copies workspace documents
and conversation backing files, and materializes pending workspace journal bytes
into the destination. Custom metadata sources are copied into the debug root;
repository paths remain repository paths. Settings, presets, prompts, workflows,
window state, slice selections and Oracle conversation artifacts are included.
Rebuildable session indexes, locks/PIDs/runtime claims, Git data, workspace folders outside the live catalog and source recovery/backup trees are not restored as active state. Source
history/recovery files remain at their original locations; an omitted unavailable
workspace cannot be reconstructed from an absent source document.

Source files and directory membership must remain stable across the capture, with
three bounded attempts. Database snapshots use SQLite's backup API, never an
uncoordinated live database-file copy, source migration or checkpoint. The current
rollback-journal continuity store is supported. WAL sources currently fail closed
rather than risk a write to production SHM read marks; they are not silently
omitted or opened with the unsafe `immutable` promise.

Copied provider conversation/cleanup handles are detached so a debug continuation
cannot append to or delete its production provider conversation. Local transcript
history is retained for the ordinary history-replay/new-conversation path. Saved
production grants/continuity are preserved separately in `ProductionContinuity`,
not promoted into debug authority. Automatic wakes and active merge/compact claims
are not revived. No provider mode is disabled.

Preparation and validation happen in staging. A same-volume atomic directory swap
publishes the complete profile; a failed preparation leaves prior debug and source
bytes intact. Prior debug-only work and its preferences are recoverable under
`RepoPrompt CE Debug Recovery` beside the profiles. The last three owned recovery
snapshots are retained. An unclassified pre-bootstrap original is preserved separately rather than pruned as an owned seed; unrelated files and unrecognized crash leftovers are not
deleted. Normal startup is silent. Failure presents an actionable debug-only error
and exits instead of opening a partial mixture. `debugSeed.json` and the redacted
startup receipt record profile/schema, clean mode, count/bytes and capture time. `debugSeedSources.json` records the source/destination manifest and
preserved-but-not-seeded exceptions; unavailable workspace IDs are recorded separately.
CLI requests do not re-seed a running app. Explicit standalone headless profiles
remain independent and do not run the app launch bootstrap. The default debug
headless runtime and interactive policy administrator hold shared admission on a
stable sibling profile lock for their store lifetime. Bootstrap requires exclusive
admission before capture/publication; the app then retains shared admission. A
busy owner causes an explicit startup refusal, never a swap under a live writer.

Missing release preference data is not an empty domain: ordinary startup retains
prior debug preferences when that source is absent, and retains debug-only Agent
Mode diagnostic toggles even when release preferences are available. Ordinary
refresh also carries debug runtime settings/grants/bindings, settings/preset backups,
workspace cleanup backups and self-compact recovery bytes verbatim. Clean-slate
continues to archive rather than carry these bytes. Continuity retention reads the
owning legacy Codable models and read-only database projection; incompatible input
aborts refresh without displacing the previous profile. Archived endpoint backing
counts even when no compose tab currently selects it.

Copied Agent session items, transcript request anchors and response activities
rebase only typed local image references under the copied workspace's managed
attachment store. External paths, remote URLs, text and arbitrary tool payloads
remain unchanged. Storage relocation admits the validated debug workspace root
through the same runtime metadata policy **before** any directory is moved; each
later write still checks production aliases and symlink components.

Custom debug storage selections and explicit headless profiles use a build-flavor-namespaced child directory. Runtime profile IDs and release directory semantics remain unchanged. Known
release roots (including configured custom storage), canonical aliases, symlinked
metadata descendants are rejected before metadata writes,
lock creation, or destructive cleanup. Nearest-existing-ancestor canonicalization
also covers symlink parents with an absent final child. These checks protect
against accidental cross-profile writes, not a malicious same-user process
racing filesystem changes. Repository edits and user-selected exports are not
application-metadata writes and do not acquire this restriction.

The app and standalone headless runtime share this location policy. Debug CLI
policy administration targets debug runtime policy, not release policy.

This is **not** blanket filesystem isolation. Existing flavor-specific MCP
socket/config names, wrappers/install destinations, provider homes/authentication,
Keychain behavior, telemetry/device identity, tooling, and harmless shared caches
or runtime downloads retain their existing behavior. Oversight transaction and
permission semantics are owned by their separate repair track.

### Acceptance evidence

Use conductor for focused profile tests, relevant persistence/app suites, lint,
product compilation and packaging. Packaged Agent Mode validation must use an
explicitly approved app lifecycle action, coexist with release, and attribute
writes to the debug process. Helper/unit tests alone do not establish live
no-production-write behavior. Do not claim that acceptance until observed.

#### Two-app same-workspace regression

With release and the approved packaged debug build running together, exercise
the same repository/workspace reference that previously resolved to one shared
persisted document. Record each PID/executable and effective metadata path. A
debug request to use the release document as writable metadata must be rejected
before lock creation, normalization, or cleanup; the usable debug workspace must
resolve to separate metadata. Exercise repeated selection switches and restore,
then compare release workspace bytes, catalog/index, window state, settings,
presets, prompts and oversight metadata against the baseline, attributing debug
writes to the debug process. Repository access remains shared and usable.

Do not disable saves, suppress CAS checks, copy production grants, or dismiss a
conflict without writer attribution. Do not copy private live history into public
fixtures/artifacts. This requires fresh lifecycle approval and coordination with
other tracks, not an unapproved stress sequence against production.

## Model Router settings

The optional app-global router policy lives at:

```text
scalarPreferences.modelRouter.enabled
scalarPreferences.modelRouter.selectedBackendRawValue
scalarPreferences.modelRouter.candidateRoleRawValues
scalarPreferences.modelRouter.allowedProviderRawValues
scalarPreferences.modelRouter.primaryProviderRawValue
scalarPreferences.modelRouter.subagentProviderRawValue
scalarPreferences.modelRouter.customInstructions
```

The base group is a schema-v9 feature fence. Its absence leaves the document's minimum schema unchanged; any presence requires v9 so older typed writers reject the document instead of silently dropping router consent. A nonnil primary provider, subagent provider, or custom guidance field requires v10. Clearing all three returns the content-derived minimum to v9. The group stores no API keys or backend secrets. Unknown nonblank backend, role, and provider raws are preserved during sibling edits and ignored by current runtime validation. An unknown backend is never replaced by the first registered backend.

Missing values resolve disabled. Production materializes Jev only for an absent Router service raw value before initial demand reconciliation; blank/unknown raw values are preserved and unavailable, not normalized into a different service. Provider scope fields are optional preferences: an available selected provider narrows that scope's candidates to it, while an unavailable selection falls back to the other connected providers. The legacy candidate-role and allowed-provider arrays remain for schema/rollback preservation but no longer authorize the provider-catalog frontier. Custom guidance is trimmed on supported writes, removed when empty, and bounded to 1,000 characters and 4,096 UTF-8 bytes. `GlobalSettingsStore.modelRouterSettingsRevision` is process-local and changes only after an actual in-memory Router mutation. Future/foreign blocking, compatible import, raw unknown-field preservation, and rollback rules remain those of the owning global settings document.

## Independent Auto Effort service selection

The existing `scalarPreferences.agentMode.autoEffortEnabled` flag remains a separate, default-off user intent. The optional `scalarPreferences.agentMode.autoEffortBackendRawValue` is an **independent exact decision-service selection**. An absent field resolves to Jev in memory for existing users without writing or raising the document schema. An explicit known, blank, or unknown raw value is preserved through unrelated edits; blank/unknown values resolve unavailable and never silently select Jev or the Router's service. Writing the explicit field requires schema v12, so an older v11 writer rejects the document rather than silently reinterpreting a non-Jev selection. For its service selection, Auto Effort persists only the raw value; its revision is process-local, held in memory, and advances only on actual enablement/selection/install changes. Removing a decision-service credential does not clear this flag or selection; the feature keeps manual effort until its selected service is usable.

## Legacy routing-profile settings

`scalarPreferences.modelRoutingProfiles.remoteUpdatesDisabled` and `lastCheckAt` are deprecated, inert optional fields retained for schema-v12 Codable and rollback compatibility. The content-derived schema fence still requires v12 whenever either value is present. Current code has no active manager reader/writer for them: it does not materialize, update, clear, or migrate them. Unrelated settings edits preserve both values and continue to write a schema-v12-compatible document, allowing an older v12-aware app to read them after rollback. These fields do not control any current profile behavior; bundled routing profiles are the only source. See [model routing](model-routing.md) and the [bundled profile publication boundary](routing-profile-publication.md).

## Agent Mode Handoff instructions

The reusable titlebar Handoff default is one optional app-wide scalar:

```text
scalarPreferences.agentMode.agentSessionHandoffInstructions
```

This setting is global across workspaces. It does not use the Agent Models
workspace-profile system, which is feature-specific rather than a generic
layered-settings authority. Workspace-scoped Handoff instructions require a
separate persistence and migration design.

The field is a JSON string when present. An absent or decoded `null` field resolves to
exactly `""` through `GlobalSettingsStore.agentSessionHandoffInstructions()` without
materializing the field or rewriting the file. The typed setter preserves text verbatim:
leading and trailing whitespace, blank lines, and whitespace-only values are significant.
Setting exactly `""` removes the optional field (`nil`); clearing an already absent field
is an accepted no-op that does not publish or save.

Supported UI and store writes accept at most 20,000 Swift `Character`s, counted with
`String.count`. Exactly 20,000 is valid. The setter rejects 20,001 or more without changing
memory or disk and never trims or truncates. An oversized value from externally authored
JSON remains loaded so Settings can show the full invalid draft for correction or clearing;
it does not make the document corrupt or authorize a compatibility fallback that silently
omits configured instructions.

This scalar belongs to the existing baseline scalar container, requires no schema-version
bump or migration, and leaves baseline-only documents stamped v2. Compatible import retains
a type-compatible string. False-v4 normalization changes only the raw root `schemaVersion`,
so the raw Handoff field and its exact value survive unchanged. Setting or clearing this
field uses the sibling-preserving Agent Mode scalar update path.

The setting is intentionally local to the Agent Mode settings UI and titlebar Handoff flow.
It has no `app_settings` descriptor, catalog key, getter, setter, candidate schema, or MCP
tool property. Do not expose `agent_mode.handoff_instructions` (or an equivalent key)
without a separate public-surface design and migration decision.

If global-settings persistence is blocked, an accepted Save or Clear remains active in
memory for the current launch and the Handoff card surfaces a noninteractive warning. The
existing global-settings warning and recovery controls remain the only recovery authority;
the card does not roll back the accepted value or create a second recovery path.

## Context Builder behavior

The seven controls shown in Settings → Context Builder use one app-wide scalar group:

```text
scalarPreferences.contextBuilder.contextTokenBudget
scalarPreferences.contextBuilder.analysisTokenBudget
scalarPreferences.contextBuilder.enhancementMode
scalarPreferences.contextBuilder.questionTimeoutSeconds
scalarPreferences.contextBuilder.allowUIClarifyingQuestions
scalarPreferences.contextBuilder.allowMCPClarifyingQuestions
scalarPreferences.contextBuilder.followUpAnalysisEnabled
```

`GlobalSettingsStore.contextBuilderBehaviorSettings()` resolves a complete non-optional `ContextBuilderBehaviorSettings` value through `ContextBuilderDefaults`; the whole-snapshot setter preserves sibling scalar groups and publishes through the store. Every window reads this same authority. Workspace and tab changes do not change these values, and Context Builder behavior does not use Agent Models workspace inheritance.

The optional scalar group is a schema-v5 fenced feature because released v1.3 typed
writers do not decode or preserve it. A document without workspace Agent Models profiles
remains v2 when the group is absent; documents with profiles remain v4 when the group is
absent; and any document containing the group requires v5. Existing v4 documents with
that group are upgraded through the raw-preserving startup transaction before ordinary
saves. All future/foreign preservation and false-v4 rules continue to apply.

When the scalar group is absent, load and reload migrate legacy workspace fields deterministically. Workspace entries are sorted by UUID string, then each field independently takes the first applicable value; invalid enhancement modes are skipped and missing values use `ContextBuilderDefaults`. The complete scalar group is materialized and legacy `ChatGlobalSettings` Context Builder fields are stripped. Startup normalization writes these changes, an absent `scalarPreferences.fileSystem.globalIgnoreDefaults` value, and repairs to invalid Oracle ↔ Built-in Chat synchronized-model state through one raw-preserving transaction. The transaction patches only its owned JSON paths, canonicalizes workspace Agent Models UUID keys with the same deterministic winner used during typed decoding, and preserves unknown root, scalar, global-default, workspace, and UUID-backed profile fields, including when false-v4 normalization runs first. Compatible import reconstructs UUID-keyed maps from decoded projections before content-derived schema stamping while retaining the original bytes in the import backup. If persistence is blocked or the save fails, repaired values remain active in memory while the original disk bytes remain under the existing recovery contract. Those optional workspace properties remain decode-compatible legacy migration inputs only. Dormant `GlobalDefaults.discoveryTokenBudget` and `discoveryEnhancementMode` never participate in migration or runtime resolution.

The legacy nested tab key `discover.autoGeneratePlan` is ignored on decode and disappears when that tab is re-encoded. Context Builder instructions, selected prompt IDs, and follow-up type remain tab-specific. Global behavior is never mirrored back into workspace or tab documents.

UI and MCP runs resolve an immutable `ContextBuilderRunBehavior` alongside the run’s prompt and selection snapshot before asynchronous provider work. UI runs use Context Budget when Follow-up Analysis is disabled and Analysis Budget plus the captured tab-selected follow-up (plan, review, or question) when enabled. MCP runs with `response_type` omitted or set to `clarify` use Context Budget; `plan`, `question`, and `review` use Analysis Budget independently of Follow-up Analysis. MCP inactive-target safety disables clarifying questions while retaining the global budgets, enhancement mode, and timeout. Later Settings edits or disk reloads affect future runs only.

Context Builder `ask_user` calls without an explicit timeout use the Question Timeout captured for that run. Question Timeout is also the live app-wide default for Agent Mode `ask_user`; Agent Mode reads the current global value rather than a Context Builder run snapshot. The seven behavioral controls are managed in the UI and are not exposed through the MCP `app_settings` catalog.

## Agent Models profiles

Agent Models settings cover the controls shown on Settings → Agent Models:

- Oracle model (`planningModelRaw`)
- Built-in Chat model (`preferredComposeModelRaw`)
- Oracle ↔ Built-in Chat sync toggle
- Context Builder agent/model
- MCP sub-agent role defaults
- MCP role-label discovery filtering

These fields are grouped in `AgentModelsSettingsProfile`.

### Global profile

The global Agent Models profile is not a separate JSON blob. It is projected from existing durable fields:

| Profile field | Backing setting |
| --- | --- |
| `planningModelRaw` | `scalarPreferences.modelSelection.planningModel` |
| `preferredComposeModelRaw` | `scalarPreferences.modelSelection.preferredComposeModel` |
| `syncChatModelWithOracle` | `scalarPreferences.modelSelection.syncChatModelWithOracle` |
| `contextBuilderAgentRaw` | `globalDefaults.discoverAgentRaw` |
| `contextBuilderModelsByAgent` | `globalDefaults.discoverModelsByAgent` |
| `mcpAgentRoleOverrides` | `globalDefaults.mcpAgentRoleOverrides` |
| `restrictMCPAgentDiscoveryToRoleLabels` | `scalarPreferences.agentMode.restrictMCPAgentDiscoveryToRoleLabels` |

Use `GlobalSettingsStore.globalAgentModelsProfile()` and `setGlobalAgentModelsProfile(_:contextBuilderWriteIntent:)` for whole-profile reads/writes. The write intent distinguishes user-owned Context Builder changes from automatic seeding while allowing unrelated model changes to preserve the existing ownership marker. User-driven Context Builder edits and workspace-to-global copies mark the selection as user-defined; automatic seeding stores an explicit unmarked state and never demotes an established user choice.

Legacy global Context Builder setters and global backing-field writers for planning, Built-in Chat, sync, MCP role overrides, and role-label discovery filtering post `.agentModelsSettingsDidChange(scope: .global)` after an actual value change because they mutate fields used by the global Agent Models profile.

### Workspace profiles

Workspace-specific Agent Models settings are stored in:

```swift
GlobalSettingsDocument.agentModelsSettingsByWorkspaceID
```

Each entry is a `WorkspaceAgentModelsSettings` value:

- `inheritanceMode: .useGlobalSettings | .useWorkspaceOverrides`
- `profile: AgentModelsSettingsProfile?`

A workspace in `.useGlobalSettings` resolves to the global profile even if it has an inactive saved profile. Switching to `.useWorkspaceOverrides` materializes a complete workspace profile from the current global profile when none exists. This keeps override editing deterministic and avoids partial per-field fallback rules.

`WindowSettingsManager` forwards scoped Agent Models reads/writes to `GlobalSettingsStore`; it does not create a window-local overlay for these settings.

Durable Agent Models profile values use trim-only normalization: surrounding whitespace and empty strings are normalized, but unknown nonempty provider identifiers, model identifiers, and map keys are preserved for forward and rollback compatibility. Catalog validation and executable fallback belong at runtime; loading or saving the settings document must not replace unknown durable values with current defaults.

## Effective runtime resolution

Runtime consumers should read the effective profile instead of directly reading scattered global fields or legacy workspace Context Builder fields:

```swift
GlobalSettingsStore.effectiveAgentModelsProfile(workspaceID:)
```

Resolution order:

1. No workspace ID → global profile.
2. Missing workspace settings → global profile.
3. Workspace set to `.useGlobalSettings` → global profile.
4. Workspace set to `.useWorkspaceOverrides` with a profile → workspace profile.

The following runtime surfaces use this effective profile:

- `PromptViewModel` for Oracle/Built-in Chat model settings.
- `ContextBuilderAgentViewModel` for Context Builder agent/model selection.
- `MCPAgentRoleDefaultsService` and MCP agent tools for role-label defaults in the active workspace.
- `AutoRecommendationEngine` for recommendation satisfaction and apply targets.

Context Builder agent/model selection follows the effective Agent Models profile. The seven Context Builder behavioral controls use the app-wide scalar authority described in [Context Builder behavior](#context-builder-behavior).

## Change notifications

Scoped Agent Models writes post:

```swift
Notification.Name.agentModelsSettingsDidChange
```

Payload keys are defined by `AgentModelsSettingsNotification`:

- `scope`: `global` or `workspace`
- `workspaceID`: included for workspace changes

Global changes refresh all Agent Models projections. Workspace changes should refresh only consumers bound to that workspace. Consumers should then re-read through `effectiveAgentModelsProfile(workspaceID:)`.

## MCP `app_settings` scope

The MCP `app_settings` surface remains global for model-related keys such as:

- `models.planning_model`
- `models.preferred_compose_model`
- `context_builder.agent`
- `context_builder.model`

Those keys write the global backing fields. Workspace-specific Agent Models overrides are not exposed through `app_settings`; they are selected by the active RepoPrompt workspace/window and resolved by runtime services.

## Delegation scope intent

Delegation scopes are not settings. `DelegationScopeRuntime` owns current user decisions;
continuity storage records them but never authorizes or vetoes a live action. Scope grants/revokes,
link intent, and delegation worktree ownership share a row-transaction repository:

```text
Release: ~/Library/Application Support/RepoPrompt CE/Overseer/continuity.sqlite
Debug:   ~/Library/Application Support/RepoPrompt CE Debug/Overseer/continuity.sqlite
```

- Owner: typed app adapters (`DelegationScopeStore`, `AgentSessionOversightIntentStore`, and
  `WorktreeOwnershipStore`) over `RepoPromptPersistence.OverseerContinuityStore`. The locations
  above are overseer-only, not an all-app path migration. `OverseerContinuityRepository.production()`
  is the sole path seam for the database and legacy input; both use the same profile directory.
    That seam composes its directory through the shared app-profile policy, without
  adding adapter-specific paths. Debug does not open the release legacy source or its lock.
  Suppressed launches perform no file I/O.
- Storage uses short SQLite `BEGIN IMMEDIATE` transactions, DELETE rollback journal,
  `synchronous=EXTRA`, `fullfsync=ON`, and foreign keys. Effective settings are checked on open;
  an Apple version string is not evidence of the upstream WAL-reset fix. No lifetime flock remains.
  The three adapters serialize short database access in-process; lock acquisition and SQLite busy
  waiting are bounded. Schema creation rechecks the version inside its transaction.
- Each transition writes only its rows and an operation-ID/digest/revision receipt atomically.
  Scope creation is immutable; explicit revocation cascades permanently to descendants. Deleted
  anchors and terminal scope identities are retained without a pruning cap. Link/worktree updates
  compare their acknowledged row revision, so a stale owner cannot replace another owner's row.
  Omission never means deletion. Receipt replay is idempotent and cannot repeat an effect.
- Live explicit user approval/revocation applies in its current process immediately. Grants save
  separately with bounded backoff. A scope revoke/deletion attempts its own synchronous transaction
  before returning, never behind an unrelated grant. Only a committed receipt acknowledges durable
  revocation. If that entire write fails, the local deny remains and the affected IDs are reported
  as **unsettled**; no record exists to carry that unsaved decision across process death. The next
  launch can recover only the last committed state, including a grant whose revoke never saved.
  This limitation is not a durable-revoke acknowledgement or a blanket invalidation of other grants.
  Quit settlement has a two-second deadline and reports unacknowledged transactions honestly.
  Impossible row transitions are retained as failed diagnostics, not retried forever at the queue
  head; independent rows can still save. `continuity_save_state` and the UI distinguish **saved**,
  **pending**, **failed**, and explicitly **not_persisted**, with the cause and retry guidance.
  A pending or failed change is not promised to survive a kill or reach another process. Storage
  failure neither manufactures approval nor denies an approved task. Caller/target routing, scope
  membership, expiry, and revocation checks remain mandatory.
- Launch restores compatible saved grants under fresh generations without clean-shutdown gating.
  Retry uses the same store/runtime after an open failure; restoration cannot replace newer live
  decisions or reactivate locally deleted anchors. Generations, leases, pending cards, batch
  confirmations, and live-only authority remain process-local.
- Legacy `delegationScopes.json` (v1/v2), `agentSessionOversightLinks.json`, and
  `delegationWorktreeOwnership.json` are **read-only sources**. Exact stable bytes and individual
  accepted/rejected rows are archived with provenance in the destination. Unknown schema, malformed
  data and invalid terminal history remain recoverable, never quarantined, rewritten, silently
  dropped, or used as approval. Destination rows/terminal identities win. Valid same-profile legacy
  rows migrate idempotently; release factories preserve existing links and worktree ownership.
  Same-profile debug links and ownership also migrate. Historically mixed sources, when explicitly
  supplied for recovery, and unknown scope authority are preserved for explicit recovery instead
  of being silently promoted. The scope recovery card displays root descriptions
  and requires a new explicit user approval, issuing new identities rather than reviving old IDs
  or lifting attenuated grants. Other valid database rows restore normally; malformed entries stay
  preserved and inactive with a diagnostic. Legacy bytes are read without opening or probing the
  release lock. An unavailable legacy source cannot veto a new approval.

### Organizational placement and delegated worktree ownership

- **Session placement.** `AgentSession` carries `organizationalParentID` and `delegationScopeID`,
  additive and decoded with `decodeIfPresent`, **without** a serialization-version bump (still 9): a
  bump would make this build rewrite every older session file on load and would not stop an older
  build from dropping the fields on its own re-save. An older file decodes with no explicit
  placement and falls back to spawn provenance (`parentSessionID`, then
  `createdByOverseerSessionID`), which stays write-once. Only delegation-scope administration
  (`reparent`, `adopt`, scoped creation, `fork`) writes placement. The index entry and live tab are
  updated synchronously; only the placement-only file rewrite of a session with no live tab is
  queued, serialized per session in the order placements were applied. A hydrate prefers the
  index's placement over the file's so it cannot revert.
- **Index mirror.** `AgentSessionMetadataRecord` / `AgentSessionIndexEntry` carry the same two
  fields additively **without** bumping `AgentSessionMetadataIndex.currentSchemaVersion` (still 8):
  a bump would make every not-yet-reopened workspace's index unreadable to the cross-workspace
  `history` scan until rebuilt, changing external `history` output. A record missing the fields
  falls back to spawn provenance, and placement only exists after this build writes it.
- **Worktree ownership.** `WorktreeOwnershipStore` records one transactional continuity row per
  worktree, including creator/scope/time and release marks. Current provenance remains usable while
  saving retries; tool results report `ownership_continuity_save_state` separately. It never
  authorizes or removes a worktree. Release records are not arbitrarily pruned; an explicit rebind
  is a new revision-checked transition, not a stale snapshot replacement.

## Sidebar groups on compose tabs

`ComposeTabState` (workspace files, not global settings) carries two optional, additive fields
beside `pinnedOrder`:

- `sidebarGroup`: the tab's sidebar group label (trimmed, at most 64 characters, one line); absent
  means ungrouped.
- `sidebarGroupOrder`: the group's position among the workspace's groups, mirrored on every tab in
  that group (`reorder_groups` rewrites the mirror on each).

Both are encoded only when present and decoded leniently: an absent or malformed value decodes as
ungrouped, so older files load unchanged and no workspace schema bump or migration is needed. Older
builds ignore the keys. Stashed (archived) tabs keep their group, so unarchiving restores it.

## Non-goals and migration notes

- Do not resurrect the old Context Builder drift resolver. Agent Models and runtime code should use the effective Agent Models profile, not compare against legacy `ChatGlobalSettings.contextBuilder*` fields.
- Do not add a second global Agent Models blob unless there is a separate migration plan; the global profile intentionally maps to existing fields.
- Existing workspaces default to `Use global settings`. Workspace overrides are opt-in and materialized from the current global profile.
- Orphaned workspace-keyed settings are intentionally retained. Pruning remains deferred until authoritative workspace IDs can drive one atomic sweep across every workspace-keyed settings map.

## Unit-test defaults

Debug builds detect SwiftPM/hosted XCTest when resolving the default settings file
and UserDefaults suite. Those defaults use a per-run temporary settings directory
and a separate defaults suite, so incidental initialization of GlobalSettingsStore.shared
cannot normalize, seed, or overwrite the real user's settings. Tests that need
specific files still inject GlobalSettingsFileStore(fileURL:) and their own suite.
Packaged application processes retain the ordinary Application Support location.
