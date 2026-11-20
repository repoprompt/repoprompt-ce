import Foundation
import RepoPromptSettingsCore

enum CommandCenterTarget: Hashable {
    case session(CommandCenterSessionRow.ID)
    case draft(projectID: UUID?, draftID: UUID)
}

/// Presentation receipts never claim delivery after the exact owner stops being current.
struct CommandCenterSendReceipt {
    enum Outcome: Equatable { case sent, blocked, uncertain, needsOpen, chooseDestination, creationIncomplete }
    let outcome: Outcome
    let sessionID: CommandCenterSessionRow.ID?
    let message: String?
    var remainsCurrent: (@MainActor () -> Bool)?
}

@MainActor
final class CommandCenterSendCoordinator {
    struct Endpoint {
        let id: CommandCenterSessionRow.ID
        let isCurrent: () -> Bool
        let submit: (String) async -> AgentModeViewModel.UserTurnSubmissionResult
    }

    enum Creation {
        case ready(Endpoint)
        case incomplete(CommandCenterSessionRow.ID)
    }

    struct Environment {
        let isEnabled: () -> Bool
        let resolve: (CommandCenterSessionRow.ID) -> Endpoint?
        let destinations: (UUID) -> [Int]
        let create: (UUID, Int, AgentSessionLanePolicy.RoleSelection, [URL], String) async throws -> Creation
        var openDestination: ((UUID) async throws -> Int)?
        var createConfigured: ((UUID, Int, AgentSessionLanePolicy.RoleSelection, [URL], String, AgentComposerDraftState) async throws -> Creation)?
    }

    private let environment: Environment
    private var pending: Set<CommandCenterTarget> = []

    init(environment: Environment) {
        self.environment = environment
    }

    func send(
        target: CommandCenterTarget,
        text: String,
        windowID: Int?,
        selection: AgentSessionLanePolicy.RoleSelection?,
        attachments: [URL] = [],
        openIfNeeded: Bool = false,
        draftConfiguration: AgentComposerDraftState? = nil
    ) async -> CommandCenterSendReceipt {
        func receipt(
            _ outcome: CommandCenterSendReceipt.Outcome,
            _ message: String?,
            _ id: CommandCenterSessionRow.ID? = nil,
            proof: (@MainActor () -> Bool)? = nil
        ) -> CommandCenterSendReceipt {
            .init(outcome: outcome, sessionID: id, message: message, remainsCurrent: proof)
        }
        guard environment.isEnabled(), !Task.isCancelled else { return receipt(.blocked, "Command Center is disabled.") }
        guard pending.insert(target).inserted else { return receipt(.blocked, "This message is already being submitted.") }
        defer { pending.remove(target) }
        let endpoint: Endpoint
        switch target {
        case let .session(id):
            guard let resolved = environment.resolve(id), resolved.isCurrent() else {
                return receipt(.needsOpen, "No unique current session owner. Open the session in its workspace.")
            }
            endpoint = resolved
        case let .draft(projectID, _):
            guard let projectID else { return receipt(.blocked, "Choose a project before sending.") }
            var hosts = environment.destinations(projectID)
            if hosts.isEmpty, openIfNeeded, windowID == nil, let open = environment.openDestination {
                guard selection != nil else { return receipt(.blocked, "Choose a provider and model first.") }
                do {
                    let opened = try await open(projectID)
                    guard environment.isEnabled(), !Task.isCancelled,
                          environment.destinations(projectID).contains(opened) else { return receipt(.blocked, "The opened project changed before creation. Your draft is preserved.") }
                    hosts = [opened]
                } catch { return receipt(.blocked, "Open & Send: \(error.localizedDescription). Your draft is preserved.") }
            }
            guard !hosts.isEmpty else { return receipt(.needsOpen, "Open this project to send. Your draft is preserved.") }
            let destination: Int
            if let windowID, hosts.contains(windowID) { destination = windowID }
            else if windowID == nil, hosts.count == 1 { destination = hosts[0] }
            else { return receipt(.chooseDestination, "Choose an exact destination window before sending.") }
            guard let selection else { return receipt(.blocked, "Choose an available provider and model.") }
            do {
                let creation: Creation = if let draftConfiguration, let create = environment.createConfigured {
                    try await create(projectID, destination, selection, attachments, text, draftConfiguration)
                } else { try await environment.create(projectID, destination, selection, attachments, text) }
                switch creation {
                case let .ready(created): endpoint = created
                case let .incomplete(id):
                    return receipt(.creationIncomplete, "Session preparation did not finish. Open the project to inspect its retained identity; the draft is preserved.", id)
                }
            } catch let failure as AgentSessionLaneDestinationFailure {
                let reason: String = switch failure {
                case .destinationChanged: "The destination window closed or changed projects. No provider turn was sent."
                case let .admissionRejected(detail): detail.detail
                case let .creationRejected(detail), let .hostError(detail): String(detail.prefix(400))
                case .callerWindowHasNoWorkspace, .selectorMatchedNone, .selectorAmbiguous: "Choose an exact open project destination."
                }
                return receipt(.blocked, reason)
            } catch {
                return receipt(.blocked, "Session creation refused: \(error.localizedDescription)")
            }
        }
        guard environment.isEnabled(), !Task.isCancelled, endpoint.isCurrent() else {
            return receipt(.uncertain, "Destination changed. Open the session to confirm its state; do not resend automatically.", endpoint.id, proof: endpoint.isCurrent)
        }
        let result = await endpoint.submit(text)
        guard environment.isEnabled(), !Task.isCancelled, endpoint.isCurrent() else {
            return receipt(.uncertain, "Delivery uncertain: open the session to confirm before retrying.", endpoint.id, proof: endpoint.isCurrent)
        }
        switch result {
        case .submitted: return receipt(.sent, nil, endpoint.id, proof: endpoint.isCurrent)
        case let .blocked(message): return receipt(.blocked, message, endpoint.id, proof: endpoint.isCurrent)
        }
    }
}
