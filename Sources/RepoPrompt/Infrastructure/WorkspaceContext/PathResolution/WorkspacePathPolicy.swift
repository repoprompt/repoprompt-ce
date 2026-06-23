import Foundation

extension WorkspaceRootRef {
    var renderedLabel: String {
        "\(name) → \(fullPath)"
    }
}
