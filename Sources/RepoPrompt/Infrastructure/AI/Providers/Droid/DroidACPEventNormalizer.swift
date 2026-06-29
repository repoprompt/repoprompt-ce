import Foundation

/// Event normalizer for Droid ACP sessions.
///
/// Delegates to the generic ACP default session update normalizer. Custom
/// Droid-specific event classification can be added here when needed.
enum DroidACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .droid)
    }
}
