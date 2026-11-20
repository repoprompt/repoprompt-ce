import Foundation

/// Immutable paths captured for one admitted request. This does not elect a writer, refresh
/// a workspace, or authorize a send; native owners retain their own Stop/attempt/controller fences.
@MainActor
struct AgentProviderLaunchInput {
    let origin: AgentSessionRuntimeStore.Command
    private let stopFence: AgentRunStartStopFence
    private let codex: Result<CodexRuntimeWorkspacePaths, Error>
    private let claude: String?
    private let workspace: AgentRunWorkspaceInput
    private let bindings: [AgentSessionWorktreeBinding]
    private let resourcesAreCurrent: @MainActor () -> Bool
    private let validateResources: (@MainActor () async -> Bool)?
    private var inputSources: [AgentSessionProviderInputRuntime.WorkspaceSource] = []

    init(
        origin: AgentSessionRuntimeStore.Command,
        workspace: AgentRunWorkspaceInput, bindings: [AgentSessionWorktreeBinding],
        resourcesAreCurrent: @escaping @MainActor () -> Bool,
        validateResources: (@MainActor () async -> Bool)? = nil
    ) throws {
        self.origin = origin
        stopFence = AgentRunStartStopFence(session: origin.writer.session)
        self.workspace = workspace
        self.bindings = bindings
        // Codex also validates the logical launch directory. Capture that result without
        // imposing Codex-only launch requirements on Claude's execution-directory request.
        codex = Result {
            try AgentWorktreeRuntimeWorkspaceResolver.codexRuntimeWorkspacePaths(
                bindings: bindings, fallbackWorkspacePath: workspace.fallbackWorkspacePath
            )
        }
        claude = try workspace.resolve(bindings: bindings)
        self.resourcesAreCurrent = resourcesAreCurrent
        self.validateResources = validateResources
    }

    func isCurrent(for session: AgentTabSession) -> Bool {
        origin.writer.session === session && !Task.isCancelled && stopFence.permitsStart(of: session)
            && (try? origin.requireCurrent()) != nil && resourcesAreCurrent()
            && inputSources.allSatisfy { $0.isCurrent() }
    }

    func validate(for session: AgentTabSession) async -> Bool {
        guard isCurrent(for: session) else { return false }
        if let validateResources, await !validateResources() { return false }
        guard isCurrent(for: session) else { return false }
        for source in inputSources {
            guard await source.validate(), isCurrent(for: session) else { return false }
        }
        return isCurrent(for: session)
    }

    func retainingInputSources(_ sources: [AgentSessionProviderInputRuntime.WorkspaceSource]) -> Self {
        var captured = self
        captured.inputSources += sources
        return captured
    }

    func codexWorkspacePaths(for session: AgentTabSession) throws -> CodexRuntimeWorkspacePaths {
        guard isCurrent(for: session) else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let captured = try codex.get()
        guard try AgentWorktreeRuntimeWorkspaceResolver.codexRuntimeWorkspacePaths(
            bindings: bindings, fallbackWorkspacePath: workspace.fallbackWorkspacePath
        ) == captured else { throw AgentHostWorkspaceResources.Failure.rootsChanged }
        return captured
    }

    func claudeWorkspacePath(for session: AgentTabSession) throws -> String? {
        guard isCurrent(for: session) else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        guard try workspace.resolve(bindings: bindings) == claude else { throw AgentHostWorkspaceResources.Failure.rootsChanged }
        return claude
    }
}
