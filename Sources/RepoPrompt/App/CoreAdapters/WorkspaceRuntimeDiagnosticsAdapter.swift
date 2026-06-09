import RepoPromptCore

@inline(__always)
func withEmbeddedWorkspaceRuntimeDiagnostics<T>(
    _ operation: () async throws -> T
) async rethrows -> T {
    try await WorkspaceRuntimePerf.withLifecycleCorrelation(
        id: EditFlowPerf.currentLifecycleCorrelation?.id,
        operation: operation
    )
}
