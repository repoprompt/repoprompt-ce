import CryptoKit
import Foundation
import MCP

/// Canonical digest of an administration call's operation arguments, so a batch confirmation card
/// authorizes exactly the arguments the user saw rather than any arguments sent under the same key.
///
/// Excluded keys are the ones bound separately or that only select *which* call this is: target
/// selectors (`targets`, `session_id`, `filter`), the scope (`scope_id`), the operation (`op`), the
/// dry-run flag (`preview`), and the retry/approval handles (`idempotency_key`, `confirmation_id`).
/// Everything else (new names, groups, model IDs, worktree settings, ...) is bound.
package enum DomainDelegationScopeArgumentsDigest {
    package static let excludedKeys: Set<String> = [
        "op", "targets", "session_id", "filter", "scope_id", "preview", "idempotency_key", "confirmation_id"
    ]

    /// Lowercase hex SHA-256 of the sorted-key JSON encoding of the bound arguments.
    package static func digest(_ arguments: [String: Value]) -> String {
        let bound = arguments.filter { !excludedKeys.contains($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Value.object(bound))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
