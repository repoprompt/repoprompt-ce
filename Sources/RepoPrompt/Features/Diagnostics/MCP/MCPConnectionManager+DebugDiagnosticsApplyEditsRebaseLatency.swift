// MARK: - DEBUG MCP Apply-Edits Stable-Rebase Diagnostics

import CryptoKit
import Foundation
import MCP
import RepoPromptShared

#if DEBUG
    final class MCPApplyEditsRebaseProbeState: @unchecked Sendable {
        struct Event: Equatable {
            let offsetMS: Double
            let category: String
            let valueMS: Double?

            func payload() -> [String: Any] {
                [
                    "offset_ms": ServerNetworkManager.debugRoundedMS(offsetMS),
                    "category": category,
                    "value_ms": valueMS.map(ServerNetworkManager.debugRoundedMS) ?? NSNull()
                ]
            }
        }

        struct Snapshot {
            let requestIdentity: MCPRequestTimelineIdentity?
            let counters: [String: UInt64]
            let events: [Event]
            let eventOverflowCount: UInt64
        }

        let probeID: UUID
        let createdAt: Date
        let startedUptimeMS: Double
        let expiryMilliseconds: Int
        let deadlineMilliseconds: Int
        let windowID: Int
        let serverIdentity: ObjectIdentifier
        let target: MCPServerViewModel.DebugReadFileAutoSelectionTarget
        let rootScope: WorkspaceLookupRootScope
        let rootID: UUID
        let rootLifetimeID: UUID
        let rootToken: UUID
        let fileID: UUID
        let physicalPath: String
        let relativePath: String
        let selectionPathCandidates: [String]
        let expectedFileSHA256: String
        let expectedByteCount: Int
        let expectedLineCount: Int
        let expectedRanges: [LineRange]
        let expectsSyntheticModification: Bool
        let baselineStore: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot
        let baselineProjection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot
        let baselineSelection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot

        private let lock = NSLock()
        private var requestIdentity: MCPRequestTimelineIdentity?
        private var rebasePathAliases: Set<String>
        private var counters: [String: UInt64] = [:]
        private var events: [Event] = []
        private var eventOverflowCount: UInt64 = 0
        private static let eventLimit = 64

        init(
            probeID: UUID,
            createdAt: Date,
            expiryMilliseconds: Int,
            deadlineMilliseconds: Int,
            windowID: Int,
            serverIdentity: ObjectIdentifier,
            target: MCPServerViewModel.DebugReadFileAutoSelectionTarget,
            rootScope: WorkspaceLookupRootScope,
            rootID: UUID,
            rootLifetimeID: UUID,
            rootToken: UUID,
            fileID: UUID,
            physicalPath: String,
            relativePath: String,
            selectionPathCandidates: [String],
            expectedFileSHA256: String,
            expectedByteCount: Int,
            expectedLineCount: Int,
            expectedRanges: [LineRange],
            expectsSyntheticModification: Bool,
            baselineStore: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot,
            baselineProjection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot,
            baselineSelection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot
        ) {
            self.probeID = probeID
            self.createdAt = createdAt
            startedUptimeMS = ProcessInfo.processInfo.systemUptime * 1000
            self.expiryMilliseconds = expiryMilliseconds
            self.deadlineMilliseconds = deadlineMilliseconds
            self.windowID = windowID
            self.serverIdentity = serverIdentity
            self.target = target
            self.rootScope = rootScope
            self.rootID = rootID
            self.rootLifetimeID = rootLifetimeID
            self.rootToken = rootToken
            self.fileID = fileID
            self.physicalPath = StandardizedPath.absolute(physicalPath)
            self.relativePath = StandardizedPath.relative(relativePath)
            var seenSelectionPaths: Set<String> = []
            self.selectionPathCandidates = selectionPathCandidates.compactMap { rawPath in
                guard let path = StoredSelectionPathNormalization.standardizedPath(rawPath),
                      seenSelectionPaths.insert(path).inserted
                else { return nil }
                return path
            }
            self.expectedFileSHA256 = expectedFileSHA256
            self.expectedByteCount = expectedByteCount
            self.expectedLineCount = expectedLineCount
            self.expectedRanges = expectedRanges
            self.expectsSyntheticModification = expectsSyntheticModification
            rebasePathAliases = [self.physicalPath]
            self.baselineStore = baselineStore
            self.baselineProjection = baselineProjection
            self.baselineSelection = baselineSelection
        }

        func bindRequestIdentity(_ identity: MCPRequestTimelineIdentity?) {
            guard let identity else { return }
            lock.lock()
            if requestIdentity == nil {
                requestIdentity = identity
                appendEventLocked(category: "request_bound", valueMS: nil)
            }
            lock.unlock()
        }

        func increment(_ counter: String, event: String? = nil, valueMS: Double? = nil, by amount: UInt64 = 1) {
            lock.lock()
            counters[counter, default: 0] &+= amount
            if let event {
                appendEventLocked(category: event, valueMS: valueMS)
            }
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                requestIdentity: requestIdentity,
                counters: counters,
                events: events,
                eventOverflowCount: eventOverflowCount
            )
        }

        func matchesRequestIdentity(_ identity: MCPRequestTimelineIdentity?) -> Bool {
            guard let identity else { return false }
            lock.lock()
            defer { lock.unlock() }
            return requestIdentity == identity
        }

        func bindRebasePathAlias(_ fullPath: String) {
            lock.lock()
            rebasePathAliases.insert(StandardizedPath.absolute(fullPath))
            lock.unlock()
        }

        func matchesRebasePath(_ fullPath: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return rebasePathAliases.contains(StandardizedPath.absolute(fullPath))
        }

        func minimumStableEvidenceFailure(
            snapshot: Snapshot,
            store: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot,
            projection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot
        ) -> String? {
            guard snapshot.requestIdentity?.appInvocationID != nil else { return "missing_request_identity" }
            if expectsSyntheticModification {
                for counter in [
                    "service_publications_syntheticMutation",
                    "publisher_ingress_modifications_syntheticMutation"
                ] where snapshot.counters[counter, default: 0] < 1 {
                    return "missing_\(counter)"
                }
            } else {
                for counter in [
                    "service_publications_syntheticMutation",
                    "publisher_ingress_modifications_syntheticMutation"
                ] where snapshot.counters[counter, default: 0] != 0 {
                    return "unexpected_\(counter)"
                }
                for counter in [
                    "service_publications_watcher",
                    "publisher_ingress_modifications_watcher"
                ] where snapshot.counters[counter, default: 0] < 1 {
                    return "missing_\(counter)"
                }
            }
            let commonRequirements: [(String, UInt64)] = [
                ("apply_edits_invocations", 1),
                ("apply_edits_outcomes", 1),
                ("apply_edits_applied", 1),
                ("store_modification_publications", 1),
                ("applied_index_modification_events", 2),
                ("projection_modification_events", 2),
                ("rebase_registrations", 2),
                ("rebase_replacements", 1),
                ("rebase_executions", 1),
                ("rebase_successful_completions", 1)
            ]
            for (counter, minimum) in commonRequirements where snapshot.counters[counter, default: 0] < minimum {
                return "missing_\(counter)"
            }
            guard store.producedAppliedIndexGeneration > baselineStore.producedAppliedIndexGeneration else {
                return "store_generation_not_advanced"
            }
            guard projection.handledGeneration > baselineProjection.handledGeneration else {
                return "projection_generation_not_advanced"
            }
            guard projection.registrationGeneration >= (baselineProjection.registrationGeneration &+ 2) else {
                return "rebase_registration_generation_not_advanced_twice"
            }
            return nil
        }

        private func appendEventLocked(category: String, valueMS: Double?) {
            guard events.count < Self.eventLimit else {
                eventOverflowCount &+= 1
                counters["event_overflow", default: 0] &+= 1
                return
            }
            events.append(Event(
                offsetMS: max(0, ProcessInfo.processInfo.systemUptime * 1000 - startedUptimeMS),
                category: Self.sanitizedCategory(category),
                valueMS: valueMS
            ))
        }

        private static func sanitizedCategory(_ raw: String) -> String {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
            let normalized = raw.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
            return String(normalized.prefix(48))
        }
    }

    enum MCPApplyEditsRebaseProbeRecorder {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var statesByProbeID: [UUID: MCPApplyEditsRebaseProbeState] = [:]

        static func register(_ state: MCPApplyEditsRebaseProbeState) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard statesByProbeID[state.probeID] == nil else { return false }
            statesByProbeID[state.probeID] = state
            return true
        }

        @discardableResult
        static func unregister(_ probeID: UUID) -> MCPApplyEditsRebaseProbeState? {
            lock.lock()
            defer { lock.unlock() }
            return statesByProbeID.removeValue(forKey: probeID)
        }

        static func resetForTesting() {
            lock.lock()
            statesByProbeID.removeAll()
            lock.unlock()
        }

        static func activeCountForTesting() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return statesByProbeID.count
        }

        static func latestApplyEditsRequestIdentity(
            connectionID: UUID?,
            events: [MCPResponseDeliveryTraceEvent] = MCPResponseDeliveryTracer.debugEventSnapshot()
        ) -> MCPRequestTimelineIdentity? {
            let applyEditsEvents = events.reversed().filter {
                $0.tool == "apply_edits" && $0.phase == "sdk_decode_completed"
            }
            return applyEditsEvents.first {
                connectionID != nil && $0.requestIdentity?.connectionID == connectionID?.uuidString
            }?.requestIdentity ?? applyEditsEvents.first?.requestIdentity
        }

        static func recordApplyEditsInvocation(
            connectionID: UUID?,
            workspaceID: UUID?,
            tabID: UUID,
            physicalPath: String,
            requestIdentity: MCPRequestTimelineIdentity?
        ) {
            let standardizedPath = StandardizedPath.absolute(physicalPath)
            let pathCandidates = matchingStates { $0.physicalPath == standardizedPath }
            let workspaceCandidates = pathCandidates.filter { $0.target.workspaceID == workspaceID }
            let scopedCandidates = workspaceCandidates.isEmpty && pathCandidates.count == 1
                ? pathCandidates
                : workspaceCandidates
            let exactTabCandidates = scopedCandidates.filter { $0.target.tabID == tabID }
            let routeCandidates = exactTabCandidates.isEmpty && scopedCandidates.count == 1
                ? scopedCandidates
                : exactTabCandidates
            for state in routeCandidates {
                state.bindRequestIdentity(requestIdentity)
                state.increment("apply_edits_invocations", event: "apply_edits_invocation")
                if state.target.connectionID != connectionID {
                    state.increment("apply_edits_child_connection_routes", event: "apply_edits_child_connection")
                }
                if state.target.workspaceID != workspaceID {
                    state.increment("apply_edits_source_workspace_routes", event: "apply_edits_source_workspace")
                }
                if state.target.tabID != tabID {
                    state.increment("apply_edits_source_tab_routes", event: "apply_edits_source_tab")
                }
            }
        }

        static func recordApplyEditsOutcome(
            connectionID: UUID?,
            workspaceID: UUID?,
            tabID: UUID,
            physicalPath: String,
            requestIdentity: MCPRequestTimelineIdentity?,
            editsApplied: Int,
            outcome: String
        ) {
            let standardizedPath = StandardizedPath.absolute(physicalPath)
            let pathCandidates = matchingStates { state in
                state.physicalPath == standardizedPath
                    && state.matchesRequestIdentity(requestIdentity)
            }
            let workspaceCandidates = pathCandidates.filter { $0.target.workspaceID == workspaceID }
            let scopedCandidates = workspaceCandidates.isEmpty && pathCandidates.count == 1
                ? pathCandidates
                : workspaceCandidates
            let exactTabCandidates = scopedCandidates.filter { $0.target.tabID == tabID }
            let routeCandidates = exactTabCandidates.isEmpty && scopedCandidates.count == 1
                ? scopedCandidates
                : exactTabCandidates
            for state in routeCandidates {
                state.increment("apply_edits_outcomes", event: "apply_edits_\(outcome)")
                if editsApplied > 0 {
                    state.increment("apply_edits_applied", by: UInt64(editsApplied))
                }
            }
        }

        static func recordServicePublication(
            rootToken: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            matchingStates { $0.rootToken == rootToken }.forEach { state in
                state.increment("service_root_publications_total")
                state.increment("service_root_publications_\(source.rawValue)")
                let matchingModifications = deltas.reduce(into: 0) { count, delta in
                    if case let .fileModified(path, _) = delta,
                       StandardizedPath.relative(path) == state.relativePath
                    {
                        count += 1
                    }
                }
                if matchingModifications > 0 {
                    state.increment("service_publications_total")
                    state.increment(
                        "service_publications_\(source.rawValue)",
                        event: "service_\(source.rawValue)",
                        by: UInt64(matchingModifications)
                    )
                }
            }
        }

        static func recordStoreModification(rootID: UUID, fileID: UUID, generation: UInt64) {
            matchingStates { $0.rootID == rootID && $0.fileID == fileID }.forEach { state in
                state.increment("store_modification_publications", event: "store_modification")
                state.increment("store_last_generation", by: generation)
            }
        }

        static func recordPublisherIngress(
            rootID: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            matchingStates { $0.rootID == rootID }.forEach { state in
                let matching = deltas.reduce(into: 0) { count, delta in
                    if case let .fileModified(path, _) = delta,
                       StandardizedPath.relative(path) == state.relativePath
                    {
                        count += 1
                    }
                }
                guard matching > 0 else { return }
                state.increment(
                    "publisher_ingress_modifications_\(source.rawValue)",
                    event: "ingress_\(source.rawValue)",
                    by: UInt64(matching)
                )
            }
        }

        static func recordAppliedIndexModification(rootID: UUID, fileIDs: [UUID], generation: UInt64) {
            matchingStates { $0.rootID == rootID && fileIDs.contains($0.fileID) }.forEach { state in
                state.increment("applied_index_modification_events", event: "applied_index_modification")
                state.increment("applied_index_generation_sum", by: generation)
            }
        }

        static func recordProjectionModification(rootID: UUID, fileIDs: [UUID], generation: UInt64) {
            matchingStates { $0.rootID == rootID && fileIDs.contains($0.fileID) }.forEach { state in
                state.increment("projection_modification_events", event: "projection_modification")
                state.increment("projection_generation_sum", by: generation)
            }
        }

        static func recordRebaseScheduleDecision(
            fileID: UUID,
            fullPath: String,
            relativePath: String,
            shouldSchedule: Bool
        ) {
            let standardizedRelativePath = StandardizedPath.relative(relativePath)
            matchingStates {
                $0.fileID == fileID || $0.relativePath == standardizedRelativePath
            }.forEach { state in
                state.bindRebasePathAlias(fullPath)
                if state.fileID != fileID {
                    state.increment("rebase_projection_file_id_aliases", event: "rebase_file_id_alias")
                }
                state.increment("rebase_schedule_attempts", event: "rebase_schedule_attempt")
                if !shouldSchedule {
                    state.increment("rebase_schedule_skips", event: "rebase_schedule_skip")
                }
            }
        }

        static func recordRebaseRegistration(fullPath: String, replaced: Bool, generation: UInt64) {
            for state in matchingPathStates(fullPath) {
                state.increment("rebase_registrations", event: "rebase_registered")
                state.increment("rebase_registration_generation_sum", by: generation)
                if replaced {
                    state.increment("rebase_replacements", event: "rebase_replaced")
                }
            }
        }

        static func recordRebaseTaskStart(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("rebase_task_starts", event: "rebase_task_started") }
        }

        static func recordRebaseExecution(fullPath: String, generation: UInt64) {
            for state in matchingPathStates(fullPath) {
                state.increment("rebase_executions", event: "rebase_execution")
                state.increment("rebase_execution_generation_sum", by: generation)
            }
        }

        static func recordRebaseCompletion(fullPath: String, cancelled: Bool) {
            for state in matchingPathStates(fullPath) {
                state.increment("rebase_completions", event: cancelled ? "rebase_cancelled" : "rebase_completed")
                if cancelled {
                    state.increment("rebase_cancellations")
                } else {
                    state.increment("rebase_successful_completions")
                }
            }
        }

        static func recordRebaseStaleExit(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("rebase_stale_exits", event: "rebase_stale") }
        }

        static func recordFullFileRead(fullPath: String, durationMS: Double) {
            for matchingPathState in matchingPathStates(fullPath) {
                matchingPathState.increment("full_file_reads", event: "full_file_read", valueMS: durationMS)
            }
        }

        static func recordEngineCall(fullPath: String, durationMS: Double, scope: String) {
            for matchingPathState in matchingPathStates(fullPath) {
                matchingPathState.increment("rebase_engine_calls", event: "engine_\(scope)", valueMS: durationMS)
            }
        }

        static func recordPartitionInspection(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("partition_scopes_inspected") }
        }

        static func recordPartitionWrite(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("partition_scopes_written", event: "partition_write") }
        }

        static func recordTabInspection(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("compose_tabs_inspected") }
        }

        static func recordTabWrite(fullPath: String) {
            matchingPathStates(fullPath).forEach { $0.increment("compose_tabs_written", event: "tab_write") }
        }

        static func recordCodemapRequest(rootID: UUID, fileID: UUID) {
            matchingStates { $0.rootID == rootID && $0.fileID == fileID }.forEach {
                $0.increment("codemap_requests", event: "codemap_request")
            }
        }

        private static func matchingPathStates(_ fullPath: String) -> [MCPApplyEditsRebaseProbeState] {
            matchingStates { $0.matchesRebasePath(fullPath) }
        }

        private static func matchingStates(
            _ predicate: (MCPApplyEditsRebaseProbeState) -> Bool
        ) -> [MCPApplyEditsRebaseProbeState] {
            lock.lock()
            let states = statesByProbeID.values.filter(predicate)
            lock.unlock()
            return states
        }
    }

    actor MCPApplyEditsRebaseProbeRegistry {
        struct Reservation {
            fileprivate let probeID: UUID
            fileprivate let token: UUID
        }

        struct Entry: @unchecked Sendable {
            let probeID: UUID
            let createdAt: Date
            let expiryMilliseconds: Int
            let serverIdentity: ObjectIdentifier
            let contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
            let state: MCPApplyEditsRebaseProbeState
        }

        static let shared = MCPApplyEditsRebaseProbeRegistry()
        private static let capacity = 16
        private var reservations: [UUID: UUID] = [:]
        private var entries: [UUID: Entry] = [:]
        private var expiryTasks: [UUID: Task<Void, Never>] = [:]

        func reserve(probeID: UUID, createdAt: Date = Date()) async -> Reservation? {
            await pruneExpired(now: createdAt)
            guard entries[probeID] == nil,
                  reservations[probeID] == nil,
                  entries.count + reservations.count < Self.capacity
            else { return nil }
            let reservation = Reservation(probeID: probeID, token: UUID())
            reservations[probeID] = reservation.token
            return reservation
        }

        func commit(_ reservation: Reservation, entry: Entry) -> Bool {
            guard entry.probeID == reservation.probeID,
                  reservations[reservation.probeID] == reservation.token,
                  MCPApplyEditsRebaseProbeRecorder.register(entry.state)
            else { return false }
            reservations.removeValue(forKey: reservation.probeID)
            entries[entry.probeID] = entry
            expiryTasks[entry.probeID] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(entry.expiryMilliseconds))
                guard !Task.isCancelled else { return }
                await self?.expire(entry.probeID)
            }
            return true
        }

        func release(_ reservation: Reservation) {
            guard reservations[reservation.probeID] == reservation.token else { return }
            reservations.removeValue(forKey: reservation.probeID)
        }

        func insert(_ entry: Entry) async -> Bool {
            guard let reservation = await reserve(probeID: entry.probeID, createdAt: entry.createdAt) else { return false }
            return commit(reservation, entry: entry)
        }

        func take(_ probeID: UUID) async -> Entry? {
            await pruneExpired(now: Date())
            expiryTasks.removeValue(forKey: probeID)?.cancel()
            return entries.removeValue(forKey: probeID)
        }

        func cancel(_ probeID: UUID) async -> Entry? {
            guard let entry = await take(probeID) else { return nil }
            entry.state.increment("probe_cancellations", event: "probe_cancelled")
            MCPApplyEditsRebaseProbeRecorder.unregister(probeID)
            return entry
        }

        func cancel(serverIdentity: ObjectIdentifier, contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey) async {
            let probeIDs = entries.values.compactMap { entry in
                entry.serverIdentity == serverIdentity && entry.contextKey == contextKey ? entry.probeID : nil
            }
            for probeID in probeIDs {
                _ = await cancel(probeID)
            }
        }

        func expireForTesting(_ probeID: UUID) async {
            await expire(probeID)
        }

        func containsForTesting(_ probeID: UUID) -> Bool {
            entries[probeID] != nil
        }

        func entryCountForTesting() -> Int {
            entries.count
        }

        func resetForTesting() async {
            let probeIDs = Array(entries.keys)
            entries.removeAll()
            reservations.removeAll()
            for task in expiryTasks.values {
                task.cancel()
            }
            expiryTasks.removeAll()
            for probeID in probeIDs {
                MCPApplyEditsRebaseProbeRecorder.unregister(probeID)
            }
        }

        private func expire(_ probeID: UUID) async {
            expiryTasks.removeValue(forKey: probeID)?.cancel()
            guard let entry = entries.removeValue(forKey: probeID) else { return }
            entry.state.increment("probe_expirations", event: "probe_expired")
            MCPApplyEditsRebaseProbeRecorder.unregister(probeID)
        }

        private func pruneExpired(now: Date) async {
            let expired = entries.values.filter {
                now.timeIntervalSince($0.createdAt) * 1000 >= Double($0.expiryMilliseconds)
            }
            for entry in expired {
                await expire(entry.probeID)
            }
        }
    }

    extension ServerNetworkManager {
        func debugMCPApplyEditsRebaseProbeBeginPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let path = debugString(arguments, "path")?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  let expectedSHA = debugString(arguments, "expected_file_sha256")?.lowercased(),
                  expectedSHA.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`path` and a 64-character lowercase `expected_file_sha256` are required.")
            }
            let windowID: Int
            let expectedByteCount: Int
            let expectedLineCount: Int
            let expiryMilliseconds: Int
            let deadlineMilliseconds: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
            case let .value(value): windowID = value
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` is required and must be positive.")
            }
            switch debugBoundedInt(arguments, "expected_byte_count", defaultValue: -1, range: 0 ... Int.max) {
            case let .value(value): expectedByteCount = value
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`expected_byte_count` is required and must be non-negative.")
            }
            switch debugBoundedInt(arguments, "expected_line_count", defaultValue: -1, range: 0 ... Int.max) {
            case let .value(value): expectedLineCount = value
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`expected_line_count` is required and must be non-negative.")
            }
            switch debugBoundedInt(arguments, "expiry_ms", defaultValue: 30 * 60 * 1000, range: 100 ... 30 * 60 * 1000) {
            case let .value(value), let .defaulted(value): expiryMilliseconds = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`expiry_ms` must be between 100 and 1800000.")
            }
            switch debugBoundedInt(arguments, "deadline_ms", defaultValue: 5000, range: 100 ... 30000) {
            case let .value(value), let .defaulted(value): deadlineMilliseconds = value
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`deadline_ms` must be between 100 and 30000.")
            }
            guard let expectedRanges = Self.debugApplyEditsProbeRanges(arguments["expected_slices"]) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`expected_slices` must be an array of integer start/end range objects.")
            }
            let expectsSyntheticModification = debugBool(arguments, "expect_synthetic_modification") ?? true
            guard let targetConnectionID = debugOptionalUUID(arguments, "target_connection_id", op: op),
                  let agentSessionID = debugOptionalUUID(arguments, "agent_session_id", op: op),
                  let tabID = debugOptionalUUID(arguments, "tab_id", op: op),
                  let expectedRunID = debugOptionalUUID(arguments, "expected_run_id", op: op)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Connection, session, tab, and run identifiers must be UUID strings when provided.")
            }
            let usesConnectionTarget = targetConnectionID != nil
            let usesSessionTarget = agentSessionID != nil || tabID != nil
            guard usesConnectionTarget != usesSessionTarget,
                  usesConnectionTarget || (agentSessionID != nil && tabID != nil)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Provide either `target_connection_id`, or both `agent_session_id` and `tab_id`.")
            }

            let resolved = await MainActor.run { () -> (WindowState, ObjectIdentifier, [MCPServerViewModel.DebugReadFileAutoSelectionTarget])? in
                guard let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else { return nil }
                return (
                    window,
                    ObjectIdentifier(window.mcpServer),
                    window.mcpServer.debugResolveReadFileAutoSelectionTargets(
                        targetConnectionID: targetConnectionID,
                        agentSessionID: agentSessionID,
                        tabID: tabID,
                        expectedRunID: expectedRunID
                    )
                )
            }
            guard let resolved else {
                return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched the requested window.")
            }
            guard resolved.2.count == 1, let target = resolved.2.first else {
                return debugDiagnosticsError(
                    op: op,
                    code: resolved.2.isEmpty ? "no_target" : "ambiguous_target",
                    message: resolved.2.isEmpty ? "No current bound Agent route matched." : "Multiple current bound Agent routes matched."
                )
            }
            guard let lookupContext = await resolved.0.mcpServer.debugApplyEditsRebaseProbeLookupContext(for: target) else {
                return debugDiagnosticsError(op: op, code: "missing_lookup_context", message: "The resolved Agent route no longer has a current file lookup context.")
            }
            let physicalPath = StandardizedPath.absolute(lookupContext.translateInputPath(path))
            let logicalPath = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: physicalPath,
                display: .full
            )
            guard let storeSnapshot = await resolved.0.workspaceFileContextStore.debugApplyEditsRebaseProbePathSnapshot(
                fullPath: physicalPath,
                rootScope: lookupContext.rootScope
            ) else {
                return debugDiagnosticsError(op: op, code: "path_not_found", message: "The path did not resolve to one exact file in the Agent route's loaded root scope.")
            }
            let projectionSnapshot = await MainActor.run {
                resolved.0.workspaceFilesViewModel.debugApplyEditsRebaseProbePathSnapshot(
                    fullPath: physicalPath,
                    rootID: storeSnapshot.rootID
                )
            }
            let selectionPathCandidates = [physicalPath, logicalPath, path, storeSnapshot.relativePath].compactMap(\.self)
            let selectionSnapshot = await MainActor.run {
                resolved.0.workspaceManager.debugApplyEditsRebaseProbeSelectionSnapshot(
                    workspaceID: target.workspaceID,
                    tabID: target.tabID,
                    candidatePaths: selectionPathCandidates
                )
            }
            guard let selectionSnapshot else {
                return debugDiagnosticsError(op: op, code: "missing_tab", message: "The canonical workspace tab is no longer available.")
            }

            let probeID = UUID()
            let createdAt = Date()
            guard let reservation = await MCPApplyEditsRebaseProbeRegistry.shared.reserve(probeID: probeID, createdAt: createdAt) else {
                return debugDiagnosticsError(op: op, code: "probe_capacity", message: "The DEBUG apply-edits rebase probe registry is at capacity 16.")
            }
            let state = MCPApplyEditsRebaseProbeState(
                probeID: probeID,
                createdAt: createdAt,
                expiryMilliseconds: expiryMilliseconds,
                deadlineMilliseconds: deadlineMilliseconds,
                windowID: windowID,
                serverIdentity: resolved.1,
                target: target,
                rootScope: lookupContext.rootScope,
                rootID: storeSnapshot.rootID,
                rootLifetimeID: storeSnapshot.rootLifetimeID,
                rootToken: storeSnapshot.rootToken,
                fileID: storeSnapshot.fileID,
                physicalPath: storeSnapshot.fullPath,
                relativePath: storeSnapshot.relativePath,
                selectionPathCandidates: selectionPathCandidates,
                expectedFileSHA256: expectedSHA,
                expectedByteCount: expectedByteCount,
                expectedLineCount: expectedLineCount,
                expectedRanges: expectedRanges,
                expectsSyntheticModification: expectsSyntheticModification,
                baselineStore: storeSnapshot,
                baselineProjection: projectionSnapshot,
                baselineSelection: selectionSnapshot
            )
            let entry = MCPApplyEditsRebaseProbeRegistry.Entry(
                probeID: probeID,
                createdAt: createdAt,
                expiryMilliseconds: expiryMilliseconds,
                serverIdentity: resolved.1,
                contextKey: target.contextKey,
                state: state
            )
            guard await MCPApplyEditsRebaseProbeRegistry.shared.commit(reservation, entry: entry) else {
                await MCPApplyEditsRebaseProbeRegistry.shared.release(reservation)
                return debugDiagnosticsError(op: op, code: "probe_admission_failed", message: "The DEBUG probe reservation could not be committed.")
            }

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "probe_id": probeID.uuidString,
                "expiry_ms": expiryMilliseconds,
                "deadline_ms": deadlineMilliseconds,
                "expect_synthetic_modification": expectsSyntheticModification,
                "identity": Self.debugApplyEditsProbeIdentityPayload(state),
                "baseline": Self.debugApplyEditsProbeSnapshotPayload(
                    store: storeSnapshot,
                    projection: projectionSnapshot,
                    selection: selectionSnapshot
                )
            ])
        }

        func debugMCPApplyEditsRebaseProbeDrainPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let rawProbeID = debugString(arguments, "probe_id"), let probeID = UUID(uuidString: rawProbeID) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`probe_id` is required and must be a UUID string.")
            }
            guard let entry = await MCPApplyEditsRebaseProbeRegistry.shared.take(probeID) else {
                return debugDiagnosticsError(op: op, code: "unknown_probe", message: "The probe was not found, expired, or already consumed.")
            }
            defer { MCPApplyEditsRebaseProbeRecorder.unregister(probeID) }
            let state = entry.state
            let deadline = ContinuousClock().now.advanced(by: .milliseconds(state.deadlineMilliseconds))
            var lastFailure = "deadline"
            var finalStore: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot?
            var finalProjection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot?
            var finalSelection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot?
            var finalFence: WorkspaceSliceRebaseFence?
            var finalContent: String?

            while ContinuousClock().now < deadline {
                guard let window = await MainActor.run(body: {
                    WindowStatesManager.shared.allWindows.first(where: {
                        $0.windowID == state.windowID && ObjectIdentifier($0.mcpServer) == state.serverIdentity
                    })
                }) else {
                    state.increment("probe_stale_failures", event: "stale_window")
                    lastFailure = "stale_window"
                    break
                }
                let routeIsCurrent = await MainActor.run {
                    let matches = window.mcpServer.debugResolveReadFileAutoSelectionTargets(
                        targetConnectionID: nil,
                        agentSessionID: state.target.agentSessionID,
                        tabID: state.target.tabID,
                        expectedRunID: state.target.runID
                    )
                    guard matches.count == 1, let current = matches.first else { return false }
                    return current.connectionID == state.target.connectionID
                        && current.runID == state.target.runID
                        && current.agentSessionID == state.target.agentSessionID
                        && current.workspaceID == state.target.workspaceID
                        && current.tabID == state.target.tabID
                }
                guard routeIsCurrent else {
                    state.increment("probe_stale_failures", event: "stale_route")
                    lastFailure = "stale_route"
                    break
                }

                _ = await window.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                    userPath: state.physicalPath,
                    fallbackScope: state.rootScope
                )
                guard let storeTarget = await window.workspaceFileContextStore.debugApplyEditsRebaseProbePathSnapshot(
                    fullPath: state.physicalPath,
                    rootScope: state.rootScope
                ), storeTarget.rootLifetimeID == state.rootLifetimeID, storeTarget.fileID == state.fileID else {
                    state.increment("probe_stale_failures", event: "stale_root")
                    lastFailure = "stale_root"
                    break
                }
                let handled = await window.workspaceFilesViewModel.debugWaitForAppliedIndexGeneration(
                    rootID: state.rootID,
                    targetGeneration: storeTarget.producedAppliedIndexGeneration,
                    deadline: deadline
                )
                guard handled else {
                    lastFailure = "projection_timeout"
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                let fence = await window.workspaceFilesViewModel.waitForPendingSliceRebasesAndCaptureFence(
                    affectingCandidatePaths: [state.physicalPath]
                )
                let projection = await MainActor.run {
                    window.workspaceFilesViewModel.debugApplyEditsRebaseProbePathSnapshot(
                        fullPath: state.physicalPath,
                        rootID: state.rootID
                    )
                }
                let selection = await MainActor.run {
                    window.workspaceManager.debugApplyEditsRebaseProbeSelectionSnapshot(
                        workspaceID: state.target.workspaceID,
                        tabID: state.target.tabID,
                        candidatePaths: state.selectionPathCandidates
                    )
                }
                let content = try? await window.workspaceFileContextStore.readContent(
                    rootID: state.rootID,
                    relativePath: state.relativePath
                )
                let currentStore = await window.workspaceFileContextStore.debugApplyEditsRebaseProbePathSnapshot(
                    fullPath: state.physicalPath,
                    rootScope: state.rootScope
                )
                let fenceCurrent = await MainActor.run {
                    window.workspaceFilesViewModel.isSliceRebaseFenceCurrent(fence)
                }

                finalStore = currentStore
                finalProjection = projection
                finalSelection = selection
                finalFence = fence
                finalContent = content ?? nil

                guard let currentStore, let selection, let content else {
                    lastFailure = "missing_final_state"
                    continue
                }
                let data = Data(content.utf8)
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let lineCount = Self.debugApplyEditsProbeLineCount(content)
                let snapshot = state.snapshot()
                let evidenceFailure = state.minimumStableEvidenceFailure(
                    snapshot: snapshot,
                    store: currentStore,
                    projection: projection
                )
                let stable = evidenceFailure == nil
                    && currentStore.rootLifetimeID == state.rootLifetimeID
                    && currentStore.fileID == state.fileID
                    && currentStore.producedAppliedIndexGeneration == storeTarget.producedAppliedIndexGeneration
                    && projection.handledGeneration >= currentStore.producedAppliedIndexGeneration
                    && !projection.hasPendingRebaseTask
                    && fenceCurrent
                    && selection.selectionRevision >= state.baselineSelection.selectionRevision
                    && selection.ranges == state.expectedRanges
                    && data.count == state.expectedByteCount
                    && lineCount == state.expectedLineCount
                    && sha == state.expectedFileSHA256
                if stable {
                    let stableUptimeMS = ProcessInfo.processInfo.systemUptime * 1000
                    let responseEvent = Self.debugApplyEditsProbeResponseEvent(
                        for: snapshot.requestIdentity,
                        events: MCPResponseDeliveryTracer.debugEventSnapshot()
                    )
                    return debugDiagnosticsResult(Self.debugApplyEditsProbeDrainPayload(
                        op: op,
                        state: state,
                        snapshot: snapshot,
                        store: currentStore,
                        projection: projection,
                        selection: selection,
                        fence: fence,
                        content: content,
                        stableUptimeMS: stableUptimeMS,
                        responseEvent: responseEvent,
                        result: "stable",
                        failure: nil
                    ))
                }
                lastFailure = evidenceFailure ?? "stability_mismatch"
                try? await Task.sleep(for: .milliseconds(10))
            }

            state.increment("probe_timeouts", event: "probe_timeout")
            let snapshot = state.snapshot()
            return debugDiagnosticsResult(Self.debugApplyEditsProbeDrainPayload(
                op: op,
                state: state,
                snapshot: snapshot,
                store: finalStore ?? state.baselineStore,
                projection: finalProjection ?? state.baselineProjection,
                selection: finalSelection ?? state.baselineSelection,
                fence: finalFence,
                content: finalContent,
                stableUptimeMS: ProcessInfo.processInfo.systemUptime * 1000,
                responseEvent: nil,
                result: "timeout",
                failure: lastFailure
            ))
        }

        func debugMCPApplyEditsRebaseProbeCancelPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let rawProbeID = debugString(arguments, "probe_id"), let probeID = UUID(uuidString: rawProbeID) else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`probe_id` is required and must be a UUID string.")
            }
            guard await MCPApplyEditsRebaseProbeRegistry.shared.cancel(probeID) != nil else {
                return debugDiagnosticsError(op: op, code: "unknown_probe", message: "The probe was not found, expired, or already consumed.")
            }
            return debugDiagnosticsResult(["ok": true, "op": op, "probe_id": probeID.uuidString, "result": "cancelled"])
        }

        private static func debugApplyEditsProbeDrainPayload(
            op: String,
            state: MCPApplyEditsRebaseProbeState,
            snapshot: MCPApplyEditsRebaseProbeState.Snapshot,
            store: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot,
            projection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot,
            selection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot,
            fence: WorkspaceSliceRebaseFence?,
            content: String?,
            stableUptimeMS: Double,
            responseEvent: MCPResponseDeliveryTraceEvent?,
            result: String,
            failure: String?
        ) -> [String: Any] {
            let responseUptimeMS = responseEvent?.monotonicUptimeMS
            let stableOffsetMS = stableUptimeMS - state.startedUptimeMS
            let responseOffsetMS = responseUptimeMS.map { $0 - state.startedUptimeMS }
            let responseToStableMS = responseUptimeMS.map { max(0, stableUptimeMS - $0) }
            let data = content.map { Data($0.utf8) }
            let sha = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            let contentPayload: [String: Any] = [
                "byte_count": Self.debugOptionalValue(data?.count),
                "line_count": Self.debugOptionalValue(content.map(debugApplyEditsProbeLineCount)),
                "sha256": Self.debugOptionalValue(sha)
            ]
            return [
                "ok": result == "stable",
                "op": op,
                "probe_id": state.probeID.uuidString,
                "result": result,
                "failure": Self.debugOptionalValue(failure),
                "expect_synthetic_modification": state.expectsSyntheticModification,
                "identity": debugApplyEditsProbeIdentityPayload(state),
                "response_timing_source": responseUptimeMS == nil ? "driver_receipt_required" : "app_delivery_tracer",
                "response_delivered_offset_ms": Self.debugOptionalValue(responseOffsetMS.map(debugRoundedMS)),
                "stable_offset_ms": debugRoundedMS(stableOffsetMS),
                "response_to_stable_ms": Self.debugOptionalValue(responseToStableMS.map(debugRoundedMS)),
                "request_identity": debugApplyEditsProbeRequestIdentityPayload(snapshot.requestIdentity),
                "counters": snapshot.counters,
                "events": snapshot.events.map { $0.payload() },
                "event_sample_limit": 64,
                "event_overflow_count": snapshot.eventOverflowCount,
                "final": debugApplyEditsProbeSnapshotPayload(store: store, projection: projection, selection: selection),
                "fence_current": fence.map { projection.registrationGeneration == $0.registrationGenerationsByFullPath[state.physicalPath] } ?? false,
                "content": contentPayload
            ]
        }

        private static func debugApplyEditsProbeIdentityPayload(_ state: MCPApplyEditsRebaseProbeState) -> [String: Any] {
            [
                "window_id": state.windowID,
                "connection_id": state.target.connectionID.uuidString,
                "run_id": debugOptionalValue(state.target.runID?.uuidString),
                "agent_session_id": debugOptionalValue(state.target.agentSessionID?.uuidString),
                "workspace_id": debugOptionalValue(state.target.workspaceID?.uuidString),
                "tab_id": state.target.tabID.uuidString,
                "binding_generation": state.target.bindingGeneration,
                "root_scope": state.baselineStore.isSessionWorktree ? "session_worktree" : "visible_workspace",
                "root_id": state.rootID.uuidString,
                "root_lifetime_id": state.rootLifetimeID.uuidString,
                "root_token": state.rootToken.uuidString,
                "file_id": state.fileID.uuidString,
                "physical_path": state.physicalPath,
                "relative_path": state.relativePath,
                "selection_path_candidate_count": state.selectionPathCandidates.count
            ]
        }

        private static func debugApplyEditsProbeSnapshotPayload(
            store: WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot,
            projection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot,
            selection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot
        ) -> [String: Any] {
            [
                "produced_generation": store.producedAppliedIndexGeneration,
                "handled_generation": projection.handledGeneration,
                "rebase_registration_generation": projection.registrationGeneration,
                "has_pending_rebase_task": projection.hasPendingRebaseTask,
                "selection_revision": selection.selectionRevision,
                "ranges": selection.ranges.map { range -> [String: Any] in
                    [
                        "start": range.start,
                        "end": range.end,
                        "description": Self.debugOptionalValue(range.description)
                    ]
                }
            ]
        }

        static func debugApplyEditsProbeResponseEvent(
            for identity: MCPRequestTimelineIdentity?,
            events: [MCPResponseDeliveryTraceEvent]
        ) -> MCPResponseDeliveryTraceEvent? {
            guard let identity, identity.appInvocationID != nil else { return nil }
            return events.last { event in
                event.phase == "transport_write_completed" && event.requestIdentity == identity
            }
        }

        private static func debugApplyEditsProbeRequestIdentityPayload(_ identity: MCPRequestTimelineIdentity?) -> Any {
            guard let identity else { return NSNull() }
            let payload: [String: Any] = [
                "jsonrpc_request_id": Self.debugOptionalValue(identity.jsonRPCRequestID?.description),
                "connection_id": Self.debugOptionalValue(identity.connectionID),
                "connection_generation": Self.debugOptionalValue(identity.connectionGeneration),
                "app_invocation_id": Self.debugOptionalValue(identity.appInvocationID),
                "request_ordinal": Self.debugOptionalValue(identity.requestOrdinal)
            ]
            return payload
        }

        private static func debugApplyEditsProbeRanges(_ value: Value?) -> [LineRange]? {
            guard let array = value?.arrayValue else { return nil }
            var ranges: [LineRange] = []
            for item in array {
                guard let object = item.objectValue,
                      let start = debugApplyEditsProbeInt(object["start_line"] ?? object["start"]),
                      let end = debugApplyEditsProbeInt(object["end_line"] ?? object["end"])
                else { return nil }
                ranges.append(LineRange(
                    start: start,
                    end: end,
                    description: object["description"]?.stringValue ?? object["desc"]?.stringValue
                ))
            }
            return SliceRangeMath.normalize(ranges)
        }

        private static func debugApplyEditsProbeInt(_ value: Value?) -> Int? {
            guard let value else { return nil }
            switch value {
            case let .int(int): return int
            case let .double(double) where double.isFinite && double.rounded(.towardZero) == double:
                return Int(double)
            case let .string(string):
                return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                return nil
            }
        }

        private static func debugApplyEditsProbeLineCount(_ content: String) -> Int {
            guard !content.isEmpty else { return 0 }
            return content.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        }
    }
#endif
