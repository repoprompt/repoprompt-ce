import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Fail-closed resolution, endpoint eligibility, and guarded Copy Session ID.
///
/// Resolution is a pure decision over a candidate set, so the "exactly one live eligible top-level
/// match" rule is exercised here without constructing windows.
final class AgentSessionLinkEndpointResolverTests: XCTestCase {
    // MARK: - Fixtures

    private func makeCandidate(
        windowID: Int = 1,
        workspaceID: UUID = UUID(),
        tabID: UUID = UUID(),
        sessionID: UUID = UUID(),
        persistentBindingGeneration: UUID? = UUID(),
        bindingTransitionGeneration: UInt64 = 0,
        isTopLevel: Bool = true,
        hasLoadedPersistedState: Bool = true,
        bindingTransitionInProgress: Bool = false,
        isClosing: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        roleAllowsOutboundMonitoring: Bool = true,
        displayName: String? = "Build API",
        providerDisplayName: String? = "Codex CLI",
        locationLabel: String? = "worktree/feature",
        isDeletionInProgress: Bool = false
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration,
            isTopLevel: isTopLevel,
            hasLoadedPersistedState: hasLoadedPersistedState,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            roleAllowsOutboundMonitoring: roleAllowsOutboundMonitoring,
            displayName: displayName,
            providerDisplayName: providerDisplayName,
            locationLabel: locationLabel,
            isDeletionInProgress: isDeletionInProgress
        )
    }

    // MARK: - Parsing

    func testParsesOnlyCanonicalUUIDs() {
        let sessionID = UUID()
        XCTAssertEqual(
            AgentSessionLinkEndpointResolver.parseSessionID("  \(sessionID.uuidString)\n"),
            sessionID
        )
        // Short aliases and routing URLs are rejected by construction, not by a later check.
        XCTAssertNil(AgentSessionLinkEndpointResolver.parseSessionID(String(sessionID.uuidString.prefix(8))))
        XCTAssertNil(AgentSessionLinkEndpointResolver.parseSessionID("repoprompt://session/\(sessionID.uuidString)"))
        XCTAssertNil(AgentSessionLinkEndpointResolver.parseSessionID(""))
    }

    // MARK: - Resolution

    func testResolvesExactlyOneLiveTopLevelMatch() throws {
        let target = makeCandidate()
        let other = makeCandidate()
        let resolved = try AgentSessionLinkEndpointResolver
            .resolve(sessionID: target.sessionID, candidates: [other, target])
            .get()
        XCTAssertEqual(resolved, target)
    }

    func testUnknownSessionIsNotFound() {
        let failure = AgentSessionLinkEndpointResolver
            .resolve(sessionID: UUID(), candidates: [makeCandidate()])
            .failure
        XCTAssertEqual(failure, .notFound)
    }

    func testDuplicateBindingsAreAmbiguousAndNeverSilentlyChosen() {
        let sessionID = UUID()
        let inWindowOne = makeCandidate(windowID: 1, sessionID: sessionID)
        let inWindowTwo = makeCandidate(windowID: 2, sessionID: sessionID)
        let failure = AgentSessionLinkEndpointResolver
            .resolve(sessionID: sessionID, candidates: [inWindowOne, inWindowTwo])
            .failure
        XCTAssertEqual(failure, .ambiguous)
    }

    func testDisqualifiersResolveToTheirSpecificReason() {
        let cases: [(AgentSessionLinkEndpointCandidate, AgentSessionLinkResolveFailure)] = [
            (makeCandidate(isTopLevel: false), .childSession),
            (makeCandidate(isClosing: true), .closing),
            (makeCandidate(bindingTransitionInProgress: true), .rebinding),
            (makeCandidate(hasLoadedPersistedState: false), .loading),
            (makeCandidate(persistentBindingGeneration: nil), .bindingUnresolved)
        ]
        for (candidate, expected) in cases {
            let failure = AgentSessionLinkEndpointResolver
                .resolve(sessionID: candidate.sessionID, candidates: [candidate])
                .failure
            XCTAssertEqual(failure, expected, "expected \(expected) for candidate")
            XCTAssertFalse(expected.uiMessage.isEmpty)
        }
    }

    func testChildSessionReasonWinsOverOtherDisqualifiers() {
        // Ordering matters: the most specific, most actionable reason must win so the popover never
        // says "still loading" for a session that can never be overseen at all.
        let candidate = makeCandidate(
            isTopLevel: false,
            hasLoadedPersistedState: false,
            bindingTransitionInProgress: true,
            isClosing: true
        )
        XCTAssertEqual(
            AgentSessionLinkEndpointResolver
                .resolve(sessionID: candidate.sessionID, candidates: [candidate])
                .failure,
            .childSession
        )
    }

    func testTargetFailureHelperAndResolverShareOrderedPrecedence() throws {
        let cases: [(String, AgentSessionLinkEndpointCandidate, AgentSessionLinkResolveFailure?)] = [
            (
                "child",
                makeCandidate(
                    persistentBindingGeneration: nil,
                    isTopLevel: false,
                    hasLoadedPersistedState: false,
                    bindingTransitionInProgress: true,
                    isClosing: true,
                    isDeletionInProgress: true
                ),
                .childSession
            ),
            (
                "closing",
                makeCandidate(
                    persistentBindingGeneration: nil,
                    hasLoadedPersistedState: false,
                    bindingTransitionInProgress: true,
                    isClosing: true,
                    isDeletionInProgress: true
                ),
                .closing
            ),
            (
                "deletion",
                makeCandidate(
                    persistentBindingGeneration: nil,
                    hasLoadedPersistedState: false,
                    bindingTransitionInProgress: true,
                    isDeletionInProgress: true
                ),
                .closing
            ),
            (
                "rebinding",
                makeCandidate(
                    persistentBindingGeneration: nil,
                    hasLoadedPersistedState: false,
                    bindingTransitionInProgress: true
                ),
                .rebinding
            ),
            (
                "loading",
                makeCandidate(persistentBindingGeneration: nil, hasLoadedPersistedState: false),
                .loading
            ),
            ("binding", makeCandidate(persistentBindingGeneration: nil), .bindingUnresolved),
            ("eligible", makeCandidate(), nil)
        ]

        for (name, candidate, expected) in cases {
            XCTAssertEqual(
                AgentSessionLinkEndpointEligibility.targetResolveFailure(for: candidate),
                expected,
                name
            )
            let resolution = AgentSessionLinkEndpointResolver.resolve(
                sessionID: candidate.sessionID,
                candidates: [candidate]
            )
            if let expected {
                XCTAssertEqual(resolution.failure, expected, name)
            } else {
                XCTAssertEqual(try resolution.get(), candidate, name)
            }
        }
    }

    func testResolverOwnsAmbiguityBeforeCandidateLocalTargetEligibility() {
        let sessionID = UUID()
        let eligible = makeCandidate(windowID: 1, sessionID: sessionID)
        let child = makeCandidate(windowID: 2, sessionID: sessionID, isTopLevel: false)

        XCTAssertNil(AgentSessionLinkEndpointEligibility.targetResolveFailure(for: eligible))
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.targetResolveFailure(for: child),
            .childSession
        )
        XCTAssertEqual(
            AgentSessionLinkEndpointResolver.resolve(
                sessionID: sessionID,
                candidates: [eligible, child]
            ).failure,
            .ambiguous
        )
    }

    // MARK: - Eligibility

    func testTargetEligibilityIgnoresOutboundToolDisqualifiers() {
        // Being observed grants a target nothing, so an MCP-controlled or MCP-originated session is
        // still a valid target even though it can never be an observer.
        let candidate = makeCandidate(isMCPControlled: true, isMCPOriginated: true)
        XCTAssertTrue(AgentSessionLinkEndpointEligibility.isEligibleTarget(candidate.eligibilityInput))
        XCTAssertNotNil(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                candidate.eligibilityInput,
                roleAllowsOutboundMonitoring: true
            )
        )
    }

    func testTargetEligibilityRejectsEveryLifecycleDisqualifier() {
        for candidate in [
            makeCandidate(persistentBindingGeneration: nil),
            makeCandidate(hasLoadedPersistedState: false),
            makeCandidate(isTopLevel: false),
            makeCandidate(bindingTransitionInProgress: true),
            makeCandidate(isClosing: true)
        ] {
            XCTAssertFalse(
                AgentSessionLinkEndpointEligibility.isEligibleTarget(candidate.eligibilityInput),
                "ineligible target accepted"
            )
        }
    }

    func testObserverEligibilityAllowsPlainUserDrivenSession() {
        let candidate = makeCandidate()
        XCTAssertNil(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                candidate.eligibilityInput,
                roleAllowsOutboundMonitoring: true
            )
        )
    }

    func testObserverEligibilityReasonsAreSpecificAndOrdered() {
        let closing = makeCandidate(hasLoadedPersistedState: false, isClosing: true, isMCPControlled: true)
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                closing.eligibilityInput,
                roleAllowsOutboundMonitoring: true
            ),
            "This session is closing."
        )

        let unbound = makeCandidate(persistentBindingGeneration: nil)
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                unbound.eligibilityInput,
                roleAllowsOutboundMonitoring: true
            ),
            AgentSessionLinkEndpointEligibility.noDurableBindingReason
        )

        let roleDenied = makeCandidate()
        XCTAssertEqual(
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                roleDenied.eligibilityInput,
                roleAllowsOutboundMonitoring: false
            ),
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        )
    }

    func testChildAndMCPObserversShareOneIndistinguishableRoleReason() {
        for candidate in [
            makeCandidate(isTopLevel: false),
            makeCandidate(isMCPControlled: true),
            makeCandidate(isMCPOriginated: true)
        ] {
            XCTAssertEqual(
                AgentSessionLinkEndpointEligibility.addDisabledReason(
                    candidate.eligibilityInput,
                    roleAllowsOutboundMonitoring: true
                ),
                AgentSessionLinkEndpointEligibility.roleDeniedReason
            )
        }
    }

    // MARK: - Display name fallback

    func testDisplayNameFallsBackToShortIDWhenBlank() {
        let candidate = makeCandidate(displayName: "   ")
        XCTAssertEqual(
            candidate.resolvedDisplayName,
            AgentMonitorSessionIDFormatter.short(candidate.sessionID)
        )
    }

    // MARK: - Copy Session ID

    func testCopyIsOfferedOnlyForEligibleEndpoints() {
        XCTAssertTrue(AgentSessionCopyIDPolicy.isOfferable(makeCandidate()))
        XCTAssertFalse(AgentSessionCopyIDPolicy.isOfferable(makeCandidate(isTopLevel: false)))
        XCTAssertFalse(AgentSessionCopyIDPolicy.isOfferable(makeCandidate(persistentBindingGeneration: nil)))
        XCTAssertFalse(AgentSessionCopyIDPolicy.isOfferable(makeCandidate(bindingTransitionInProgress: true)))
    }

    func testCopyWritesTheFullCanonicalUUID() {
        let candidate = makeCandidate()
        let target = AgentSessionCopyIDTarget(candidate: candidate)
        XCTAssertEqual(
            AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: [candidate]),
            .copied(candidate.sessionID.uuidString)
        )
    }

    func testCopyFailsClosedWhenTheBindingGenerationChanged() {
        // The whole point of the generation-bearing capture: the tab still shows the same session ID
        // but rebound underneath, so the click must write nothing.
        let candidate = makeCandidate()
        let target = AgentSessionCopyIDTarget(candidate: candidate)
        let rebound = makeCandidate(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: candidate.bindingTransitionGeneration
        )
        XCTAssertEqual(
            AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: [rebound]),
            .staleTarget
        )
    }

    func testCopyFailsClosedWhenTheTransitionGenerationAdvanced() {
        let candidate = makeCandidate(bindingTransitionGeneration: 3)
        let target = AgentSessionCopyIDTarget(candidate: candidate)
        let advanced = makeCandidate(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: candidate.persistentBindingGeneration,
            bindingTransitionGeneration: 4
        )
        XCTAssertEqual(
            AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: [advanced]),
            .staleTarget
        )
    }

    func testCopyFailsClosedWhenTheEndpointDisappeared() {
        let target = AgentSessionCopyIDTarget(candidate: makeCandidate())
        XCTAssertEqual(AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: []), .staleTarget)
    }

    func testCopyRejectsAnAmbiguousLiveSet() {
        let candidate = makeCandidate()
        let target = AgentSessionCopyIDTarget(candidate: candidate)
        XCTAssertEqual(
            AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: [candidate, candidate]),
            .staleTarget
        )
    }

    func testCopyRejectsARowThatBecameIneligible() {
        let candidate = makeCandidate()
        let target = AgentSessionCopyIDTarget(candidate: candidate)
        let closing = makeCandidate(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: candidate.persistentBindingGeneration,
            bindingTransitionGeneration: candidate.bindingTransitionGeneration,
            isClosing: true
        )
        XCTAssertEqual(
            AgentSessionCopyIDPolicy.outcome(for: target, liveCandidates: [closing]),
            .ineligible
        )
    }

    // MARK: - Endpoint DTO

    func testDomainEndpointMirrorsTheCapturedIncarnation() {
        let candidate = makeCandidate()
        let endpoint = candidate.domainEndpoint
        XCTAssertEqual(endpoint.windowID, candidate.windowID)
        XCTAssertEqual(endpoint.workspaceID, candidate.workspaceID)
        XCTAssertEqual(endpoint.tabID, candidate.tabID)
        XCTAssertEqual(endpoint.sessionID, candidate.sessionID)
        XCTAssertEqual(endpoint.persistentBindingGeneration, candidate.persistentBindingGeneration)
        XCTAssertEqual(endpoint.bindingTransitionGeneration, candidate.bindingTransitionGeneration)
        XCTAssertTrue(endpoint.hasResolvedPersistentBinding)
        XCTAssertEqual(AgentSessionCopyIDTarget(candidate: candidate).domainEndpoint, endpoint)
    }

    func testUnboundEndpointFailsClosedRatherThanMatchingAnotherUnboundTab() {
        let first = makeCandidate(persistentBindingGeneration: nil).domainEndpoint
        let second = makeCandidate(persistentBindingGeneration: nil).domainEndpoint
        XCTAssertFalse(first.hasResolvedPersistentBinding)
        XCTAssertNotEqual(first, second)
    }
}

// MARK: - Helpers

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
