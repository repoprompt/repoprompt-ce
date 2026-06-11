// MARK: - DEBUG Transport and Routing Diagnostics

import Foundation
import MCP

#if DEBUG
    private actor MCPDebugDiagnosticsProbeStore {
        struct CancellationRecord {
            let marker: String
            let count: Int
            let lastCancelledAt: Date?
        }

        static let shared = MCPDebugDiagnosticsProbeStore()

        private var countsByMarker: [String: Int] = [:]
        private var lastCancelledAtByMarker: [String: Date] = [:]

        func recordCancel(marker: String) {
            countsByMarker[marker, default: 0] += 1
            lastCancelledAtByMarker[marker] = Date()
        }

        func snapshot(markers: [String]?) -> [CancellationRecord] {
            let keys: [String] = if let markers, !markers.isEmpty {
                markers
            } else {
                Array(Set(countsByMarker.keys).union(lastCancelledAtByMarker.keys)).sorted()
            }
            return keys.map { marker in
                CancellationRecord(
                    marker: marker,
                    count: countsByMarker[marker] ?? 0,
                    lastCancelledAt: lastCancelledAtByMarker[marker]
                )
            }
        }

        func clear(markers: [String]?) {
            if let markers, !markers.isEmpty {
                for marker in markers {
                    countsByMarker.removeValue(forKey: marker)
                    lastCancelledAtByMarker.removeValue(forKey: marker)
                }
            } else {
                countsByMarker.removeAll()
                lastCancelledAtByMarker.removeAll()
            }
        }
    }

    extension ServerNetworkManager {
        func debugPingPayload(
            connectionID: UUID,
            op: String,
            arguments: [String: Value]
        ) async -> [String: Any] {
            let identity = identityContext(for: connectionID)
            let clientName = identity?.clientName ?? clientIdentifier(forConnection: connectionID)
            let sessionToken = sessionToken(for: connectionID)
            let windowID = selectedWindow(for: connectionID)
            let bindingKind = await debugBindingKind(for: connectionID)
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "connection_id": connectionID.uuidString,
                "session_token_present": sessionToken != nil,
                "session_key_present": sessionToken != nil,
                "session_fingerprint": debugSessionFingerprint(forToken: sessionToken) ?? NSNull(),
                "client_name": clientName ?? NSNull(),
                "normalized_client_id": debugNormalizedClientID(for: clientName) ?? NSNull(),
                "window_id": windowID ?? NSNull(),
                "binding_kind": bindingKind
            ]
            if let tag = debugString(arguments, "tag") {
                payload["tag"] = tag
            }
            return payload
        }

        func debugConnectionSnapshotToolPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let requestedID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string when provided.")
            }
            let historyLimit: Int
            switch debugBoundedInt(arguments, "history_limit", defaultValue: 20, range: 1 ... 200) {
            case let .value(value), let .defaulted(value): historyLimit = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "history_limit must be an integer in 1...200.")
            }
            let includeHistory = debugBool(arguments, "include_history") ?? false
            return await debugDiagnosticsResult(debugConnectionSnapshotPayload(
                currentConnectionID: connectionID,
                requestedConnectionID: requestedID,
                includeHistory: includeHistory,
                historyLimit: historyLimit
            ))
        }

        func debugTransportIngressSnapshotToolPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let requestedID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string when provided.")
            }
            return await debugDiagnosticsResult(debugTransportIngressSnapshotPayload(
                currentConnectionID: connectionID,
                requestedConnectionID: requestedID
            ))
        }

        func debugRoutingSnapshotToolPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let requestedID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string when provided.")
            }
            let payload = await debugRoutingSnapshotPayload(
                currentConnectionID: connectionID,
                requestedConnectionID: requestedID,
                clientNameFilter: debugString(arguments, "client_name"),
                includeRecords: debugBool(arguments, "include_records") ?? true,
                includeWindows: debugBool(arguments, "include_windows") ?? true
            )
            return debugDiagnosticsResult(payload)
        }

        func debugConnectionHistoryToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let limit: Int
            switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1 ... 500) {
            case let .value(value), let .defaulted(value): limit = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "limit must be an integer in 1...500.")
            }
            guard let connectionID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string when provided.")
            }
            return debugDiagnosticsResult(debugConnectionHistoryPayload(
                limit: limit,
                clientName: debugString(arguments, "client_name"),
                sessionFingerprint: debugString(arguments, "session_fingerprint"),
                connectionID: connectionID
            ))
        }

        func debugRunRoutingHistoryToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let limit: Int
            switch debugBoundedInt(arguments, "limit", defaultValue: 200, range: 1 ... 500) {
            case let .value(value), let .defaulted(value): limit = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "limit must be an integer in 1...500.")
            }
            guard let parsedRunID = debugOptionalUUID(arguments, "run_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "run_id must be a UUID string.")
            }
            guard let runID = parsedRunID else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "run_id is required.")
            }
            return debugDiagnosticsResult(debugRunRoutingHistoryPayload(runID: runID, limit: limit))
        }

        func debugClearConnectionHistoryToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "clear_connection_history requires allow_destructive=true.")
            }
            return debugDiagnosticsResult(debugClearConnectionHistoryPayload())
        }

        func debugWaitForReconnectToolPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let timeoutMS: Int
            switch debugBoundedInt(arguments, "timeout_ms", defaultValue: 10000, range: 100 ... 60000) {
            case let .value(value), let .defaulted(value): timeoutMS = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "timeout_ms must be an integer in 100...60000.")
            }
            let pollMS: Int
            switch debugBoundedInt(arguments, "poll_ms", defaultValue: 100, range: 25 ... 1000) {
            case let .value(value), let .defaulted(value): pollMS = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "poll_ms must be an integer in 25...1000.")
            }
            guard let excludeIDs = debugUUIDSet(arguments, "exclude_connection_ids", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "exclude_connection_ids must be a UUID string or array of UUID strings.")
            }
            let payload = await debugWaitForReconnectPayload(
                currentConnectionID: connectionID,
                clientName: debugString(arguments, "client_name"),
                sessionFingerprint: debugString(arguments, "session_fingerprint"),
                excludeConnectionIDs: excludeIDs,
                timeoutMS: timeoutMS,
                pollMS: pollMS,
                requireReady: debugBool(arguments, "require_ready") ?? true
            )
            return debugDiagnosticsResult(payload, isError: (payload["ok"] as? Bool) == false)
        }

        func debugClearRoutingStateToolPayload(op: String, connectionID: UUID, arguments: [String: Value]) -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "clear_routing_state requires allow_destructive=true.")
            }
            let payload = debugClearRoutingStatePayload(
                currentConnectionID: connectionID,
                clientName: debugString(arguments, "client_name"),
                allClients: debugBool(arguments, "all_clients") ?? false
            )
            return debugDiagnosticsResult(payload, isError: (payload["ok"] as? Bool) == false)
        }

        func debugClearPersistedRoutingSessionToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let allowedKeys: Set = [
                "op",
                "allow_destructive",
                "session_fingerprint",
                "expected_last_connection_id"
            ]
            guard Set(arguments.keys).isSubset(of: allowedKeys) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "clear_persisted_routing_session received an unexpected argument.")
            }
            guard case .bool(true)? = arguments["allow_destructive"] else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "clear_persisted_routing_session requires allow_destructive=true.")
            }
            guard let sessionFingerprint = debugString(arguments, "session_fingerprint") else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "session_fingerprint must match ^sha256:[0-9a-f]{16}$ exactly.")
            }
            let fullFingerprintRange = sessionFingerprint.startIndex ..< sessionFingerprint.endIndex
            guard let matchRange = sessionFingerprint.range(of: #"^sha256:[0-9a-f]{16}$"#, options: .regularExpression),
                  matchRange == fullFingerprintRange
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "session_fingerprint must match ^sha256:[0-9a-f]{16}$ exactly.")
            }
            guard let expectedLastConnectionIDString = debugString(arguments, "expected_last_connection_id"),
                  let expectedLastConnectionID = UUID(uuidString: expectedLastConnectionIDString)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "expected_last_connection_id must be a UUID string.")
            }
            let payload = debugClearPersistedRoutingSessionPayload(
                sessionFingerprint: sessionFingerprint,
                expectedLastConnectionID: expectedLastConnectionID
            )
            return debugDiagnosticsResult(payload, isError: (payload["ok"] as? Bool) == false)
        }

        func debugSeedRoutingAffinityToolPayload(op: String, connectionID: UUID, arguments: [String: Value]) async -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "seed_routing_affinity requires allow_destructive=true.")
            }
            let targetID: UUID
            if let rawTarget = debugString(arguments, "connection_id") {
                guard let parsed = UUID(uuidString: rawTarget) else {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string.")
                }
                targetID = parsed
            } else {
                targetID = connectionID
            }
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 1, range: 1 ... 10000) {
            case let .value(value), let .defaulted(value): windowID = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "window_id must be an integer in 1...10000.")
            }
            let payload = await debugSeedRoutingAffinityPayload(connectionID: targetID, windowID: windowID)
            return debugDiagnosticsResult(payload, isError: (payload["ok"] as? Bool) == false)
        }

        func debugShutdownAndRestartToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "shutdown_and_restart requires allow_destructive=true.")
            }
            let mode = debugString(arguments, "mode") ?? "network_manager"
            guard mode == "network_manager" else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "mode must be network_manager.")
            }
            let delayMS: Int
            switch debugBoundedInt(arguments, "delay_ms", defaultValue: 250, range: 100 ... 10000) {
            case let .value(value), let .defaulted(value): delayMS = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "delay_ms must be an integer in 100...10000.")
            }
            let downMS: Int
            switch debugBoundedInt(arguments, "down_ms", defaultValue: 1000, range: 0 ... 60000) {
            case let .value(value), let .defaulted(value): downMS = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "down_ms must be an integer in 0...60000.")
            }
            let restartID: UUID
            if let rawRestartID = debugString(arguments, "restart_id") {
                guard let parsed = UUID(uuidString: rawRestartID) else {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "restart_id must be a UUID string.")
                }
                restartID = parsed
            } else {
                restartID = UUID()
            }
            return debugDiagnosticsResult(debugScheduleShutdownAndRestartPayload(
                restartID: restartID,
                delayMS: delayMS,
                downMS: downMS,
                mode: mode
            ))
        }

        func debugRestartStatusToolPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let restartID = debugOptionalUUID(arguments, "restart_id", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "restart_id must be a UUID string when provided.")
            }
            return debugDiagnosticsResult(debugRestartStatusPayload(restartID: restartID))
        }

        func debugConnectionsPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let includeIdentity = debugBool(arguments, "include_identity") ?? false
            let snapshot = await dashboardSnapshot()
            let activeToolScopes = debugActiveToolScopesForTesting()
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "connections": snapshot.connections.map { entry in
                    [
                        "id": entry.id.uuidString,
                        "client_name": entry.clientName.isEmpty ? NSNull() : entry.clientName,
                        "normalized_client_id": debugNormalizedClientID(for: entry.clientName) ?? NSNull(),
                        "window_id": entry.windowID.map { $0 as Any } ?? NSNull(),
                        "state": entry.state.rawValue,
                        "transport": entry.transport.rawValue,
                        "has_in_flight_calls": entry.hasInFlightCalls,
                        "active_tool_name": entry.activeToolName ?? NSNull(),
                        "active_tool_window_id": entry.activeToolWindowID.map { $0 as Any } ?? NSNull(),
                        "active_tool_scope_count": entry.activeToolScopeCount,
                        "active_tool_scopes": entry.activeToolScopes.map { scope in
                            [
                                "window_id": scope.windowID,
                                "tool_name": scope.toolName,
                                "sequence": scope.sequence
                            ] as [String: Any]
                        },
                        "session_key_present": entry.sessionKey != nil,
                        "session_fingerprint": debugSessionFingerprint(forToken: entry.sessionKey) ?? NSNull()
                    ] as [String: Any]
                },
                "active_tool_scopes": activeToolScopes.map { scope in
                    [
                        "scope_id": scope.scopeID.uuidString,
                        "window_id": scope.windowID,
                        "connection_id": scope.connectionID.uuidString,
                        "tool_name": scope.toolName,
                        "sequence": scope.sequence
                    ] as [String: Any]
                }
            ]
            if includeIdentity {
                payload["identities"] = identityContextSnapshots().map { identity in
                    [
                        "connection_id": identity.connectionID.uuidString,
                        "client_name": identity.clientName ?? NSNull(),
                        "has_handshake": identity.hasHandshake,
                        "source": identity.source.rawValue,
                        "session_key_present": identity.capabilityToken != nil
                    ] as [String: Any]
                }
            }
            return debugDiagnosticsResult(payload)
        }

        func debugSleepPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let milliseconds: Int
            switch debugBoundedInt(arguments, "milliseconds", defaultValue: 0, range: 0 ... 5000) {
            case let .value(value), let .defaulted(value):
                milliseconds = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "milliseconds must be an integer in 0...5000.")
            }
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "slept_milliseconds": milliseconds
            ]
            if let tag = debugString(arguments, "tag") {
                payload["tag"] = tag
            }
            return debugDiagnosticsResult(payload)
        }

        func debugLargeResponsePayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let payload = debugLargeResponseObject(op: op, arguments: arguments) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "bytes must be in 0...33554432 and character must be a single ASCII byte.")
            }
            return debugDiagnosticsResult(payload)
        }

        func debugSleepThenLargeResponsePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let milliseconds: Int
            switch debugBoundedInt(arguments, "milliseconds", defaultValue: 500, range: 0 ... 5000) {
            case let .value(value), let .defaulted(value):
                milliseconds = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "milliseconds must be an integer in 0...5000.")
            }
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            guard let payload = debugLargeResponseObject(op: "large_response", arguments: arguments) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "bytes must be in 0...33554432 and character must be a single ASCII byte.")
            }
            var adjusted = payload
            adjusted["op"] = op
            adjusted["slept_milliseconds"] = milliseconds
            return debugDiagnosticsResult(adjusted)
        }

        func debugForceRemoveConnectionPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "force_remove_connection requires allow_destructive=true.")
            }
            guard let targetString = debugString(arguments, "connection_id"),
                  let targetID = UUID(uuidString: targetString)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string.")
            }
            guard targetID != connectionID else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Refusing to remove the calling connection.")
            }
            let snapshot = await dashboardSnapshot()
            let existed = snapshot.connections.contains { $0.id == targetID }
            if existed {
                await removeConnection(targetID)
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "connection_id": targetID.uuidString,
                "removed": existed
            ])
        }

        func debugSeedActiveToolProbePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "seed_active_tool_probe requires allow_destructive=true.")
            }
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 1, range: 1 ... 10000) {
            case let .value(value), let .defaulted(value):
                windowID = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "window_id must be an integer in 1...10000.")
            }
            guard let targetString = debugString(arguments, "connection_id"),
                  let targetID = UUID(uuidString: targetString)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "connection_id must be a UUID string.")
            }
            let toolName = debugString(arguments, "tool_name") ?? "context_builder"
            guard let marker = debugString(arguments, "marker"), !marker.isEmpty, marker.count <= 128 else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "marker is required and must be <= 128 characters.")
            }

            let slotToken = await MainActor.run { () -> UUID? in
                guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                return window.mcpServer.test_setActiveToolSlot(
                    toolName: toolName,
                    connectionID: targetID,
                    cancel: {
                        Task {
                            await MCPDebugDiagnosticsProbeStore.shared.recordCancel(marker: marker)
                        }
                    }
                )
            }
            guard let slotToken else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "No window found for window_id \(windowID).")
            }
            guard let scopeID = debugBeginActiveToolScopeForTesting(
                windowID: windowID,
                connectionID: targetID,
                toolName: toolName,
                scopeID: slotToken
            ) else {
                await MainActor.run {
                    guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else { return }
                    window.mcpServer.test_clearActiveToolSlot(ifToken: slotToken)
                }
                return debugDiagnosticsError(op: op, code: "internal_error", message: "Unable to allocate an active-tool scope.")
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "window_id": windowID,
                "connection_id": targetID.uuidString,
                "tool_name": toolName,
                "scope_id": scopeID.uuidString,
                "marker": marker
            ])
        }

        func debugActiveToolProbeStatusPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            guard let markers = debugStringArray(arguments, "markers", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "markers must be a string or an array of strings.")
            }
            let records = await MCPDebugDiagnosticsProbeStore.shared.snapshot(markers: markers)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "cancellations": records.map { record in
                    var entry: [String: Any] = [
                        "marker": record.marker,
                        "count": record.count
                    ]
                    if let lastCancelledAt = record.lastCancelledAt {
                        entry["last_cancelled_at"] = lastCancelledAt.timeIntervalSince1970
                    }
                    return entry
                }
            ])
        }

        func debugClearActiveToolProbePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "clear_active_tool_probe requires allow_destructive=true.")
            }
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 1, range: 1 ... 10000) {
            case let .value(value), let .defaulted(value):
                windowID = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "window_id must be an integer in 1...10000.")
            }
            guard let markers = debugStringArray(arguments, "markers", op: op) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "markers must be a string or an array of strings.")
            }
            let scopeID: UUID?
            if let scopeIDString = debugString(arguments, "scope_id") {
                guard let parsedScopeID = UUID(uuidString: scopeIDString) else {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "scope_id must be a UUID string.")
                }
                scopeID = parsedScopeID
            } else {
                scopeID = nil
            }
            let didFindWindow = await MainActor.run { () -> Bool in
                guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else {
                    return false
                }
                if let scopeID {
                    _ = window.mcpServer.test_clearActiveToolSlot(ifToken: scopeID)
                } else {
                    window.mcpServer.test_clearActiveToolSlot()
                }
                return true
            }
            let removedScopeCount: Int
            if let scopeID {
                removedScopeCount = debugEndActiveToolScopeForTesting(
                    windowID: windowID,
                    scopeID: scopeID
                ) ? 1 : 0
            } else {
                let beforeCount = debugActiveToolScopesForTesting().count
                debugClearActiveToolOwner(windowID: windowID)
                removedScopeCount = beforeCount - debugActiveToolScopesForTesting().count
            }
            await MCPDebugDiagnosticsProbeStore.shared.clear(markers: markers)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "window_id": windowID,
                "window_found": didFindWindow,
                "removed_scope_count": removedScopeCount
            ])
        }

        func debugBootstrapDiagnosticsPayload(op: String) async -> CallTool.Result {
            let snapshot = await dashboardSnapshot()
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "socket_path": MCPFilesystemConstants.bootstrapSocketURL().path,
                "manager_running": snapshot.isRunning,
                "manager_enabled": NSNull(),
                "listener": NSNull()
            ])
        }

        private func debugLargeResponseObject(op: String, arguments: [String: Value]) -> [String: Any]? {
            let bytes: Int
            switch debugBoundedInt(arguments, "bytes", defaultValue: 1_048_576, range: 0 ... 33_554_432) {
            case let .value(value), let .defaulted(value):
                bytes = value
            case .invalid:
                return nil
            }
            let character = debugString(arguments, "character") ?? "A"
            guard character.utf8.count == 1 else { return nil }
            return [
                "ok": true,
                "op": op,
                "bytes": bytes,
                "payload": String(repeating: character, count: bytes)
            ]
        }
    }
#endif
