import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The oversight read boundary must be the *canonical* user-visible projection: archived plus
/// working rows in stable order, taken from the runtime transcript and the projection builder.
///
/// It must never be the target window's presentation state, whose row set changes when the target's
/// user expands compressed history or when a load degrades collapsed blocks.
@MainActor
final class AgentSessionLinkCanonicalTranscriptTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFullTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("request \(index)", sequenceIndex: index * 3)
        let thinking = AgentChatItem.thinking("private \(index)", sequenceIndex: index * 3 + 1)
        let assistant = AgentChatItem.assistant("response \(index)", sequenceIndex: index * 3 + 2)
        return AgentTranscriptTurn(
            id: UUID(),
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt.addingTimeInterval(1),
                    completedAt: startedAt.addingTimeInterval(1),
                    activities: [
                        AgentTranscriptActivity(from: thinking),
                        AgentTranscriptActivity(from: assistant)
                    ]
                )
            ],
            retentionTier: .full,
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(1),
            completedAt: startedAt.addingTimeInterval(1)
        )
    }

    private func makeArchivedTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("archived request \(index)", sequenceIndex: index * 3)
        return AgentTranscriptTurn(
            id: UUID(),
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [],
            retentionTier: .archived,
            summary: AgentTranscriptTurnSummary(
                middleSummaryItemID: UUID(),
                requestText: "archived request \(index)",
                conclusionText: "archived conclusion \(index)",
                compactConclusionText: "archived conclusion \(index)",
                middleSummaryText: "archived middle summary \(index)",
                toolCount: 2,
                notableToolNames: ["apply_edits"],
                keyPaths: ["/Users/monitored/secret.swift"],
                compactedActivityCount: 5,
                hadWarning: false,
                hadError: false,
                lastUserInteractionAt: startedAt
            ),
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(1),
            completedAt: startedAt.addingTimeInterval(1)
        )
    }

    // MARK: - Canonical projection

    func testCanonicalProjectionIncludesArchivedAndWorkingRowsInStableOrder() {
        let transcript = AgentTranscript(
            turns: [makeArchivedTurn(index: 0), makeFullTurn(index: 1), makeFullTurn(index: 2)],
            nextSequenceIndex: 9
        )
        let canonical = AgentModeViewModel.canonicalTranscript(from: transcript, sourceItemsRevision: 7)

        XCTAssertFalse(canonical.rows.isEmpty)
        XCTAssertEqual(canonical.sourceItemsRevision, 7)
        XCTAssertEqual(
            canonical.rows.map(\.sequenceIndex),
            canonical.rows.map(\.sequenceIndex).sorted(),
            "Rows must arrive in stable sequence order for cursor anchoring to be meaningful"
        )
        // Archived history is part of the canonical conversation, independent of any reveal toggle.
        XCTAssertTrue(canonical.rows.contains { $0.text.contains("archived request 0") })
        XCTAssertTrue(canonical.rows.contains { $0.text.contains("request 1") })
        XCTAssertTrue(canonical.rows.contains { $0.text.contains("response 2") })
        XCTAssertTrue(canonical.summaryRowIDs.isSubset(of: Set(canonical.rows.map(\.id))))
    }

    func testEmptyTranscriptProducesAnEmptyCanonicalProjection() {
        let canonical = AgentModeViewModel.canonicalTranscript(from: .empty, sourceItemsRevision: nil)
        XCTAssertTrue(canonical.rows.isEmpty)
        XCTAssertTrue(canonical.summaryRowIDs.isEmpty)
        XCTAssertNil(canonical.sourceItemsRevision)
    }

    func testSanitizedPageOverTheCanonicalProjectionDropsThinkingAndKeepsNarrative() {
        let transcript = AgentTranscript(turns: [makeFullTurn(index: 0)], nextSequenceIndex: 3)
        let canonical = AgentModeViewModel.canonicalTranscript(from: transcript, sourceItemsRevision: 1)
        let page = AgentSessionLinkTranscriptSanitizer.page(
            rows: canonical.rows,
            summaryRowIDs: canonical.summaryRowIDs,
            anchor: nil,
            direction: .start,
            maxItems: 100,
            maxOutputBytes: 20000
        )
        XCTAssertFalse(page.items.contains { $0.text?.contains("private 0") == true })
        XCTAssertTrue(page.items.contains { $0.role == .user && $0.text == "request 0" })
        XCTAssertTrue(page.items.contains { $0.role == .assistant && $0.text == "response 0" })
    }

    // MARK: - Role policy

    func testOutboundMonitoringEligibilityComesFromTheToolPolicyCatalog() {
        // A user-driven session has no MCP control context, so it is `.direct`.
        XCTAssertEqual(AgentSessionLinkToolPolicy.role(for: nil), .direct)
        XCTAssertEqual(AgentSessionLinkToolPolicy.role(for: .explore), .explore)
        XCTAssertEqual(AgentSessionLinkToolPolicy.role(for: .engineer), .engineer)
        XCTAssertEqual(AgentSessionLinkToolPolicy.role(for: .pair), .engineer)
        XCTAssertEqual(AgentSessionLinkToolPolicy.role(for: .design), .engineer)

        XCTAssertTrue(AgentSessionLinkToolPolicy.allowsOutboundMonitoring(taskLabelKind: nil))
        // Explore is tool-denied, so Monitor must not promise it can observe anything.
        XCTAssertFalse(AgentSessionLinkToolPolicy.allowsOutboundMonitoring(taskLabelKind: .explore))
    }

    func testRoleDeniedObserverCannotAddMonitors() {
        let denied = AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: true,
            hasLoadedPersistedState: true,
            isChildSession: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            bindingTransitionInProgress: false,
            isClosing: false
        )
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.addDisabledReason(denied, roleAllowsOutboundMonitoring: false),
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        )
        XCTAssertNil(
            AgentSessionLinkEndpointEligibility.addDisabledReason(denied, roleAllowsOutboundMonitoring: true)
        )
    }
}
