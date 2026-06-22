@testable import RepoPrompt
@testable import RepoPromptCore

/// Deterministic root-test adapter for fixtures that intentionally construct app surfaces
/// without a hydrated Phase 5 session. Production composition never uses this type.
struct TestPromptFactualContextProvider: PromptFactualContextProviding {
    let store: WorkspaceFileContextStore

    func capture(
        _ request: PromptFactualCaptureRequest,
        admission _: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome {
        let first = await PromptFactualContextCaptureService.capture(request: request, store: store)
        guard case .unavailable(.staleGeneration) = first else { return first }
        return await PromptFactualContextCaptureService.capture(request: request, store: store)
    }
}
