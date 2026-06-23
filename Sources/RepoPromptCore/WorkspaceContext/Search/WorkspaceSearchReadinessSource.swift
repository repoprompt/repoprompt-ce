import Foundation

package protocol WorkspaceSearchReadinessSource: AnyObject, Sendable {
    func awaitWorkspaceSearchReadiness(timeout: Duration) async throws -> WorkspaceSearchReadinessTicket
    func validateWorkspaceSearchReadinessSnapshot(_ ticket: WorkspaceSearchReadinessTicket) throws
}
