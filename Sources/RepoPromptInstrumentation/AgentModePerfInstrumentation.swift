import Foundation

/// Only bounded identifiers, counters, and pre-redacted diagnostic fields cross this seam.
package struct AgentPerfSidebarDeleteBeginContext: Sendable {
    package let tabID: UUID
    package let sessionID: UUID?
    package let source: String
    package let reason: String?
    package let wasCurrentTab: Bool
    package let wasRunning: Bool
    package let isMCPControlled: Bool

    package init(
        tabID: UUID,
        sessionID: UUID?,
        source: String,
        reason: String?,
        wasCurrentTab: Bool,
        wasRunning: Bool,
        isMCPControlled: Bool
    ) {
        self.tabID = tabID
        self.sessionID = sessionID
        self.source = source
        self.reason = reason
        self.wasCurrentTab = wasCurrentTab
        self.wasRunning = wasRunning
        self.isMCPControlled = isMCPControlled
    }
}

package enum AgentPerfSnapshotValue: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case integer(Int)
    case unsigned(UInt64)
    case double(Double)
    case boolean(Bool)
    case null

    package init(stringLiteral value: String) { self = .string(value) }
    package init(integerLiteral value: Int) { self = .integer(value) }
    package init(floatLiteral value: Double) { self = .double(value) }
    package init(booleanLiteral value: Bool) { self = .boolean(value) }
    package init(_ value: String) { self = .string(value) }
    package init(_ value: Int) { self = .integer(value) }
    package init(_ value: UInt64) { self = .unsigned(value) }
    package init(_ value: Double) { self = .double(value) }
    package init(_ value: Bool) { self = .boolean(value) }
}

/// Replay telemetry contains only aggregate counts and fixed category labels, never transcript content.
package struct AgentPerfConversationReplayEvent: Sendable {
    package let mode: String
    package let fields: [String: String]
    package let truncatedToolCallCount: Int
    package let omittedRowCount: Int
    package let essentialOverflowUTF8Bytes: Int

    package init(
        mode: String,
        fields: [String: String],
        truncatedToolCallCount: Int,
        omittedRowCount: Int,
        essentialOverflowUTF8Bytes: Int
    ) {
        self.mode = mode
        self.fields = fields
        self.truncatedToolCallCount = truncatedToolCallCount
        self.omittedRowCount = omittedRowCount
        self.essentialOverflowUTF8Bytes = essentialOverflowUTF8Bytes
    }
}

package enum AgentPerfCodexLifecyclePhase: String, CaseIterable, Sendable {
    case runtimeResolution = "runtime_resolution"
    case provisioning
    case spawnInitialize = "spawn_initialize"
    case threadStart = "thread_start"
    case threadResume = "thread_resume"
    case turnAcceptance = "turn_acceptance"
    case shutdown
}

package enum AgentPerfCodexLifecycleOutcome: String, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// Per-owner synchronous contract. The app adapter owns policy, storage, and OSLog output.
package protocol AgentModePerfRecording: Sendable {
    var isEnabled: Bool { get }
    func timestampMSIfEnabled() -> Double?
    func timestampMS() -> Double
    func elapsedMS(since startMS: Double) -> Double
    func formatMS(_ value: Double) -> String
    func formatElapsedMS(since startMS: Double) -> String
    func shortID(_ id: UUID?) -> String
    func counterKey(_ base: String, source: String?) -> String
    func increment(_ key: String, tabID: UUID?, by amount: Int)
    func event(_ name: String, tabID: UUID?, fields: [String: String])
    func durationEvent(_ name: String, startMS: Double?, tabID: UUID?, fields: [String: String])
    func recordStoreUpdate(_ store: String, published: Bool, details: [String: String])
    func recordConversationReplay(_ event: AgentPerfConversationReplayEvent, startMS: Double?)
    func beginSidebarDelete(_ context: AgentPerfSidebarDeleteBeginContext) -> UUID
    func markSidebarDeleteVisibleRemoved(tabID: UUID, source: String, fields: [String: String])
    func markSidebarDeleteAgentCleanupComplete(tabID: UUID, source: String, fields: [String: String])
    func markSidebarDeleteFullCleanupComplete(tabID: UUID, source: String, fields: [String: String])
    func cancelSidebarDeleteTracking(tabID: UUID, source: String, fields: [String: String])
    func recordSessionSnapshot(tabID: UUID, fields: [String: AgentPerfSnapshotValue])
    func recordCodexLifecyclePhase(
        _ phase: AgentPerfCodexLifecyclePhase,
        outcome: AgentPerfCodexLifecycleOutcome,
        startMS: Double?,
        tabID: UUID,
        transportGeneration: UInt64?
    )
}

