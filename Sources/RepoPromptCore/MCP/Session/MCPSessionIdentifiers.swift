import Foundation

package struct RepoPromptSessionID: Hashable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Process-lifetime routing identity. Production allocators must never reuse a value.
package struct MCPRoutingSessionID: Hashable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
}
