import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Operation-time observer capability re-checks, and redaction of the agent-facing status preview.
///
/// A grant is created against an eligible observer, but eligibility is not frozen at creation. These
/// tests pin the two ways that can go wrong: a session that keeps its endpoint identity while losing
/// the capability, and a status snapshot that carries model-generated prose straight to an observer.
@MainActor
final class AgentSessionLinkObserverCapabilityTests: XCTestCase {
    // MARK: - Eligibility classification

    private func input(
        hasDurableBinding: Bool = true,
        hasLoadedPersistedState: Bool = true,
        isChildSession: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        bindingTransitionInProgress: Bool = false,
        isClosing: Bool = false
    ) -> AgentSessionLinkEndpointEligibility.Input {
        AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: hasDurableBinding,
            hasLoadedPersistedState: hasLoadedPersistedState,
            isChildSession: isChildSession,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing
        )
    }

    func testPermanentCapabilityLossDisqualifiesTheObserver() {
        let disqualifying: [(String, AgentSessionLinkEndpointEligibility.Input, Bool)] = [
            ("mcp controlled", input(isMCPControlled: true), true),
            ("mcp originated", input(isMCPOriginated: true), true),
            ("child session", input(isChildSession: true), true),
            ("closing", input(isClosing: true), true),
            ("role denied", input(), false)
        ]
        for (label, value, roleAllows) in disqualifying {
            XCTAssertEqual(
                AgentSessionLinkEndpointEligibility.observerOperationEligibility(
                    value,
                    roleAllowsOutboundMonitoring: roleAllows
                ),
                .disqualified,
                label
            )
        }
    }

    func testMomentaryStatesDenyWithoutDestroyingTheGrant() {
        // Revoking here would tear down a healthy link every time a thread reloads or rebinds.
        for (label, value) in [
            ("rebinding", input(bindingTransitionInProgress: true)),
            ("hydrating", input(hasLoadedPersistedState: false)),
            ("unbound", input(hasDurableBinding: false))
        ] {
            XCTAssertEqual(
                AgentSessionLinkEndpointEligibility.observerOperationEligibility(
                    value,
                    roleAllowsOutboundMonitoring: true
                ),
                .transientlyUnavailable,
                label
            )
        }
    }

    func testFullyEligibleObserverProceeds() {
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.observerOperationEligibility(
                input(),
                roleAllowsOutboundMonitoring: true
            ),
            .eligible
        )
    }

    func testDisqualifiedObserverIsAlsoBlockedFromAddingNewLinks() {
        // The Add gate and the operation-time gate must not disagree about the same session.
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                input(isMCPControlled: true),
                roleAllowsOutboundMonitoring: true
            ),
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        )
    }

    // MARK: - Redacted status preview

    func testAssistantPreviewIsRedactedBeforeTheByteCap() throws {
        let home = "/Users/monitored"
        let items = [
            AgentChatItem.assistant("older", sequenceIndex: 0),
            AgentChatItem.assistant(
                "Deployed with Authorization: Bearer abc123def456ghi from \(home)/projects/app",
                sequenceIndex: 1
            )
        ]
        let preview = try XCTUnwrap(
            AgentModeViewModel.latestVisibleAssistantPreview(items: items, homeDirectory: home)
        )
        XCTAssertFalse(preview.contains("abc123def456ghi"))
        XCTAssertFalse(preview.contains(home))
        XCTAssertTrue(preview.contains(AgentSessionLinkTextRedactor.placeholder))
        XCTAssertTrue(preview.contains("~/projects/app"))
    }

    func testPreviewRedactionSurvivesTheDomainSnapshotCap() throws {
        let home = "/Users/monitored"
        // A secret placed past the 280-byte preview cap: redacting after capping would leave a
        // truncated credential fragment the redactor never inspected.
        let filler = String(repeating: "a", count: 400)
        let items = [
            AgentChatItem.assistant("\(filler) api_key=sk-abcdefghijklmnopqrstuvwx", sequenceIndex: 0)
        ]
        let preview = try XCTUnwrap(
            AgentModeViewModel.latestVisibleAssistantPreview(items: items, homeDirectory: home)
        )
        XCTAssertFalse(preview.contains("sk-abcdefghijklmnopqrstuvwx"))

        let snapshot = DomainAgentSessionObservationSnapshot(
            sessionID: UUID(),
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            status: .running,
            idleForSend: false,
            pendingInteractionKind: nil,
            latestVisibleAssistantPreview: preview,
            visibleRowCount: 1,
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let capped = try XCTUnwrap(snapshot.latestVisibleAssistantPreview)
        XCTAssertLessThanOrEqual(
            capped.utf8.count,
            DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
        )
        XCTAssertFalse(capped.contains("sk-"))
    }

    // MARK: - Status projection contract

    private func makeStatusCandidate(tabID: UUID) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: 1,
            workspaceID: UUID(),
            tabID: tabID,
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main"
        )
    }

    /// The narrow UI projection and the agent-facing snapshot must never disagree about state.
    ///
    /// They are separate code paths for cost reasons only, so this pins them together across the
    /// states an Oversee row actually distinguishes.
    func testNarrowStatusProjectionMatchesTheFullSnapshotAcrossStates() {
        let mutations: [(String, (AgentModeViewModel.TabSession) -> Void)] = [
            ("idle", { _ in }),
            ("running", { $0.runState = .running }),
            ("completed is still idle", { $0.runState = .completed }),
            ("failed is still idle", { $0.runState = .failed }),
            ("waiting for user", { $0.runState = .waitingForUser }),
            ("waiting for approval", { $0.runState = .waitingForApproval }),
            ("waiting for question", { $0.runState = .waitingForQuestion })
        ]
        for (label, mutate) in mutations {
            let tabID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            mutate(session)
            let candidate = makeStatusCandidate(tabID: tabID)

            let projection = AgentModeViewModel.statusProjection(for: session)
            let snapshot = AgentModeViewModel.observationSnapshot(for: session, candidate: candidate)

            XCTAssertEqual(projection.status, snapshot.status, label)
            XCTAssertEqual(projection.pendingInteractionKind, snapshot.pendingInteractionKind, label)
            XCTAssertEqual(projection.lastActivityAt, snapshot.lastActivityAt, label)
            XCTAssertEqual(
                AgentMonitorLinkStatus(
                    status: projection.status,
                    pendingInteraction: projection.pendingInteractionKind
                ),
                AgentMonitorLinkStatus(
                    status: snapshot.status,
                    pendingInteraction: snapshot.pendingInteractionKind
                ),
                label
            )
        }
    }

    func testStatusProjectionIgnoresTranscriptContentEntirely() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.runState = .running
        let baseline = AgentModeViewModel.statusProjection(for: session)

        // Transcript churn is the high-frequency event on a streaming target. It must not change,
        // or cost, anything the status projection reads.
        session.items = (0 ..< 200).map {
            AgentChatItem.assistant("chunk \($0) api_key=sk-abcdefghijklmnopqrstuvwx", sequenceIndex: $0)
        }
        XCTAssertEqual(AgentModeViewModel.statusProjection(for: session), baseline)
    }

    func testStreamingAndNonAssistantRowsAreNeverPreviewed() {
        var streaming = AgentChatItem.assistant("partial secret token=abcdefghijklmnop", sequenceIndex: 2)
        streaming.isStreaming = true
        let items = [
            AgentChatItem.assistant("settled answer", sequenceIndex: 0),
            AgentChatItem.thinking("private deliberation", sequenceIndex: 1),
            streaming,
            AgentChatItem.toolResult(
                name: "git",
                argsJSON: nil,
                resultJSON: #"{"token":"abcdefghijklmnop"}"#,
                isError: false,
                sequenceIndex: 3
            )
        ]
        XCTAssertEqual(
            AgentModeViewModel.latestVisibleAssistantPreview(items: items, homeDirectory: "/Users/monitored"),
            "settled answer"
        )
    }
}
