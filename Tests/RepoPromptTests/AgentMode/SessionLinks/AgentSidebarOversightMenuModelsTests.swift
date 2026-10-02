import AppKit
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import SwiftUI
import XCTest

final class AgentSidebarOversightMenuModelsTests: XCTestCase {
    private struct Linked {
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let linkID: UUID
        let generation: UInt64
        var createdAt: Date?
    }

    private func id(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func candidate(
        windowID: Int,
        workspaceID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        tabID: UUID = UUID(),
        sessionID: UUID = UUID(),
        bindingID: UUID? = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        transitionGeneration: UInt64 = 1,
        isTopLevel: Bool = true,
        hasLoadedPersistedState: Bool = true,
        bindingTransitionInProgress: Bool = false,
        isClosing: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        roleAllowsOutboundMonitoring: Bool = true,
        displayName: String? = "Agent",
        providerDisplayName: String? = "Codex CLI",
        locationLabel: String? = nil,
        isDeletionInProgress: Bool = false
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: bindingID,
            bindingTransitionGeneration: transitionGeneration,
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

    /// Builds projection inputs for a row. `linked` are inbound (the row is the target);
    /// `linkedTargets` are outbound (the row is the observer).
    private func inputs(
        target: AgentSessionLinkEndpointCandidate,
        linked: [Linked] = [],
        linkedTargets: [Linked] = [],
        activeOutboundObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    ) -> DomainAgentSessionLinkEndpointProjectionInputs {
        let inboundItems = linked.map { relationship in
            DomainAgentSessionLinkInventoryItem(
                linkID: relationship.linkID,
                generation: relationship.generation,
                observerSessionID: relationship.endpoint.sessionID,
                targetSessionID: target.sessionID,
                displayName: nil,
                capabilities: DomainAgentSessionLinkCapability.version1,
                createdAt: relationship.createdAt ?? Date(timeIntervalSince1970: 0)
            )
        }
        let outboundItems = linkedTargets.map { relationship in
            DomainAgentSessionLinkInventoryItem(
                linkID: relationship.linkID,
                generation: relationship.generation,
                observerSessionID: target.sessionID,
                targetSessionID: relationship.endpoint.sessionID,
                displayName: nil,
                capabilities: DomainAgentSessionLinkCapability.version1,
                createdAt: relationship.createdAt ?? Date(timeIntervalSince1970: 0)
            )
        }
        return DomainAgentSessionLinkEndpointProjectionInputs(
            outbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: UInt64(linkedTargets.count),
                authorityRevision: 1,
                items: outboundItems
            ),
            inbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: UInt64(linked.count),
                authorityRevision: 1,
                items: inboundItems
            ),
            outboundTargetEndpoints: Dictionary(
                uniqueKeysWithValues: linkedTargets.map { ($0.linkID, $0.endpoint) }
            ),
            inboundObserverEndpoints: Dictionary(
                uniqueKeysWithValues: linked.map { ($0.linkID, $0.endpoint) }
            ),
            activeOutboundObserverEndpoints: activeOutboundObserverEndpoints,
            notices: []
        )
    }

    func testProjectionPartitionsAvailableAndRetainsUnavailableAndIneligibleLinkedObservers() {
        let target = candidate(windowID: 10, displayName: "Target")
        let ineligibleLinked = candidate(
            windowID: 2,
            roleAllowsOutboundMonitoring: false,
            displayName: "Éclair"
        )
        let unavailableEndpoint = candidate(
            windowID: 3,
            sessionID: id("F0000000-0000-0000-0000-000000000003"),
            displayName: "Gone"
        ).domainEndpoint
        let available = candidate(windowID: 4, displayName: "alpha", providerDisplayName: "   ")
        let linked = [
            Linked(endpoint: unavailableEndpoint, linkID: UUID(), generation: 7),
            Linked(endpoint: ineligibleLinked.domainEndpoint, linkID: UUID(), generation: 2)
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: linked,
                activeOutboundObserverEndpoints: Set(
                    linked.map(\.endpoint) + [available.domainEndpoint]
                )
            ),
            candidates: [available, target, ineligibleLinked]
        )

        XCTAssertEqual(menu.targetEndpoint, target.domainEndpoint)
        XCTAssertEqual(menu.targetSessionID, target.sessionID)
        XCTAssertEqual(menu.targetDisplayName, "Target")
        XCTAssertEqual(menu.linkedObservers.map(\.displayName), ["Éclair", AgentMonitorSessionIDFormatter.short(
            unavailableEndpoint.sessionID
        )])
        XCTAssertEqual(menu.availableObservers.map(\.peerEndpoint), [available.domainEndpoint])
        XCTAssertNil(menu.availableObservers.first?.providerDisplayName)
        XCTAssertEqual(
            menu.inboundObserverNames,
            [AgentMonitorSessionIDFormatter.short(unavailableEndpoint.sessionID), "Éclair"]
        )
        XCTAssertFalse(menu.isEmpty)

