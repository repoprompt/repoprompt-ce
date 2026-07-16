# Settings Persistence

Current as of 2026-07-12. This document is contributor-facing: use it when changing durable settings, workspace overrides, Agent Models settings, or MCP settings surfaces.

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

`requiredSchemaVersion` returns the maximum fixed feature version required by the
document. It must never use `currentSchemaVersion` as the version of an existing feature:
when another feature introduces v5, add a fixed constant for that feature and include it
in the maximum. Baseline CE content is stamped v2. A document is stamped v4 only when
`agentModelsSettingsByWorkspaceID` is nonempty. Save, compatible import, recovery, and
default creation all use this content-derived minimum. Lineage is still stamped on every
CE write, and future-schema and unlineaged preservation guards remain unchanged.

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

The rollback boundary uses a test-only codec frozen from annotated tag `v1.0.28`
(`65d473858d7a140dc82364f4b359482d6dc5ce80`), peeled commit
`1b185f74e72af3000550796b3d1d7476d244e546`. That source defines the seven-field v2
root contract. Tests exercise baseline and normalized files across patched → v1.0.28 →
patched round trips. Genuine same-lineage v4 workspace-profile documents are outside
that rollback compatibility guarantee.

## Frozen legacy ceiling

`GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling` is intentionally frozen at
`2`: the last schema version OSS CE wrote without `schemaLineage`. Do not raise it when
`currentSchemaVersion` increases.

Classic/internal RepoPrompt wrote unlineaged v3/v4 `globalSettings.json` files before CE
introduced `schemaLineage`. An unlineaged version above the frozen ceiling is therefore
foreign forever, even after CE reaches v3/v4 numerically. This prevents old live/dev files
from being silently adopted and overwritten by a newer CE build.

The guardrail tests are:

- `SettingsJSONOnlyPersistenceTests.testLegacyUnlineagedCeilingIsFrozenAtTwo`
- `SettingsJSONOnlyPersistenceTests.testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup`
- `SettingsJSONOnlyPersistenceTests.testVersionFourSettingsFileWithAgentModelsKeyIsPreserved`

## Recovery lanes

When persistence is blocked, the app runs with in-memory settings and refuses to overwrite
the preserved file until the user chooses an action:

- **Same-lineage future CE**: show the file or reset after backing it up. Compatible import
  is intentionally unavailable because an older build cannot know how to preserve future CE
  fields.
- **Incompatible/foreign JSON**: offer compatible import. Import backs up the original
  byte-for-byte, decodes CE-known fields, writes a current-schema CE file, and leaves
  unknown fields only in the backup.
- **Save failure**: offer retry before reset.

Every save re-checks the on-disk header before writing. This matters because CE dev builds
can share the live app support folder; a future/foreign file may appear after launch.

Blocked-persistence warnings may be dismissed in workspace windows for the current app
session. The store owns dismissal across workspace windows and clears it when the reason
changes or persistence unblocks. It is never stored in `UserDefaults`. The Settings
window always shows the active warning and recovery controls.

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

Context Builder discovery budget, enhancement mode, clarifying-question behavior, and related per-workspace discovery options remain in workspace chat settings. Only the Context Builder agent/model selection moved into Agent Models profiles.

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
