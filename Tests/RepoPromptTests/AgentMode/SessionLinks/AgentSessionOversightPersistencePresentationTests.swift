import Foundation
@testable import RepoPromptApp
import XCTest

/// The durable-oversight level a user actually sees, and the rule that a failed save never renders
/// as success.
///
/// These are pure model assertions on purpose: the overlay is a function of `(published projection,
/// live eligibility, process-wide persistence level)`, and pinning it here keeps it testable without
/// building a window.
final class AgentSessionOversightPersistencePresentationTests: XCTestCase {
    private func eligibleInput() -> AgentSessionLinkEndpointEligibility.Input {
        AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: true,
            hasLoadedPersistedState: true,
            isChildSession: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            bindingTransitionInProgress: false,
            isClosing: false
        )
    }

    private func loadingInput() -> AgentSessionLinkEndpointEligibility.Input {
        var input = eligibleInput()
        input.hasLoadedPersistedState = false
        return input
    }

    // MARK: - Add blocker composition

    func testAPersistenceBlockerDisablesAddOnAnOtherwiseEligibleSession() {
        let props = AgentModeViewModel.monitorPillProps(
            sessionID: UUID(),
            published: nil,
            eligibility: eligibleInput(),
            roleAllowsOutboundMonitoring: true,
            persistence: AgentSessionOversightPersistencePresentation(
                availability: .blocked(AgentSessionOversightPersistenceCopy.futureSchema)
            )
        )

        XCTAssertFalse(props.canAdd)
        XCTAssertEqual(props.canAddReason, AgentSessionOversightPersistenceCopy.futureSchema)
    }

    /// Persistence wins over eligibility: telling a user to load a thread when the real problem is a
    /// preserved manifest sends them to fix the wrong thing.
    func testThePersistenceBlockerTakesPrecedenceOverTheLiveEligibilityReason() {
        let props = AgentModeViewModel.monitorPillProps(
            sessionID: UUID(),
            published: nil,
            eligibility: loadingInput(),
            roleAllowsOutboundMonitoring: true,
            persistence: AgentSessionOversightPersistencePresentation(availability: .suppressed)
        )

        XCTAssertEqual(props.canAddReason, AgentSessionOversightPersistenceCopy.suppressedLaunch)
    }

    func testEligibilityStillDisablesAddWhenPersistenceIsReady() {
        let props = AgentModeViewModel.monitorPillProps(
            sessionID: UUID(),
            published: nil,
            eligibility: loadingInput(),
            roleAllowsOutboundMonitoring: true,
            persistence: AgentSessionOversightPersistencePresentation(availability: .ready)
        )

        XCTAssertEqual(props.canAddReason, "Load this thread before adding sessions to oversee.")
    }

    /// A dormant launch still saves explicit work, so Add stays enabled and only an informational
    /// notice is shown.
    func testDormantLaunchExplainsItselfWithoutDisablingAdd() {
        let presentation = AgentSessionOversightPersistencePresentation(availability: .dormant)
        let props = AgentModeViewModel.monitorPillProps(
            sessionID: UUID(),
            published: nil,
            eligibility: eligibleInput(),
            roleAllowsOutboundMonitoring: true,
            persistence: presentation
        )

        XCTAssertTrue(props.canAdd)
        XCTAssertEqual(
            props.persistence.noticeMessage,
            AgentSessionOversightPersistenceCopy.autoRestoreDisabled
        )
    }

    /// A link-free tab receives no authority projection at all, so the overlay is the only way the
    /// store's state reaches it.
    func testALinkFreeProjectionStillCarriesTheProcessWidePersistenceLevel() {
        let presentation = AgentSessionOversightPersistencePresentation(availability: .loading)
        let props = AgentMonitorPillProps.empty.withPersistence(
            presentation,
            eligibilityReason: AgentMonitorPillProps.empty.canAddReason
        )

        XCTAssertEqual(props.persistence.availability, .loading)
        XCTAssertEqual(props.canAddReason, AgentSessionOversightPersistenceCopy.loading)
    }

    // MARK: - Warnings

    func testWarningsAreDeduplicatedByIdentityAndCappedOldestFirst() {
        var presentation = AgentSessionOversightPersistencePresentation(availability: .ready)
        for index in 0 ..< (AgentSessionOversightPersistencePresentation.maxWarnings + 2) {
            presentation.appendWarning(id: "warning.\(index)", message: "Message \(index)")
        }

        XCTAssertEqual(
            presentation.warnings.count,
            AgentSessionOversightPersistencePresentation.maxWarnings
        )
        XCTAssertEqual(presentation.warnings.first?.id, "warning.2", "The cap drops oldest first.")

        let changed = presentation.appendWarning(id: "warning.6", message: "Message 6")
        XCTAssertFalse(changed, "An identical repeat must not repaint every window.")
        XCTAssertEqual(
            presentation.warnings.count,
            AgentSessionOversightPersistencePresentation.maxWarnings
        )
    }

    /// Dismiss clears the message, never the obligation: the disk work is still owed and **Retry
    /// saving** is how the user asks for it.
    func testDismissClearsWarningsButNotPendingCleanup() {
        var presentation = AgentSessionOversightPersistencePresentation(availability: .ready)
        presentation.appendWarning(
            id: AgentSessionOversightWarningID.cleanupFailed,
            message: AgentSessionOversightPersistenceCopy.automaticCleanupFailed
        )
        presentation.hasPendingCleanupRetry = true

        let changed = presentation.dismissWarnings(
            ids: [AgentSessionOversightWarningID.cleanupFailed]
        )

        XCTAssertTrue(changed)
        XCTAssertTrue(presentation.warnings.isEmpty)
        XCTAssertTrue(presentation.hasPendingCleanupRetry)
    }

    /// Aggregate copy is broadcast to every window, so it must never carry a session name or UUID.
    func testAggregateCopyCarriesNoIdentifiers() {
        let messages = [
            AgentSessionOversightPersistenceCopy.loading,
            AgentSessionOversightPersistenceCopy.suppressedLaunch,
            AgentSessionOversightPersistenceCopy.autoRestoreDisabled,
            AgentSessionOversightPersistenceCopy.futureSchema,
            AgentSessionOversightPersistenceCopy.unreadable,
            AgentSessionOversightPersistenceCopy.quarantined,
            AgentSessionOversightPersistenceCopy.terminalRestorationSummary,
            AgentSessionOversightPersistenceCopy.automaticCleanupFailed,
            AgentSessionOversightPersistenceCopy.shutdownBeforeInsert,
            AgentSessionOversightPersistenceCopy.shutdownAfterInsert
        ]
        let uuidPattern = try? NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            let range = NSRange(message.startIndex ..< message.endIndex, in: message)
            XCTAssertNil(uuidPattern?.firstMatch(in: message, range: range), "Copy leaked an identifier: \(message)")
        }
    }

    // MARK: - Stop outcome

    /// A Stop that could not commit its durable removal must never render as success.
    func testFailedStopOutcomeCarriesAUserFacingMessage() {
        let failed = AgentMonitorStopOutcome.failed(
            message: AgentSessionOversightPersistenceCopy.stopWriteFailed
        )

        XCTAssertEqual(failed.failureMessage, AgentSessionOversightPersistenceCopy.stopWriteFailed)
        XCTAssertNil(AgentMonitorStopOutcome.stopped.failureMessage)
        XCTAssertNil(AgentMonitorStopOutcome.alreadyStopped.failureMessage)
    }
}
