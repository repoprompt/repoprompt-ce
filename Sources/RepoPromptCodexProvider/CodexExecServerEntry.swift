import Foundation

/// Existing Codex configuration entry identity, captured before the broken-server cache await.
// Keep the checked package-boundary contract explicit for this shared identity value.
// swiftformat:disable:next redundantSendable
package struct CodexExecServerEntry: Equatable, Sendable {
    package let rawName: String
    package let normalizedName: String
    package let cliPathComponent: String

    package init(rawName: String, normalizedName: String, cliPathComponent: String) {
        self.rawName = rawName
        self.normalizedName = normalizedName
        self.cliPathComponent = cliPathComponent
    }
}