        guard case let .linked(ineligibleReference, ineligibleEligible) = menu.linkedObservers[0].relationship,
              case let .linked(goneReference, goneEligible) = menu.linkedObservers[1].relationship
        else {
            return XCTFail("expected linked relationship options")
        }
        XCTAssertFalse(ineligibleEligible)
        XCTAssertFalse(goneEligible)
        XCTAssertEqual(ineligibleReference.generation, 2)
        XCTAssertEqual(goneReference.generation, 7)
        XCTAssertTrue(menu.linkedObservers[1].fullIdentityDescription.contains(unavailableEndpoint.tabID.uuidString))
    }

    func testAvailableProjectionRequiresActiveOverseerAndExcludesIneligibleSelfAndLinkedEndpoints() {
        let target = candidate(windowID: 10, displayName: "Target")
        let linked = candidate(windowID: 2, displayName: "Linked")
        let eligibleOverseer = candidate(windowID: 3, displayName: "Eligible overseer")
        let ordinaryEligibleLane = candidate(windowID: 4, displayName: "Ordinary eligible lane")
        let sameSessionIncarnation = candidate(
            windowID: 5,
            sessionID: target.sessionID,
            displayName: "Target duplicate"
        )
        let ineligible = [
            candidate(windowID: 6, isTopLevel: false, displayName: "Child"),
            candidate(windowID: 7, isMCPControlled: true, displayName: "Controlled"),
            candidate(windowID: 8, isMCPOriginated: true, displayName: "Originated"),
            candidate(windowID: 9, roleAllowsOutboundMonitoring: false, displayName: "Denied"),
            candidate(windowID: 11, hasLoadedPersistedState: false, displayName: "Loading")
        ]
        let relationship = Linked(endpoint: linked.domainEndpoint, linkID: UUID(), generation: 1)
        let activeOverseers = [sameSessionIncarnation, linked, eligibleOverseer] + ineligible

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [relationship],
                activeOutboundObserverEndpoints: Set(activeOverseers.map(\.domainEndpoint))
            ),
            candidates: [
                target,
                sameSessionIncarnation,
                linked,
                eligibleOverseer,
                ordinaryEligibleLane
            ] + ineligible
        )

        XCTAssertEqual(menu.linkedObservers.map(\.peerEndpoint), [linked.domainEndpoint])
        XCTAssertEqual(menu.availableObservers.map(\.peerEndpoint), [eligibleOverseer.domainEndpoint])
    }

    /// Ordering contract: the row's own workspace cohort first, then folded name — flat across
    /// linked and available observers in the inbound list.
    func testInboundListOrdersOwnWorkspaceFirstThenName() {
        let ownWorkspace = id("10000000-0000-0000-0000-000000000001")
        let otherWorkspace = id("20000000-0000-0000-0000-000000000002")
        let target = candidate(windowID: 10, workspaceID: ownWorkspace, displayName: "Target")
        // In the row's workspace but sorts last by name; a linked observer elsewhere sorts first
        // among the other-workspace group but still after every same-workspace option.
        let linkedRemote = candidate(
            windowID: 2,
            workspaceID: otherWorkspace,
            displayName: "AAA linked remote"
        )
        let availableLocal = candidate(windowID: 3, workspaceID: ownWorkspace, displayName: "Zeta local")
        let availableRemote = candidate(
            windowID: 4,
            workspaceID: otherWorkspace,
            displayName: "BBB remote"
        )
        let relationship = Linked(endpoint: linkedRemote.domainEndpoint, linkID: UUID(), generation: 3)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [relationship],
                activeOutboundObserverEndpoints: [
                    linkedRemote.domainEndpoint,
                    availableLocal.domainEndpoint,
                    availableRemote.domainEndpoint
                ]
            ),
            candidates: [target, linkedRemote, availableLocal, availableRemote]
        )

        XCTAssertEqual(
            menu.observerOptions.map(\.displayName),
            ["Zeta local", "AAA linked remote", "BBB remote"]
        )
        guard case .linked = menu.observerOptions[1].relationship else {
            return XCTFail("expected the remote option to stay linked after sorting")
        }
    }

    /// The inverse list keeps ticked (linked) targets first, then applies the same
    /// own-workspace/name ordering inside each group.
    func testOutboundListKeepsLinkedFirstThenWorkspaceThenName() {
        let ownWorkspace = id("10000000-0000-0000-0000-000000000001")
        let otherWorkspace = id("20000000-0000-0000-0000-000000000002")
        let observer = candidate(windowID: 10, workspaceID: ownWorkspace, displayName: "Observer")
        let linkedRemote = candidate(
            windowID: 2,
            workspaceID: otherWorkspace,
            displayName: "Linked target"
        )
        let availableLocal = candidate(windowID: 3, workspaceID: ownWorkspace, displayName: "Alpha local")
        let selfSession = candidate(windowID: 5, sessionID: observer.sessionID, displayName: "Self")
        let ineligibleTarget = candidate(
            windowID: 6,
            hasLoadedPersistedState: false,
            displayName: "Loading target"
        )
        let relationship = Linked(endpoint: linkedRemote.domainEndpoint, linkID: UUID(), generation: 9)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: observer,
            inputs: inputs(target: observer, linkedTargets: [relationship]),
            candidates: [observer, linkedRemote, availableLocal, selfSession, ineligibleTarget]
        )

        XCTAssertEqual(
            menu.targetOptions.map(\.peerEndpoint),
            [linkedRemote.domainEndpoint, availableLocal.domainEndpoint]
        )
        XCTAssertTrue(menu.isOverseer)
        XCTAssertEqual(menu.outboundTargetNames, ["Linked target"])
        XCTAssertNil(menu.observerIneligibleReason)
    }

    /// An ineligible target keeps its menu with a greyed reason and retains linked observers for
    /// unlinking; an ineligible observer gets the inverse reason and an empty available list.
    func testIneligibleDirectionsSurfaceReasonsInsteadOfHidingMenus() {
        let loadingRow = candidate(
            windowID: 1,
            hasLoadedPersistedState: false,
            displayName: "Loading row"
        )
        let overseer = candidate(windowID: 2, displayName: "Overseer")
        let linked = Linked(endpoint: overseer.domainEndpoint, linkID: UUID(), generation: 4)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: loadingRow,
            inputs: inputs(target: loadingRow, linked: [linked]),
            candidates: [loadingRow, overseer]
        )

        XCTAssertEqual(
            menu.targetIneligibleReason,
            AgentSessionLinkResolveFailure.loading.uiMessage
        )
        XCTAssertTrue(menu.availableObservers.isEmpty)
        // The linked observer stays reachable so the relationship remains unlinkable.
        XCTAssertEqual(menu.linkedObservers.map(\.peerEndpoint), [overseer.domainEndpoint])
        XCTAssertEqual(menu.inboundObserverNames, ["Overseer"])
        XCTAssertTrue(menu.hasInbound)
        // The same row cannot observe while still loading, either.
        XCTAssertEqual(
            menu.observerIneligibleReason,
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                loadingRow.eligibilityInput,
                roleAllowsOutboundMonitoring: loadingRow.roleAllowsOutboundMonitoring
            )
        )
        XCTAssertTrue(menu.targetOptions.isEmpty)
    }

    /// Fb iconography: one mark per row — a role eye — and a neutral management affordance.
    /// The link/provenance mark is gone; creator origin lives in the combined tooltip only.
    func testMarkGlyphCopyMovedToTheUnifiedCopyOwner() {
        XCTAssertEqual(AgentOversightUICopy.overseerMarkIcon, "eye.fill")
        XCTAssertEqual(AgentOversightUICopy.overseenMarkIcon, "eye")
        XCTAssertEqual(AgentOversightUICopy.dualRoleMarkIcon, "eye.circle.fill")
        XCTAssertEqual(AgentOversightUICopy.manageOversightIcon, "person.2.badge.gearshape")
        XCTAssertEqual(
            AgentOversightUICopy.createdByTooltip(creator: "RepoPrompt PM"),
            "Created by: RepoPrompt PM"
        )
    }

    func testCreatorLabelSurvivesAnEmptyUnlinkedMenuWithoutChangingEligibility() {
        let target = candidate(windowID: 1, isMCPControlled: false, isMCPOriginated: false)
        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target],
            createdByLabel: "Overseer",
            creatorSessionID: UUID()
        )
        XCTAssertTrue(menu.isEmpty)
        XCTAssertFalse(menu.hasInbound)
        XCTAssertEqual(menu.createdByLabel, "Overseer")
        XCTAssertNotNil(menu.creatorSessionID)
        XCTAssertNil(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target]
        ).createdByLabel)
        XCTAssertFalse(target.isMCPControlled)
    }

    func testMenuLabelsPrefixLiveObserverLocationAndFallBackWhenUnavailable() {
        let target = candidate(windowID: 10, displayName: "Target")
        let linked = candidate(
            windowID: 2,
            displayName: "Existing overseer",
            locationLabel: "release-main"
        )
        let available = candidate(
            windowID: 3,
            displayName: "Coordinate PIN-boundary design review",
            locationLabel: " kidfriendly-nova "
        )
        let unavailableEndpoint = candidate(
            windowID: 4,
            sessionID: id("F0000000-0000-0000-0000-000000000004"),
            displayName: "Unavailable"
        ).domainEndpoint
        let relationships = [
            Linked(endpoint: linked.domainEndpoint, linkID: UUID(), generation: 1),
            Linked(endpoint: unavailableEndpoint, linkID: UUID(), generation: 2)
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: relationships,
                activeOutboundObserverEndpoints: [linked.domainEndpoint, available.domainEndpoint]
            ),
            candidates: [target, linked, available]
        )

        XCTAssertEqual(
            menu.linkedObservers.first { $0.peerEndpoint == linked.domainEndpoint }?.menuLabel,
            "release-main: Existing overseer"
        )
        XCTAssertEqual(
            menu.availableObservers.first?.menuLabel,
            "kidfriendly-nova: Coordinate PIN-boundary design review"
        )
        XCTAssertEqual(
            menu.linkedObservers.first { $0.peerEndpoint == unavailableEndpoint }?.menuLabel,
            AgentMonitorSessionIDFormatter.short(unavailableEndpoint.sessionID)
        )
    }

    func testUnlinkVoiceOverLabelQuotesThePeerName() {
        let observer = "release-main: Existing overseer"
        XCTAssertEqual(
            AgentOversightUICopy.unlinkAccessibilityLabel(observer),
            "Unlink \"release-main: Existing overseer\""
        )
    }

    /// Approved 2026-09-30 mark tooltip: one combined line, segments omitted when empty,
    /// three names then "+N more".
    func testMarkTooltipIsOneCombinedLineWithOptionalSegments() {
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: ["A", "B", "C", "D"],
                overseenByNames: ["E", "F"],
                creator: "G",
                creatorIsSoleOverseer: false
            ),
            "Overseeing: A, B, C +1 more · Overseen by: E, F · Created by: G"
        )
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: [],
                overseenByNames: ["D", "E"],
                creator: nil,
                creatorIsSoleOverseer: false
            ),
            "Overseen by: D, E"
        )
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: ["A"],
                overseenByNames: [],
                creator: nil,
                creatorIsSoleOverseer: false
            ),
            "Overseeing: A"
        )
        // Creator as the only overseer collapses the inbound + provenance segments.
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: [],
                overseenByNames: ["RepoPrompt PM"],
                creator: "RepoPrompt PM",
                creatorIsSoleOverseer: true
            ),
            "Created and overseen by: RepoPrompt PM"
        )
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: ["Lane"],
                overseenByNames: ["RepoPrompt PM"],
                creator: "RepoPrompt PM",
                creatorIsSoleOverseer: true
            ),
            "Overseeing: Lane · Created and overseen by: RepoPrompt PM"
        )
        XCTAssertEqual(
            AgentOversightUICopy.oversightMarkTooltip(
                overseeingNames: [],
                overseenByNames: ["Other"],
                creator: "RepoPrompt PM",
                creatorIsSoleOverseer: false
            ),
            "Overseen by: Other · Created by: RepoPrompt PM"
        )
    }

    func testConfirmationCopyMatchesTheApprovedGrantShape() {
        XCTAssertEqual(
            AgentOversightUICopy.confirmationTitle(observer: "Overseer", target: "Lane"),
            "Allow \"Overseer\" to oversee \"Lane\"?"
        )
        let body = AgentOversightUICopy.confirmationBody(observer: "Overseer", target: "Lane")
        XCTAssertTrue(body.contains("“Overseer” will be able to:"))
        XCTAssertTrue(body.contains("read Lane’s status and conversation"))
        XCTAssertTrue(body.contains("send it instructions, steer it and stop its current run"))
        XCTAssertTrue(body.contains("answer its questions and one-time approval requests"))
        XCTAssertTrue(body.contains("compact its context, and be woken up by its updates"))
        XCTAssertTrue(body.contains("You can unlink anytime."))
        XCTAssertEqual(AgentOversightUICopy.confirmationSuppressionCheckbox, "Don’t ask again")
        XCTAssertEqual(AgentOversightUICopy.confirmationAllowButton, "Allow oversight")
    }

    /// Approved 2026-09-30 copy decisions for the Session-ID sheets and stale/menu strings.
    func testSheetAndStaleCopyMatchesApproval() {
        XCTAssertEqual(
            AgentOversightUICopy.sessionIDSheetTitle(observer: "Lane A"),
            "Choose a session for \"Lane A\" to oversee"
        )
        XCTAssertEqual(
            AgentOversightUICopy.inboundSessionIDSheetTitle(session: "Lane A"),
            "Choose an overseer for \"Lane A\""
        )
        XCTAssertEqual(AgentOversightUICopy.addOverseerButton, "Add overseer")
        XCTAssertEqual(AgentOversightUICopy.overseeSessionButton, "Oversee session")
        XCTAssertEqual(AgentOversightUICopy.staleSelectionMessage, "Sessions changed. Please choose again.")
        XCTAssertEqual(
            AgentOversightUICopy.overseeMenuAccessibilityValue(overseeingCount: 2, availableCount: 3),
            "Overseeing 2; 3 available"
        )
        XCTAssertEqual(
            AgentOversightUICopy.overseeByMenuAccessibilityValue(overseenByCount: 1, availableCount: 4),
            "Overseen by 1; 4 available"
        )
    }

    func testCollisionLabelsWidenThroughSessionWindowTabAndFullExactIdentity() throws {
        let target = candidate(windowID: 99, displayName: "Target")
        let sessionA = id("AAAA0000-0000-0000-0000-00000000AAAA")
        let sessionB = id("BBBB0000-0000-0000-0000-00000000BBBB")
        let sharedTab = id("CCCC0000-0000-0000-0000-00000000CCCC")
        let otherTab = id("DDDD0000-0000-0000-0000-00000000DDDD")
        let first = candidate(windowID: 1, sessionID: sessionA, displayName: "Duplicate")
        let differentSession = candidate(windowID: 2, sessionID: sessionB, displayName: "Duplicate")
        let sameSession = candidate(windowID: 3, sessionID: sessionA, displayName: "Duplicate")
        let sameWindowFirstTab = candidate(
            windowID: 4,
            tabID: sharedTab,
            sessionID: sessionA,
            displayName: "Duplicate"
        )
        let sameWindowOtherTab = candidate(
            windowID: 4,
            tabID: otherTab,
            sessionID: sessionA,
            displayName: "Duplicate"
        )
        let pathological = candidate(
            windowID: 4,
            workspaceID: id("EEEE0000-0000-0000-0000-00000000EEEE"),
            tabID: sharedTab,
            sessionID: sessionA,
            bindingID: id("FFFF0000-0000-0000-0000-00000000FFFF"),
            transitionGeneration: 8,
            displayName: "Duplicate"
        )
        let unique = candidate(windowID: 5, displayName: "Unique")
        let candidates = [
            target,
            first,
            differentSession,
            sameSession,
            sameWindowFirstTab,
            sameWindowOtherTab,
            pathological,
            unique
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                activeOutboundObserverEndpoints: Set(candidates.map(\.domainEndpoint))
            ),
            candidates: candidates
        )
        let byEndpoint = Dictionary(
            uniqueKeysWithValues: menu.availableObservers.map { ($0.peerEndpoint, $0) }
        )

        XCTAssertEqual(byEndpoint[unique.domainEndpoint]?.menuLabel, "Unique")
        XCTAssertTrue(try XCTUnwrap(byEndpoint[first.domainEndpoint]?.menuLabel).contains("AAAA…AAAA"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[differentSession.domainEndpoint]?.menuLabel).contains("BBBB…BBBB"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[sameSession.domainEndpoint]?.menuLabel).contains("window 3"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[sameWindowOtherTab.domainEndpoint]?.menuLabel).contains("tab DDDD…DDDD"))
        let full = try XCTUnwrap(byEndpoint[pathological.domainEndpoint]?.menuLabel)
        XCTAssertTrue(full.contains(pathological.workspaceID.uuidString))
        XCTAssertTrue(try full.contains(XCTUnwrap(pathological.persistentBindingGeneration?.uuidString)))
        XCTAssertEqual(Set(menu.availableObservers.map(\.menuLabel)).count, menu.availableObservers.count)
    }

    func testCreatorNavigationRequiresOneLiveMatchingRoute() {
        let creatorID = UUID()
        let route = AgentSessionDeepLinkRoute(
            workspaceID: UUID(), tabID: UUID(), sessionID: creatorID
        )
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(for: creatorID, candidates: []))
        XCTAssertEqual(
            AgentSidebarCreatorNavigation.uniqueRoute(for: creatorID, candidates: [route]), route
        )
        let sameTabInAnotherWindow = AgentSessionDeepLinkRoute(
            windowID: 2, workspaceID: route.workspaceID, tabID: route.tabID, sessionID: creatorID
        )
        XCTAssertEqual(AgentSidebarCreatorNavigation.uniqueRoute(
            for: creatorID, candidates: [route, sameTabInAnotherWindow]
        ), route)
        let differentTab = AgentSessionDeepLinkRoute(
            workspaceID: route.workspaceID, tabID: UUID(), sessionID: creatorID
        )
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(
            for: creatorID, candidates: [route, differentTab]
        ))
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(
            for: UUID(), candidates: [route]
        ))
    }

    func testActionKeysAreExactEndpointAndGenerationQualified() {
        let observer = candidate(windowID: 1).domainEndpoint
        let target = candidate(windowID: 2).domainEndpoint
        let linkID = UUID()
        let reboundObserver = DomainAgentSessionLinkEndpointIdentity(
            windowID: observer.windowID,
            workspaceID: observer.workspaceID,
            tabID: observer.tabID,
            sessionID: observer.sessionID,
            persistentBindingGeneration: observer.persistentBindingGeneration,
            bindingTransitionGeneration: observer.bindingTransitionGeneration + 1
        )
        XCTAssertNotEqual(
            AgentSidebarOversightActionKey.add(observerEndpoint: observer, targetEndpoint: target),
            .add(observerEndpoint: reboundObserver, targetEndpoint: target)
        )
        XCTAssertNotEqual(
            AgentSidebarOversightActionKey.unlink(
                observerEndpoint: observer,
                targetEndpoint: target,
                reference: DomainAgentSessionLinkReference(linkID: linkID, generation: 1)
            ),
            .unlink(
                observerEndpoint: observer,
                targetEndpoint: target,
                reference: DomainAgentSessionLinkReference(linkID: linkID, generation: 2)
            )
        )
    }

    // MARK: - Unified menu model (approved 2026-10-01)

    /// Model-partition check for the shared props the mark, hover glyph and context menu all
    /// render: each direction splits into exactly the linked jump items plus the candidate
    /// submenu entries — disjoint, complete, and carrying the expected endpoints.
    func testMenuPropsPartitionIntoLinkedAndAvailableSubsets() {
        let target = candidate(windowID: 1, displayName: "Row")
        let linkedObserver = candidate(windowID: 2, displayName: "Overseer")
        let availableObserver = candidate(windowID: 3, displayName: "Candidate")
        let linkedTarget = candidate(windowID: 4, displayName: "Managed")
        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [Linked(endpoint: linkedObserver.domainEndpoint, linkID: UUID(), generation: 1)],
                linkedTargets: [Linked(endpoint: linkedTarget.domainEndpoint, linkID: UUID(), generation: 1)],
                activeOutboundObserverEndpoints: [availableObserver.domainEndpoint]
            ),
            candidates: [target, linkedObserver, availableObserver, linkedTarget]
        )

        let observerEndpoints = Set(menu.observerOptions.map(\.peerEndpoint))
        let linkedObserverEndpoints = Set(menu.linkedObservers.map(\.peerEndpoint))
        let availableObserverEndpoints = Set(menu.availableObservers.map(\.peerEndpoint))
        XCTAssertEqual(linkedObserverEndpoints, [linkedObserver.domainEndpoint])
        XCTAssertEqual(availableObserverEndpoints, [availableObserver.domainEndpoint])
        XCTAssertEqual(
            observerEndpoints,
            linkedObserverEndpoints.union(availableObserverEndpoints)
        )
        XCTAssertTrue(linkedObserverEndpoints.isDisjoint(with: availableObserverEndpoints))

        let targetEndpoints = Set(menu.targetOptions.map(\.peerEndpoint))
        let linkedTargetEndpoints = Set(menu.linkedTargets.map(\.peerEndpoint))
        let availableTargetEndpoints = Set(menu.availableTargets.map(\.peerEndpoint))
        XCTAssertEqual(linkedTargetEndpoints, [linkedTarget.domainEndpoint])
        XCTAssertFalse(availableTargetEndpoints.isEmpty)
        XCTAssertEqual(
            targetEndpoints,
            linkedTargetEndpoints.union(availableTargetEndpoints)
        )
        XCTAssertTrue(linkedTargetEndpoints.isDisjoint(with: availableTargetEndpoints))

        // Candidates never carry a linked relationship — the checkmark-unlink contract is gone.
        XCTAssertTrue(menu.availableObservers.allSatisfy { $0.relationship == .available })
        XCTAssertTrue(menu.availableTargets.allSatisfy { $0.relationship == .available })
    }

    /// A linked overseer whose live incarnation sits at a different endpoint — e.g. rebound or
    /// living in another window — still resolves its name from the app-wide candidate list by
    /// session ID instead of degrading to the compact ID. Reproduces the live-check bug where
    /// the overseer rendered as `6F23…A872`.
    func testCrossWindowLinkedObserverNameResolvesBySessionID() throws {
        let sessionID = id("ABCD0000-0000-0000-0000-00000000000B")
        let target = candidate(windowID: 1, displayName: "Row")
        // The linked endpoint captured at grant time: different window and transition generation.
        let linkedEndpoint = DomainAgentSessionLinkEndpointIdentity(
            windowID: 7,
            workspaceID: id("20000000-0000-0000-0000-000000000002"),
            tabID: UUID(),
            sessionID: sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 3
        )
        // The live candidate for the same session: another endpoint in another window.
        let livePeer = candidate(
            windowID: 7,
            workspaceID: id("20000000-0000-0000-0000-000000000002"),
            tabID: UUID(),
            sessionID: sessionID,
            transitionGeneration: 4,
            displayName: "RepoPrompt PM",
            locationLabel: "kidfriendly-overseer (main)"
        )
        XCTAssertNotEqual(linkedEndpoint, livePeer.domainEndpoint)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [Linked(endpoint: linkedEndpoint, linkID: UUID(), generation: 1)]
            ),
            candidates: [target, livePeer]
        )

        let linked = try XCTUnwrap(menu.linkedObservers.first)
        XCTAssertEqual(linked.menuLabel, "kidfriendly-overseer (main): RepoPrompt PM")
        XCTAssertEqual(menu.inboundObserverNames, ["RepoPrompt PM"])
    }

    /// The creator label resolves the same way: a live creator in another window names itself
    /// even when the persisted index label is stale or missing.
    func testCreatorLabelResolvesTheLiveCandidateNameBySessionID() {
        let creatorID = id("ABCD0000-0000-0000-0000-00000000000C")
        let target = candidate(windowID: 1, displayName: "Row")
        let creator = candidate(
            windowID: 7,
            workspaceID: id("20000000-0000-0000-0000-000000000002"),
            sessionID: creatorID,
            displayName: "RepoPrompt PM"
        )
        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target, creator],
            createdByLabel: AgentMonitorSessionIDFormatter.short(creatorID),
            creatorSessionID: creatorID
        )
        XCTAssertEqual(menu.createdByLabel, "RepoPrompt PM")
    }

    /// Jump items are exactly the linked observers, linked targets and the unlinked-creator
    /// row — they render with `jumpItemIcon` so they read as links, while candidates, section
    /// labels and unlink items stay plain. The icon lives in the view layer; this asserts the
    /// model partition that decides icon-ness plus the pinned symbol.
    func testJumpItemsAreExactlyTheLinkedOptionsAndCreator() {
        XCTAssertEqual(AgentOversightUICopy.jumpItemIcon, "arrow.up.forward")

        let target = candidate(windowID: 1, displayName: "Row")
        let linkedObserver = candidate(windowID: 2, displayName: "Overseer")
        let availableObserver = candidate(windowID: 3, displayName: "Candidate")
        let linkedTarget = candidate(windowID: 4, displayName: "Managed")
        let creator = candidate(windowID: 5, displayName: "Creator")
        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [Linked(endpoint: linkedObserver.domainEndpoint, linkID: UUID(), generation: 1)],
                linkedTargets: [Linked(endpoint: linkedTarget.domainEndpoint, linkID: UUID(), generation: 1)],
                activeOutboundObserverEndpoints: [availableObserver.domainEndpoint]
            ),
            candidates: [target, linkedObserver, availableObserver, linkedTarget, creator],
            createdByLabel: "Creator",
            creatorSessionID: creator.sessionID
        )

        // Jump items: linked observers + linked targets + the unlinked creator section.
        XCTAssertEqual(
            Set(menu.linkedObservers.map(\.peerEndpoint)),
            [linkedObserver.domainEndpoint]
        )
        XCTAssertEqual(
            Set(menu.linkedTargets.map(\.peerEndpoint)),
            [linkedTarget.domainEndpoint]
        )
        XCTAssertTrue(menu.showsCreatedBySection)
        // Candidates stay plain — none of them are jump items.
        XCTAssertTrue(menu.availableObservers.allSatisfy { $0.relationship == .available })
        XCTAssertTrue(menu.availableTargets.allSatisfy { $0.relationship == .available })
    }

    /// Creator collapse: sole-overseer creator merges the section; a creator who still oversees
    /// alongside others or not at all never produces a separate Created-by section.
    func testCreatorSectionCollapseRules() {
        let target = candidate(windowID: 1, displayName: "Row")
        let creator = candidate(windowID: 2, displayName: "Creator")
        let other = candidate(windowID: 3, displayName: "Other overseer")
        let soleMenu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [Linked(endpoint: creator.domainEndpoint, linkID: UUID(), generation: 1)]
            ),
            candidates: [target, creator],
            createdByLabel: "Creator",
            creatorSessionID: creator.sessionID
        )
        XCTAssertTrue(soleMenu.creatorIsOverseer)
        XCTAssertTrue(soleMenu.creatorIsSoleOverseer)
        XCTAssertFalse(soleMenu.showsCreatedBySection)

        let sharedMenu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [
                    Linked(endpoint: creator.domainEndpoint, linkID: UUID(), generation: 1),
                    Linked(endpoint: other.domainEndpoint, linkID: UUID(), generation: 2)
                ]
            ),
            candidates: [target, creator, other],
            createdByLabel: "Creator",
            creatorSessionID: creator.sessionID
        )
        XCTAssertTrue(sharedMenu.creatorIsOverseer)
        XCTAssertFalse(sharedMenu.creatorIsSoleOverseer)
        XCTAssertFalse(sharedMenu.showsCreatedBySection)

        let unlinkedCreatorMenu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target, creator],
            createdByLabel: "Creator",
            creatorSessionID: creator.sessionID
        )
        XCTAssertFalse(unlinkedCreatorMenu.creatorIsOverseer)
        XCTAssertTrue(unlinkedCreatorMenu.showsCreatedBySection)
    }
}