package extension AgentModePerfRecording {
    func increment(_ key: String) { increment(key, tabID: nil, by: 1) }
    func increment(_ key: String, tabID: UUID?) { increment(key, tabID: tabID, by: 1) }
    func increment(_ key: String, by amount: Int) { increment(key, tabID: nil, by: amount) }

    func event(_ name: String) { event(name, tabID: nil, fields: [:]) }
    func event(_ name: String, tabID: UUID?) { event(name, tabID: tabID, fields: [:]) }
    func event(_ name: String, fields: [String: String]) { event(name, tabID: nil, fields: fields) }

    func durationEvent(_ name: String, startMS: Double?) {
        durationEvent(name, startMS: startMS, tabID: nil, fields: [:])
    }

    func durationEvent(_ name: String, startMS: Double?, tabID: UUID?) {
        durationEvent(name, startMS: startMS, tabID: tabID, fields: [:])
    }

    func durationEvent(_ name: String, startMS: Double?, fields: [String: String]) {
        durationEvent(name, startMS: startMS, tabID: nil, fields: fields)
    }

    func recordStoreUpdate(_ store: String, published: Bool) {
        recordStoreUpdate(store, published: published, details: [:])
    }

    func markSidebarDeleteVisibleRemoved(tabID: UUID, source: String) {
        markSidebarDeleteVisibleRemoved(tabID: tabID, source: source, fields: [:])
    }

    func markSidebarDeleteAgentCleanupComplete(tabID: UUID, source: String) {
        markSidebarDeleteAgentCleanupComplete(tabID: tabID, source: source, fields: [:])
    }

    func markSidebarDeleteFullCleanupComplete(tabID: UUID, source: String) {
        markSidebarDeleteFullCleanupComplete(tabID: tabID, source: source, fields: [:])
    }

    func cancelSidebarDeleteTracking(tabID: UUID, source: String) {
        cancelSidebarDeleteTracking(tabID: tabID, source: source, fields: [:])
    }
}

package struct NoopAgentModePerfRecorder: AgentModePerfRecording {
    package init() {}
    package var isEnabled: Bool { false }
    package func timestampMSIfEnabled() -> Double? { nil }
    package func timestampMS() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }
    package func elapsedMS(since startMS: Double) -> Double { timestampMS() - startMS }
    package func formatMS(_ value: Double) -> String { String(format: "%.1fms", value) }
    package func formatElapsedMS(since startMS: Double) -> String { formatMS(elapsedMS(since: startMS)) }
    package func shortID(_ id: UUID?) -> String { id?.uuidString.prefix(8).description ?? "nil" }
    package func counterKey(_ base: String, source: String?) -> String {
        let normalized = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
        guard let normalized, !normalized.isEmpty else { return "\(base).source.unknown" }
        return "\(base).source.\(normalized)"
    }
    package func increment(_: String, tabID _: UUID?, by _: Int) {}
    package func event(_: String, tabID _: UUID?, fields _: [String: String]) {}
    package func durationEvent(_: String, startMS _: Double?, tabID _: UUID?, fields _: [String: String]) {}
    package func recordStoreUpdate(_: String, published _: Bool, details _: [String: String]) {}
    package func recordConversationReplay(_: AgentPerfConversationReplayEvent, startMS _: Double?) {}
    package func beginSidebarDelete(_: AgentPerfSidebarDeleteBeginContext) -> UUID { UUID() }
    package func markSidebarDeleteVisibleRemoved(tabID _: UUID, source _: String, fields _: [String: String]) {}
    package func markSidebarDeleteAgentCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
    package func markSidebarDeleteFullCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
    package func cancelSidebarDeleteTracking(tabID _: UUID, source _: String, fields _: [String: String]) {}
    package func recordSessionSnapshot(tabID _: UUID, fields _: [String: AgentPerfSnapshotValue]) {}
    package func recordCodexLifecyclePhase(
        _: AgentPerfCodexLifecyclePhase,
        outcome _: AgentPerfCodexLifecycleOutcome,
        startMS _: Double?,
        tabID _: UUID,
        transportGeneration _: UInt64?
    ) {}
}

/// Per-owner synchronous slot for actor singletons composed before asynchronous startup.
package final class AgentModePerfRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: any AgentModePerfRecording = NoopAgentModePerfRecorder()

    package init() {}

    package func install(_ recorder: any AgentModePerfRecording) {
        lock.lock()
        value = recorder
        lock.unlock()
    }

    package func snapshot() -> any AgentModePerfRecording {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
