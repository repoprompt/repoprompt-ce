import Foundation

package extension DomainAgentSessionLinkAuthority {
    /// Every active link observed by any of `observerSessionIDs`, for read-only inventory
    /// (`session_admin links`/`tree`). Grants no authority: unlinking still goes through the exact
    /// `revoke(linkID:generation:)` owner path.
    func linkItems(forObservers observerSessionIDs: Set<UUID>) -> [DomainAgentSessionLinkInventoryItem] {
        observerSessionIDs
            .sorted { $0.uuidString < $1.uuidString }
            .flatMap { links(forObserver: $0).items }
    }
}
