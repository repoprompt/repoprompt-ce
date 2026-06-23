import RepoPromptCore

struct CorePromptFactualContextProvider: PromptFactualContextProviding {
    let handle: RepoPromptCoreSessionHandle

    func capture(
        _ request: PromptFactualCaptureRequest,
        admission suppliedAdmission: WorkspaceSessionAdmissionToken?
    ) async -> PromptFactualCaptureOutcome {
        let admission: WorkspaceSessionAdmissionToken
        if let suppliedAdmission {
            admission = suppliedAdmission
        } else if case let .admitted(current) = await handle.admit() {
            admission = current
        } else {
            return .unavailable(.notReady)
        }
        return await handle.capturePromptFactualContext(admission: admission, request: request)
    }
}
