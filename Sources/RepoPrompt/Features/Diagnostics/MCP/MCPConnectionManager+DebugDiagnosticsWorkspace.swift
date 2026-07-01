// MARK: - DEBUG Workspace Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugWorkspaceSelectionFixturePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let action = debugString(arguments, "action")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "snapshot"
                let windowID: Int
                switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0 ... Int.max) {
                case let .value(parsed), let .defaulted(parsed):
                    windowID = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be a non-negative integer.")
                }

                let selectedWindow = await Self.debugSelectWindow(windowID: windowID)
                guard let window = selectedWindow else {
                    let detail = windowID > 0 ? "window_id \(windowID)" : "a focused or latest window"
                    return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched \(detail).")
                }

                let includeOwners = debugBool(arguments, "include_owners") == true

                switch action {
                case "snapshot":
                    let payload = await Self.debugWorkspaceSelectionFixtureSnapshot(op: op, action: action, window: window, includeOwners: includeOwners)
                    return debugDiagnosticsResult(payload)
                case "owners":
                    let payload = await Self.debugWorkspaceSelectionFixtureSnapshot(op: op, action: action, window: window, includeOwners: true)
                    return debugDiagnosticsResult(payload)
                case "apply":
                    let selectedPathsOptional = debugStringArray(arguments, "selected_paths", op: op)
                    guard let selectedPathsOptional else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`selected_paths` must be an array of strings when provided.")
                    }
                    let parsedSlices = Self.debugParseSelectionFixtureSlices(arguments["slices"])
                    if let message = parsedSlices.error {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: message)
                    }
                    let slices = parsedSlices.slices ?? [:]
                    let selection = StoredSelection(
                        selectedPaths: (selectedPathsOptional ?? []).map(StandardizedPath.absolute),
                        slices: slices,
                        codemapAutoEnabled: debugBool(arguments, "codemap_auto_enabled") ?? true
                    )
                    let payload = await Self.debugApplyWorkspaceSelectionFixture(op: op, action: action, window: window, selection: selection)
                    return debugDiagnosticsResult(payload)
                default:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "Unknown `workspace_selection_fixture` action: \(action). Use `snapshot`, `owners`, or `apply`.")
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`workspace_selection_fixture` is only available in DEBUG builds.")
            #endif
        }

        @MainActor
        private static func debugSelectWindow(windowID: Int) -> WindowState? {
            let manager = WindowStatesManager.shared
            if windowID > 0 {
                return manager.allWindows.first { $0.windowID == windowID }
            }
            return manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
        }

        @MainActor
        private static func debugWorkspaceSelectionFixtureSnapshot(
            op: String,
            action: String,
            window: WindowState,
            includeOwners: Bool
        ) async -> [String: Any] {
            let snapshot = window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false)
            var extra: [String: Any] = ["snapshotFlushedPendingUI": false]
            if includeOwners {
                extra["owners"] = await debugWorkspaceSelectionOwnerSnapshots(window: window)
            }
            return debugWorkspaceSelectionFixturePayload(
                op: op,
                action: action,
                window: window,
                tabID: snapshot.tabID,
                selection: snapshot.selection,
                extra: extra
            )
        }

        @MainActor
        private static func debugApplyWorkspaceSelectionFixture(
            op: String,
            action: String,
            window: WindowState,
            selection: StoredSelection
        ) async -> [String: Any] {
            let requestedFields = WorkspaceSelectionDebugSignature.unprefixedFields(for: selection)
            let targetTabID = window.selectionCoordinator.activeTabID()
            if let targetTabID, window.promptManager.activeComposeTabID != targetTabID {
                await window.promptManager.switchComposeTab(targetTabID)
            }
            if window.workspaceFilesViewModel.currentTabIDForDebugOwnerTrace != targetTabID {
                window.workspaceFilesViewModel.setActiveTabID(targetTabID)
            }
            WorkspaceRestorePerfLog.event(
                "workspaceSelection.fixtureApply.before",
                fields: WorkspaceSelectionDebugSignature.unprefixedFields(for: window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false).selection)
            )
            _ = await window.selectionCoordinator.persistActiveSelection(selection, source: .runtimeMutation, mirrorToUI: false)
            let sameWorkspaceWindows = WindowStatesManager.shared.allWindows.filter { candidate in
                guard candidate !== window else { return false }
                return candidate.workspaceManager.activeWorkspace?.id == window.workspaceManager.activeWorkspace?.id
            }
            for candidate in sameWorkspaceWindows {
                let candidateTabID = candidate.selectionCoordinator.activeTabID()
                if let candidateTabID,
                   candidate.promptManager.activeComposeTabID != candidateTabID
                {
                    await candidate.promptManager.switchComposeTab(candidateTabID)
                }
                if candidate.workspaceFilesViewModel.currentTabIDForDebugOwnerTrace != candidateTabID {
                    candidate.workspaceFilesViewModel.setActiveTabID(candidateTabID)
                }
                _ = await candidate.selectionCoordinator.persistActiveSelection(selection, source: .runtimeMutation, mirrorToUI: false)
                await candidate.selectionCoordinator.withApplyingSelectionMirror {
                    await candidate.workspaceFilesViewModel.applyStoredSelection(selection)
                    await candidate.workspaceFilesViewModel.hydrateSlicesForActiveTab(from: selection)
                }
            }
            var afterCoordinatorFields = WorkspaceSelectionDebugSignature.unprefixedFields(for: window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false).selection)
            afterCoordinatorFields["mirroredWindowCount"] = "\(sameWorkspaceWindows.count)"
            WorkspaceRestorePerfLog.event(
                "workspaceSelection.fixtureApply.afterCoordinator",
                fields: afterCoordinatorFields
            )
            await window.selectionCoordinator.withApplyingSelectionMirror {
                await window.workspaceFilesViewModel.applyStoredSelection(selection)
                await window.workspaceFilesViewModel.hydrateSlicesForActiveTab(from: selection)
            }
            let afterHydrateSelection = window.workspaceFilesViewModel.snapshotSelection()
            WorkspaceRestorePerfLog.event(
                "workspaceSelection.fixtureApply.afterHydrate",
                fields: WorkspaceSelectionDebugSignature.unprefixedFields(for: afterHydrateSelection)
            )
            let coordinatorBeforeFlush = window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false)
            let flushed = window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
            WorkspaceRestorePerfLog.event(
                "workspaceSelection.fixtureApply.afterFlush",
                fields: WorkspaceSelectionDebugSignature.unprefixedFields(for: flushed.selection)
            )
            var extra: [String: Any] = [
                "snapshotFlushedPendingUI": true,
                "requestedSelectionSignature": requestedFields["selectionSignature"] ?? "",
                "requestedSelectedPaths": requestedFields["selectedPaths"] ?? "0",
                "requestedSliceFiles": requestedFields["sliceFiles"] ?? "0",
                "requestedSliceRanges": requestedFields["sliceRanges"] ?? "0",
                "requestedCodemapAutoEnabled": requestedFields["codemapAutoEnabled"] ?? "false",
                "sliceHydrationPerformed": true,
                "uiMatchesRequestedAfterHydrate": afterHydrateSelection == selection,
                "coordinatorMatchesRequestedBeforeFlush": coordinatorBeforeFlush.selection == selection
            ]
            extra["appliedMatchesRequested"] = flushed.selection == selection
            if let activeWorkspace = window.workspaceManager.activeWorkspace {
                do {
                    WorkspaceRestorePerfLog.event(
                        "workspaceSelection.fixtureApply.beforeDiskFlush",
                        fields: WorkspaceSelectionDebugSignature.unprefixedFields(for: window.workspaceManager.composeTab(with: flushed.tabID ?? UUID())?.selection ?? flushed.selection)
                    )
                    let finalURL = try await window.workspaceManager.saveWorkspaceToFileAsync(activeWorkspace, source: .debugWorkspaceSelectionFixtureApply)
                    await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: finalURL)
                    extra["workspaceSaveFlushed"] = true
                    if let diskSelection = Self.debugDiskActiveComposeTabSelection(window: window) {
                        WorkspaceRestorePerfLog.event(
                            "workspaceSelection.fixtureApply.afterDiskFlush",
                            fields: WorkspaceSelectionDebugSignature.unprefixedFields(for: diskSelection)
                        )
                    }
                } catch {
                    extra["workspaceSaveFlushed"] = false
                    extra["workspaceSaveError"] = String(describing: error)
                }
            } else {
                extra["workspaceSaveFlushed"] = false
                extra["workspaceSaveError"] = "no active workspace"
            }
            extra["owners"] = await debugWorkspaceSelectionOwnerSnapshots(window: window)
            return debugWorkspaceSelectionFixturePayload(
                op: op,
                action: action,
                window: window,
                tabID: flushed.tabID,
                selection: flushed.selection,
                extra: extra
            )
        }

        @MainActor
        private static func debugWorkspaceSelectionOwnerSnapshots(window: WindowState) async -> [[String: Any]] {
            var owners: [[String: Any]] = []

            func appendOwner(_ name: String, tabID: UUID?, selection: StoredSelection?, extra: [String: Any] = [:]) {
                var object: [String: Any] = [
                    "owner": name,
                    "tab_id": tabID?.uuidString ?? "<none>"
                ]
                if let selection {
                    for (key, value) in WorkspaceSelectionDebugSignature.unprefixedFields(for: selection) {
                        object[key] = value
                    }
                } else {
                    object["selectionMissing"] = true
                }
                for (key, value) in extra {
                    object[key] = value
                }
                owners.append(object)
            }

            let coordinatorNoFlush = window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false)
            appendOwner(
                "selectionCoordinator.noFlush",
                tabID: coordinatorNoFlush.tabID,
                selection: coordinatorNoFlush.selection,
                extra: ["isVirtual": coordinatorNoFlush.isVirtual]
            )

            let coordinatorFlushed = window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
            appendOwner(
                "selectionCoordinator.flushed",
                tabID: coordinatorFlushed.tabID,
                selection: coordinatorFlushed.selection,
                extra: ["isVirtual": coordinatorFlushed.isVirtual]
            )

            let promptTabID = window.promptManager.activeComposeTabID
            let promptTab = promptTabID.flatMap { id in window.promptManager.currentComposeTabs.first(where: { $0.id == id }) }
            appendOwner("promptViewModel.activeComposeTab", tabID: promptTabID, selection: promptTab?.selection)

            let workspace = window.workspaceManager.activeWorkspace
            let workspaceTabID = workspace?.activeComposeTabID ?? workspace?.composeTabs.first?.id
            let workspaceTab = workspaceTabID.flatMap { id in window.workspaceManager.composeTab(with: id) }
            appendOwner(
                "workspaceManager.activeWorkspace.activeComposeTab",
                tabID: workspaceTabID,
                selection: workspaceTab?.selection,
                extra: [
                    "workspace_id": workspace?.id.uuidString ?? "<none>",
                    "workspace_name": workspace?.name ?? "<none>"
                ]
            )

            appendOwner("workspaceFilesViewModel.snapshot", tabID: window.workspaceFilesViewModel.currentTabIDForDebugOwnerTrace, selection: window.workspaceFilesViewModel.snapshotSelection())

            let diskSelection = Self.debugDiskActiveComposeTabSelection(window: window)
            appendOwner("disk.activeWorkspace.activeComposeTab", tabID: workspaceTabID, selection: diskSelection)

            return owners
        }

        @MainActor
        private static func debugDiskActiveComposeTabSelection(window: WindowState) -> StoredSelection? {
            guard let workspace = window.workspaceManager.activeWorkspace else { return nil }
            let url = window.workspaceManager.workspaceFileURL(for: workspace)
            guard FileManager.default.fileExists(atPath: url.path),
                  let diskWorkspace = try? WorkspaceManagerViewModel.loadWorkspaceFromFile(at: url)
            else {
                return nil
            }
            let activeTabID = diskWorkspace.activeComposeTabID ?? diskWorkspace.composeTabs.first?.id
            return activeTabID.flatMap { id in diskWorkspace.composeTabs.first(where: { $0.id == id })?.selection }
        }

        @MainActor
        private static func debugWorkspaceSelectionFixturePayload(
            op: String,
            action: String,
            window: WindowState,
            tabID: UUID?,
            selection: StoredSelection,
            extra: [String: Any]
        ) -> [String: Any] {
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "action": action,
                "window_id": window.windowID,
                "workspace_id": window.workspaceManager.activeWorkspace?.id.uuidString ?? "<none>",
                "workspace_name": window.workspaceManager.activeWorkspace?.name ?? "<none>",
                "tab_id": tabID?.uuidString ?? "<none>"
            ]
            for (key, value) in WorkspaceSelectionDebugSignature.unprefixedFields(for: selection) {
                payload[key] = value
            }
            for (key, value) in extra {
                payload[key] = value
            }
            return payload
        }

        private static func debugParseSelectionFixtureSlices(_ value: Value?) -> (slices: [String: [LineRange]]?, error: String?) {
            guard let value else { return ([:], nil) }
            var result: [String: [LineRange]] = [:]

            if let array = value.arrayValue {
                for item in array {
                    guard let object = item.objectValue else {
                        return (nil, "Each `slices` entry must be an object.")
                    }
                    guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                        return (nil, "Each `slices` entry requires a non-empty string `path`.")
                    }
                    guard let rangesValue = object["ranges"]?.arrayValue else {
                        return (nil, "Each `slices` entry requires a `ranges` array.")
                    }
                    let parsedRanges = Self.debugParseSelectionFixtureRangeArray(rangesValue)
                    if let error = parsedRanges.error {
                        return (nil, error)
                    }
                    let ranges = parsedRanges.ranges ?? []
                    if !ranges.isEmpty {
                        result[StandardizedPath.absolute(path), default: []].append(contentsOf: ranges)
                    }
                }
                return (result, nil)
            }

            if let object = value.objectValue {
                guard !object.isEmpty else { return ([:], nil) }
                for (path, rangesValue) in object {
                    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedPath.isEmpty else {
                        return (nil, "`slices` object keys must be non-empty file paths.")
                    }
                    guard let rangesArray = rangesValue.arrayValue else {
                        return (nil, "`slices` must be an array of {path,ranges} entries, an empty object, or an object mapping file paths to range arrays.")
                    }
                    let parsedRanges = Self.debugParseSelectionFixtureRangeArray(rangesArray)
                    if let error = parsedRanges.error {
                        return (nil, error)
                    }
                    let ranges = parsedRanges.ranges ?? []
                    if !ranges.isEmpty {
                        result[StandardizedPath.absolute(trimmedPath), default: []].append(contentsOf: ranges)
                    }
                }
                return (result, nil)
            }

            return (nil, "`slices` must be an array of {path,ranges} entries, an empty object, or an object mapping file paths to range arrays.")
        }

        static func debugParseSelectionFixtureSlicesForTesting(_ value: Value?) -> (slices: [String: [LineRange]]?, error: String?) {
            debugParseSelectionFixtureSlices(value)
        }

        private static func debugParseSelectionFixtureRangeArray(_ rangesValue: [Value]) -> (ranges: [LineRange]?, error: String?) {
            var ranges: [LineRange] = []
            for rangeValue in rangesValue {
                guard let rangeObject = rangeValue.objectValue else {
                    return (nil, "Each slice range must be an object.")
                }
                guard let start = Self.debugIntValue(rangeObject["start_line"] ?? rangeObject["start"]),
                      let end = Self.debugIntValue(rangeObject["end_line"] ?? rangeObject["end"])
                else {
                    return (nil, "Each slice range requires integer `start_line`/`end_line` values.")
                }
                let description = rangeObject["description"]?.stringValue
                    ?? rangeObject["desc"]?.stringValue
                    ?? rangeObject["label"]?.stringValue
                ranges.append(LineRange(start: start, end: end, description: description))
            }
            return (ranges, nil)
        }

        private static func debugIntValue(_ value: Value?) -> Int? {
            guard let value else { return nil }
            switch value {
            case let .int(int):
                return int
            case let .double(double):
                guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
                return Int(double)
            case let .string(string):
                return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                return nil
            }
        }

        func debugRestorePerfMetricsPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            #if DEBUG
                if let enable = debugBool(arguments, "enable") {
                    WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(enable)
                }
                if debugBool(arguments, "clear") == true {
                    WorkspaceRestorePerfLog.clearRecentMetricLines()
                }
                if debugBool(arguments, "emit_probe") == true {
                    WorkspaceRestorePerfLog.log("restore.metrics probe source=debugDiagnostics")
                }

                let emittedMark: String?
                if let rawMark = debugString(arguments, "mark") {
                    let mark = rawMark.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !mark.isEmpty else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`mark` must be a non-empty string when provided.")
                    }
                    WorkspaceRestorePerfLog.event("restore.metrics.mark", fields: ["mark": mark])
                    emittedMark = mark
                } else {
                    emittedMark = nil
                }

                let limit: Int
                switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1 ... 2000) {
                case let .value(parsed), let .defaulted(parsed):
                    limit = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 2000.")
                }

                var payload = WorkspaceRestorePerfLog.debugStateSnapshot(lineLimit: limit)
                payload["ok"] = true
                payload["op"] = op
                if let emittedMark {
                    payload["mark"] = emittedMark
                }
                return debugDiagnosticsResult(payload)
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`restore_perf_metrics` is only available in DEBUG builds.")
            #endif
        }

        @MainActor
        func debugWorkspaceLoadingSnapshotPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0 ... Int.max) {
            case let .value(parsed), let .defaulted(parsed):
                windowID = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be a non-negative integer.")
            }

            let manager = WindowStatesManager.shared
            let selectedWindow: WindowState? = if windowID > 0 {
                manager.allWindows.first { $0.windowID == windowID }
            } else {
                manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
            }

            guard let window = selectedWindow else {
                return debugDiagnosticsError(op: op, code: "no_window", message: "No matching RepoPrompt window is available for workspace loading diagnostics.")
            }

            let workspace = window.workspaceManager.activeWorkspace
            let visibleCatalog = await window.workspaceFileContextStore.catalogDiagnostics(rootScope: .visibleWorkspace)
            let allLoadedCatalog = await window.workspaceFileContextStore.catalogDiagnostics(rootScope: .allLoaded)
            let searchDiagnostics = await window.workspaceSearchService.diagnostics
            let indexedGeneration = await window.workspaceSearchService.indexedGeneration
            let snapshotGeneration = await window.workspaceSearchService.snapshotGeneration
            let indexedPathCount = await window.workspaceSearchService.indexedPathCount
            let pendingGeneration = await window.workspaceSearchService.pendingGeneration
            let observedCatalogGeneration = await window.workspaceSearchService.observedCatalogGeneration
            let discardedStaleRebuildCount = await window.workspaceSearchService.discardedStaleRebuildCount
            let uiProjection = Self.debugUIProjectionPayload(for: window.workspaceFilesViewModel)
            let overlayState = window.workspaceManager.workspaceSwitchOverlayState
            let overlayElapsedMS = overlayState.map { Date().timeIntervalSince($0.startedAt) * 1000 }

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "window_id": window.windowID,
                "workspace_id": workspace?.id.uuidString ?? "<none>",
                "workspace_name": workspace?.name ?? "<none>",
                "workspace_loading": [
                    "readiness": Self.debugReadinessStatePayload(window.workspaceManager.workspaceSearchReadinessState),
                    "store_catalog": [
                        "visible_workspace": Self.debugCatalogDiagnosticsPayload(visibleCatalog),
                        "all_loaded": Self.debugCatalogDiagnosticsPayload(allLoadedCatalog)
                    ],
                    "search_index": [
                        "snapshot_generation": Self.debugOptionalValue(snapshotGeneration),
                        "indexed_generation": Self.debugOptionalValue(indexedGeneration),
                        "pending_generation": Self.debugOptionalValue(pendingGeneration),
                        "observed_catalog_generation": Self.debugOptionalValue(observedCatalogGeneration),
                        "indexed_path_count": indexedPathCount,
                        "discarded_stale_rebuild_count": discardedStaleRebuildCount,
                        "diagnostics": Self.debugOptionalValue(searchDiagnostics.map(Self.debugCatalogDiagnosticsPayload))
                    ],
                    "ui_projection": uiProjection,
                    "workspace_switch": [
                        "overlay": [
                            "is_visible": window.workspaceManager.isWorkspaceSwitchOverlayVisible,
                            "target_workspace_name": Self.debugOptionalValue(overlayState?.targetWorkspaceName),
                            "elapsed_ms": Self.debugOptionalValue(overlayElapsedMS.map(Self.debugRoundedMS))
                        ],
                        "debug_open_trace": window.workspaceManager.debugWorkspaceOpenTraceSnapshot()
                    ],
                    "timing_notes": [
                        "activation": "See restore_perf_metrics events workspaceSwitch.diskLoad and workspaceSwitch.restoreState when enabled.",
                        "catalog_hydration": "See restore_perf_metrics event workspaceSwitch.loadWorkspaceFolders.userRoots.catalogHydration.end.",
                        "root_shell_possible": "See restore_perf_metrics event workspaceSwitch.loadWorkspaceFolders.rootShellPossible and store.rootLoad.rootRecordCreated; current loadRoot behavior still completes catalog before shell possible.",
                        "root_visible": "See restore_perf_metrics events workspaceSwitch.loadWorkspaceFolders.firstPrimaryRootVisible, workspaceSwitch.loadWorkspaceFolders.allPrimaryRootsVisible, and workspaceSwitch.loadWorkspaceFolders.rootVisibilitySummary.",
                        "catalog_complete_after_visible": "Future pre-catalog shell candidates should report workspaceSwitch.loadWorkspaceFolders.rootCatalogCompleteAfterVisible and allRootCatalogsCompleteAfterVisible while readiness remains loading/building until complete.",
                        "index_build": "See restore_perf_metrics event workspaceSwitch.searchIndexBuild.end.",
                        "overlay": "See restore_perf_metrics events workspaceSwitch.overlay.shown and workspaceSwitch.overlay.hidden.",
                        "first_ui_materialization": "No eager UI tree materialization is expected; ui_projection reports currently materialized root-shell/index counts."
                    ]
                ]
            ])
        }

        static func debugCatalogDiagnosticsPayload(_ diagnostics: WorkspaceCatalogDiagnostics) -> [String: Any] {
            [
                "generation": diagnostics.generation,
                "root_scope": debugRootScopeName(diagnostics.rootScope),
                "root_count": diagnostics.rootCount,
                "folder_count": diagnostics.folderCount,
                "file_count": diagnostics.fileCount,
                "total_item_count": diagnostics.totalItemCount
            ]
        }

        private static func debugRootScopeName(_ scope: WorkspaceLookupRootScope) -> String {
            switch scope {
            case .visibleWorkspace:
                "visibleWorkspace"
            case .visibleWorkspacePlusGitData:
                "visibleWorkspacePlusGitData"
            case .allLoaded:
                "allLoaded"
            case .allLoadedExcludingGitData:
                "allLoadedExcludingGitData"
            case .sessionBoundWorkspace:
                "sessionBoundWorkspace"
            case .validatedSessionBoundWorkspace:
                "validatedSessionBoundWorkspace"
            }
        }

        static func debugReadinessStatePayload(_ state: WorkspaceSearchReadinessState) -> [String: Any] {
            switch state {
            case .idle:
                ["state": "idle"]
            case let .activating(workspaceID, generation):
                [
                    "state": "activating",
                    "workspace_id": debugOptionalValue(workspaceID?.uuidString),
                    "generation": generation
                ]
            case let .loadingCatalog(workspaceID, generation, loadedRootCount, expectedRootCount, failures):
                [
                    "state": "loadingCatalog",
                    "workspace_id": debugOptionalValue(workspaceID?.uuidString),
                    "generation": generation,
                    "loaded_root_count": loadedRootCount,
                    "expected_root_count": expectedRootCount,
                    "failure_count": failures.count,
                    "failures": failures.map(debugRootLoadFailurePayload)
                ]
            case let .buildingIndexes(workspaceID, generation, catalogGeneration, failures):
                [
                    "state": "buildingIndexes",
                    "workspace_id": debugOptionalValue(workspaceID?.uuidString),
                    "generation": generation,
                    "catalog_generation": catalogGeneration,
                    "failure_count": failures.count,
                    "failures": failures.map(debugRootLoadFailurePayload)
                ]
            case let .ready(workspaceID, generation, catalogGeneration, indexedGeneration, diagnostics):
                [
                    "state": "ready",
                    "workspace_id": debugOptionalValue(workspaceID?.uuidString),
                    "generation": generation,
                    "catalog_generation": catalogGeneration,
                    "indexed_generation": indexedGeneration,
                    "diagnostics": debugCatalogDiagnosticsPayload(diagnostics)
                ]
            case let .degraded(workspaceID, generation, catalogGeneration, indexedGeneration, failures, diagnostics):
                [
                    "state": "degraded",
                    "workspace_id": debugOptionalValue(workspaceID?.uuidString),
                    "generation": generation,
                    "catalog_generation": debugOptionalValue(catalogGeneration),
                    "indexed_generation": debugOptionalValue(indexedGeneration),
                    "failure_count": failures.count,
                    "failures": failures.map(debugRootLoadFailurePayload),
                    "diagnostics": debugOptionalValue(diagnostics.map(debugCatalogDiagnosticsPayload))
                ]
            }
        }

        private static func debugRootLoadFailurePayload(_ failure: WorkspaceRootLoadFailure) -> [String: Any] {
            [
                "root_path": failure.standardizedRootPath,
                "kind": debugRootKindName(failure.kind),
                "error": failure.errorDescription
            ]
        }

        private static func debugRootKindName(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace:
                "primaryWorkspace"
            case .workspaceGitData:
                "workspaceGitData"
            case .supplementalSystem:
                "supplementalSystem"
            case .sessionWorktree:
                "sessionWorktree"
            }
        }

        @MainActor
        static func debugUIProjectionPayload(for fileManager: WorkspaceFilesViewModel) -> [String: Any] {
            let counts = fileManager.restorePerfLoadedTreeCounts()
            return [
                "root_shells": fileManager.rootFolders.count,
                "visible_root_shells": fileManager.visibleRootFolders.count,
                "materialized_folder_vms": counts.folderCount,
                "materialized_file_vms": counts.fileCount,
                "selected_files": fileManager.selectedFiles.count,
                "auto_codemap_files": fileManager.autoCodemapFiles.count,
                "notes": "UI projection counts are informational only; store catalog counts are canonical for workspace loading/search readiness."
            ]
        }
    }
#endif
