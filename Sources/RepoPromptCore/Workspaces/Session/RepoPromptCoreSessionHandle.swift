import Foundation

package struct RepoPromptCoreSessionHandle: WorkspaceSessionCommandIngress {
    package let sessionID: WorkspaceSessionID
    package let query: WorkspaceSessionQueryCapability

    private let snapshotClosure: @Sendable () async -> WorkspaceSessionSnapshot?
    private let observationsClosure: @Sendable (UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot>
    private let admitClosure: @Sendable () async -> WorkspaceSessionAdmissionResult
    private let executeClosure: @Sendable (WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult
    private let capturePromptClosure: @Sendable (
        WorkspaceSessionAdmissionToken,
        PromptFactualCaptureRequest
    ) async -> PromptFactualCaptureOutcome
    private let shutdownClosure: @Sendable () async -> Void

    package init(
        constructionKey _: RepoPromptCoreSessionHandleConstructionKey,
        sessionID: WorkspaceSessionID,
        query: WorkspaceSessionQueryCapability,
        currentSnapshot: @escaping @Sendable () async -> WorkspaceSessionSnapshot?,
        observations: @escaping @Sendable (UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot>,
        admit: @escaping @Sendable () async -> WorkspaceSessionAdmissionResult,
        execute: @escaping @Sendable (WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult,
        capturePrompt: @escaping @Sendable (
            WorkspaceSessionAdmissionToken,
            PromptFactualCaptureRequest
        ) async -> PromptFactualCaptureOutcome,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.sessionID = sessionID
        self.query = query
        snapshotClosure = currentSnapshot
        observationsClosure = observations
        admitClosure = admit
        executeClosure = execute
        capturePromptClosure = capturePrompt
        shutdownClosure = shutdown
    }

    package func currentSnapshot() async -> WorkspaceSessionSnapshot? {
        await snapshotClosure()
    }

    package func observations(after sequence: UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot> {
        await observationsClosure(sequence)
    }

    package func admit() async -> WorkspaceSessionAdmissionResult {
        await admitClosure()
    }

    package func execute(_ command: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        await executeClosure(command)
    }

    package func capturePromptFactualContext(
        admission: WorkspaceSessionAdmissionToken,
        request: PromptFactualCaptureRequest
    ) async -> PromptFactualCaptureOutcome {
        await capturePromptClosure(admission, request)
    }

    package func shutdown() async {
        await shutdownClosure()
    }

    package func runtimeSessionHandle() -> WorkspaceRuntimeSessionHandle {
        WorkspaceRuntimeSessionHandle(
            sessionID: sessionID,
            query: query,
            currentSnapshot: snapshotClosure,
            admit: admitClosure,
            execute: executeClosure,
            shutdown: shutdownClosure
        )
    }
}
