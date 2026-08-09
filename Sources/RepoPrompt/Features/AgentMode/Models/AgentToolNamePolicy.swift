import Foundation

/// Bounds untrusted provider tool names before any normalization or display work.
enum AgentToolNamePolicy {
    /// Tool names are identifiers, not payloads. This keeps all downstream work bounded while
    /// leaving ample room for namespaced MCP and provider tool names.
    static let maximumUTF8Length = 512
    static let fallbackName = "tool"

    static func accepted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let inspectedLength = raw.utf8.prefix(maximumUTF8Length + 1).count
        return inspectedLength <= maximumUTF8Length ? raw : nil
    }
}
