import RepoPromptCore

protocol PromptFactualContextProviding: Sendable {
    func capture(
        _ request: PromptFactualCaptureRequest,
        admission: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome
}

struct UnavailablePromptFactualContextProvider: PromptFactualContextProviding {
    func capture(_: PromptFactualCaptureRequest, admission _: WorkspaceSessionAdmissionToken?) async -> PromptFactualCaptureOutcome {
        .unavailable(.notReady)
    }
}

actor DeferredPromptFactualContextProvider: PromptFactualContextProviding {
    private var target: (any PromptFactualContextProviding)?

    func bind(_ target: any PromptFactualContextProviding) {
        precondition(self.target == nil, "selected factual provider may be bound only once")
        self.target = target
    }

    func capture(
        _ request: PromptFactualCaptureRequest,
        admission: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome {
        guard let target else { return .unavailable(.notReady) }
        return await target.capture(request, admission: admission)
    }
}
