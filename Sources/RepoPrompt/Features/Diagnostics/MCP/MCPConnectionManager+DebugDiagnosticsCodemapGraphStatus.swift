import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        @MainActor
        func debugCodemapGraphStatusPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0 ... Int.max) {
            case let .value(value), let .defaulted(value):
                windowID = value
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`window_id` must be a non-negative integer."
                )
            }
            guard let window = Self.debugCodemapGraphStatusWindow(windowID: windowID) else {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No matching RepoPrompt window is available."
                )
            }

            let rootID: UUID?
            if let rawRootID = debugString(arguments, "root_id") {
                guard let parsed = UUID(uuidString: rawRootID) else {
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "`root_id` must be a UUID."
                    )
                }
                rootID = parsed
            } else {
                rootID = nil
            }
            let includeEvents = debugBool(arguments, "include_events") ?? false
            guard arguments["include_events"] == nil || debugBool(arguments, "include_events") != nil else {
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`include_events` must be a boolean."
                )
            }
            let eventLimit: Int
            switch debugBoundedInt(arguments, "event_limit", defaultValue: 256, range: 1 ... 1024) {
            case let .value(value), let .defaulted(value):
                eventLimit = value
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`event_limit` must be an integer between 1 and 1024."
                )
            }
            guard let sinceStoreOrdinal = debugOptionalOrdinal(arguments, key: "since_store_ordinal"),
                  let sinceEngineOrdinal = debugOptionalOrdinal(arguments, key: "since_engine_ordinal")
            else {
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "Event cursors must be non-negative integers."
                )
            }

            let snapshot = await window.workspaceFileContextStore.debugCodemapGraphStatusSnapshot(
                rootID: rootID,
                includeEvents: includeEvents,
                sinceStoreOrdinal: sinceStoreOrdinal,
                sinceEngineOrdinal: sinceEngineOrdinal,
                eventLimit: eventLimit
            )
            return debugDiagnosticsResult(CodemapGraphStatusDebugSupport.payload(
                snapshot: snapshot,
                op: op,
                windowID: window.windowID,
                workspaceID: window.workspaceManager.activeWorkspace?.id
            ))
        }

        private nonisolated func debugOptionalOrdinal(
            _ arguments: [String: Value],
            key: String
        ) -> UInt64?? {
            guard arguments[key] != nil else { return .some(nil) }
            switch debugBoundedInt(arguments, key, defaultValue: 0, range: 0 ... Int.max) {
            case let .value(value), let .defaulted(value):
                return .some(UInt64(value))
            case .invalid:
                return nil
            }
        }

        @MainActor
        private static func debugCodemapGraphStatusWindow(windowID: Int) -> WindowState? {
            let manager = WindowStatesManager.shared
            if windowID > 0 {
                return manager.allWindows.first { $0.windowID == windowID }
            }
            return manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
        }
    }
#endif
