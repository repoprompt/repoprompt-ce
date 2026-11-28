import Foundation

/// A provider follow-up and its separately typed, locally restorable draft. Provider text
/// may mix local and managed ACP steering; its contents never establish draft authorship.
package struct AgentRunPendingInstruction: Equatable, ExpressibleByStringLiteral {
    package let providerText: String
    package let localDraftText: String?
    /// Retains the producer's original Stop generation across terminal follow-up handoffs.
    package let stopFence: AgentRunStartStopFence?
    package var skipsSlashExpansion: Bool

    package init(providerText: String, localDraftText: String?, stopFence: AgentRunStartStopFence? = nil, skipsSlashExpansion: Bool = false) {
        self.providerText = providerText
        self.localDraftText = localDraftText
        self.stopFence = stopFence
        self.skipsSlashExpansion = skipsSlashExpansion
    }

    package func retainingStopFence(_ fence: AgentRunStartStopFence) -> Self {
        Self(providerText: providerText, localDraftText: localDraftText, stopFence: fence, skipsSlashExpansion: skipsSlashExpansion)
    }

    package init(stringLiteral value: String) {
        self.init(providerText: value, localDraftText: value)
    }

    package static func providerOnly(_ text: String) -> Self {
        Self(providerText: text, localDraftText: nil)
    }
}
