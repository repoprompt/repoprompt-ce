import Foundation
import RepoPromptInstrumentation

/// App-owned bridge; all recorder state, opt-in policy, and output remain in Diagnostics.
struct AppAgentModePerfRecorder: AgentModePerfRecording {
    var isEnabled: Bool {
        #if DEBUG
            AgentModePerfDiagnostics.isEnabled
        #else
            false
        #endif
    }

    func timestampMSIfEnabled() -> Double? {
        #if DEBUG
            AgentModePerfDiagnostics.timestampMSIfEnabled()
        #else
            nil
        #endif
    }

    func timestampMS() -> Double {
        CFAbsoluteTimeGetCurrent() * 1000
    }

    func elapsedMS(since startMS: Double) -> Double {
        timestampMS() - startMS
    }

    func formatMS(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    func formatElapsedMS(since startMS: Double) -> String {
        formatMS(elapsedMS(since: startMS))
    }

    func shortID(_ id: UUID?) -> String {
        id?.uuidString.prefix(8).description ?? "nil"
    }

    func counterKey(_ base: String, source: String?) -> String {
        #if DEBUG
            AgentModePerfDiagnostics.counterKey(base, source: source)
        #else
            NoopAgentModePerfRecorder().counterKey(base, source: source)
        #endif
    }

    func increment(_ key: String, tabID: UUID?, by amount: Int) {
        #if DEBUG
            AgentModePerfDiagnostics.increment(key, tabID: tabID, by: amount)
        #endif
    }

    func event(_ name: String, tabID: UUID?, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.event(name, tabID: tabID, fields: fields)
        #endif
    }

    func durationEvent(_ name: String, startMS: Double?, tabID: UUID?, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(name, startMS: startMS, tabID: tabID, fields: fields)
        #endif
    }

    func recordConversationReplay(_ event: AgentPerfConversationReplayEvent, startMS: Double?) {
        #if DEBUG
            guard AgentModePerfDiagnostics.isEnabled else { return }
            AgentModePerfDiagnostics.durationEvent("conversationReplay.serialize", startMS: startMS, fields: event.fields)
            AgentModePerfDiagnostics.increment("conversationReplay.serialize.\(event.mode)")
            AgentModePerfDiagnostics.increment("conversationReplay.truncatedToolCalls", by: event.truncatedToolCallCount)
            AgentModePerfDiagnostics.increment("conversationReplay.omittedRows", by: event.omittedRowCount)
            if event.essentialOverflowUTF8Bytes > 0 {
                AgentModePerfDiagnostics.increment("conversationReplay.essentialOverflow")
            }
        #endif
    }

    func recordStoreUpdate(_ store: String, published: Bool, details: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(store, published: published, details: details)
        #endif
    }

    func beginSidebarDelete(_ context: AgentPerfSidebarDeleteBeginContext) -> UUID {
        #if DEBUG
            AgentModePerfDiagnostics.beginSidebarDelete(.init(
                tabID: context.tabID,
                sessionID: context.sessionID,
                source: context.source,
                reason: context.reason,
                wasCurrentTab: context.wasCurrentTab,
                wasRunning: context.wasRunning,
                isMCPControlled: context.isMCPControlled
            ))
        #else
            UUID()
        #endif
    }

    func markSidebarDeleteVisibleRemoved(tabID: UUID, source: String, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.markSidebarDeleteVisibleRemoved(tabID: tabID, source: source, fields: fields)
        #endif
    }

    func markSidebarDeleteAgentCleanupComplete(tabID: UUID, source: String, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.markSidebarDeleteAgentCleanupComplete(tabID: tabID, source: source, fields: fields)
        #endif
    }

    func markSidebarDeleteFullCleanupComplete(tabID: UUID, source: String, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.markSidebarDeleteFullCleanupComplete(tabID: tabID, source: source, fields: fields)
        #endif
    }

    func cancelSidebarDeleteTracking(tabID: UUID, source: String, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.cancelSidebarDeleteTracking(tabID: tabID, source: source, fields: fields)
        #endif
    }

    func recordSessionSnapshot(tabID: UUID, fields: [String: AgentPerfSnapshotValue]) {
        #if DEBUG
            let appFields: [String: Any] = fields.mapValues { value in
                switch value {
                case let .string(text): text
                case let .integer(number): number
                case let .unsigned(number): number
                case let .double(number): number
                case let .boolean(value): value
                case .null: NSNull()
                }
            }
            AgentModePerfDiagnostics.recordSessionSnapshot(tabID: tabID, fields: appFields)
        #endif
    }

    func recordCodexLifecyclePhase(
        _ phase: AgentPerfCodexLifecyclePhase,
        outcome: AgentPerfCodexLifecycleOutcome,
        startMS: Double?,
        tabID: UUID,
        transportGeneration: UInt64?
    ) {
        #if DEBUG
            guard let appPhase = AgentModePerfDiagnostics.CodexLifecyclePhase(rawValue: phase.rawValue),
                  let appOutcome = AgentModePerfDiagnostics.CodexLifecycleOutcome(rawValue: outcome.rawValue)
            else { return }
            AgentModePerfDiagnostics.recordCodexLifecyclePhase(
                appPhase,
                outcome: appOutcome,
                startMS: startMS,
                tabID: tabID,
                transportGeneration: transportGeneration
            )
        #endif
    }
}
