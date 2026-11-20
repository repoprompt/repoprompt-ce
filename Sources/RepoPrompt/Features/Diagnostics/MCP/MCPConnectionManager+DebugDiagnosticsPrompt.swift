// MARK: - DEBUG Prompt Diagnostics

import Foundation
import MCP
import RepoPromptWorkspaceContext

#if DEBUG
    extension ServerNetworkManager {
        func debugChatPreviewContextLatencyPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let windowID: Int
                switch debugBoundedInt(arguments, "window_id", defaultValue: -1, range: -1 ... 100_000) {
                case let .value(parsed), let .defaulted(parsed):
                    windowID = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be an integer between -1 and 100000; values <= 0 or omission use the focused/latest window.")
                }

                let warmups: Int
                switch debugBoundedInt(arguments, "warmups", defaultValue: 1, range: 0 ... 20) {
                case let .value(parsed), let .defaulted(parsed):
                    warmups = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`warmups` must be an integer between 0 and 20.")
                }

                let iterations: Int
                switch debugBoundedInt(arguments, "iterations", defaultValue: 5, range: 1 ... 100) {
                case let .value(parsed), let .defaulted(parsed):
                    iterations = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`iterations` must be an integer between 1 and 100.")
                }

                switch await Self.debugMeasureChatPreviewContextLatency(op: op, windowID: windowID, warmups: warmups, iterations: iterations) {
                case let .payload(payload):
                    return debugDiagnosticsResult(payload)
                case let .error(code, message):
                    return debugDiagnosticsError(op: op, code: code, message: message)
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`chat_preview_context_latency` is only available in DEBUG builds.")
            #endif
        }

        @MainActor
        private static func debugMeasureChatPreviewContextLatency(op: String, windowID: Int, warmups: Int, iterations: Int) async -> DebugDiagnosticsPayloadResult {
            let manager = WindowStatesManager.shared
            let selectedWindow: WindowState? = if windowID > 0 {
                manager.allWindows.first { $0.windowID == windowID }
            } else {
                manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
            }

            guard let window = selectedWindow else {
                return .error(code: "no_window", message: "No matching RepoPrompt window is available for chat preview context latency measurement.")
            }

            let promptViewModel = window.promptManager
            var lastTokenCount = 0

            for _ in 0 ..< warmups {
                lastTokenCount = await promptViewModel.calculateTokensForChatContext()
            }

            var durations: [Double] = []
            durations.reserveCapacity(iterations)
            for _ in 0 ..< iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                lastTokenCount = await promptViewModel.calculateTokensForChatContext()
                let end = DispatchTime.now().uptimeNanoseconds
                durations.append(Double(end - start) / 1_000_000.0)
            }

            let sorted = durations.sorted()
            let median = Self.debugMedian(sorted)
            let p95 = Self.debugNearestRankPercentile(sorted, percentile: 0.95)
            let workspace = window.workspaceManager.activeWorkspace
            let storeDiagnostics = await window.workspaceFileContextStore.catalogDiagnostics(rootScope: .visibleWorkspace)
            let searchDiagnostics = await window.workspaceSearchService.diagnostics
            let indexedGeneration = await window.workspaceSearchService.indexedGeneration
            let indexedPathCount = await window.workspaceSearchService.indexedPathCount
            let uiProjection = debugUIProjectionPayload(for: window.workspaceFilesViewModel)
            let readiness = debugReadinessStatePayload(window.workspaceManager.workspaceSearchReadinessState)
            let currentPreset = promptViewModel.currentChatPreset()
            let fixtureDescription = "real workspace \"\(workspace?.name ?? "<none>")\"; storeRoots=\(storeDiagnostics.rootCount), storeFolders=\(storeDiagnostics.folderCount), storeFiles=\(storeDiagnostics.fileCount), catalogGeneration=\(storeDiagnostics.generation), readiness=\(readiness["state"] ?? "unknown"), indexedGeneration=\(indexedGeneration.map(String.init) ?? "nil"), indexedPaths=\(indexedPathCount), uiRootShells=\(uiProjection["root_shells"] ?? 0), uiMaterializedFolders=\(uiProjection["materialized_folder_vms"] ?? 0), uiMaterializedFiles=\(uiProjection["materialized_file_vms"] ?? 0), selected=\(window.workspaceFilesViewModel.selectedFiles.count), autoCodemap=\(window.workspaceFilesViewModel.autoCodemapFiles.count), chatPreset=\(currentPreset.name), fileTree=\(promptViewModel.fileTreeOptionForChat.rawValue), codeMap=\(promptViewModel.codeMapUsageForChat.rawValue), git=\(promptViewModel.gitDiffInclusionModeForChat.rawValue)"

            return .payload([
                "ok": true,
                "op": op,
                "metric": "chat_preview_context_baseline_ms",
                "scope": "real_workspace_rp_cli_debug_prompt_context",
                "window_id": window.windowID,
                "workspace_id": workspace?.id.uuidString ?? "<none>",
                "workspace_name": workspace?.name ?? "<none>",
                "warmups": warmups,
                "iterations": iterations,
                "median_ms": median,
                "p95_ms": p95,
                "durations_ms": durations.map { Self.debugRoundedMS($0) },
                "last_token_count": lastTokenCount,
                "fixture": fixtureDescription,
                "workspace_loading": [
                    "readiness": readiness,
                    "store_catalog": debugCatalogDiagnosticsPayload(storeDiagnostics),
                    "search_index": [
                        "indexed_generation": debugOptionalValue(indexedGeneration),
                        "indexed_path_count": indexedPathCount,
                        "diagnostics": debugOptionalValue(searchDiagnostics.map(debugCatalogDiagnosticsPayload))
                    ],
                    "ui_projection": uiProjection
                ],
                "shape": [
                    "store_roots": storeDiagnostics.rootCount,
                    "store_folders": storeDiagnostics.folderCount,
                    "store_files": storeDiagnostics.fileCount,
                    "store_total_items": storeDiagnostics.totalItemCount,
                    "ui_root_shells": uiProjection["root_shells"] ?? 0,
                    "ui_visible_root_shells": uiProjection["visible_root_shells"] ?? 0,
                    "ui_materialized_folder_vms": uiProjection["materialized_folder_vms"] ?? 0,
                    "ui_materialized_file_vms": uiProjection["materialized_file_vms"] ?? 0,
                    "selected_files": window.workspaceFilesViewModel.selectedFiles.count,
                    "auto_codemap_files": window.workspaceFilesViewModel.autoCodemapFiles.count
                ],
                "chat_preset": [
                    "id": currentPreset.id.uuidString,
                    "name": currentPreset.name,
                    "mode": currentPreset.mode.rawValue,
                    "file_tree": promptViewModel.fileTreeOptionForChat.rawValue,
                    "code_map": promptViewModel.codeMapUsageForChat.rawValue,
                    "git": promptViewModel.gitDiffInclusionModeForChat.rawValue
                ],
                "selector": "\(MCPIntegrationHelper.cliCommandName) --call __repoprompt_debug_diagnostics --json '{\"op\":\"chat_preview_context_latency\",\"window_id\":\(window.windowID),\"warmups\":\(warmups),\"iterations\":\(iterations)}'"
            ])
        }
    }
#endif
