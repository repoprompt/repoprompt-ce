import Foundation

#if DEBUG
    import os

    /// Debug-only, opt-in instrumentation for steady-state Agent Mode performance hot paths.
    ///
    /// Enable in debug builds with either:
    /// - `defaults write com.repoprompt.RepoPrompt enableAgentModePerfDiagnostics -bool YES`
    /// - `RP_AGENT_MODE_PERF_DIAGNOSTICS=1`
    /// - the hidden MCP diagnostics op: `__repoprompt_debug_diagnostics` with `{ "op": "agent_perf_metrics", "enable": true }`
    ///
    /// This file is compiled behind `#if DEBUG`; release builds do not include the logger.
    enum AgentModePerfDiagnostics {
        private static let logger = Logger(subsystem: "com.repoprompt.agent-perf", category: "agent-mode")
        private static let defaultsKey = "enableAgentModePerfDiagnostics"
        private static let environmentKey = "RP_AGENT_MODE_PERF_DIAGNOSTICS"
        private static let osLogDefaultsKey = "emitAgentModePerfDiagnosticsToOSLog"
        private static let osLogEnvironmentKey = "RP_AGENT_MODE_PERF_OSLOG"
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let bufferLimit = 1000
        private static let structuredEventLimit = 5000
        private static let sessionSnapshotLimit = 500
        private static let bufferLock = NSLock()
        private static var processOverrideEnabled: Bool?
        private static var recentMetricLines: [String] = []
        private static var eventRecords: [AgentPerfEventRecord] = []
        private static var nextEventSequence = 0
        private static var droppedEventRecordCount = 0
        private static var counters: [String: Int] = [:]
        private static var latestSessionSnapshots: [String: [String: Any]] = [:]
        private static var latestSessionSnapshotOrder: [String] = []
        private static var pendingSidebarDeleteByTabID: [UUID: PendingSidebarDelete] = [:]

        struct SidebarDeleteBeginContext {
            let tabID: UUID
            let sessionID: UUID?
            let source: String
            let reason: String?
            let wasCurrentTab: Bool
            let wasRunning: Bool
            let isMCPControlled: Bool
        }

        private struct PendingSidebarDelete {
            let deleteID: UUID
            let tabID: UUID
            let sessionID: UUID?
            let startMS: Double
            let source: String
            let reason: String?
            let wasCurrentTab: Bool
            let wasRunning: Bool
            let isMCPControlled: Bool
            var didEmitVisibleRemoved: Bool
            var didEmitAgentCleanupComplete: Bool
            var didEmitFullCleanupComplete: Bool
        }

        private struct SidebarDeleteEmission {
            let eventName: String
            let fields: [String: String]
        }

        private struct AgentPerfEventRecord {
            let sequence: Int
            let timestampMS: Double
            let name: String
            let fields: [String: String]
        }

        static var isEnabled: Bool {
            if let override = debugProcessOverrideEnabled {
                return override
            }
            return defaultsEnabled || environmentEnabled
        }

        static var defaultsEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        static var environmentEnabled: Bool {
            environmentFlagEnabled(environmentKey)
        }

        static var debugProcessOverrideEnabled: Bool? {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return processOverrideEnabled
        }

        static var osLogEnabled: Bool {
            UserDefaults.standard.bool(forKey: osLogDefaultsKey) || environmentFlagEnabled(osLogEnvironmentKey)
        }

        static func timestampMSIfEnabled() -> Double? {
            guard isEnabled else { return nil }
            return timestampMS()
        }

        static func timestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        static func elapsedMS(since startMS: Double) -> Double {
            timestampMS() - startMS
        }

        static func formatMS(_ value: Double) -> String {
            String(format: "%.1fms", value)
        }

        static func formatElapsedMS(since startMS: Double) -> String {
            formatMS(elapsedMS(since: startMS))
        }

        static func durationEvent(
            _ name: String,
            startMS: Double?,
            tabID: UUID? = nil,
            fields: [String: String] = [:]
        ) {
            guard let startMS else { return }
            var renderedFields = fields
            renderedFields["duration"] = formatElapsedMS(since: startMS)
            event(name, tabID: tabID, fields: renderedFields)
        }

        enum CodexLifecyclePhase: String, CaseIterable {
            case runtimeResolution = "runtime_resolution"
            case provisioning
            case spawnInitialize = "spawn_initialize"
            case threadStart = "thread_start"
            case threadResume = "thread_resume"
            case turnAcceptance = "turn_acceptance"
            case shutdown
        }

        enum CodexLifecycleOutcome: String, CaseIterable {
            case succeeded
            case failed
            case cancelled
        }

        /// Fixed-field Codex lifecycle timing event. Typed phase/outcome values and numeric generations
        /// prevent callers from attaching paths, prompts, identifiers, payloads, auth data, or raw errors.
        static func recordCodexLifecyclePhase(
            _ phase: CodexLifecyclePhase,
            outcome: CodexLifecycleOutcome,
            startMS: Double?,
            tabID: UUID,
            transportGeneration: UInt64? = nil
        ) {
            var fields = [
                "phase": phase.rawValue,
                "outcome": outcome.rawValue
            ]
            if let transportGeneration {
                fields["transportGeneration"] = String(transportGeneration)
            }
            durationEvent(
                "provider.codex.lifecycle.phase",
                startMS: startMS,
                tabID: tabID,
                fields: fields
            )
        }

        static func counterKey(_ base: String, source: String?) -> String {
            let normalizedSource = source?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\t", with: "_")
            guard let normalizedSource, !normalizedSource.isEmpty else {
                return "\(base).source.unknown"
            }
            return "\(base).source.\(normalizedSource)"
        }

        static func shortID(_ id: UUID?) -> String {
            id?.uuidString.prefix(8).description ?? "nil"
        }

        static func increment(_ key: String, tabID: UUID? = nil, by amount: Int = 1) {
            guard isEnabled else { return }
            bufferLock.lock()
            incrementLocked(key, by: amount)
            if let tabID {
                incrementLocked("\(key).tab.\(tabID.uuidString)", by: amount)
            }
            bufferLock.unlock()
        }

        static func event(_ name: String, tabID: UUID? = nil, fields: [String: String] = [:]) {
            guard isEnabled else { return }
            var renderedFields = fields
            if let tabID {
                renderedFields["tabID"] = shortID(tabID)
            }
            let timestamp = timestampMS()
            let renderedMessage = renderEvent(name, fields: renderedFields)
            bufferLock.lock()
            incrementLocked("event.\(name)")
            appendRecentMetricLineLocked(renderedMessage, timestampMS: timestamp)
            appendEventRecordLocked(
                AgentPerfEventRecord(
                    sequence: nextEventSequence,
                    timestampMS: timestamp,
                    name: name,
                    fields: renderedFields
                )
            )
            nextEventSequence &+= 1
            bufferLock.unlock()
            if osLogEnabled {
                logger.debug("\(renderedMessage, privacy: .public)")
            }
        }

        static func recordConversationReplay(
            _ metrics: AgentConversationReplayMetrics,
            startMS: Double?
        ) {
            guard isEnabled else { return }
            var fields: [String: String] = [
                "mode": metrics.mode.rawValue,
                "turnCount": String(metrics.turnCount),
                "examinedRowCount": String(metrics.examinedRowCount),
                "unboundedOutputUTF8Bytes": String(metrics.unboundedOutputUTF8Bytes),
                "outputUTF8Bytes": String(metrics.outputUTF8Bytes),
                "userAuthoredUTF8Bytes": String(metrics.userAuthoredUTF8Bytes),
                "originalToolArgumentCharacters": String(metrics.originalToolArgumentCharacters),
                "emittedToolArgumentCharacters": String(metrics.emittedToolArgumentCharacters),
                "truncatedToolCallCount": String(metrics.truncatedToolCallCount),
                "omittedRowCount": String(metrics.omittedRowCount),
                "essentialOverflowUTF8Bytes": String(metrics.essentialOverflowUTF8Bytes),
                "finalOverBudgetUTF8Bytes": String(metrics.finalOverBudgetUTF8Bytes)
            ]
            for category in AgentConversationReplayCategory.allCases {
                let categoryMetrics = metrics.categories[category] ?? .init()
                fields["\(category.rawValue).examined"] = String(categoryMetrics.examinedCount)
                fields["\(category.rawValue).emitted"] = String(categoryMetrics.emittedCount)
                fields["\(category.rawValue).omitted"] = String(categoryMetrics.omittedCount)
                fields["\(category.rawValue).unboundedUTF8Bytes"] = String(categoryMetrics.unboundedUTF8Bytes)
                fields["\(category.rawValue).emittedUTF8Bytes"] = String(categoryMetrics.emittedUTF8Bytes)
            }
            durationEvent("conversationReplay.serialize", startMS: startMS, fields: fields)
            increment("conversationReplay.serialize.\(metrics.mode.rawValue)")
            increment("conversationReplay.truncatedToolCalls", by: metrics.truncatedToolCallCount)
            increment("conversationReplay.omittedRows", by: metrics.omittedRowCount)
            if metrics.essentialOverflowUTF8Bytes > 0 {
                increment("conversationReplay.essentialOverflow")
            }
        }

        static func recordStoreUpdate(_ store: String, published: Bool, details: [String: String] = [:]) {
            guard isEnabled else { return }
            increment("store.\(store).called")
            increment("store.\(store).\(published ? "published" : "skipped")")
            var fields = details
            fields["store"] = store
            fields["published"] = String(published)
            event("store.update", fields: fields)
            if store.hasPrefix("sessionSidebar.attention.") {
                event(store, fields: fields)
            }
        }

        @discardableResult
        static func beginSidebarDelete(_ context: SidebarDeleteBeginContext) -> UUID {
            let deleteID = UUID()
            guard isEnabled else { return deleteID }
            let pending = PendingSidebarDelete(
                deleteID: deleteID,
                tabID: context.tabID,
                sessionID: context.sessionID,
                startMS: timestampMS(),
                source: context.source,
                reason: context.reason,
                wasCurrentTab: context.wasCurrentTab,
                wasRunning: context.wasRunning,
                isMCPControlled: context.isMCPControlled,
                didEmitVisibleRemoved: false,
                didEmitAgentCleanupComplete: false,
                didEmitFullCleanupComplete: false
            )
            bufferLock.lock()
            pendingSidebarDeleteByTabID[context.tabID] = pending
            bufferLock.unlock()
            event("sidebar.delete.requested", fields: sidebarDeleteFields(for: pending))
            return deleteID
        }

        static func markSidebarDeleteVisibleRemoved(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.visibleRemoved",
                durationEventName: "sidebar.delete.requestToVisible",
                duplicateEventName: "sidebar.delete.duplicateVisibleRemoved",
                orphanEventName: "sidebar.delete.orphanVisibleRemoved",
                markEmitted: { $0.didEmitVisibleRemoved = true },
                hasEmitted: { $0.didEmitVisibleRemoved }
            )
        }

        static func markSidebarDeleteAgentCleanupComplete(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.agentCleanupComplete",
                durationEventName: "sidebar.delete.requestToAgentCleanup",
                duplicateEventName: "sidebar.delete.duplicateAgentCleanupComplete",
                orphanEventName: "sidebar.delete.orphanAgentCleanupComplete",
                markEmitted: { $0.didEmitAgentCleanupComplete = true },
                hasEmitted: { $0.didEmitAgentCleanupComplete }
            )
        }

        static func markSidebarDeleteFullCleanupComplete(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.fullCleanupComplete",
                durationEventName: "sidebar.delete.requestToFullCleanup",
                duplicateEventName: "sidebar.delete.duplicateFullCleanupComplete",
                orphanEventName: "sidebar.delete.orphanFullCleanupComplete",
                markEmitted: { $0.didEmitFullCleanupComplete = true },
                hasEmitted: { $0.didEmitFullCleanupComplete }
            )
        }

        static func cancelSidebarDeleteTracking(tabID: UUID, source: String, fields: [String: String] = [:]) {
            guard isEnabled else { return }
            let pending: PendingSidebarDelete?
            bufferLock.lock()
            pending = pendingSidebarDeleteByTabID.removeValue(forKey: tabID)
            bufferLock.unlock()
            var eventFields = fields
            eventFields["source"] = source
            if let pending {
                event("sidebar.delete.cancelled", fields: sidebarDeleteFields(for: pending, extraFields: eventFields))
            } else {
                eventFields["tabID"] = tabID.uuidString
                event("sidebar.delete.orphanCancelled", fields: eventFields)
            }
        }

        static func recordSessionSnapshot(tabID: UUID, fields: [String: Any]) {
            guard isEnabled else { return }
            let key = tabID.uuidString
            var snapshot = fields
            snapshot["tabID"] = key
            snapshot["shortTabID"] = shortID(tabID)
            snapshot["recordedAtMS"] = timestampMS()
            bufferLock.lock()
            if latestSessionSnapshots[key] == nil {
                latestSessionSnapshotOrder.append(key)
            }
            latestSessionSnapshots[key] = snapshot
            while latestSessionSnapshotOrder.count > sessionSnapshotLimit {
                let staleKey = latestSessionSnapshotOrder.removeFirst()
                latestSessionSnapshots.removeValue(forKey: staleKey)
            }
            bufferLock.unlock()

            let stringFields = fields.reduce(into: [String: String]()) { partial, entry in
                partial[entry.key] = String(describing: entry.value)
            }
            event("memory.sessionSnapshot", tabID: tabID, fields: stringFields)
        }

        static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            bufferLock.lock()
            processOverrideEnabled = enabled
            bufferLock.unlock()
        }

        static func clearRecentMetrics() {
            bufferLock.lock()
            recentMetricLines.removeAll(keepingCapacity: true)
            eventRecords.removeAll(keepingCapacity: true)
            nextEventSequence = 0
            droppedEventRecordCount = 0
            counters.removeAll(keepingCapacity: true)
            latestSessionSnapshots.removeAll(keepingCapacity: true)
            latestSessionSnapshotOrder.removeAll(keepingCapacity: true)
            pendingSidebarDeleteByTabID.removeAll(keepingCapacity: true)
            bufferLock.unlock()
        }

        static func recentMetricLinesSnapshot(limit requestedLimit: Int) -> [String] {
            let limit = max(1, min(requestedLimit, bufferLimit))
            bufferLock.lock()
            let lines = Array(recentMetricLines.suffix(limit))
            bufferLock.unlock()
            return lines
        }

        static func debugStateSnapshot(lineLimit: Int) -> [String: Any] {
            let limit = max(1, min(lineLimit, bufferLimit))
            bufferLock.lock()
            let lines = Array(recentMetricLines.suffix(limit))
            let countersSnapshot = counters
            let sessionSnapshots = latestSessionSnapshots
            let structuredCount = eventRecords.count
            let structuredDropped = droppedEventRecordCount
            let pendingSidebarDeleteCount = pendingSidebarDeleteByTabID.count
            bufferLock.unlock()
            return [
                "enabled": isEnabled,
                "defaults_enabled": defaultsEnabled,
                "environment_enabled": environmentEnabled,
                "process_override_enabled": debugProcessOverrideEnabled ?? NSNull(),
                "os_log_enabled": osLogEnabled,
                "line_count": lines.count,
                "buffer_limit": bufferLimit,
                "structured_event_count": structuredCount,
                "structured_event_limit": structuredEventLimit,
                "structured_event_dropped_count": structuredDropped,
                "session_snapshot_limit": sessionSnapshotLimit,
                "pending_sidebar_delete_count": pendingSidebarDeleteCount,
                "mcp_long_thread_baseline_inventory": MCPAgentLongThreadBaselineInventory.debugSnapshot,
                "lines": lines,
                "counters": countersSnapshot,
                "latest_session_snapshots": sessionSnapshots
            ]
        }

        static func debugMetricSummarySnapshot(
            lineLimit requestedLineLimit: Int,
            startMark: String? = nil,
            endMark: String? = nil,
            eventNames: Set<String>? = nil
        ) -> [String: Any] {
            let trimmedStartMark = startMark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedEndMark = endMark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let eventNameFilter = eventNames.map { Set($0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
            let lineLimit = max(1, min(requestedLineLimit, bufferLimit))

            let records: [AgentPerfEventRecord]
            let countersSnapshot: [String: Int]
            let droppedCount: Int
            bufferLock.lock()
            records = eventRecords
            countersSnapshot = counters
            droppedCount = droppedEventRecordCount
            bufferLock.unlock()

            let windowResult = recordsInWindow(
                records,
                startMark: trimmedStartMark,
                endMark: trimmedEndMark
            )
            guard windowResult.ok else {
                let missingWindow: [String: Any] = [
                    "start_mark": anyOrNull(trimmedStartMark),
                    "end_mark": anyOrNull(trimmedEndMark),
                    "record_count": 0,
                    "buffer_truncated": droppedCount > 0
                ]
                return [
                    "ok": false,
                    "code": "missing_mark",
                    "missing_mark": anyOrNull(windowResult.missingMark),
                    "window": missingWindow,
                    "events": [String: Any](),
                    "counters": countersSnapshot,
                    "line_limit": lineLimit
                ]
            }

            let filteredRecords = windowResult.records.filter { record in
                guard let eventNameFilter, !eventNameFilter.isEmpty else { return true }
                return eventNameFilter.contains(record.name)
            }
            let groupedRecords = Dictionary(grouping: filteredRecords, by: \.name)
            let eventSummaries = groupedRecords.keys.sorted().reduce(into: [String: Any]()) { partial, name in
                partial[name] = summaryPayload(for: groupedRecords[name] ?? [])
            }

            let windowPayload: [String: Any] = [
                "start_mark": anyOrNull(trimmedStartMark),
                "end_mark": anyOrNull(trimmedEndMark),
                "start_sequence": anyOrNull(windowResult.startSequence),
                "end_sequence": anyOrNull(windowResult.endSequence),
                "record_count": windowResult.records.count,
                "filtered_record_count": filteredRecords.count,
                "oldest_retained_sequence": anyOrNull(records.first?.sequence),
                "newest_retained_sequence": anyOrNull(records.last?.sequence),
                "buffer_truncated": droppedCount > 0,
                "dropped_record_count": droppedCount
            ]
            let eventNamesFilterPayload: Any = eventNameFilter.map { Array($0).sorted() } ?? NSNull()
            return [
                "ok": true,
                "window": windowPayload,
                "events": eventSummaries,
                "counters": countersSnapshot,
                "event_names_filter": eventNamesFilterPayload,
                "line_limit": lineLimit
            ]
        }

        private struct MetricWindowResult {
            let ok: Bool
            let records: [AgentPerfEventRecord]
            let startSequence: Int?
            let endSequence: Int?
            let missingMark: String?
        }

        private static func recordsInWindow(
            _ records: [AgentPerfEventRecord],
            startMark: String?,
            endMark: String?
        ) -> MetricWindowResult {
            var lowerBoundSequence: Int?
            var upperBoundSequence: Int?
            if let startMark {
                guard let start = records.last(where: { isMark($0, named: startMark) }) else {
                    return MetricWindowResult(ok: false, records: [], startSequence: nil, endSequence: nil, missingMark: startMark)
                }
                lowerBoundSequence = start.sequence
                if let endMark {
                    guard let end = records.first(where: { $0.sequence > start.sequence && isMark($0, named: endMark) }) else {
                        return MetricWindowResult(ok: false, records: [], startSequence: start.sequence, endSequence: nil, missingMark: endMark)
                    }
                    upperBoundSequence = end.sequence
                }
            } else if let endMark {
                guard let end = records.first(where: { isMark($0, named: endMark) }) else {
                    return MetricWindowResult(ok: false, records: [], startSequence: nil, endSequence: nil, missingMark: endMark)
                }
                upperBoundSequence = end.sequence
            }

            let windowRecords = records.filter { record in
                if let lowerBoundSequence, record.sequence <= lowerBoundSequence { return false }
                if let upperBoundSequence, record.sequence > upperBoundSequence { return false }
                return true
            }
            return MetricWindowResult(
                ok: true,
                records: windowRecords,
                startSequence: lowerBoundSequence,
                endSequence: upperBoundSequence,
                missingMark: nil
            )
        }

        private static func isMark(_ record: AgentPerfEventRecord, named mark: String) -> Bool {
            record.name == "agent.metrics.mark" && record.fields["mark"] == mark
        }

        private static func summaryPayload(for records: [AgentPerfEventRecord]) -> [String: Any] {
            var durations: [Double] = []
            var malformedDurationCount = 0
            for record in records {
                guard let duration = record.fields["duration"] else { continue }
                if let parsed = parseDurationMS(duration) {
                    durations.append(parsed)
                } else {
                    malformedDurationCount += 1
                }
            }
            let sortedDurations = durations.sorted()
            let total = sortedDurations.reduce(0, +)
            return [
                "count": records.count,
                "duration_count": sortedDurations.count,
                "malformed_duration_count": malformedDurationCount,
                "median_ms": median(sortedDurations).map(roundedMS) ?? NSNull(),
                "p95_ms": nearestRankPercentile(sortedDurations, percentile: 0.95).map(roundedMS) ?? NSNull(),
                "max_ms": sortedDurations.last.map(roundedMS) ?? NSNull(),
                "total_ms": sortedDurations.isEmpty ? NSNull() : roundedMS(total),
                "first_sequence": records.first?.sequence ?? NSNull(),
                "last_sequence": records.last?.sequence ?? NSNull()
            ]
        }

        private static func median(_ sortedValues: [Double]) -> Double? {
            guard !sortedValues.isEmpty else { return nil }
            let midpoint = sortedValues.count / 2
            if sortedValues.count.isMultiple(of: 2) {
                return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2.0
            }
            return sortedValues[midpoint]
        }

        private static func nearestRankPercentile(_ sortedValues: [Double], percentile: Double) -> Double? {
            guard !sortedValues.isEmpty else { return nil }
            let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
            let clamped = min(max(rank, 0), sortedValues.count - 1)
            return sortedValues[clamped]
        }

        private static func roundedMS(_ value: Double) -> Double {
            (value * 10.0).rounded() / 10.0
        }

        private static func parseDurationMS(_ raw: String) -> Double? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let numeric = trimmed.hasSuffix("ms") ? String(trimmed.dropLast(2)) : trimmed
            guard let value = Double(numeric), value.isFinite else { return nil }
            return value
        }

        private static func anyOrNull(_ value: (some Any)?) -> Any {
            value.map { $0 as Any } ?? NSNull()
        }

        private static func emitSidebarDeleteMilestone(
            tabID: UUID,
            source: String,
            fields: [String: String],
            milestoneEventName: String,
            durationEventName: String,
            duplicateEventName: String,
            orphanEventName: String,
            markEmitted: (inout PendingSidebarDelete) -> Void,
            hasEmitted: (PendingSidebarDelete) -> Bool
        ) {
            guard isEnabled else { return }
            let nowMS = timestampMS()
            let emissions: [SidebarDeleteEmission]
            bufferLock.lock()
            if var pending = pendingSidebarDeleteByTabID[tabID] {
                if hasEmitted(pending) {
                    emissions = [
                        SidebarDeleteEmission(
                            eventName: duplicateEventName,
                            fields: sidebarDeleteFields(for: pending, extraFields: fields.merging(["source": source]) { _, new in new })
                        )
                    ]
                } else {
                    markEmitted(&pending)
                    if pending.didEmitVisibleRemoved, pending.didEmitFullCleanupComplete {
                        pendingSidebarDeleteByTabID.removeValue(forKey: tabID)
                    } else {
                        pendingSidebarDeleteByTabID[tabID] = pending
                    }
                    var milestoneFields = fields
                    milestoneFields["source"] = source
                    var durationFields = milestoneFields
                    durationFields["duration"] = formatMS(nowMS - pending.startMS)
                    emissions = [
                        SidebarDeleteEmission(
                            eventName: milestoneEventName,
                            fields: sidebarDeleteFields(for: pending, extraFields: milestoneFields)
                        ),
                        SidebarDeleteEmission(
                            eventName: durationEventName,
                            fields: sidebarDeleteFields(for: pending, extraFields: durationFields)
                        )
                    ]
                }
            } else {
                var orphanFields = fields
                orphanFields["tabID"] = tabID.uuidString
                orphanFields["source"] = source
                emissions = [SidebarDeleteEmission(eventName: orphanEventName, fields: orphanFields)]
            }
            bufferLock.unlock()

            for emission in emissions {
                event(emission.eventName, fields: emission.fields)
            }
        }

        private static func sidebarDeleteFields(
            for pending: PendingSidebarDelete,
            extraFields: [String: String] = [:]
        ) -> [String: String] {
            var fields = extraFields
            fields["deleteID"] = pending.deleteID.uuidString
            fields["tabID"] = pending.tabID.uuidString
            fields["shortTabID"] = shortID(pending.tabID)
            fields["sessionID"] = pending.sessionID?.uuidString ?? "nil"
            fields["shortSessionID"] = shortID(pending.sessionID)
            fields["requestSource"] = pending.source
            fields["reason"] = pending.reason ?? "nil"
            fields["wasCurrentTab"] = String(pending.wasCurrentTab)
            fields["wasRunning"] = String(pending.wasRunning)
            fields["isMCPControlled"] = String(pending.isMCPControlled)
            return fields
        }

        private static func environmentFlagEnabled(_ key: String) -> Bool {
            let rawValue = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
        }

        private static func incrementLocked(_ key: String, by amount: Int = 1) {
            counters[key, default: 0] += amount
        }

        private static func appendRecentMetricLineLocked(_ message: String, timestampMS: Double) {
            let line = "t+\(formatMS(timestampMS)) \(message)"
            recentMetricLines.append(line)
            if recentMetricLines.count > bufferLimit {
                recentMetricLines.removeFirst(recentMetricLines.count - bufferLimit)
            }
        }

        private static func appendEventRecordLocked(_ record: AgentPerfEventRecord) {
            eventRecords.append(record)
            if eventRecords.count > structuredEventLimit {
                let dropCount = eventRecords.count - structuredEventLimit
                eventRecords.removeFirst(dropCount)
                droppedEventRecordCount += dropCount
            }
        }

        private static func renderEvent(_ name: String, fields: [String: String]) -> String {
            guard !fields.isEmpty else { return name }
            let suffix = fields.keys.sorted().map { key in
                "\(key)=\(sanitize(fields[key] ?? ""))"
            }.joined(separator: " ")
            return "\(name) \(suffix)"
        }

        private static func sanitize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: " ", with: "_")
        }
    }

    private extension String {
        var nilIfEmpty: String? {
            isEmpty ? nil : self
        }
    }
#endif