// MARK: - Oversight colour assignment

/// Fb iconography support types: the palette slot allocator, the per-row role derivation, and
/// the palette's contrast contract against the sidebar background in both appearances.
@MainActor
final class AgentOversightColourAssignmentTests: XCTestCase {
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", seed))!
    }

    private func endpoint(sessionID: UUID) -> DomainAgentSessionLinkEndpointIdentity {
        AgentSessionLinkIdentityTestSupport.endpoint(sessionID: sessionID)
    }

    private func inbound(
        overseerSessionID: UUID,
        linkID: UUID = UUID(),
        linkCreatedAt: Date? = nil,
        displayName: String = "Overseer"
    ) -> AgentSessionOversightRole.OverseerLink {
        .init(
            observerSessionID: overseerSessionID,
            displayName: displayName,
            linkID: linkID,
            linkCreatedAt: linkCreatedAt
        )
    }

    private func outbound(
        targetSessionID _: UUID,
        linkCreatedAt _: Date? = nil,
        displayName: String = "Lane"
    ) -> AgentSessionOversightRole.OverseeingLink {
        .init(displayName: displayName)
    }

    // MARK: - Allocator

    func testAllocatorTakesLowestFreeSlotAndKeepsItAcrossChurn() {
        let allocator = AgentOversightColourAllocator()
        let a = id(1)
        let b = id(2)
        let c = id(3)
        let now = Date()

        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, b: now, c: now])
        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: b), 1)
        XCTAssertEqual(allocator.slot(for: c), 2)

        // Removing the middle holder frees its slot but never reshuffles the survivors.
        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, c: now])
        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: c), 2)

        // A newcomer fills the vacated lowest slot rather than appending.
        let d = id(4)
        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, c: now, d: now])
        XCTAssertEqual(allocator.slot(for: d), 1)
    }

    func testAllocatorReleasesOnLastLinkAndReassignsInLinkOrder() {
        let allocator = AgentOversightColourAllocator()
        let early = id(1)
        let late = id(2)
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)

        allocator.reconcile(activeOverseerFirstLinkDates: [early: t0, late: t1])
        XCTAssertEqual(allocator.slot(for: early), 0)
        XCTAssertEqual(allocator.slot(for: late), 1)

        // Last link gone: the slot is released and a later appearance starts over.
        allocator.reconcile(activeOverseerFirstLinkDates: [:])
        XCTAssertEqual(allocator.slotsByOverseerID, [:])

        // Reappearing overseers are assigned in link-creation order, not dictionary order.
        allocator.reconcile(activeOverseerFirstLinkDates: [late: t1, early: t0])
        XCTAssertEqual(allocator.slot(for: early), 0)
        XCTAssertEqual(allocator.slot(for: late), 1)
    }

    func testAllocatorWrapsPastTenOverseers() {
        let allocator = AgentOversightColourAllocator()
        let now = Date()
        var active: [UUID: Date] = [:]
        for index in 0 ..< 11 {
            active[id(UInt8(index + 1))] = now + TimeInterval(index)
        }
        allocator.reconcile(activeOverseerFirstLinkDates: active)

        XCTAssertEqual(Set(active.keys).count, 11)
        // The eleventh distinct overseer wraps onto slot 0 rather than extending the palette.
        XCTAssertEqual(allocator.slotsByOverseerID[id(11)], 0)
        XCTAssertEqual(allocator.slotsByOverseerID.count, 11)
    }

    // MARK: - Role derivation

    func testRoleIsNoneWithoutLinks() {
        let role = AgentSessionOversightRole.make(
            inbound: [],
            outbound: [],
            ownSessionID: id(1)
        ) { _ in 0 }
        XCTAssertFalse(role.hasMark)
    }

    func testRoleOverseerOnlyGetsOwnSlotAndTargetNames() {
        let me = id(1)
        let role = AgentSessionOversightRole.make(
            inbound: [],
            outbound: [outbound(targetSessionID: id(9), displayName: "Lane A")],
            ownSessionID: me
        ) { sessionID in
            XCTAssertEqual(sessionID, me)
            return 4
        }
        XCTAssertEqual(role.ownOverseerSlot, 4)
        XCTAssertTrue(role.isOverseer)
        XCTAssertFalse(role.isOverseen)
        XCTAssertEqual(role.overseeingNames, ["Lane A"])
    }

    func testRoleOverseenOnlyListsOverseersInLinkCreationOrder() {
        let first = id(10)
        let second = id(11)
        let t0 = Date(timeIntervalSince1970: 10)
        let t1 = Date(timeIntervalSince1970: 20)
        let role = AgentSessionOversightRole.make(
            inbound: [
                // Listed in reverse creation order to prove the sort, not the input order.
                inbound(overseerSessionID: second, linkCreatedAt: t1, displayName: "Late"),
                inbound(overseerSessionID: first, linkCreatedAt: t0, displayName: "Early")
            ],
            outbound: [],
            ownSessionID: id(1)
        ) { sessionID in
            sessionID == first ? 3 : 7
        }
        XCTAssertEqual(role.overseers.map(\.sessionID), [first, second])
        XCTAssertEqual(role.overseers.map(\.slot), [3, 7])
        XCTAssertNil(role.ownOverseerSlot)
        XCTAssertTrue(role.hasMark)
    }

    func testRoleBothRolesAndDuplicateIncarnationDedupes() {
        let me = id(1)
        let overseer = id(10)
        let role = AgentSessionOversightRole.make(
            inbound: [
                // Same overseer session projected through two incarnations stays one group.
                inbound(overseerSessionID: overseer, linkCreatedAt: Date(timeIntervalSince1970: 5)),
                inbound(overseerSessionID: overseer, linkCreatedAt: Date(timeIntervalSince1970: 9))
            ],
            outbound: [outbound(targetSessionID: id(20))],
            ownSessionID: me
        ) { $0 == me ? 0 : 2 }
        XCTAssertEqual(role.ownOverseerSlot, 0)
        XCTAssertEqual(role.overseers.count, 1)
        XCTAssertEqual(role.overseers.first?.slot, 2)
    }

    // MARK: - Palette

    func testPaletteWrapsAndContrastsWithTheSidebarBackground() {
        // Approximate sidebar backgrounds; a material backdrop only ever reduces contrast, so the
        // flat colours are the conservative bound.
        let lightBackground = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1)
        let darkBackground = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)

        for slot in 0 ..< AgentOversightPalette.slotCount {
            let light = AgentOversightPalette.resolvedColor(for: slot, darkAppearance: false)
            let dark = AgentOversightPalette.resolvedColor(for: slot, darkAppearance: true)
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(light, lightBackground), 3.0,
                "slot \(slot) light variant fails the non-text contrast floor"
            )
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(dark, darkBackground), 3.0,
                "slot \(slot) dark variant fails the non-text contrast floor"
            )
        }

        // Slots wrap rather than indexing past the palette.
        let first = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: false)
        let wrapped = AgentOversightPalette.resolvedColor(
            for: AgentOversightPalette.slotCount,
            darkAppearance: false
        )
        XCTAssertEqual(first, wrapped)
    }

    /// WCAG relative-luminance contrast ratio.
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ channel: CGFloat) -> Double {
                let c = Double(channel)
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(srgb.redComponent)
                + 0.7152 * linear(srgb.greenComponent)
                + 0.0722 * linear(srgb.blueComponent)
        }
        let bright = max(luminance(a), luminance(b))
        let dark = min(luminance(a), luminance(b))
        return (bright + 0.05) / (dark + 0.05)
    }
}

