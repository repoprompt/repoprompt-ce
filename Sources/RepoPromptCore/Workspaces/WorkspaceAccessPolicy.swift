import Foundation

/// Host-level admission policy for workspace roots.
///
/// The embedded app keeps its existing unrestricted behavior; the future standalone
/// host supplies a fail-closed implementation when Item 6 lands.
@MainActor
package protocol WorkspaceAccessPolicy: AnyObject {
    func allowsWorkspaceRoot(_ url: URL) -> Bool
}

@MainActor
package final class UnrestrictedWorkspaceAccessPolicy: WorkspaceAccessPolicy {
    package init() {}

    package func allowsWorkspaceRoot(_ url: URL) -> Bool {
        _ = url
        return true
    }
}
