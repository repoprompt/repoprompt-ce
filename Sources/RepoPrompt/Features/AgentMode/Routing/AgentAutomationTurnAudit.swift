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
    }

    static let retainedTurnLimit = 128

    var schemaVersion = 1
    let turnID: UUID
    let createdAt: Date
    var router: Feature
    var autoEffort: Feature
    /// Selection at local turn acceptance, not a provider-effective configuration.
    var acceptedProviderRaw: String?
    var acceptedModelRaw: String?
    var acceptedEffortRaw: String?
    /// A physical provider send was attempted; a later acceptance is recorded separately.
    var providerDispatchAttempted = false
    /// The provider accepted the user turn. This is not an effective-effort or billing receipt.
    var providerTurnAccepted = false

    static func retain(_ records: [Self]) -> [Self] {
        Array(records.suffix(retainedTurnLimit))
    }
}