// MARK: - Oversight mark rendering

/// The interactive oversight mark must keep its palette colour. Wrapping the glyph in a macOS
/// `Menu` label template-renders it, flattening every `foregroundStyle` to the control tint —
/// the fix keeps the glyph as ordinary content underneath a clear-label Menu hit target.
/// These tests rasterize the row and sample pixels, because a structure check cannot see
/// through the Menu's native label rendering.
@MainActor
final class AgentOversightMarkRenderTests: XCTestCase {
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", seed))!
    }

    private func props() -> AgentSidebarOversightMenuProps {
        let endpoint = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: id(9))
        return AgentSidebarOversightMenuProps(
            targetEndpoint: endpoint,
            targetSessionID: endpoint.sessionID,
            targetDisplayName: "Lane",
            observerOptions: []
        )
    }

    private func row(role: AgentSessionOversightRole, interactive: Bool) -> AgentSessionRow {
        var row = AgentSessionRow(
            title: "Lane A",
            isActive: false,
            isPinned: false,
            isMCPControlled: false,
            runState: .idle,
            threadDepth: 0,
            onSelectionGesture: { _ in .ignored },
            onSelect: {},
            onTogglePin: {},
            onDelete: {},
            onRename: { _ in },
            sessionIDCopyAction: AgentSidebarSessionIDCopyAction(sessionID: nil, clipboardWriter: { _ in })
        )
        row.oversightRole = role
        if interactive {
            let props = props()
            row.resolveSidebarOversightMenu = { props }
            row.onAddSidebarOversight = { _, _ in .changed }
            row.onStopSidebarOversight = { _, _, _ in .changed }
        }
        return row
    }

    /// Hosts a row in a real window so the Menu materializes its native control, then
    /// rasterizes it in dark appearance (the reported failure environment).
    private func rasterize(_ view: some View) -> (rep: NSBitmapImageRep, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 280)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not allocate bitmap for hosted row")
            return (NSBitmapImageRep(), window)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, window)
    }

    /// Pixels within `tolerance` (per sRGB channel) of `expected`. A template-rendered mark
    /// samples as the control's text tint instead — a very different colour. `pixelsWide`/`High`
    /// are used (not `size`, which is points) so a retina backing still scans the whole bitmap.
    private func pixelCount(
        near expected: NSColor,
        in rep: NSBitmapImageRep,
        tolerance: CGFloat = 0.14
    ) -> Int {
        guard let want = expected.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - want.redComponent) < tolerance,
                   abs(pixel.greenComponent - want.greenComponent) < tolerance,
                   abs(pixel.blueComponent - want.blueComponent) < tolerance
                {
                    count += 1
                }
            }
        }
        return count
    }

    /// A glyph-sized mark is far more than a stray matching pixel even at 1x backing.
    private let markPixelFloor = 8

    /// The failing case from Cristian's live check: an overseen row's interactive mark must
    /// paint the overseer's slot-0 group colour, not the control tint. The selected row
    /// reported identical white pixels — same template path — so both states are asserted.
    func testInteractiveOverseenMarkKeepsTheFirstOverseersPaletteColour() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true)

        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), markPixelFloor,
            "interactive overseen mark lost the overseer's palette colour (template-flattened)"
        )

        var selectedRow = row(role: role, interactive: true)
        selectedRow.isSelected = true
        let (selectedRep, selectedWindow) = rasterize(selectedRow)
        defer { selectedWindow.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: selectedRep), markPixelFloor,
            "interactive overseen mark lost the palette colour on the selected row"
        )
    }

    /// The non-interactive branch was already correct — the mark was only template-flattened
    /// inside a Menu label — so a muted row keeps its colour too. Guards the two branches
    /// staying visually identical.
    func testNonInteractiveOverseenMarkKeepsTheSamePaletteColour() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true)

        let (rep, window) = rasterize(row(role: role, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), markPixelFloor,
            "non-interactive overseen mark lost the palette colour"
        )
    }

    /// A selected/active-looking row hits the same Menu label path — the palette survives
    /// because the glyph is ordinary content, not a template image.
    func testInteractiveBothRolesMarkKeepsBothPaletteColours() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: 1,
            overseers: [
                .init(sessionID: id(1), displayName: "Overseer A", slot: 0),
                .init(sessionID: id(2), displayName: "Overseer B", slot: 3)
            ],
            overseeingNames: ["Lane B"]
        )
        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }

        XCTAssertGreaterThanOrEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 1, darkAppearance: true), in: rep),
            markPixelFloor,
            "dual-role mark lost the row's own group colour"
        )
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            markPixelFloor,
            "dual-role mark lost the first overseer's ring colour"
        )
    }

    /// Control: an inactive (no link) row draws no palette pixels at all, proving the colour
    /// assertions above come from the mark rather than stray UI.
    func testRowWithoutRolePaintsNoPalettePixels() {
        let (rep, window) = rasterize(row(role: .none, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThan(rep.pixelsWide, 0, "raster produced an empty bitmap")
        XCTAssertEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            0
        )
    }

    // MARK: - Passive-mark switch

    private func role(own: Int?, overseers: Int) -> AgentSessionOversightRole {
        AgentSessionOversightRole(
            ownOverseerSlot: own,
            overseers: (0 ..< overseers).map {
                .init(sessionID: id(UInt8($0 + 1)), displayName: "Overseer \($0)", slot: $0)
            },
            overseeingNames: own == nil ? [] : ["Lane B"]
        )
    }

    /// Switch OFF (current default): every role mark opens the unified oversight menu.
    func testMarkSwitchDefaultOpensMenuForAllRoles() {
        agentOversightRoleMarksArePassive = false
        defer { agentOversightRoleMarksArePassive = false }
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 0)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: nil, overseers: 1)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 1)))
    }

    /// Switch ON (rollback path): every role mark becomes a passive tooltip-only indicator.
    func testPassiveSwitchOnMakesAllMarksPassive() {
        agentOversightRoleMarksArePassive = true
        defer { agentOversightRoleMarksArePassive = false }
        XCTAssertFalse(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 0)))
        XCTAssertFalse(agentSessionRowOversightMarkIsInteractive(role: role(own: nil, overseers: 1)))
        XCTAssertFalse(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 1)))
    }

    // MARK: - ID-less rows (option a)

    /// A fresh chat has no session ID until the first send: its context menu still lists both
    /// Oversee submenus, each containing only the approved disabled reason.
    func testIDLessRowOffersDisabledOversightSubmenusWithReason() {
        XCTAssertEqual(
            AgentOversightUICopy.oversightAvailableAfterFirstMessage,
            "Available after the first message"
        )

        var idlessRow = row(role: .none, interactive: false)
        idlessRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        XCTAssertTrue(idlessRow.showsDisabledOversightContextSubmenus)

        // Multi-select / bulk-mutation modes suppress the oversight section entirely.
        var suppressedRow = row(role: .none, interactive: false)
        suppressedRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        suppressedRow.showsSelectionPresentation = true
        XCTAssertFalse(suppressedRow.showsDisabledOversightContextSubmenus)

        // A bound row resolves a live menu — the disabled pair must not appear alongside it.
        var linkedRow = row(role: .none, interactive: true)
        linkedRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        XCTAssertFalse(linkedRow.showsDisabledOversightContextSubmenus)

        // And a bound row never carries the reason.
        XCTAssertFalse(row(role: .none, interactive: true).showsDisabledOversightContextSubmenus)
    }
}

