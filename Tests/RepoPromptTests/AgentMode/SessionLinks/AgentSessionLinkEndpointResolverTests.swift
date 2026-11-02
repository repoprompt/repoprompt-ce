import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Fail-closed resolution, endpoint eligibility, and guarded Copy Session ID.
///
/// Resolution is a pure decision over a candidate set, so the "exactly one live eligible top-level
/// match" rule is exercised here without constructing windows.
final class AgentSessionLinkEndpointResolverTests: XCTestCase {
    @MainActor
    func testAttributionLiveSourceRoutesToItsExactWindowAndSession() async {
        let sourceID = UUID()
        for windowID in [1, 2] {
            let source = makeCandidate(windowID: windowID, sessionID: sourceID)
            var routed: [AgentSessionDeepLinkRoute] = []
            await AppDeepLinkRouter.routeLoadedAgentSession(sessionID: sourceID, resolve: { requestedID in
                XCTAssertEqual(requestedID, sourceID)
                return [source]
            }, isAvailable: { $0 == source }, navigate: { routed.append($0) })
            XCTAssertEqual(routed, [AgentSessionDeepLinkRoute(
                windowID: windowID, workspaceID: source.workspaceID, tabID: source.tabID, sessionID: sourceID
            )])
        }
    }

    @MainActor
    func testAttributionStaleSourceNeverInvokesFocusOrRestoreNavigation() async {
        let sourceID = UUID()
        let live = makeCandidate(sessionID: sourceID)
        let closed = makeCandidate(sessionID: sourceID, isClosing: true)
        var navigationCount = 0
        for matches in [[], [closed], [makeCandidate(sessionID: sourceID, hasLoadedPersistedState: false)], [live, live]] {
            await AppDeepLinkRouter.routeLoadedAgentSession(
                sessionID: sourceID,
                resolve: { _ in matches },
                isAvailable: { _ in true },
                navigate: { _ in navigationCount += 1 }
            )
        }
        await AppDeepLinkRouter.routeLoadedAgentSession(
            sessionID: sourceID,
            resolve: { _ in [live] },
            isAvailable: { _ in false },
            navigate: { _ in navigationCount += 1 }
        )
        var unready = live
        unready.restorationReadiness = .unbound
        await AppDeepLinkRouter.routeLoadedAgentSession(
            sessionID: sourceID,
            resolve: { _ in [unready] },
            isAvailable: { _ in true },
            navigate: { _ in navigationCount += 1 }
        )
        XCTAssertEqual(navigationCount, 0, "Stale attribution must not enter the focus/restore router")
    }

    @MainActor
    func testAttributionSourceReplacedDuringTabSwitchNeverNavigates() async {
        let source = makeCandidate()
        var matches = [source]
        var navigationCount = 0
        await AppDeepLinkRouter.routeLoadedAgentSession(
            sessionID: source.sessionID,
            resolve: { _ in matches },
            isAvailable: { matches.contains($0) },
            prepareNavigation: { _ in
                // The tab switch suspends while the user opens a different session in that tab.
                matches = []
            },
            navigate: { _ in navigationCount += 1 }
        )
        XCTAssertEqual(navigationCount, 0, "A badge click must not restore the replaced source")
    }

