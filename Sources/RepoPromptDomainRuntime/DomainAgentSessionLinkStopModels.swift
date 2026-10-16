import Foundation

/// One immutable answer for a stop request within a link generation.
package struct DomainAgentSessionLinkStopReceipt: Hashable, Sendable {
    package let requestID: UUID
    package let targetSessionID: UUID
    package let result: Result
    package let failureReason: FailureReason?
    package let stopRequested: Bool?
    package let teardownCompleted: Bool?
    package let targetItemID: String?
    package let auditStatus: AuditStatus
    package let resultingRunState: String?
    package let settledAt: Date
    package let duplicate: Bool

    package init(
        requestID: UUID,
        targetSessionID: UUID,
        result: Result,
        failureReason: FailureReason? = nil,
        stopRequested: Bool?,
        teardownCompleted: Bool? = nil,
        targetItemID: String? = nil,
        auditStatus: AuditStatus,
        resultingRunState: String? = nil,
        settledAt: Date,
        duplicate: Bool = false
    ) {
        self.requestID = requestID
        self.targetSessionID = targetSessionID
        self.result = result
        self.failureReason = failureReason
        self.stopRequested = stopRequested
        self.teardownCompleted = teardownCompleted
        self.targetItemID = targetItemID
        self.auditStatus = auditStatus
        self.resultingRunState = resultingRunState
        self.settledAt = settledAt
        self.duplicate = duplicate
    }

    package func markedDuplicate() -> Self {
        Self(
            requestID: requestID,
            targetSessionID: targetSessionID,
            result: result,
            failureReason: failureReason,
            stopRequested: stopRequested,
            teardownCompleted: teardownCompleted,
            targetItemID: targetItemID,
            auditStatus: auditStatus,
            resultingRunState: resultingRunState,
            settledAt: settledAt,
            duplicate: true
        )
    }

    package enum Result: String, Hashable, Sendable {
        case stopped
        case notRunning = "not_running"
        case stopFailed = "stop_failed"
    }

    package enum FailureReason: String, Hashable, Sendable {
        case targetChanged = "target_changed"
        case cancellationUnconfirmed = "cancellation_unconfirmed"
        case terminalPublicationRejected = "terminal_publication_rejected"
        case terminalPublicationStale = "terminal_publication_stale"
        case teardownTimeout = "teardown_timeout"
    }

    package enum AuditStatus: String, Hashable, Sendable {
        case notRequired = "not_required"
        case persisted
        case failed
        case unknown
    }
}

/// Stop uses the existing shared send reservation and ledger limits, but never returns a send receipt.
package enum DomainAgentSessionLinkStopReservationDisposition: Equatable, Sendable {
    case reserved(DomainAgentSessionLinkSendReservation)
    case duplicate(DomainAgentSessionLinkStopReceipt)
    case inProgress
    case indeterminate
    case conflict
    case inFlightLimitReached
    case retainedOutcomeLimitReached
    case rejected(DomainAgentSessionLinkError)
}
