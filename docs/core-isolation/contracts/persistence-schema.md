# Persistence Schema and Compatibility Contract

**Frozen:** 2026-06-21
**Current implementation:** `WorkspaceModel.swift` and
`WorkspaceManagerViewModel.swift` at
`8e42951159c9f1d6973a4538a309908baacdb371`

## Locations and names

- Default root:
  `~/Library/Application Support/RepoPrompt CE/Workspaces`.
- Workspace index: `workspacesIndex.json`.
- Default workspace directory:
  `Workspace-<name>-<workspace UUID>/workspace.json`.
- A non-nil `customStoragePath` replaces the default workspace directory but
  retains the `workspace.json` filename.
- Each workspace directory also owns `Chats/`.
- Window restore remains app-owned at
  `~/Library/Application Support/RepoPrompt CE/windowSessions.json`.

Path selection and Application Support policy remain in the app. Core receives
resolved URLs; it does not derive these paths.

## Index schema

`workspacesIndex.json` is an ordered JSON array of:

- `id: UUID`
- `name: String`
- `customStoragePath: URL?`
- `isSystemWorkspace: Bool`
- `isHiddenInMenus: Bool`

Index order is workspace order. Ephemeral workspaces are excluded. Missing or
corrupt workspace files are skipped on load. Duplicate workspace IDs are
last-wins. Current synthesized `Codable` makes a missing required index field
fail decoding of the array; this is frozen current behavior, not permission to
silently broaden or repair it during extraction.

## Workspace schema

`workspace.json` fields:

| Group | Fields |
| --- | --- |
| Identity/version/date | `id`, `schemaVersion`, `dateModified`, `lastUsed` |
| Storage/policy | `customStoragePath`, `isSystemWorkspace`, `isHiddenInMenus`, `ephemeralFlag` |
| Workspace/root order | `name`, ordered `repoPaths` |
| Presets | ordered `presets`, `activePresetID` |
| Legacy/custom state still persisted | `customPath`, `currentPromptText`, `lastSearchQuery`, ordered `selectedMetaPromptIDs` |
| Copy/chat | `copyPresetId`, `copyCustomizations`, `chatPresetId` |
| Tabs | ordered `composeTabs`, `activeComposeTabID`, ordered `stashedTabs` |

`normalizationRequiresSave` is transient and excluded from coding and equality.

A compose tab persists `id`, `name`, `lastModified`, `isPinned`,
`activeChatSessionID`, `activeAgentSessionID`, `selection`,
`expandedFolders`, `promptText`, `selectedMetaPromptIDs`, `activeSubView`,
`contextOverrides`, and Context Builder configuration under the legacy key
`discover`. Renaming `discover` is a schema break.

Nested schemas are frozen as follows:

- `WorkspacePreset`: `id`, `name`, `capturesFileSelection`,
  `capturesFileTreeExpansion`, `capturesSelectedPrompts`, ordered
  `selectedFilePaths`, ordered `expandedFolders`, ordered `selectedPromptIDs`,
  and `lastUpdated`.
- `StoredSelection`: ordered `selectedPaths`, ordered `autoCodemapPaths`, a
  path-keyed `slices` dictionary whose range arrays are ordered, and
  `codemapAutoEnabled`.
- `LineRange`: `start`, `end`, and optional `description`.
- `ContextBuilderOverrides`: `useOverridePrompt` and `overridePromptText`.
- `ContextBuilderTabConfig` (encoded as `discover`): `instructions`, optional
  `autoGeneratePlan`, optional `followUpTypeRaw`, and ordered
  `selectedContextBuilderPromptIDs`.
- `StashedTab`: `id`, nested `tab`, and `stashedAt`.
- `CopyCustomizations`: optional `selectedPromptIDs`, `fileTreeMode`,
  `codeMapUsage`, `gitInclusion`, `includeFiles`, `includeUserPrompt`,
  `includeMetaPrompts`, and `includeFileTree`.

## Missing/malformed defaults

- `id`: new UUID.
- `schemaVersion`: 1.
- `dateModified` and `lastUsed`: current `Date()`.
- `name`: `Untitled Workspace`.
- booleans: false; `ephemeralFlag` nil, so `isEphemeral == false`.
- arrays/dictionaries: empty.
- optional IDs, URLs, strings, and customizations: nil.
- malformed `composeTabs`: empty with one-time logging.
- `StoredSelection`: empty paths/codemaps/slices and
  `codemapAutoEnabled == true`.
