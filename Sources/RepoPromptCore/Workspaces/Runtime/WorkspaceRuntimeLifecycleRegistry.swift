import Foundation

package actor WorkspaceRuntimeLifecycleRegistry {
    private struct Record {
        let runtimeID: WorkspaceRuntimeID
        let sessionHandle: WorkspaceRuntimeSessionHandle
        var state: WorkspaceRuntimeLifecycleState = .created
        var runtimeEpochID: UUID?
        var activeAdmissions: [UUID: WorkspaceRuntimeAdmissionToken] = [:]
        var issuedAdmissions: [UUID: WorkspaceRuntimeAdmissionToken] = [:]
        var releasedAdmissionIDs: Set<UUID> = []
        var duplicateReleaseCount = 0
        var foreignReleaseCount = 0
        var shutdownInvocationCount = 0
        var drainStartedAt: ContinuousClock.Instant?
        var drainDuration: Duration?
        var finalizationStarted = false
        var removalWaiters: [CheckedContinuation<Void, Never>] = []

        var snapshot: WorkspaceRuntimeLifecycleSnapshot {
            WorkspaceRuntimeLifecycleSnapshot(
                runtimeID: runtimeID,
                sessionID: sessionHandle.sessionID,
                state: state,
                runtimeEpochID: runtimeEpochID,
                activeAdmissionCount: activeAdmissions.count,
                issuedAdmissionCount: issuedAdmissions.count,
                releasedAdmissionCount: releasedAdmissionIDs.count,
                duplicateReleaseCount: duplicateReleaseCount,
                foreignReleaseCount: foreignReleaseCount,
                shutdownInvocationCount: shutdownInvocationCount,
                drainDuration: drainDuration
            )
        }
    }

    private let clock = ContinuousClock()
    private var records: [WorkspaceRuntimeID: Record] = [:]

    package init() {}

    package func register(
        runtimeID: WorkspaceRuntimeID,
        sessionHandle: WorkspaceRuntimeSessionHandle
    ) -> WorkspaceRuntimeRegistrationResult {
        guard records[runtimeID] == nil else { return .duplicateRuntimeID }
        guard !records.values.contains(where: {
            $0.state != .removed && $0.sessionHandle.sessionID == sessionHandle.sessionID
        }) else {
            return .duplicateLiveSession
        }
        records[runtimeID] = Record(runtimeID: runtimeID, sessionHandle: sessionHandle)
        return .registered
    }

    package func activate(
        runtimeID: WorkspaceRuntimeID,
        initialAdmission: WorkspaceSessionAdmissionToken
    ) -> WorkspaceRuntimeActivationResult {
        guard var record = records[runtimeID] else { return .runtimeNotFound }
        guard initialAdmission.sessionID == record.sessionHandle.sessionID else {
            return .sessionMismatch
        }
        switch record.state {
        case .created:
            record.runtimeEpochID = initialAdmission.activationID
            record.state = .active
            records[runtimeID] = record
            return .activated
        case .active:
            guard record.runtimeEpochID == initialAdmission.activationID else {
                return .activationMismatch
            }
            return .alreadyActive
        case .draining, .removed:
            return .invalidState(record.state)
        }
    }

    package func admit(runtimeID: WorkspaceRuntimeID) async -> WorkspaceRuntimeAdmissionResult {
        guard let record = records[runtimeID] else {
            return .unavailable(.runtimeNotFound)
        }
        guard record.state == .active else {
            return .unavailable(.notActive(record.state))
        }
        guard let expectedEpochID = record.runtimeEpochID else {
            return .unavailable(.lifecycleChanged)
        }
        let handle = record.sessionHandle
        let sessionResult = await handle.admit()

        guard var current = records[runtimeID] else {
            return .unavailable(.lifecycleChanged)
        }
        guard current.state == .active,
              current.runtimeEpochID == expectedEpochID,
              !current.finalizationStarted
        else {
            return .unavailable(.lifecycleChanged)
        }
        guard case let .admitted(sessionToken) = sessionResult else {
            if case let .notReady(availability) = sessionResult {
                return .unavailable(.sessionUnavailable(availability))
            }
            return .unavailable(.lifecycleChanged)
        }
        guard sessionToken.sessionID == handle.sessionID else {
            return .unavailable(.sessionMismatch)
        }
        guard sessionToken.activationID == expectedEpochID else {
            return .unavailable(.activationMismatch)
        }

        let admissionID = UUID()
        let token = WorkspaceRuntimeAdmissionToken(
            runtimeID: runtimeID,
            runtimeEpochID: expectedEpochID,
            admissionID: admissionID,
            workspaceSessionToken: sessionToken
        )
        current.activeAdmissions[admissionID] = token
        current.issuedAdmissions[admissionID] = token
        records[runtimeID] = current
        return .admitted(
            WorkspaceAdmittedRuntimeSession(admissionToken: token, handle: handle)
        )
    }

    package func release(
        _ admissionToken: WorkspaceRuntimeAdmissionToken
    ) async -> WorkspaceRuntimeReleaseResult {
        guard var record = records[admissionToken.runtimeID] else { return .foreign }
        guard record.runtimeEpochID == admissionToken.runtimeEpochID,
              admissionToken.workspaceSessionToken.sessionID == record.sessionHandle.sessionID,
              admissionToken.workspaceSessionToken.activationID == admissionToken.runtimeEpochID
        else {
            record.foreignReleaseCount += 1
            records[admissionToken.runtimeID] = record
            return .foreign
        }
        guard record.issuedAdmissions[admissionToken.admissionID] == admissionToken else {
            record.foreignReleaseCount += 1
            records[admissionToken.runtimeID] = record
            return .foreign
        }
        guard record.activeAdmissions.removeValue(forKey: admissionToken.admissionID) != nil else {
            record.duplicateReleaseCount += 1
            records[admissionToken.runtimeID] = record
            return .duplicate
        }
        record.releasedAdmissionIDs.insert(admissionToken.admissionID)
        let remaining = record.activeAdmissions.count
        records[admissionToken.runtimeID] = record

        if record.state == .draining, remaining == 0 {
            await finalizeIfNeeded(runtimeID: admissionToken.runtimeID)
            return .releasedAndRemoved
        }
        return .released(remainingAdmissionCount: remaining)
    }

    package func beginDraining(
        runtimeID: WorkspaceRuntimeID
    ) async -> WorkspaceRuntimeDrainResult {
        guard var record = records[runtimeID] else { return .runtimeNotFound }
        switch record.state {
        case .created, .active:
            record.state = .draining
            record.drainStartedAt = clock.now
            let activeCount = record.activeAdmissions.count
            records[runtimeID] = record
            if activeCount == 0 {
                await finalizeIfNeeded(runtimeID: runtimeID)
                return .removed
            }
            return .draining(activeAdmissionCount: activeCount)
        case .draining:
            if record.activeAdmissions.isEmpty {
                if record.finalizationStarted {
                    records[runtimeID] = record
                    await waitUntilRemoved(runtimeID: runtimeID)
                    return .removed
                }
                await finalizeIfNeeded(runtimeID: runtimeID)
                return .removed
            }
            return .draining(activeAdmissionCount: record.activeAdmissions.count)
        case .removed:
            return .removed
        }
    }

    package func waitUntilRemoved(runtimeID: WorkspaceRuntimeID) async {
        guard var record = records[runtimeID], record.state != .removed else { return }
        await withCheckedContinuation { continuation in
            record.removalWaiters.append(continuation)
            records[runtimeID] = record
        }
    }

    package func snapshot(
        runtimeID: WorkspaceRuntimeID
    ) -> WorkspaceRuntimeLifecycleSnapshot? {
        records[runtimeID]?.snapshot
    }

    package func purgeRemoved(runtimeID: WorkspaceRuntimeID) -> Bool {
        guard records[runtimeID]?.state == .removed else { return false }
        records.removeValue(forKey: runtimeID)
        return true
    }

    package func liveRuntimeCount() -> Int {
        records.values.count(where: { $0.state != .removed })
    }

    private func finalizeIfNeeded(runtimeID: WorkspaceRuntimeID) async {
        guard var record = records[runtimeID],
              record.state == .draining,
              record.activeAdmissions.isEmpty,
              !record.finalizationStarted
        else { return }
        record.finalizationStarted = true
        record.shutdownInvocationCount += 1
        let handle = record.sessionHandle
        let epochID = record.runtimeEpochID
        records[runtimeID] = record

        await handle.shutdown()

        guard var finalized = records[runtimeID],
              finalized.state == .draining,
              finalized.runtimeEpochID == epochID
        else { return }
        finalized.state = .removed
        if let drainStartedAt = finalized.drainStartedAt {
            finalized.drainDuration = drainStartedAt.duration(to: clock.now)
        }
        let waiters = finalized.removalWaiters
        finalized.removalWaiters.removeAll()
        records[runtimeID] = finalized
        waiters.forEach { $0.resume() }
    }
}
