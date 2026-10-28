import Foundation

/// A provider follow-up and its separately typed, locally restorable draft. Provider text
/// may mix local and managed ACP steering; its contents never establish draft authorship.
struct AgentRunPendingInstruction: Equatable, ExpressibleByStringLiteral {
    let providerText: String
    let localDraftText: String?
    /// Retains the producer's original Stop generation across terminal follow-up handoffs.
    let stopFence: AgentRunStartStopFence?
    var skipsSlashExpansion: Bool

    init(providerText: String, localDraftText: String?, stopFence: AgentRunStartStopFence? = nil, skipsSlashExpansion: Bool = false) {
        self.providerText = providerText
        self.localDraftText = localDraftText
        self.stopFence = stopFence
        self.skipsSlashExpansion = skipsSlashExpansion
    }

    func retainingStopFence(_ fence: AgentRunStartStopFence) -> Self {
        Self(providerText: providerText, localDraftText: localDraftText, stopFence: fence, skipsSlashExpansion: skipsSlashExpansion)
    }

    init(stringLiteral value: String) {
        self.init(providerText: value, localDraftText: value)
    }

    static func providerOnly(_ text: String) -> Self {
        Self(providerText: text, localDraftText: nil)
    }
}
