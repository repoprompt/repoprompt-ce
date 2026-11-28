import Foundation

/// The existing bounded retained recovery policy. Both publishers hand it the same
/// identity and claim; only a presenter supplies a projection rollback.
@MainActor
enum WorkspaceAgentAdmissionRecoveryRetention {
    @MainActor
    struct Adapters {
        typealias Operation = @MainActor @Sendable () async -> AgentAdmissionRetainedRecoverySettlement

        let attempt: () async -> AgentAdmissionRecoveryOutcome
        let retryUnderLease: () async throws -> AgentAdmissionRecoveryOutcome
        let retain: (AgentAdmissionRetainedRecoveryStart, @escaping Operation) -> Void
        var rollbackProjection: () async -> Void = {}
        var recordBlocked: (WorkspacePersistenceFailureCategory, Int) -> Void = { _, _ in }
        var didRecover: (AgentAdmissionRecoveryOutcome) async -> Void = { _ in }
        var waitBeforeRetry: (Int, AgentAdmissionRecoveryOutcome) async -> Void = { attempt, _ in
            await WorkspaceAgentAdmissionRecoveryRetention.waitBeforeRetry(attempt: attempt)
        }
    }

    static func settle(
        claim: AgentProvisionalAdmissionClaim, adapters: Adapters
    ) async -> AgentAdmissionRecoveryOutcome {
        let outcome = await adapters.attempt()
        let start: AgentAdmissionRetainedRecoveryStart
        let initial: AgentAdmissionRecoveryOutcome
        switch outcome {
        case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
            return outcome
        case .retryablePartial:
            (start, initial) = (.automatic, outcome)
        case let .failed(category) where category.isRetryableAgentAdmissionRecoveryFailure:
            (start, initial) = (.automatic, outcome)
        case let .failed(category), let .blockedManual(category):
            claim.markBlockedForManualRecovery(category)
            adapters.recordBlocked(category, 0)
            (start, initial) = (.blockedManual(category), .blockedManual(category))
        }
        adapters.retain(start) {
            await retry(claim: claim, initial: initial, adapters: adapters)
        }
        return initial
    }

    static func waitBeforeRetry(attempt: Int) async {
        let exponent = min(attempt, 4)
        let delayMilliseconds = min(2000, 100 * (1 << exponent))
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
    }

    private static func retry(
        claim: AgentProvisionalAdmissionClaim, initial: AgentAdmissionRecoveryOutcome, adapters: Adapters
    ) async -> AgentAdmissionRetainedRecoverySettlement {
        if case .blockedManual = claim.state, !claim.resumeBlockedWorkspaceRecovery() {
            return .blockedManual(.durabilityUncertain)
        }
        var prior = initial
        for attempt in 0 ..< 4 {
            await adapters.waitBeforeRetry(attempt, prior)
            let outcome: AgentAdmissionRecoveryOutcome
            do {
                outcome = try await adapters.retryUnderLease()
            } catch {
                prior = .failed(.durabilityUncertain)
                continue
            }
            switch outcome {
            case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
                if outcome != .ownershipChanged { claim.markWorkspaceRecovered() }
                claim.markComplete()
                await adapters.rollbackProjection()
                await adapters.didRecover(outcome)
                return .complete(outcome)
            case .retryablePartial:
                await adapters.rollbackProjection()
                prior = outcome
            case let .failed(category) where category.isRetryableAgentAdmissionRecoveryFailure:
                prior = outcome
            case let .failed(category), let .blockedManual(category):
                return await markBlocked(category, attempts: attempt + 1, claim: claim, adapters: adapters)
            }
        }
        let category: WorkspacePersistenceFailureCategory = switch prior {
        case let .failed(category), let .blockedManual(category): category
        default: .durabilityUncertain
        }
        return await markBlocked(category, attempts: 4, claim: claim, adapters: adapters)
    }

    private static func markBlocked(
        _ category: WorkspacePersistenceFailureCategory, attempts: Int,
        claim: AgentProvisionalAdmissionClaim, adapters: Adapters
    ) async -> AgentAdmissionRetainedRecoverySettlement {
        claim.markBlockedForManualRecovery(category)
        adapters.recordBlocked(category, attempts)
        await adapters.didRecover(.blockedManual(category))
        return .blockedManual(category)
    }
}
