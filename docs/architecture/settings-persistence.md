# Settings Persistence

Current as of 2026-09-05. This document is contributor-facing: use it when changing durable settings, workspace overrides, Agent Models settings, or MCP settings surfaces.

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
| bytes are not JSON | n/a | Back up as corrupt and write current defaults if the backup succeeds. |

## Minimum schema stamping

`GlobalSettingsDocument` is the single authority for the lowest schema capable of
representing its content. Schema-requiring features have fixed introduction constants:

- `baselineSchemaVersion = 2`
- `workspaceAgentModelsSchemaVersion = 4`
- `contextBuilderSchemaVersion = 5`

`requiredSchemaVersion` returns the maximum fixed feature version required by the
document. It must never use `currentSchemaVersion` as the version of an existing feature.
Baseline CE content is stamped v2; a document is stamped v4 only when
`agentModelsSettingsByWorkspaceID` is nonempty; and a document containing the
`scalarPreferences.contextBuilder` group is stamped v5. An existing same-lineage v4 file
that already contains that group is upgraded through the raw-preserving startup
transaction before an ordinary typed save can occur. Save, compatible import, recovery,
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
old write on the non-interleaved, single-writer path. This does not claim cross-process ordering;
#806 remains unresolved. Do not treat this as a lossless v1.3 round-trip guarantee for
v4 files; genuine v4 workspace-profile compatibility remains outside the v1.0.28
rollback guarantee.

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
- **Save failure**: offer retry before reset. If a raw-preserving startup migration
  failed, retry repeats that same raw-preserving transaction; it records the typed document
  from the failed attempt and overlays only changed, explicitly owned known fields onto the
  latest raw JSON, including known optional removals. Unknown root and nested fields remain,
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

Every save re-checks the on-disk header before writing. This matters because CE dev builds
can share the live app support folder; a future/foreign file may appear after launch. This
is a fail-closed header preflight, not a compare-and-swap transaction: it does not protect
the read/merge/write interval from a non-cooperating older writer. The supported-writer
ownership and atomic-CAS design for that interval remains unresolved in #806 and must not
be represented as closed by this preflight.

Blocked-persistence warnings may be dismissed in workspace windows for the current app
session. The store owns dismissal across workspace windows and clears it when the reason
changes or persistence unblocks. It is never stored in `UserDefaults`. The Settings
window always shows the active warning and recovery controls.

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

## Non-goals and migration notes

- Do not resurrect the old Context Builder drift resolver. Agent Models and runtime code should use the effective Agent Models profile, not compare against legacy `ChatGlobalSettings.contextBuilder*` fields.
- Do not add a second global Agent Models blob unless there is a separate migration plan; the global profile intentionally maps to existing fields.
- Existing workspaces default to `Use global settings`. Workspace overrides are opt-in and materialized from the current global profile.
- Orphaned workspace-keyed settings are intentionally retained. Pruning remains deferred until authoritative workspace IDs can drive one atomic sweep across every workspace-keyed settings map.