- Context Builder fields: empty instructions, nil auto-plan/follow-up, empty
  prompt IDs.
- future workspace schema versions are currently accepted, not rejected.

Foundation `JSONEncoder`/`JSONDecoder` defaults are used, including numeric
`Date` values measured from Foundation's reference date. No custom date strategy
exists.

## Ordering and normalization

- Persisted arrays preserve input order. Schema code performs no general sorting,
  whitespace trimming, tilde expansion, or deduplication.
- Empty `composeTabs` synthesizes a `T1` tab from legacy top-level prompt and
  meta-prompt fields.
- A missing/invalid active tab selects the first compose tab.
- Stashed tabs whose tab IDs collide with active tabs are removed.
- These changes set `normalizationRequiresSave`.
- Root equality for disk reconciliation compares standardized lowercased paths
  but preserves the winning array's order.
- If local roots still equal the recorded baseline and disk roots changed, disk
  `repoPaths` win. A real local root edit wins over disk roots.
- Normalization writeback is compare-and-swap-like: original path, file size,
  and filesystem modification date must match, and no normal writer may be
  pending.

## Dirty/saved generations and selection revisions

- App dirty state uses per-workspace integer
  `stateVersionByWorkspaceID` and `lastSavedVersionByWorkspaceID`.
- Detached encoding captures the state version and retries if it changed while
  suspended.
- Canonical selection revision is a process-global monotonic `UInt64` starting
  at 1 and stored per `(workspaceID, tabID)`.
- It advances only when `StoredSelection` equality changes.
- It is not persisted. Save metadata includes the active revision only when the
  recorded selection still equals the active tab selection.
- MCP peer propagation has a separate process-global monotonic counter and
  accepts only `incoming > latest`.
- Coordinator UI-mirror revisions are separate again.
- Tab/context revision makes an A→B→A transition distinguishable from no change.

## Disk-writer arbitration and stale reconciliation

One shared actor serializes writes per URL.

1. Strictly higher active-selection revision wins pending-payload arbitration.
2. Otherwise strictly newer `dateModified` wins.
3. Equal dates are last-in-wins.
4. Disk is reread immediately before writing.
5. Strictly newer disk suppresses a stale payload.
6. If a newer unwritten selection revision exists, only that active-tab
   selection is merged into the newer disk model; unrelated newer disk fields
   survive and the merged model receives `Date()`.
7. Revision-zero payloads may be patched with the latest known selection.
8. Successful atomic writes advance the last-written selection revision.

## Byte and semantic fixture

Executable fixture:

`root/RepoPromptTests.WorkspaceRootSyncTests/testWorkspacePersistenceLegacyDecodeCurrentEncodeAndCurrentReaderRoundTripContract`

The inline representative legacy UTF-8 JSON and expected current UTF-8 JSON freeze:

- fixed UUID/date/value types;
- exact current field/key spelling and omission of removed legacy keys;
- `discover` compatibility;
- ordered roots, selections, codemap paths, folders, prompt IDs, and ranges;
- slice values and optional description;
- no normalization for an already valid tab graph;
- current bytes re-decoding and re-encoding through the unchanged current app reader.

Because Foundation does not contractually guarantee JSON object-key order or
whitespace, the test canonicalizes object keys through `JSONSerialization` and
does not sort arrays. Raw object-key order is explicitly not a compatibility
contract. The executable fixture intentionally covers the high-risk representative
subset above; it does not claim non-nil coverage for every optional preset,
copy/chat, stashed-tab, active-session, storage-path, or subview value. The
field inventory in this contract remains authoritative for those omitted values.

Existing stale-selection tests remain authoritative:

- `root/RepoPromptTests.WorkspaceSelectionPersistenceTests/testDiskWriterPreservesNewerSelectionRevisionAgainstLaterStalePayload`
- `root/RepoPromptTests.WorkspaceSelectionPersistenceTests/testDiskWriterMergesNewerSelectionIntoNewerDiskInsteadOfSkipping`
- `root/RepoPromptTests.WorkspaceSelectionPersistenceTests/testApplySelectionToWorkspaceUpdatesActiveTabOnly`

Phase 2 moves this fixture with the concrete persisted type and preserves the
exact oracle. Typealiases or module movement are not permission to rewrite the
fixture. Before Phase 2 closes, the split must add an independent legacy/rollback
reader fixture proving old bytes decode through the new type and new bytes decode
through the retained rollback backend; Phase 0 does not claim that future dual-
reader mechanism already exists.