    @MainActor
    func testAttributionRealTabApplicationPreservesCurrentSession() async throws {
        for replaceSource in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadgeRouting-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let window = WindowState(automaticProviderModelDiscoveryEnabled: false)
            let windows = WindowStatesManager.shared
            let originalWindows = windows.allWindows
            windows.allWindows = [window]
            defer {
                windows.allWindows = originalWindows
                window.workspaceManager.setComposeTabFastStateDidApplyHandlerForTesting(nil)
                for session in window.agentModeViewModel.sessions.values {
                    session.saveDebounceTask?.cancel()
                }
                try? FileManager.default.removeItem(at: root)
            }
            let manager = window.workspaceManager
            await manager.awaitInitialized()
            let workspace = manager.createWorkspace(name: "Badge routing", repoPaths: [], ephemeral: true)
            await manager.switchWorkspace(to: workspace, saveState: false, reason: "badgeRoutingTest")
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace.id })
            manager.workspaces[index].customStoragePath = root
            try window.promptManager.loadComposeTabsFromWorkspace(XCTUnwrap(manager.activeWorkspace), syncPromptText: true)
            let vm = window.agentModeViewModel
            let createdSourceTabID = await vm.createAndActivateSessionTab()
            let sourceTabID = try XCTUnwrap(createdSourceTabID)
            let source = try XCTUnwrap(vm.sessions[sourceTabID])
            let sourceID = try XCTUnwrap(source.activeAgentSessionID)
            let sourceBinding = source.persistentSessionBindingIdentity
            let replacementID = UUID()
            let replacement = AgentSession(id: replacementID, workspaceID: workspace.id, composeTabID: sourceTabID, name: "New selection")
            _ = try await AgentSessionDataService.shared.saveAgentSession(replacement, for: XCTUnwrap(manager.activeWorkspace))
            _ = await vm.createAndActivateSessionTab()
            var appliedSource = false
            var replacementResult: AgentRouteSessionActivationResult?
            manager.setComposeTabFastStateDidApplyHandlerForTesting { tabID in
                guard tabID == sourceTabID else { return }
                appliedSource = true
                if replaceSource {
                    replacementResult = await vm.activateRoutedAgentSession(
                        tabID: sourceTabID, sessionID: replacementID, workspace: manager.activeWorkspace!
                    )
                }
            }
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in
                if id == sourceID { XCTFail("Badge navigation must never hydrate the old source") }
            }
            await AppDeepLinkRouter(windowStatesManager: windows).routeLoadedAgentSession(sessionID: sourceID)
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            XCTAssertTrue(appliedSource, "The badge must traverse the actual suspended tab application")
            XCTAssertEqual(window.promptManager.activeComposeTabID, sourceTabID)
            XCTAssertEqual(
                manager.activeWorkspace?.composeTabs.first { $0.id == sourceTabID }?.activeAgentSessionID,
                replaceSource ? replacementID : sourceID
            )
            XCTAssertEqual(vm.sessions[sourceTabID]?.activeAgentSessionID, replaceSource ? replacementID : sourceID)
            if replaceSource {
                XCTAssertEqual(replacementResult, .ready)
            } else {
                XCTAssertEqual(vm.sessions[sourceTabID]?.persistentSessionBindingIdentity, sourceBinding)
            }
            await vm.prepareForWindowClose()
            await vm.test_drainSessionPersistenceAfterWindowClose()
        }
    }

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
        isDeletionInProgress: Bool = false,
        parentSessionID: UUID? = nil,
        createdByOverseerSessionID: UUID? = nil
    ) -> AgentSessionLinkEndpointCandidate {
        let readiness: AgentSessionRestorationReadiness
        if let persistentBindingGeneration {
            let token = AgentSessionRestorationBindingToken(
                bindingIdentity: AgentPersistentSessionBindingIdentity(
                    tabID: tabID, sessionID: sessionID, generation: persistentBindingGeneration
                ),
                bindingTransitionGeneration: bindingTransitionGeneration
            )
            readiness = hasLoadedPersistedState
                ? .authoritative(token, .persistedPayloadApplied)
                : .pending(token)
        } else {
            readiness = .unbound
        }
        return AgentSessionLinkEndpointCandidate(
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
            restorationReadiness: readiness,
            isDeletionInProgress: isDeletionInProgress,
            parentSessionID: parentSessionID,
            createdByOverseerSessionID: createdByOverseerSessionID
        )
    }

    func testChildTargetQualificationUsesImmutableProvenanceWithoutChangingObserverEligibility() throws {
        let observer = UUID()
        let child = makeCandidate(isTopLevel: false, parentSessionID: observer)
        XCTAssertEqual(AgentSessionLinkEndpointResolver.resolve(sessionID: child.sessionID, candidates: [child]).failure, .childSession)
        XCTAssertEqual(try AgentSessionLinkEndpointResolver.resolve(sessionID: child.sessionID, candidates: [child], observerSessionID: observer).get(), child)
        XCTAssertFalse(child.isTopLevel)
        XCTAssertEqual(AgentSessionLinkEndpointResolver.resolve(sessionID: child.sessionID, candidates: [child], observerSessionID: UUID()).failure, .childSession)
        XCTAssertEqual(try AgentSessionLinkEndpointResolver.resolve(sessionID: child.sessionID, candidates: [child], observerSessionID: UUID(), permitsChildTarget: true).get(), child)
        XCTAssertNotEqual(AgentSessionLinkEndpointEligibility.observerOperationEligibility(child.eligibilityInput, roleAllowsOutboundMonitoring: true), .eligible)
        let created = makeCandidate(isTopLevel: false, parentSessionID: UUID(), createdByOverseerSessionID: observer)
        XCTAssertEqual(try AgentSessionLinkEndpointResolver.resolve(sessionID: created.sessionID, candidates: [created], observerSessionID: observer).get(), created)
        let closing = makeCandidate(isTopLevel: false, isClosing: true, parentSessionID: observer)
        XCTAssertEqual(AgentSessionLinkEndpointResolver.resolve(sessionID: closing.sessionID, candidates: [closing], observerSessionID: observer, permitsChildTarget: true).failure, .closing)
        XCTAssertEqual(AgentSessionLinkEndpointResolver.resolve(sessionID: child.sessionID, candidates: [child, child], observerSessionID: observer, permitsChildTarget: true).failure, .ambiguous)
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

    func testCompletedLoadLatchRequiresAuthoritativeReadinessForResolution() throws {
        var candidate = makeCandidate()
        let token = try XCTUnwrap(candidate.restorationReadiness.bindingToken)
        let ownerID = UUID()
        let unavailable: [(String, AgentSessionRestorationReadiness)] = [
            ("unbound", .unbound),
            ("pending", .pending(token)),
            ("preparing", .creating(token, .init(
                workspaceID: candidate.workspaceID, ownerID: ownerID, phase: .preparing
            ))),
            ("ready to persist", .creating(token, .init(
                workspaceID: candidate.workspaceID, ownerID: ownerID,
                phase: .readyToPersist(configurationStamp: Data("configured".utf8))
            ))),
            ("failed configuration", .creating(token, .init(
                workspaceID: candidate.workspaceID, ownerID: ownerID,
                phase: .failedBeforeConfiguration("Configuration failed.")
            ))),
            ("missing payload", .terminal(token, .missingPayload)),
            ("load failed", .terminal(token, .loadFailed)),
            ("superseded source", .terminal(token, .sourceRevisionSuperseded))
        ]
        for (name, readiness) in unavailable {
            candidate.restorationReadiness = readiness
            XCTAssertTrue(candidate.hasLoadedPersistedState, name)
            XCTAssertEqual(
                AgentSessionLinkEndpointResolver.resolve(sessionID: candidate.sessionID, candidates: [candidate]).failure,
                .loading,
                name
            )
            XCTAssertFalse(AgentSessionCopyIDPolicy.isOfferable(candidate), name)
            XCTAssertEqual(
                AgentSessionLinkEndpointEligibility.observerOperationEligibility(
                    candidate.eligibilityInput, roleAllowsOutboundMonitoring: true
                ),
                .transientlyUnavailable,
                name
            )
        }

        let authoritativeSources: [AgentSessionRestorationReadiness.Source] = [
            .persistedPayloadApplied, .freshBindingDurablyCreated
        ]
        for source in authoritativeSources {
            candidate.restorationReadiness = .authoritative(token, source)
            XCTAssertEqual(
                try AgentSessionLinkEndpointResolver.resolve(sessionID: candidate.sessionID, candidates: [candidate]).get(),
                candidate
            )
            XCTAssertTrue(AgentSessionCopyIDPolicy.isOfferable(candidate))
        }
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
            (makeCandidate(persistentBindingGeneration: nil), .loading)
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
            ("unbound", makeCandidate(persistentBindingGeneration: nil), .loading),
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
