import Foundation

package struct WorkspaceRuntimeID: Hashable, Codable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum WorkspaceRuntimeLifecycleState: String, Codable {
    case created
    case active
    case draining
    case removed
}

/// Strong, backend-neutral ownership of one selected workspace session.
///
/// This is deliberately narrower than ``WorkspaceSessionCommandIngress``: runtime ownership
/// does not expose observations, the mutable lifecycle owner, or the underlying session actor.
package struct WorkspaceRuntimeSessionHandle: @unchecked Sendable {
    package let sessionID: WorkspaceSessionID
    package let query: WorkspaceSessionQueryCapability

    private let currentSnapshotClosure: @Sendable () async -> WorkspaceSessionSnapshot?
    private let admitClosure: @Sendable () async -> WorkspaceSessionAdmissionResult
    private let executeClosure: @Sendable (WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult
    private let shutdownClosure: @Sendable () async -> Void

    package init(
        sessionID: WorkspaceSessionID,
        query: WorkspaceSessionQueryCapability,
        currentSnapshot: @escaping @Sendable () async -> WorkspaceSessionSnapshot?,
        admit: @escaping @Sendable () async -> WorkspaceSessionAdmissionResult,
        execute: @escaping @Sendable (WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.sessionID = sessionID
        self.query = query
        currentSnapshotClosure = currentSnapshot
        admitClosure = admit
        executeClosure = execute
        shutdownClosure = shutdown
    }

    package func currentSnapshot() async -> WorkspaceSessionSnapshot? {
        await currentSnapshotClosure()
    }

    package func admit() async -> WorkspaceSessionAdmissionResult {
        await admitClosure()
    }

    package func execute(_ envelope: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        await executeClosure(envelope)
    }

    package func shutdown() async {
        await shutdownClosure()
    }
}

package struct WorkspaceRuntimeAdmissionToken: Hashable, @unchecked Sendable {
    package let runtimeID: WorkspaceRuntimeID
    package let runtimeEpochID: UUID
    package let admissionID: UUID
    package let workspaceSessionToken: WorkspaceSessionAdmissionToken

    package init(
        runtimeID: WorkspaceRuntimeID,
        runtimeEpochID: UUID,
        admissionID: UUID,
        workspaceSessionToken: WorkspaceSessionAdmissionToken
    ) {
        self.runtimeID = runtimeID
        self.runtimeEpochID = runtimeEpochID
        self.admissionID = admissionID
        self.workspaceSessionToken = workspaceSessionToken
    }
}

/// A restricted, strongly retained runtime admitted for one exact lifecycle epoch.
///
/// It intentionally has no admission or shutdown operation. Command envelopes are rebound to
/// the captured Phase 5 token so a caller cannot exchange this admission for another session.
package struct WorkspaceAdmittedRuntimeSession: @unchecked Sendable, Equatable {
    package let admissionToken: WorkspaceRuntimeAdmissionToken
    package let query: WorkspaceSessionQueryCapability

    private let handle: WorkspaceRuntimeSessionHandle

    package var runtimeID: WorkspaceRuntimeID {
        admissionToken.runtimeID
    }

    package var sessionID: WorkspaceSessionID {
        admissionToken.workspaceSessionToken.sessionID
    }

    package var workspaceSessionToken: WorkspaceSessionAdmissionToken {
        admissionToken.workspaceSessionToken
    }

    package init(
        admissionToken: WorkspaceRuntimeAdmissionToken,
        handle: WorkspaceRuntimeSessionHandle
    ) {
        self.admissionToken = admissionToken
        query = handle.query
        self.handle = handle
    }

    package func currentSnapshot() async -> WorkspaceSessionSnapshot? {
        guard let snapshot = await handle.currentSnapshot(), snapshot.sessionID == sessionID else {
            return nil
        }
        return snapshot
    }

    package func execute(_ envelope: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        await handle.execute(
            WorkspaceSessionCommandEnvelope(
                commandID: envelope.commandID,
                admissionToken: workspaceSessionToken,
                expectedGeneration: envelope.expectedGeneration,
                command: envelope.command,
                source: envelope.source
            )
        )
    }

    package static func == (
        lhs: WorkspaceAdmittedRuntimeSession,
        rhs: WorkspaceAdmittedRuntimeSession
    ) -> Bool {
        lhs.admissionToken == rhs.admissionToken
    }
}

package struct WorkspaceRuntimeLifecycleSnapshot: Equatable, @unchecked Sendable {
    package let runtimeID: WorkspaceRuntimeID
    package let sessionID: WorkspaceSessionID
    package let state: WorkspaceRuntimeLifecycleState
    package let runtimeEpochID: UUID?
    package let activeAdmissionCount: Int
    package let issuedAdmissionCount: Int
    package let releasedAdmissionCount: Int
    package let duplicateReleaseCount: Int
    package let foreignReleaseCount: Int
    package let shutdownInvocationCount: Int
    package let drainDuration: Duration?
}

package enum WorkspaceRuntimeRegistrationResult: Equatable {
    case registered
    case duplicateRuntimeID
    case duplicateLiveSession
}

package enum WorkspaceRuntimeActivationResult: Equatable {
    case activated
    case alreadyActive
    case runtimeNotFound
    case invalidState(WorkspaceRuntimeLifecycleState)
    case sessionMismatch
    case activationMismatch
}

package enum WorkspaceRuntimeAdmissionFailure: Equatable {
    case runtimeNotFound
    case notActive(WorkspaceRuntimeLifecycleState)
    case sessionUnavailable(WorkspaceSessionAvailability)
    case sessionMismatch
    case activationMismatch
    case lifecycleChanged
}

package enum WorkspaceRuntimeAdmissionResult: @unchecked Sendable, Equatable {
    case admitted(WorkspaceAdmittedRuntimeSession)
    case unavailable(WorkspaceRuntimeAdmissionFailure)
}

package enum WorkspaceRuntimeReleaseResult: Equatable {
    case released(remainingAdmissionCount: Int)
    case releasedAndRemoved
    case duplicate
    case foreign
}

package enum WorkspaceRuntimeDrainResult: Equatable {
    case draining(activeAdmissionCount: Int)
    case removed
    case runtimeNotFound
}
