import Foundation

/// Local, non-content evidence for one accepted user turn. `turnID` is the existing
/// transcript request ID (and Claude usage turn ID), not an exported analytics ID.
struct AgentAutomationTurnAudit: Codable, Equatable {
    enum Decision: String, Codable {
        case disabled
        case ineligible
        case unavailable
        case selected
        case fallback
    }

    enum Application: String, Codable {
        case notObserved
        /// A provider control call returned, but this is not proof of effective effort.
        case controlAccepted
        /// The provider accepted a turn. For Model Router this does not independently
        /// prove the selected target was effective; for Codex Auto effort the sent
        /// argument is revalidated at turn/start.
        case turnAccepted
        case fallbackToManual
        case failed
    }

    struct Feature: Codable, Equatable {
        var configured: Bool
        var eligible: Bool
        var judgmentRequested: Bool
        var decision: Decision
        /// Non-content Jev choice, not proof of what the provider used.
        var chosenModelRaw: String?
        var chosenEffortRaw: String?
        /// A judged choice was replaced by a deterministic/manual fallback, including effort-only fallback.
        var fallbackApplied = false
        var application: Application = .notObserved

        func discardedAfterMCPReclassification() -> Self {
            var result = self
            if result.decision == .selected {
                result.fallbackApplied = true
                result.application = .fallbackToManual
            }
            return result
        }
    }

    enum CodexDelivery: String, Codable {
        case start
        case steer
        case queuedFallback
        case fallbackStart
        case managedAuthReplay
    }

    static let retainedTurnLimit = 128

    var schemaVersion = 2
    let turnID: UUID
    let createdAt: Date
    var router: Feature
    var autoEffort: Feature
    /// Local selection, updated with the physical effort argument when a provider accepts a start.
    /// This is never proof of effective effort or billing.
    var acceptedProviderRaw: String?
    var acceptedModelRaw: String?
    var acceptedEffortRaw: String?
    /// A physical provider send was attempted; a later acceptance is recorded separately.
    var providerDispatchAttempted = false
    /// The provider accepted the user turn. This is not an effective-effort or billing receipt.
    var providerTurnAccepted = false
    /// Codex's last observed delivery path. A queued fallback is local durability, not provider acceptance.
    var codexDelivery: CodexDelivery?

    mutating func recordCodexQueuedFallback() {
        codexDelivery = .queuedFallback
    }

    mutating func recordCodexDispatch(_ delivery: CodexDelivery) {
        codexDelivery = delivery
        providerDispatchAttempted = true
    }

    mutating func recordCodexStartAccepted(effortRaw: String?, autoEffortApplied: Bool) {
        providerTurnAccepted = true
        acceptedEffortRaw = effortRaw
        if router.decision == .selected {
            router.application = .turnAccepted
        }
        if autoEffort.decision == .selected {
            autoEffort.application = autoEffortApplied ? .turnAccepted : .fallbackToManual
            autoEffort.fallbackApplied = !autoEffortApplied
        }
    }

    mutating func recordCodexSteerAccepted() {
        // A steer accepts content into an existing turn; it does not apply a new model selection.
        providerTurnAccepted = true
    }

    mutating func recordClaudeTurnAccepted(autoEffortRaw: String?, manualEffortRaw: String) {
        providerTurnAccepted = true
        acceptedEffortRaw = autoEffortRaw ?? manualEffortRaw
        if router.decision == .selected {
            router.application = .turnAccepted
        }
        if autoEffort.decision == .selected {
            if autoEffortRaw != nil, autoEffort.application == .controlAccepted {
                autoEffort.application = .turnAccepted
            } else {
                autoEffort.application = .fallbackToManual
                autoEffort.fallbackApplied = true
            }
        }
    }

    static func retain(_ records: [Self]) -> [Self] {
        Array(records.suffix(retainedTurnLimit))
    }
}
