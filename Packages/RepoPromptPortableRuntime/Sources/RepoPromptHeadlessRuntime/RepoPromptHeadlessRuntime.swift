import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

public enum HeadlessRuntimeError: Error, Equatable, Sendable {
    case providerRuntimeUnavailable
    case workspaceCapabilitiesUnavailable
}

public actor RepoPromptHeadlessRuntime {
    private let workspace: WorkspaceRuntime
    private let turnRuntime: AgentTurnRuntime?
    private let workspaceCapabilities: WorkspaceCapabilityRuntime?
    private var agents: [RuntimeOwnerID: AgentRuntime] = [:]

    public init(workspace: WorkspaceRuntime = WorkspaceRuntime()) {
        self.workspace = workspace
        turnRuntime = nil
        workspaceCapabilities = nil
    }

    public init(
        workspace: WorkspaceRuntime = WorkspaceRuntime(),
        settingsProvider: any ProviderTurnSettingsProviding,
        provider: any ProviderTurnExecuting,
        filesystem: any WorkspaceFilesystemPort,
        worktrees: any WorkspaceWorktreePort,
        artifacts: any WorkspaceArtifactPort,
        projectSources: any WorkspaceProjectSourcePort,
        clock: any RuntimeClock = SystemRuntimeClock(),
        idGenerator: any RuntimeIDGenerator = SystemRuntimeIDGenerator()
    ) {
        self.workspace = workspace
        turnRuntime = AgentTurnRuntime(
            settingsProvider: settingsProvider,
            provider: provider,
            clock: clock,
            idGenerator: idGenerator
        )
        workspaceCapabilities = WorkspaceCapabilityRuntime(
            authority: workspace,
            filesystem: filesystem,
            worktrees: worktrees,
            artifacts: artifacts,
            projectSources: projectSources
        )
    }

    public func registerOwner(_ ownerID: RuntimeOwnerID) async throws {
        try await workspace.registerOwner(ownerID)
        if agents[ownerID] == nil {
            agents[ownerID] = AgentRuntime(ownerID: ownerID) { [workspace] reference, requestedBy in
                try await workspace.authorize(reference, requestedBy: requestedBy)
            }
        }
    }

    public func removeOwner(_ ownerID: RuntimeOwnerID) async {
        agents.removeValue(forKey: ownerID)
        await workspace.removeOwner(ownerID)
    }

    public func attach(
        _ resourceID: RuntimeResourceID,
        to ownerID: RuntimeOwnerID
    ) async throws -> OwnedResourceReference {
        do {
            return try await workspace.attach(resourceID, to: ownerID)
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func detach(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws {
        do {
            try await workspace.detach(reference, requestedBy: ownerID)
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func validate(_ workflow: WorkflowDefinition, for ownerID: RuntimeOwnerID) async throws {
        guard let agent = agents[ownerID] else {
            throw AuthorityError.ownerUnavailable(ownerID)
        }
        do {
            try await agent.validateAccess(for: workflow)
        } catch let error as AgentRuntimeError {
            switch error {
            case let .resourceUnavailable(reference):
                throw AuthorityError.resourceUnavailable(reference)
            }
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    @discardableResult
    public func execute(_ request: AgentTurnRequest) async throws -> PreparedProviderTurn {
        guard let agent = agents[request.ownerID] else {
            throw AuthorityError.ownerUnavailable(request.ownerID)
        }
        do {
            try await agent.validateAccess(for: request.workflow)
            guard let turnRuntime else {
                throw HeadlessRuntimeError.providerRuntimeUnavailable
            }
            return try await turnRuntime.prepareAndExecute(request)
        } catch let error as AgentRuntimeError {
            switch error {
            case let .resourceUnavailable(reference):
                throw AuthorityError.resourceUnavailable(reference)
            }
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func readFile(
        _ reference: OwnedResourceReference,
        path: WorkspaceRelativePath,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceFileSnapshot {
        guard let workspaceCapabilities else {
            throw HeadlessRuntimeError.workspaceCapabilitiesUnavailable
        }
        return try await workspaceCapabilities.readFile(reference, path: path, requestedBy: ownerID)
    }

    private nonisolated static func authorityError(from error: WorkspaceRuntimeError) -> AuthorityError {
        switch error {
        case let .ownerUnavailable(ownerID):
            .ownerUnavailable(ownerID)
        case let .resourceUnavailable(reference):
            .resourceUnavailable(reference)
        case let .staleGrant(grant):
            .staleGrant(grant)
        case .generationExhausted:
            .resourceGenerationExhausted
        }
    }
}

// PR 2 intentionally provides no authority-store implementation or local
// committed-projection reducer. Concrete persistence and proposal/application
// behavior are owned by later Server slices.