@MainActor
final class AgentSidebarOversightStableMenuTests: XCTestCase {
    private func endpoint(_ seed: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: seed,
            workspaceID: UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!,
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func peer(
        _ label: String,
        seed: Int,
        relationship: AgentSidebarOversightMenuProps.Relationship = .available
    ) -> AgentSidebarOversightMenuProps.PeerOption {
        AgentSidebarOversightMenuProps.PeerOption(
            peerEndpoint: endpoint(seed),
            peerSessionID: UUID(),
            displayName: label,
            providerDisplayName: nil,
            menuLabel: label,
            fullIdentityDescription: "identity \(label)",
            relationship: relationship
        )
    }

    private func link(_ seed: Int) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: UUID(), generation: UInt64(seed))
    }

    private func props(
        observerOptions: [AgentSidebarOversightMenuProps.PeerOption] = [],
        targetOptions: [AgentSidebarOversightMenuProps.PeerOption] = [],
        createdByLabel: String? = nil,
        creatorSessionID: UUID? = nil,
        targetIneligibleReason: String? = nil,
        observerIneligibleReason: String? = nil
    ) -> AgentSidebarOversightMenuProps {
        let targetEndpoint = endpoint(0)
        return AgentSidebarOversightMenuProps(
            targetEndpoint: targetEndpoint,
            targetSessionID: targetEndpoint.sessionID,
            targetDisplayName: "Row",
            observerOptions: observerOptions,
            createdByLabel: createdByLabel,
            targetOptions: targetOptions,
            targetIneligibleReason: targetIneligibleReason,
            observerIneligibleReason: observerIneligibleReason,
            inboundObserverNames: [],
            inboundObserverSessionIDs: [],
            outboundTargetNames: [],
            creatorSessionID: creatorSessionID
        )
    }

    /// Fires the item's AppKit action through the menu, the same dispatch the presenter
    /// relies on (`NSMenu.stableMenu` + `performActionForItem`).
    private func fire(_ item: NSMenuItem) {
        _ = NSApplication.shared
        guard let owner = item.menu else {
            XCTFail("item is not attached to a menu")
            return
        }
        owner.performActionForItem(at: owner.index(of: item))
    }

    private func submenu(_ title: String, in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenu {
        try XCTUnwrap(
            menu.items.first { $0.title == title }?.submenu,
            "expected submenu \(title)",
            file: file,
            line: line
        )
    }

    func testLinkedRowShapeMatchesApprovedOrder() {
        let target = peer("Target", seed: 1, relationship: .linked(reference: link(11), peerCurrentlyEligible: true))
        let observer = peer("Observer", seed: 2, relationship: .linked(reference: link(12), peerCurrentlyEligible: true))
        let creatorID = UUID()
        let menuProps = props(
            observerOptions: [observer, peer("Candidate", seed: 3)],
            targetOptions: [target, peer("Other", seed: 4)],
            createdByLabel: "Creator",
            creatorSessionID: creatorID
        )

        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init()
        ))

        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, [
            "Overseeing", "Target",
            "Overseen by", "Observer",
            "Created by", "Creator",
            "",
            "Oversee new", "Oversee by",
            "",
            "Unlink"
        ])
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        XCTAssertTrue(menu.items[9].isSeparatorItem)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[0].accessibilityHelp(), nil)
    }

    func testOverseeNewItemsAndDisabledReason() throws {
        let candidateItem = peer("Session B", seed: 1)
        let menuProps = props(targetOptions: [candidateItem])
        var added: [AgentSidebarOversightMenuProps.TargetOption] = []
        var chooseTargetCount = 0
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init(
                addOutbound: { added.append($0) },
                presentChooseTargetSheet: { chooseTargetCount += 1 }
            )
        ))

        let overseeNew = try submenu("Oversee new", in: menu)
        XCTAssertEqual(overseeNew.items.map(\.title), ["Session B", "", "Session ID…"])
        XCTAssertTrue(overseeNew.items[0].isEnabled)
        XCTAssertTrue(overseeNew.items[1].isSeparatorItem)
        XCTAssertTrue(overseeNew.items[2].isEnabled)
        XCTAssertEqual(overseeNew.items[0].accessibilityHelp(), "identity Session B")

        fire(overseeNew.items[0])
        XCTAssertEqual(added.map(\.peerEndpoint), [candidateItem.peerEndpoint])

        fire(overseeNew.items[2])
        XCTAssertEqual(chooseTargetCount, 1)
    }

    func testOverseeByInboundActionAndIneligibleReason() throws {
        let candidateItem = peer("Overseer", seed: 1)
        let menuProps = props(observerOptions: [candidateItem])
        var added: [AgentSidebarOversightMenuProps.ObserverOption] = []
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init(addInbound: { added.append($0) })
        ))

        let overseeBy = try submenu("Oversee by", in: menu)
        XCTAssertEqual(overseeBy.items.map(\.title), ["Overseer", "", "Session ID…"])
        fire(overseeBy.items[0])
        XCTAssertEqual(added.map(\.peerEndpoint), [candidateItem.peerEndpoint])

        let blocked = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(observerOptions: [candidateItem], targetIneligibleReason: "Not eligible"),
            busyKeys: [],
            actions: .init()
        ))
        let blockedBy = try submenu("Oversee by", in: blocked)
        XCTAssertEqual(blockedBy.items.map(\.title), ["Not eligible", "Overseer", "", "Session ID…"])
        XCTAssertFalse(blockedBy.items[0].isEnabled)
        // Parity with the SwiftUI builder: the candidate itself stays enabled; only the
        // reason row and the Session-ID item are disabled by an inbound eligibility reason.
        XCTAssertTrue(blockedBy.items[1].isEnabled)
        XCTAssertFalse(blockedBy.items[3].isEnabled)
    }

    func testEmptyDirectionFallsBackToMessageItem() throws {
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(),
            busyKeys: [],
            actions: .init()
        ))
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, ["Manage session oversight", "Oversee new", "Oversee by"])

        let overseeNew = try submenu("Oversee new", in: menu)
        XCTAssertEqual(overseeNew.items.map(\.title), ["No sessions to oversee", "", "Session ID…"])
        XCTAssertFalse(overseeNew.items[0].isEnabled)

        let overseeBy = try submenu("Oversee by", in: menu)
        XCTAssertEqual(overseeBy.items.map(\.title), ["No eligible overseers", "", "Session ID…"])
    }

    func testUnlinkSubmenuFiresExactReference() throws {
        let reference = link(7)
        let linkedObserver = peer(
            "Overseer",
            seed: 1,
            relationship: .linked(reference: reference, peerCurrentlyEligible: true)
        )
        let menuProps = props(observerOptions: [linkedObserver])
        var unlinked: [(DomainAgentSessionLinkEndpointIdentity, DomainAgentSessionLinkEndpointIdentity, DomainAgentSessionLinkReference)] = []
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init(unlink: { unlinked.append(($0, $1, $2)) })
        ))

        let unlink = try submenu("Unlink", in: menu)
        XCTAssertEqual(unlink.items.map(\.title), ["Overseen by", "Overseer"])
        XCTAssertFalse(unlink.items[0].isEnabled)
        XCTAssertEqual(unlink.items[1].accessibilityLabel(), "Unlink \"Overseer\"")

        fire(unlink.items[1])
        XCTAssertEqual(unlinked.count, 1)
        XCTAssertEqual(unlinked[0].0, linkedObserver.peerEndpoint)
        XCTAssertEqual(unlinked[0].1, menuProps.targetEndpoint)
        XCTAssertEqual(unlinked[0].2, reference)
    }

    /// When the creator is the row's only overseer the Overseen-by header collapses to
    /// "Created and overseen by" and no separate Created-by section renders.
    func testCreatorSoleOverseerCollapsesOverseenByHeader() {
        let creatorSessionID = UUID()
        let creatorEndpoint = endpoint(1)
        let creator = AgentSidebarOversightMenuProps.PeerOption(
            peerEndpoint: creatorEndpoint,
            peerSessionID: creatorSessionID,
            displayName: "Creator",
            providerDisplayName: nil,
            menuLabel: "Creator",
            fullIdentityDescription: "identity Creator",
            relationship: .linked(reference: link(5), peerCurrentlyEligible: true)
        )
        let menuProps = props(
            observerOptions: [creator],
            createdByLabel: "Creator",
            creatorSessionID: creatorSessionID
        )

        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init()
        ))
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Created and overseen by"))
        XCTAssertFalse(titles.contains("Overseen by"))
        XCTAssertFalse(titles.contains("Created by"))
        XCTAssertEqual(titles.count(where: { $0 == "Creator" }), 1)
    }

    /// The outbound direction unlink passes the row as observer and the peer as target —
    /// the reverse of the inbound arm — so the runtime bridge fences the right link.
    func testUnlinkOutboundDispatchesRowAsObserver() throws {
        let reference = link(9)
        let linkedTarget = peer(
            "Target",
            seed: 1,
            relationship: .linked(reference: reference, peerCurrentlyEligible: true)
        )
        let menuProps = props(targetOptions: [linkedTarget])
        var unlinked: [(DomainAgentSessionLinkEndpointIdentity, DomainAgentSessionLinkEndpointIdentity, DomainAgentSessionLinkReference)] = []
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init(unlink: { unlinked.append(($0, $1, $2)) })
        ))

        let unlink = try submenu("Unlink", in: menu)
        XCTAssertEqual(unlink.items.map(\.title), ["Overseeing", "Target"])
        fire(unlink.items[1])
        XCTAssertEqual(unlinked.count, 1)
        XCTAssertEqual(unlinked[0].0, menuProps.targetEndpoint)
        XCTAssertEqual(unlinked[0].1, linkedTarget.peerEndpoint)
        XCTAssertEqual(unlinked[0].2, reference)
    }

    func testBusyKeyFreezesItemDisabledWithHourglass() throws {
        let candidateItem = peer("Session B", seed: 1)
        let menuProps = props(targetOptions: [candidateItem])
        let busy: Set<AgentSidebarOversightActionKey> = [
            .add(
                observerEndpoint: menuProps.targetEndpoint,
                targetEndpoint: candidateItem.peerEndpoint
            )
        ]
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: busy,
            actions: .init()
        ))

        let overseeNew = try submenu("Oversee new", in: menu)
        let item = overseeNew.items[0]
        XCTAssertFalse(item.isEnabled)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(item.accessibilityValue() as? String, "In progress")
    }

    func testJumpItemRoutesPeerEndpoint() {
        let target = peer("Target", seed: 1, relationship: .linked(reference: link(1), peerCurrentlyEligible: true))
        var opened: [DomainAgentSessionLinkEndpointIdentity] = []
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(targetOptions: [target]),
            busyKeys: [],
            actions: .init(openLinkedSession: { opened.append($0) })
        ))

        let jumpItem = menu.items[1]
        XCTAssertEqual(jumpItem.title, "Target")
        XCTAssertEqual(jumpItem.accessibilityHelp(), "Opens \"Target\"")
        fire(jumpItem)
        XCTAssertEqual(opened, [target.peerEndpoint])
    }

    func testSubmenuAccessibilityValuesCarryCounts() throws {
        let target = peer("T", seed: 1, relationship: .linked(reference: link(1), peerCurrentlyEligible: true))
        let observer = peer("O", seed: 2, relationship: .linked(reference: link(2), peerCurrentlyEligible: true))
        let menuProps = props(
            observerOptions: [observer, peer("C", seed: 3)],
            targetOptions: [target]
        )
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            menuProps,
            busyKeys: [],
            actions: .init()
        ))

        let overseeNewItem = try XCTUnwrap(menu.items.first { $0.title == "Oversee new" })
        XCTAssertEqual(overseeNewItem.accessibilityValue() as? String, "Overseeing 1; 0 available")
        let overseeByItem = try XCTUnwrap(menu.items.first { $0.title == "Oversee by" })
        XCTAssertEqual(overseeByItem.accessibilityValue() as? String, "Overseen by 1; 1 available")
        let unlinkItem = try XCTUnwrap(menu.items.first { $0.title == "Unlink" })
        XCTAssertEqual(unlinkItem.accessibilityValue() as? String, "2 linked")
    }
}
