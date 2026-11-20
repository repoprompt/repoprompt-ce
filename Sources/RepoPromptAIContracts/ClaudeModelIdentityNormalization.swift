import Foundation

package func normalizedClaudeCodeModelIdentitySpecifier(_ specifier: String) -> String {
    specifier
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}
