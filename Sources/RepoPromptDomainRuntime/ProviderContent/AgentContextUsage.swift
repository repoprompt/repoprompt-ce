import Foundation

package struct AgentContextUsage: Codable, Equatable {
    package var modelContextWindow: Int?
    package var lastTotalTokens: Int?
    package var totalTotalTokens: Int?
    /// Optional for backward-compatible decoding of older usage snapshots; nil means not pending.
    package var awaitingPostCompactionUsage: Bool? = nil
    package init(
        modelContextWindow: Int? = nil,
        lastTotalTokens: Int? = nil,
        totalTotalTokens: Int? = nil,
        awaitingPostCompactionUsage: Bool? = nil
    ) {
        self.modelContextWindow = modelContextWindow
        self.lastTotalTokens = lastTotalTokens
        self.totalTotalTokens = totalTotalTokens
        self.awaitingPostCompactionUsage = awaitingPostCompactionUsage
    }
}
