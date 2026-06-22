import RepoPromptCore

struct LegacyPromptFactualContextProvider: PromptFactualContextProviding {
    let backend: LegacyWorkspaceSessionBackend

    func capture(
        _ request: PromptFactualCaptureRequest,
        admission suppliedAdmission: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome {
        let admission: WorkspaceSessionAdmissionToken
        if let suppliedAdmission {
            admission = suppliedAdmission
        } else if case let .admitted(current) = await backend.admit() {
            admission = current
        } else {
            return .unavailable(.notReady)
        }
        return await backend.capturePromptFactualContext(admission: admission, request: request)
    }
}
