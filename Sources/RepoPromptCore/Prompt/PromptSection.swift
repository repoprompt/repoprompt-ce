import Foundation

/// All blocks that can appear in the final prompt, in logical order.
/// Raw values are persisted by the app, so they must remain stable.
public enum PromptSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case fileMap
    case fileContents
    case metaPrompts
    case userInstructions
    case gitDiff

    public var id: String {
        rawValue
    }
}
