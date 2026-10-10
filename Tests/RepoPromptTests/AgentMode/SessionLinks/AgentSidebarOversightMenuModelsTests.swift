import AppKit
import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptSettingsCore
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

/// The interactive oversight mark must keep its role colour. Wrapping the glyph in a macOS
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
            row.resolveSidebarOversightSummary = {
                AgentSidebarOversightSummary(
                    linkedObserverCount: props.linkedObservers.count, availableObserverCount: props.availableObservers.count,
                    inboundObserverNames: props.linkedObservers.map(\.displayName),
                    inboundObserverSessionIDs: props.linkedObservers.map(\.peerSessionID),
                    outboundTargetNames: [], createdByLabel: nil, creatorSessionID: nil,
                    targetIneligibleReason: nil, observerIneligibleReason: nil
                )
            }
            row.onAddSidebarOversight = { _, _ in .changed }
            row.onStopSidebarOversight = { _, _, _ in .changed }
        }
        return row
    }

    /// Hosts a row in a real window so the Menu materializes its native control, then
    /// rasterizes it in dark appearance (the reported failure environment).
    private func rasterize(
        _ view: some View,
        appearance: NSAppearance.Name = .darkAqua,
        size: NSSize = NSSize(width: 280, height: 60)
    ) -> (rep: NSBitmapImageRep, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
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

    func testSelectedInteractiveOverseerKeepsAmber() {
        for (appearance, expected) in [
            (NSAppearance.Name.darkAqua, NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1)),
            (NSAppearance.Name.aqua, NSColor(srgbRed: 194 / 255, green: 106 / 255, blue: 0, alpha: 1))
        ] {
            var selectedRow = row(role: role(own: 0, overseers: 0), interactive: true)
            selectedRow.isSelected = true
            let (rep, window) = rasterize(selectedRow, appearance: appearance)
            XCTAssertGreaterThanOrEqual(
                pixelCount(near: expected, in: rep), markPixelFloor,
                "selected overseer mark lost adaptive amber in \(appearance)"
            )
            window.close()
        }
    }

    /// Worker grey must survive the native menu label path, including a selected row.
    func testInteractiveOverseenMarkKeepsWorkerGrey() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = NSColor.systemGray
        let (controlRep, controlWindow) = rasterize(row(role: .none, interactive: true))
        defer { controlWindow.close() }
        let workerPixelFloor = pixelCount(near: expected, in: controlRep) + markPixelFloor

        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), workerPixelFloor,
            "interactive worker mark lost system grey (template-flattened)"
        )

        var selectedRow = row(role: role, interactive: true)
        selectedRow.isSelected = true
        let (selectedRep, selectedWindow) = rasterize(selectedRow)
        defer { selectedWindow.close() }
        var selectedControl = row(role: .none, interactive: true)
        selectedControl.isSelected = true
        let (selectedControlRep, selectedControlWindow) = rasterize(selectedControl)
        defer { selectedControlWindow.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: selectedRep),
            pixelCount(near: expected, in: selectedControlRep) + markPixelFloor,
            "interactive worker mark lost system grey on the selected row"
        )
    }

    /// Passive role marks use the same vector and colour as interactive marks.
    func testNonInteractiveOverseenMarkKeepsWorkerGrey() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = NSColor.systemGray

        let (controlRep, controlWindow) = rasterize(row(role: .none, interactive: false))
        defer { controlWindow.close() }
        let (rep, window) = rasterize(row(role: role, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), pixelCount(near: expected, in: controlRep) + markPixelFloor,
            "non-interactive worker mark lost system grey"
        )
    }

    /// Dual-role rows retain both the amber hub and grey worker, plus the inbound count.
    func testInteractiveBothRolesMarkKeepsBothRoleColours() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: 1,
            overseers: [
                .init(sessionID: id(1), displayName: "Overseer A", slot: 0),
                .init(sessionID: id(2), displayName: "Overseer B", slot: 3)
            ],
            overseeingNames: ["Lane B"]
        )
        // Keep the count out of this render assertion: it also paints grey pixels.
        let singleInboundRole = AgentSessionOversightRole(
            ownOverseerSlot: role.ownOverseerSlot,
            overseers: Array(role.overseers.prefix(1)),
            overseeingNames: role.overseeingNames
        )
        let (controlRep, controlWindow) = rasterize(row(role: self.role(own: 1, overseers: 0), interactive: true))
        defer { controlWindow.close() }
        let (rep, window) = rasterize(row(role: singleInboundRole, interactive: true))
        defer { window.close() }

        XCTAssertGreaterThanOrEqual(
            pixelCount(near: NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1), in: rep),
            markPixelFloor,
            "dual-role mark lost the amber hub"
        )
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: .systemGray, in: rep),
            pixelCount(near: .systemGray, in: controlRep) + markPixelFloor,
            "dual-role mark lost the grey worker"
        )
    }

    /// Control: an inactive (no link) row draws no amber role pixels.
    func testRowWithoutRolePaintsNoAmberPixels() {
        let (rep, window) = rasterize(row(role: .none, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThan(rep.pixelsWide, 0, "raster produced an empty bitmap")
        XCTAssertEqual(
            pixelCount(near: NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1), in: rep),
            0
        )
    }

    /// The shared vectors must paint with the caller's foreground at the intended 16px size.
    func testRoleVectorsRespectForegroundAtSixteenPoints() {
        for role in [AgentOversightRoleIcon.Role.overseer, .worker] {
            let (rep, window) = rasterize(
                AgentOversightRoleIcon(role: role, size: 16).foregroundStyle(Color(nsColor: .red))
            )
            XCTAssertGreaterThanOrEqual(pixelCount(near: .red, in: rep), markPixelFloor)
            window.close()
        }
    }

    func testToolbarRoleMapping() {
        typealias Role = AgentOversightRoleIcon.Role
        XCTAssertEqual(Role.toolbarRoles(isOverseer: false, hasInbound: false), [.overseer])
        XCTAssertEqual(Role.toolbarRoles(isOverseer: false, hasInbound: true), [.worker])
        XCTAssertEqual(Role.toolbarRoles(isOverseer: true, hasInbound: false), [.overseer])
        XCTAssertEqual(Role.toolbarRoles(isOverseer: true, hasInbound: true), [.overseer, .worker])
    }

    func testRoleGeometryAndWorkerParentFade() throws {
        for role in [AgentOversightRoleIcon.Role.overseer, .worker] {
            let (rep, window) = rasterize(
                AgentOversightRoleIcon(role: role, size: 24)
                    .foregroundStyle(Color(nsColor: .red))
                    .background(Color.black),
                size: NSSize(width: 24, height: 24)
            )
            defer { window.close() }
            func red(atX x: CGFloat, y: CGFloat) throws -> CGFloat {
                let pixel = try XCTUnwrap(rep.colorAt(
                    x: Int(x * CGFloat(rep.pixelsWide) / 24),
                    y: Int(y * CGFloat(rep.pixelsHigh) / 24)
                )?.usingColorSpace(.sRGB))
                return pixel.redComponent
            }
            if role == .overseer {
                XCTAssertGreaterThan(try red(atX: 12, y: 12), 0.9, "hub must be filled")
                XCTAssertLessThan(try red(atX: 12, y: 17), 0.1, "hub must not use worker geometry")
                XCTAssertLessThan(try red(atX: 12, y: 3.5), 0.1, "satellite must be hollow")
            } else {
                XCTAssertGreaterThan(try red(atX: 12, y: 17), 0.9, "worker must be filled")
                XCTAssertLessThan(try red(atX: 12, y: 4.5), 0.1, "parent must be hollow")
                XCTAssertEqual(try red(atX: 12, y: 9), 0.5, accuracy: 0.1, "parent link must be faded")
                XCTAssertEqual(try red(atX: 12, y: 7), 0.5, accuracy: 0.1, "parent overlap must not darken")
            }
        }
    }

    func testOverseerAmberResolvesForBothAppearances() throws {
        for (appearanceName, expected) in [
            (NSAppearance.Name.darkAqua, NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1)),
            (NSAppearance.Name.aqua, NSColor(srgbRed: 194 / 255, green: 106 / 255, blue: 0, alpha: 1))
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = AgentOversightRoleStyle.overseerNSColor.usingColorSpace(.sRGB)
            }
            let actual = try XCTUnwrap(resolved)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        }
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

    /// Switch OFF (not the default): every role mark would open the unified oversight menu.
    func testMarkSwitchOffOpensMenuForAllRoles() {
        agentOversightRoleMarksArePassive = false
        defer { agentOversightRoleMarksArePassive = true }
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 0)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: nil, overseers: 1)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 1)))
    }

    /// Switch ON (current default): every role mark is a passive tooltip-only indicator.
    func testPassiveSwitchOnMakesAllMarksPassive() {
        agentOversightRoleMarksArePassive = true
        defer { agentOversightRoleMarksArePassive = true }
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
            "Overseen by", "Observer",
            "Overseeing", "Target",
            "Created by", "Creator",
            "",
            "Link overseer", "Oversee", "Unlink"
        ])
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        XCTAssertFalse(menu.items[9].isSeparatorItem)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[0].accessibilityHelp(), nil)
    }

    /// Order contract: "Overseen by" — including its "Created and overseen by" collapse —
    /// leads "Overseeing" wherever both sections render: the menu's top sections, the Unlink
    /// submenu (where the groups are headed "Unlink overseer" / "Unlink overseen"), and the
    /// monitor pill popover. The hierarchy reads top-down.
    func testOverseenBySectionLeadsOverseeingWhereBothSectionsExist() throws {
        let target = peer("Target", seed: 1, relationship: .linked(reference: link(11), peerCurrentlyEligible: true))
        let observer = peer("Observer", seed: 2, relationship: .linked(reference: link(12), peerCurrentlyEligible: true))
        let menu = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(observerOptions: [observer], targetOptions: [target]),
            busyKeys: [],
            actions: .init()
        ))

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Overseen by", "Observer", "Overseeing", "Target", "", "Link overseer", "Oversee", "Unlink"]
        )
        XCTAssertEqual(
            try submenu("Unlink", in: menu).items.map(\.title),
            ["Unlink overseer", "Observer", "Unlink overseen", "Target"]
        )
        XCTAssertEqual(
            AgentMonitorPopoverLinkedSection.displayOrder(hasInbound: true, hasOutbound: true),
            [.inbound, .outbound]
        )

        // The sole-overseer collapse keeps the same lead position.
        let creatorSessionID = UUID()
        let creator = AgentSidebarOversightMenuProps.PeerOption(
            peerEndpoint: endpoint(3),
            peerSessionID: creatorSessionID,
            displayName: "Creator",
            providerDisplayName: nil,
            menuLabel: "Creator",
            fullIdentityDescription: "identity Creator",
            relationship: .linked(reference: link(13), peerCurrentlyEligible: true)
        )
        let collapsed = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(
                observerOptions: [creator],
                targetOptions: [target],
                createdByLabel: "Creator",
                creatorSessionID: creatorSessionID
            ),
            busyKeys: [],
            actions: .init()
        ))
        XCTAssertEqual(
            collapsed.items.map(\.title),
            [
                "Created and overseen by", "Creator",
                "Overseeing", "Target",
                "", "Link overseer", "Oversee", "Unlink"
            ]
        )
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

        let overseeNew = try submenu("Oversee", in: menu)
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

    func testPersistenceOverlayRetainsDisabledOutboundChoicesAndAccessibilityCount() throws {
        let offered = [peer("Session B", seed: 1), peer("Session C", seed: 2)]
        let presentation = AgentSessionOversightPersistencePresentation(availability: .blocked("Persistence blocked"))
        let blocker = try XCTUnwrap(presentation.addBlockerMessage)
        let published = AgentMonitorPillProps(
            sessionID: nil, outbound: [], inbound: [], recentNotices: [], canAddReason: nil
        )
        // Menus are lazy now: apply the same persistence-first reason supplied by the shared pill.
        let reason = published.withPersistence(presentation, eligibilityReason: "Lifecycle reason").canAddReason
        let overlaid = props(targetOptions: offered).withObserverIneligibleReason(reason)
        XCTAssertEqual(overlaid.observerIneligibleReason, blocker)
        XCTAssertEqual(overlaid.availableTargets, offered, "Offered choices are not actionable eligibility")

        let root = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            overlaid, busyKeys: [], actions: .init()
        ))
        let choices = try submenu("Oversee", in: root)
        XCTAssertEqual(choices.items.map(\.title), [blocker, "Session B", "Session C", "", "Session ID…"])
        XCTAssertTrue(choices.items.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(
            root.items.first { $0.title == "Oversee" }?.accessibilityValue() as? String,
            AgentOversightUICopy.overseeMenuAccessibilityValue(overseeingCount: 0, availableCount: 2)
        )
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

        let overseeBy = try submenu("Link overseer", in: menu)
        XCTAssertEqual(overseeBy.items.map(\.title), ["Overseer", "", "Session ID…"])
        fire(overseeBy.items[0])
        XCTAssertEqual(added.map(\.peerEndpoint), [candidateItem.peerEndpoint])

        let blocked = NSMenu.stableMenu(from: AgentSessionRow.sidebarOversightMenuItems(
            props(observerOptions: [candidateItem], targetIneligibleReason: "Not eligible"),
            busyKeys: [],
            actions: .init()
        ))
        let blockedBy = try submenu("Link overseer", in: blocked)
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
        XCTAssertEqual(titles, ["Manage session oversight", "Link overseer", "Oversee"])

        let overseeNew = try submenu("Oversee", in: menu)
        XCTAssertEqual(overseeNew.items.map(\.title), ["No sessions to oversee", "", "Session ID…"])
        XCTAssertFalse(overseeNew.items[0].isEnabled)

        let overseeBy = try submenu("Link overseer", in: menu)
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
        XCTAssertEqual(unlink.items.map(\.title), ["Unlink overseer", "Overseer"])
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
        XCTAssertEqual(unlink.items.map(\.title), ["Unlink overseen", "Target"])
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

        let overseeNew = try submenu("Oversee", in: menu)
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

        let overseeNewItem = try XCTUnwrap(menu.items.first { $0.title == "Oversee" })
        XCTAssertEqual(overseeNewItem.accessibilityValue() as? String, "Overseeing 1; 0 available")
        let overseeByItem = try XCTUnwrap(menu.items.first { $0.title == "Link overseer" })
        XCTAssertEqual(overseeByItem.accessibilityValue() as? String, "Overseen by 1; 1 available")
        let unlinkItem = try XCTUnwrap(menu.items.first { $0.title == "Unlink" })
        XCTAssertEqual(unlinkItem.accessibilityValue() as? String, "2 linked")
    }
}

/// Records entry into the forbidden hydration boundary, separately from provider factories.
private struct SidebarHydrationRecorder: WorkspaceRestorePerfRecording {
    let attempts: LifecycleRecorder
    private let fallback = NoopWorkspaceRestorePerfRecorder()
    var isEnabled: Bool {
        true
    }

    func timestampMSIfEnabled() -> Double? {
        fallback.timestampMS()
    }

    func timestampMS() -> Double {
        fallback.timestampMS()
    }

    func elapsedMS(since startMS: Double) -> Double {
        fallback.elapsedMS(since: startMS)
    }

    func formatMS(_ value: Double) -> String {
        fallback.formatMS(value)
    }

    func formatElapsedMS(since startMS: Double) -> String {
        fallback.formatElapsedMS(since: startMS)
    }

    func shortID(_ id: UUID?) -> String {
        fallback.shortID(id)
    }

    @MainActor func nextAgentActivationTrueCount() -> Int {
        0
    }

    func log(_: @autoclosure () -> String) {}
    func event(_ name: String, fields: [String: String]) {
        if name == "agentSessionHydration.loadTask" {
            attempts.record(fields["outcome"] ?? "unknown")
        }
    }
}

/// Full sidebar construction and native opening, not supplied-props item-builder coverage.
@MainActor
final class AgentSidebarHostedContextMenuTests: XCTestCase {
    @MainActor private struct Fixture {
        let state: WindowState
        let tabs: [ComposeTabState]
        let host: NSHostingView<AgentModeSessionsSidebarView>
        let window: NSWindow
        let providerAttempts: LifecycleRecorder
        let hydrationAttempts: LifecycleRecorder
        var vm: AgentModeViewModel {
            state.agentModeViewModel
        }
    }

    private enum UnexpectedProviderLaunch: Error { case refused }
    private enum Opening { case rightClick, controlClick, accessibility }

    @MainActor private final class SubmenuOpeningObserver: NSObject, NSMenuDelegate {
        let delegate: NSMenuDelegate?
        var onOpen: (NSMenu) -> Void = { _ in }

        init(delegate: NSMenuDelegate?) {
            self.delegate = delegate
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            delegate?.menuNeedsUpdate?(menu)
        }

        func menuWillOpen(_ menu: NSMenu) {
            onOpen(menu)
        }
    }

    func testColdRightClickShowsEightOutboundAndInbound() async throws {
        let fixture = try await makeFixture()
        for index in 1 ... 8 {
            try await add(from: 0, to: index, in: fixture)
        }
        try await add(from: 9, to: 0, in: fixture)
        let props = try menuProps(in: fixture)
        XCTAssertEqual(props.linkedTargets.count, 8)
        XCTAssertEqual(props.linkedObservers.count, 1)

        let menu = try await open(in: fixture)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains(AgentOversightUICopy.overseeingSectionLabel))
        XCTAssertTrue(titles.contains(AgentOversightUICopy.overseenBySectionLabel))
        for index in 1 ... 9 {
            XCTAssertTrue(titles.contains { $0.contains("Hosted peer \(index)") }, "Missing peer \(index)")
        }
        let unlinkIndex = try XCTUnwrap(titles.firstIndex(of: AgentOversightUICopy.unlinkTitle))
        XCTAssertEqual(titles[unlinkIndex - 1], AgentOversightUICopy.overseeNewTitle)
        XCTAssertTrue(menu.items[unlinkIndex + 1].isSeparatorItem)
        XCTAssertEqual(titles[unlinkIndex + 2], "Select chat")
        XCTAssertTrue(titles.contains("Stash chat for later"), "Opening must also capture current standard callbacks")
        XCTAssertEqual(try menuProps(in: fixture), props, "Opening alone must not mutate the settled relationship presentation")
    }

    func testColdRightClickShowsUnavailableSubmenusBeforeProjectionReady() async throws {
        let fixture = try await makeFixture(peerCount: 2)
        let endpoint = try menuProps(in: fixture).targetEndpoint
        AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
        defer { AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false }
        XCTAssertNil(fixture.vm.agentSidebarOversightMenuProps(
            tabID: fixture.tabs[0].id, expectedSessionID: endpoint.sessionID
        ))

        let menu = try await open(in: fixture)
        for title in [AgentOversightUICopy.overseeNewTitle, AgentOversightUICopy.overseeByTitle] {
            let submenu = try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), ["Not available yet — reopen this menu"])
            XCTAssertFalse(submenu.items[0].isEnabled)
        }
    }

    func testColdControlClickShowsInboundOnly() async throws {
        let fixture = try await makeFixture(peerCount: 2)
        try await add(from: 1, to: 0, in: fixture)
        let menu = try await open(in: fixture, via: .controlClick)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains(AgentOversightUICopy.overseenBySectionLabel))
        XCTAssertFalse(titles.contains(AgentOversightUICopy.overseeingSectionLabel))
        XCTAssertTrue(titles.contains { $0.contains("Hosted peer 1") })
        XCTAssertNotNil(menu.items.first { $0.title == AgentOversightUICopy.overseeNewTitle }?.submenu)
        XCTAssertNotNil(menu.items.first { $0.title == AgentOversightUICopy.overseeByTitle }?.submenu)
    }

    func testColdAccessibilityOpeningShowsLinklessLiveChoices() async throws {
        let fixture = try await makeFixture(peerCount: 2)
        let props = try menuProps(in: fixture)
        XCTAssertTrue(props.linkedTargets.isEmpty)
        XCTAssertTrue(props.linkedObservers.isEmpty)
        let menu = try await open(in: fixture, via: .accessibility)
        let targets = try XCTUnwrap(menu.items.first { $0.title == AgentOversightUICopy.overseeNewTitle }?.submenu)
        XCTAssertTrue(targets.items.contains { $0.title.contains("Hosted peer 1") && $0.isEnabled })
        XCTAssertFalse(targets.items.contains { $0.title == "Loading…" })
        XCTAssertNotNil(menu.items.first { $0.title == AgentOversightUICopy.overseeByTitle }?.submenu)
        XCTAssertFalse(menu.items.contains { $0.title == AgentOversightUICopy.overseeingSectionLabel })
        XCTAssertFalse(menu.items.contains { $0.title == AgentOversightUICopy.overseenBySectionLabel })
    }

    func testColdIDlessRowShowsDisabledReasonsWithoutMintingSession() async throws {
        let fixture = try await makeFixture(peerCount: 1, idless: true)
        let menu = try await open(in: fixture)
        for title in [AgentOversightUICopy.overseeNewTitle, AgentOversightUICopy.overseeByTitle] {
            let submenu = try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), [AgentOversightUICopy.oversightAvailableAfterFirstMessage])
            XCTAssertFalse(submenu.items[0].isEnabled)
        }
        XCTAssertNil(fixture.vm.session(for: fixture.tabs[0].id).activeAgentSessionID)
    }

    func testIDlessMountedRowReadsInstalledBindingOnFreshNativeOpening() async throws {
        let fixture = try await makeFixture(peerCount: 1, idless: true)
        let otherWindow = try await makeFixture(peerCount: 1)
        try await add(from: 0, to: 1, in: otherWindow)
        let region = try mountedRegion(in: fixture)
        let cold = try await open(in: fixture)
        XCTAssertFalse(try XCTUnwrap(cold.items.first { $0.title == "Copy Session ID" }).isEnabled)

        let session = fixture.vm.session(for: fixture.tabs[0].id)
        let workspaceID = try XCTUnwrap(fixture.state.workspaceManager.activeWorkspaceID)
        let firstID = UUID()
        XCTAssertNotNil(fixture.vm.test_installPersistentSessionBinding(
            sessionID: firstID, on: session, compareAndSetInWorkspaceID: workspaceID
        ))
        session.items = [AgentChatItem(kind: .user, text: "First bound fixture message")]
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
        await AgentSessionLinkRuntimeBridge.shared.test_settleMonitorProjectionRefresh()
        await settleHostedPublication(in: fixture)

        let input = try XCTUnwrap(fixture.state.promptManager.sidebarWorkspaceSnapshot)
        XCTAssertEqual(fixture.vm.agentChatsSidebarSessions(for: input.composeTabs).first {
            $0.tabID == fixture.tabs[0].id
        }?.sessionID, firstID, "The sidebar row cache must publish the installed binding")
        let props = try XCTUnwrap(fixture.vm.agentSidebarOversightMenuProps(
            tabID: fixture.tabs[0].id, expectedSessionID: firstID
        ))
        let observerEndpoint = try menuProps(in: otherWindow).targetEndpoint
        let observer = try XCTUnwrap(props.availableObservers.first { $0.peerEndpoint == observerEndpoint })
        let target = try XCTUnwrap(props.availableTargets.first { $0.peerEndpoint == observerEndpoint })
        XCTAssertTrue(try mountedRegion(in: fixture) === region, "Binding must update the existing native row provider")
        let bound = try await open(in: fixture)
        XCTAssertTrue(try XCTUnwrap(bound.items.first { $0.title == "Copy Session ID" }).isEnabled)
        for (title, label) in [
            (AgentOversightUICopy.overseeNewTitle, target.menuLabel),
            (AgentOversightUICopy.overseeByTitle, observer.menuLabel)
        ] {
            let submenu = try XCTUnwrap(bound.items.first { $0.title == title }?.submenu)
            XCTAssertTrue(submenu.items.contains { $0.title == label && $0.isEnabled })
        }

        // A retained provider belongs to this exact incarnation, not whatever UUID
        // later occupies the same visible tab. Fresh openings must acquire the new one.
        let oldProvider = region.itemsProvider
        let oldCopyTarget = try XCTUnwrap(fixture.vm.agentSessionCopyIDTarget(
            tabID: fixture.tabs[0].id, sessionID: firstID, tabName: fixture.tabs[0].name
        ))
        let replacementID = UUID()
        XCTAssertNotNil(fixture.vm.test_installPersistentSessionBinding(
            sessionID: replacementID, on: session, compareAndSetInWorkspaceID: workspaceID
        ))
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
        await AgentSessionLinkRuntimeBridge.shared.test_settleMonitorProjectionRefresh()
        await settleHostedPublication(in: fixture)
        var copiedIDs: [String] = []
        XCTAssertFalse(fixture.vm.copyAgentSessionID(target: oldCopyTarget, copyToClipboard: { copiedIDs.append($0) }))
        XCTAssertTrue(copiedIDs.isEmpty, "The old row must never copy its replaced UUID")
        let stale = NSMenu.stableMenu(from: oldProvider())
        for title in [AgentOversightUICopy.overseeNewTitle, AgentOversightUICopy.overseeByTitle] {
            let submenu = try XCTUnwrap(stale.items.first { $0.title == title }?.submenu)
            XCTAssertFalse(submenu.items.contains { $0.isEnabled }, "The old provider must not acquire the replacement's oversight authority")
        }
        XCTAssertTrue(try mountedRegion(in: fixture) === region)
        let replacement = try await open(in: fixture)
        XCTAssertTrue(try XCTUnwrap(replacement.items.first { $0.title == "Copy Session ID" }).isEnabled)
        for (title, label) in [
            (AgentOversightUICopy.overseeNewTitle, target.menuLabel),
            (AgentOversightUICopy.overseeByTitle, observer.menuLabel)
        ] {
            let submenu = try XCTUnwrap(replacement.items.first { $0.title == title }?.submenu)
            XCTAssertTrue(submenu.items.contains { $0.title == label && $0.isEnabled }, "The fresh root must capture the replacement UUID")
        }
        let newCopyTarget = try XCTUnwrap(fixture.vm.agentSessionCopyIDTarget(
            tabID: fixture.tabs[0].id, sessionID: replacementID, tabName: fixture.tabs[0].name
        ))
        XCTAssertTrue(fixture.vm.copyAgentSessionID(target: newCopyTarget, copyToClipboard: { copiedIDs.append($0) }))
        XCTAssertEqual(copiedIDs, [replacementID.uuidString])
    }

    private func settleHostedPublication(in fixture: Fixture) async {
        // Drain the publication/layout boundary without replacing rootView or forcing
        // a sidebar refresh; either would conceal the stale capture under investigation.
        let settled = expectation(description: "Hosted binding publication reached the main run loop")
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                fixture.host.layoutSubtreeIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 3)
        fixture.host.layoutSubtreeIfNeeded()
    }

    func testReopeningWithoutHoverReadsChangedRelationships() async throws {
        let fixture = try await makeFixture(peerCount: 2)
        let before = try await open(in: fixture)
        XCTAssertFalse(before.items.contains { $0.title == AgentOversightUICopy.overseeingSectionLabel })
        try await add(from: 0, to: 1, in: fixture)
        let linked = try await open(in: fixture)
        XCTAssertTrue(linked.items.contains { $0.title == AgentOversightUICopy.overseeingSectionLabel })
        let props = try menuProps(in: fixture)
        let peer = try XCTUnwrap(props.linkedTargets.first)
        guard case let .linked(reference, _) = peer.relationship else { return XCTFail("Expected linked target") }
        _ = await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
            observerEndpoint: props.targetEndpoint,
            targetEndpoint: peer.peerEndpoint,
            expectedReference: reference
        )
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        let stopped = try await open(in: fixture)
        XCTAssertFalse(stopped.items.contains { $0.title == AgentOversightUICopy.overseeingSectionLabel })
        XCTAssertTrue(linked.items.contains { $0.title == AgentOversightUICopy.overseeingSectionLabel }, "Previous menu remains a value snapshot")
    }

    func testMenuOpeningLeavesColdPersistedRowUnloaded() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let tabID = fixture.tabs[0].id
        let sessionID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let workspaceID = try XCTUnwrap(fixture.state.workspaceManager.activeWorkspaceID)
        let provider = try mountedRegion(in: fixture).itemsProvider
        let persisted = fixture.vm.session(for: tabID)
        persisted.selectedAgent = .devin
        persisted.selectedModelRaw = AgentModelCatalog.defaultModelRaw(for: .devin)
        persisted.providerSessionID = "hosted-existing-acp-session"
        await fixture.vm.flushSave(for: tabID)
        // Keep ordinary active-chat ownership away from this cold menu target.
        fixture.vm.test_setCurrentTabIDOverride(fixture.tabs[1].id)
        fixture.vm.test_removeSession(tabID: tabID)
        let hydrationBefore = fixture.hydrationAttempts.events
        fixture.vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        _ = provider()
        await settleHostedPublication(in: fixture)
        XCTAssertNil(fixture.vm.sessions[tabID], "Opening a menu must not mount or hydrate a persisted row")
        XCTAssertNil(fixture.vm.agentSidebarOversightMenuProps(tabID: tabID, expectedSessionID: sessionID))
        XCTAssertEqual(fixture.hydrationAttempts.events, hydrationBefore, "No-launch boundary: menu repair must not enter hydration")
        XCTAssertTrue(fixture.providerAttempts.events.isEmpty, "Cold persisted rows must not request a provider")
    }

    func testMenuOpeningRepairsLoadedNilBindingWithoutHydration() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let tabID = fixture.tabs[0].id
        let sessionID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let session = fixture.vm.session(for: tabID)
        let region = try mountedRegion(in: fixture)
        let provider = region.itemsProvider
        session.selectedAgent = .devin
        session.selectedModelRaw = AgentModelCatalog.defaultModelRaw(for: .devin)
        session.providerSessionID = "hosted-existing-acp-session"
        XCTAssertFalse(fixture.vm.test_isCursorModelPollingActive)
        await fixture.vm.flushSave(for: tabID)
        let retired = try menuProps(in: fixture).targetEndpoint
        let items = session.items
        let revision = session.sourceItemsRevision
        await fixture.vm.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)
        fixture.vm.test_publishTranscriptPresentation(tabID: tabID)
        let presentation = fixture.vm.activeTranscriptPresentation
        let hydrationBefore = fixture.hydrationAttempts.events
        XCTAssertFalse(presentation.visibleRows.isEmpty, "Exercise an already-displayed active transcript")
        await recoverByOpening(provider, in: fixture, sessionID: sessionID) {
            session.testInstallPersistentSessionBinding(sessionID: nil)
            XCTAssertNil(fixture.vm.agentSidebarOversightMenuProps(tabID: tabID, expectedSessionID: sessionID))
        }
        XCTAssertFalse(fixture.vm.test_isCursorModelPollingActive, "Menu recovery must not acquire discovery interest")
        XCTAssertTrue(fixture.vm.sessions[tabID] === session, "Repair the retained entry through its normal binding installer")
        let menu = try menuProps(in: fixture)
        XCTAssertEqual(menu.targetSessionID, sessionID)
        XCTAssertNotEqual(menu.targetEndpoint, retired)
        let reopened = NSMenu.stableMenu(from: provider())
        let choices = try XCTUnwrap(reopened.items.first { $0.title == AgentOversightUICopy.overseeByTitle }?.submenu)
        XCTAssertNotEqual(choices.items.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])
        XCTAssertTrue(try mountedRegion(in: fixture) === region)
        XCTAssertEqual(fixture.vm.activeTranscriptPresentation.visibleRows, presentation.visibleRows)
        XCTAssertEqual(fixture.vm.activeTranscriptPresentation.visibleBlocks, presentation.visibleBlocks)
        XCTAssertFalse(fixture.vm.activeTranscriptPresentation.bindingsHydrated, "Presentation must not inherit retired hydration authority")
        XCTAssertEqual(session.sourceItemsRevision, revision, "Identity repair must not replace loaded content")
        XCTAssertEqual(session.items.map(\.text), items.map(\.text))
        XCTAssertNil(session.persistedLoadTask)
        XCTAssertTrue(session.hasLoadedPersistedState)
        XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative, "A repaired identity cannot earn hydration proof")
        XCTAssertEqual(session.selectedAgent, .devin)
        XCTAssertEqual(session.providerSessionID, "hosted-existing-acp-session")
        XCTAssertEqual(fixture.hydrationAttempts.events, hydrationBefore, "No-launch boundary: identity repair must not enter hydration")
        XCTAssertTrue(fixture.providerAttempts.events.isEmpty, "Nil-binding repair must not resume a provider")
    }

    func testSidebarPreparationRejectsStaleClaimsAndInProgressRebinding() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let hydrationBefore = fixture.hydrationAttempts.events
        let vm = fixture.vm
        let tabID = fixture.tabs[0].id
        let workspaceID = try XCTUnwrap(fixture.state.workspaceManager.activeWorkspaceID)
        let sessionID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let session = vm.session(for: tabID)
        XCTAssertTrue(AgentSessionLinkRuntimeBridge.shared.canPrepareSidebarSession(.init(
            windowID: fixture.state.windowID, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID
        )), "This registered fixture must exercise the binding guards, not fail host qualification")
        session.testInstallPersistentSessionBinding(sessionID: nil)
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: UUID(), workspaceID: workspaceID)
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: UUID())
        XCTAssertNil(session.activeAgentSessionID)
        session.items.append(AgentChatItem(kind: .user, text: "Unsaved retained change"))
        session.isDirty = true
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        XCTAssertNil(session.activeAgentSessionID)
        XCTAssertEqual(session.items.last?.text, "Unsaved retained change")
        XCTAssertNil(session.persistedLoadTask, "Dirty retained state must not be overwritten by disk hydration")
        session.isDirty = false
        session.hasLoadedPersistedState = false
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        XCTAssertNil(session.activeAgentSessionID, "Cold retained state must not be rebound or hydrated")
        XCTAssertNil(session.persistedLoadTask)
        session.hasLoadedPersistedState = true
        let ownership = session.beginRunAttempt(source: "hosted-fixture")
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        XCTAssertNil(session.activeAgentSessionID, "Idle run ownership still blocks repair")
        XCTAssertEqual(session.activeRunOwnership, ownership)
        _ = session.endRunAttempt(ifCurrent: ownership, source: "hosted-fixture")
        let transition = session.beginPersistentBindingTransition()
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        XCTAssertNil(session.activeAgentSessionID, "Never replace an in-progress transition")
        session.finishPersistentBindingTransition(generation: transition)
        let replacementID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: replacementID)
        vm.prepareSidebarOversightSession(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
        XCTAssertEqual(session.activeAgentSessionID, replacementID, "Never steal a conflicting live binding")
        XCTAssertEqual(fixture.hydrationAttempts.events, hydrationBefore, "No-launch boundary: refused repair must not enter hydration")
        XCTAssertTrue(fixture.providerAttempts.events.isEmpty, "Refused repair must not request a provider")
    }

    private func recoverByOpening(
        _ provider: () -> [StableMenuItem], in fixture: Fixture, sessionID: UUID,
        invalidate: () -> Void
    ) async {
        let installed = expectation(description: "Normal binding installer publishes recovery")
        let token = NotificationCenter.default.publisher(for: .agentSessionBindingDidChange)
            .filter { note in
                note.object as? AgentModeViewModel === fixture.vm
                    && note.userInfo?["tabID"] as? UUID == fixture.tabs[0].id
                    && note.userInfo?["sessionID"] as? UUID == sessionID
            }
            .prefix(1).sink { _ in installed.fulfill() }
        defer { token.cancel() }
        invalidate() // Observe before synchronous sidebar publication can remount the entry.
        _ = provider() // Retained native opening must schedule the preparation itself.
        await fulfillment(of: [installed], timeout: 3)
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        await settleHostedPublication(in: fixture)
    }

    func testColdProviderReadsReadyProjectionOnReopenWithoutRemount() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let otherWindow = try await makeFixture(peerCount: 1)
        try await add(from: 0, to: 1, in: otherWindow)
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        let props = try menuProps(in: fixture)
        let observerEndpoint = try menuProps(in: otherWindow).targetEndpoint
        let observer = try XCTUnwrap(props.availableObservers.first { $0.peerEndpoint == observerEndpoint })
        let region = try mountedRegion(in: fixture)
        let originalProvider = region.itemsProvider

        AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
        defer { AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false }
        let cold = NSMenu.stableMenu(from: originalProvider())
        let coldSubmenu = try XCTUnwrap(cold.items.first { $0.title == AgentOversightUICopy.overseeByTitle }?.submenu)
        XCTAssertEqual(coldSubmenu.items.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])

        AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        XCTAssertEqual(try menuProps(in: fixture).targetEndpoint, props.targetEndpoint)
        let reopened = NSMenu.stableMenu(from: originalProvider())
        let reopenedSubmenu = try XCTUnwrap(reopened.items.first { $0.title == AgentOversightUICopy.overseeByTitle }?.submenu)
        XCTAssertTrue(reopenedSubmenu.items.contains { $0.title == observer.menuLabel && $0.isEnabled })
        XCTAssertEqual(coldSubmenu.items.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])
        XCTAssertTrue(try mountedRegion(in: fixture) === region, "The original mounted provider must recover without remount or reassignment")
    }

    func testSubmenuUpdateReadsReadyProjectionWithoutReopeningRoot() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let otherWindow = try await makeFixture(peerCount: 1)
        try await add(from: 0, to: 1, in: otherWindow)
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
        await AgentSessionLinkRuntimeBridge.shared.test_settleMonitorProjectionRefresh()
        let props = try menuProps(in: fixture)
        let peerEndpoint = try menuProps(in: otherWindow).targetEndpoint
        let observer = try XCTUnwrap(props.availableObservers.first { $0.peerEndpoint == peerEndpoint })
        let target = try XCTUnwrap(props.availableTargets.first { $0.peerEndpoint == peerEndpoint })
        AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
        defer { AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false }

        var observed = false
        _ = try await open(in: fixture, whileTracking: { root in
            let rootItems = root.items
            let directions = [
                (AgentOversightUICopy.overseeNewTitle, target.menuLabel),
                (AgentOversightUICopy.overseeByTitle, observer.menuLabel)
            ]
            AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false
            for (title, peerLabel) in directions {
                guard let submenu = root.items.first(where: { $0.title == title })?.submenu else {
                    XCTFail("Missing \(title) submenu")
                    continue
                }
                XCTAssertEqual(submenu.items.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])
                let updater = submenu.delegate
                XCTAssertNotNil(updater, "The native submenu must retain its updater independently of the row")
                // Exercise the AppKit pre-tracking callback for this submenu, not a new
                // root provider or a SwiftUI root replacement.
                updater?.menuNeedsUpdate?(submenu)
                XCTAssertEqual(submenu.items.count { $0.title == peerLabel && $0.isEnabled }, 1)
                let parent = root.items.first { $0.submenu === submenu }
                XCTAssertNotEqual(parent?.accessibilityValue() as? String, AgentOversightUICopy.oversightMenuUnavailableMessage)

                AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
                updater?.menuNeedsUpdate?(submenu)
                XCTAssertEqual(submenu.items.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])
                XCTAssertFalse(submenu.items[0].isEnabled)
                XCTAssertEqual(parent?.accessibilityValue() as? String, AgentOversightUICopy.oversightMenuUnavailableMessage)
                AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false
                updater?.menuNeedsUpdate?(submenu)
                XCTAssertEqual(submenu.items.count { $0.title == peerLabel && $0.isEnabled }, 1)
            }
            XCTAssertEqual(root.items.count, rootItems.count)
            XCTAssertTrue(zip(root.items, rootItems).allSatisfy { $0 === $1 }, "Root identity and structure must not change during submenu refresh")
            XCTAssertTrue(fixture.window.stableMenuPresenter.openMenu === root)
            observed = true
        })
        XCTAssertTrue(observed)
        XCTAssertNil(fixture.window.stableMenuPresenter.openMenu)
    }

    func testNativeSubmenuReadsReadyProjectionWithoutReopeningRoot() async throws {
        let fixture = try await makeFixture(peerCount: 1)
        let props = try menuProps(in: fixture)
        let target = try XCTUnwrap(props.availableTargets.first)
        AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
        defer { AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false }
        var observer: SubmenuOpeningObserver?
        var timeout: Timer?
        var openings = 0
        defer { timeout?.invalidate() }

        func postKey(_ code: UInt16, character: String) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code
            ) else { return XCTFail("Could not create menu navigation event") }
            NSApp.postEvent(event, atStart: false)
        }

        _ = try await open(in: fixture, cancelAfterOpening: false, whileTracking: { root in
            guard let submenu = root.items.first(where: { $0.title == AgentOversightUICopy.overseeNewTitle })?.submenu else {
                XCTFail("Missing candidate submenu")
                return root.cancelTracking()
            }
            let rootItems = root.items
            AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false
            let forwarding = SubmenuOpeningObserver(delegate: submenu.delegate)
            observer = forwarding
            submenu.delegate = forwarding
            forwarding.onOpen = { child in
                openings += 1
                XCTAssertTrue(child.items.contains { $0.title == target.menuLabel && $0.isEnabled })
                XCTAssertTrue(zip(root.items, rootItems).allSatisfy { $0 === $1 })
                XCTAssertTrue(fixture.window.stableMenuPresenter.openMenu === root)
                root.cancelTracking()
            }
            let watchdog = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { root.cancelTracking() }
            }
            timeout = watchdog
            RunLoop.main.add(watchdog, forMode: .common)
            // Down-arrow once per root position before the submenu's own, then Right to open:
            // the first Down highlights item 0, so the count follows the item's index, not a
            // fixed press count.
            guard let submenuIndex = root.items.firstIndex(where: { $0.submenu === submenu }) else {
                XCTFail("candidate submenu is not a root item")
                return root.cancelTracking()
            }
            for _ in 0 ... submenuIndex {
                postKey(125, character: "\u{F701}")
            }
            postKey(124, character: "\u{F703}")
        })
        withExtendedLifetime(observer) {}
        XCTAssertEqual(openings, 1, "AppKit must display the submenu while the original root tracks")
    }

    func testTrackedMenuSurvivesProjectionReplacementAndSidebarRerender() async throws {
        let fixture = try await makeFixture(peerCount: 2)
        try await add(from: 0, to: 1, in: fixture)
        let props = try menuProps(in: fixture)
        var observedWhileTracking = false
        _ = try await open(in: fixture, whileTracking: { menu in
            let originalTitles = menu.items.map(\.title)
            // Exercise the real presentation publication boundary synchronously inside tracking.
            // No fake row/builder input: the initial menu came from the real bridge grant above.
            AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = true
            defer { AgentSessionLinkRuntimeBridge.shared.test_menuCatalogUnavailable = false }
            fixture.host.rootView = self.sidebar(for: fixture.state, tabID: fixture.tabs[0].id)
            fixture.host.layoutSubtreeIfNeeded()
            XCTAssertNil(fixture.vm.agentSidebarOversightMenuProps(
                tabID: fixture.tabs[0].id, expectedSessionID: props.targetSessionID
            ))
            XCTAssertTrue(fixture.window.stableMenuPresenter.openMenu === menu)
            XCTAssertEqual(menu.items.map(\.title), originalTitles)
            XCTAssertTrue(originalTitles.contains(AgentOversightUICopy.overseeingSectionLabel))
            observedWhileTracking = true
        })
        XCTAssertTrue(observedWhileTracking, "Must observe the same retained menu before intentional cancellation")
        XCTAssertNil(fixture.window.stableMenuPresenter.openMenu)
    }

    private func makeFixture(peerCount: Int = 9, idless: Bool = false) async throws -> Fixture {
        _ = NSApplication.shared
        let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let key = SettingKeys.agentModeShowComposeTabsWithoutAgentSessions
        let oldShowEmpty = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        addTeardownBlock {
            await MainActor.run {
                GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false)
                if let oldShowEmpty { UserDefaults.standard.set(oldShowEmpty, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let providerAttempts = LifecycleRecorder()
        let hydrationAttempts = LifecycleRecorder()
        let state = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let vm = AgentModeViewModel(
                    testWindowID: windowID,
                    codexControllerFactory: { _, _, _, _, _, _ in
                        providerAttempts.record("codex")
                        return LifecycleNoopCodexController(recorder: LifecycleRecorder())
                    },
                    claudeControllerFactory: { _, _, _, _ in
                        providerAttempts.record("claude")
                        return MonitorFakeNativeController()
                    },
                    headlessProviderFactory: { _, _ in
                        providerAttempts.record("headless")
                        return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { _, _ in
                        providerAttempts.record("acp-provider")
                        throw UnexpectedProviderLaunch.refused
                    },
                    acpControllerFactory: { _, _ in
                        providerAttempts.record("acp-controller")
                        throw UnexpectedProviderLaunch.refused
                    },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                    mcpRunRoutingCleaner: { _, _, _ in },
                    mcpServerEnabler: { false },
                    testMCPServer: server,
                    testWorkspaceFileContextStore: prompt.workspaceFileContextStore,
                    testRestorePerfRecorder: SidebarHydrationRecorder(attempts: hydrationAttempts)
                )
                vm.promptManager = prompt
                vm.workspaceManager = manager
                return vm
            },
            contextBuilderProviderFactory: { _, _, _, _ in
                providerAttempts.record("context-builder")
                return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            }
        )
        addTeardownBlock {
            await state.tearDown()
            XCTAssertTrue(providerAttempts.events.isEmpty, "Hosted menu fixtures must never request a provider: \(providerAttempts.events)")
        }
        await state.workspaceManager.awaitInitialized()
        let tabs = (0 ... peerCount).map { index in
            ComposeTabState(
                name: index == 0 ? "Hosted overseer" : "Hosted peer \(index)",
                isPinned: index == 0,
                activeAgentSessionID: index == 0 && idless ? nil : UUID()
            )
        }
        let workspace = WorkspaceModel(
            name: "Hosted oversight", repoPaths: [], ephemeralFlag: true,
            composeTabs: tabs, activeComposeTabID: tabs[0].id
        )
        state.workspaceManager.workspaces = [workspace]
        let switched = await state.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "hostedContextMenuTest")
        XCTAssertEqual(switched, .switched)
        state.promptManager.loadComposeTabsFromWorkspace(workspace)
        let vm = state.agentModeViewModel
        await vm.handleWorkspaceSwitch(workspace)
        vm.test_setCurrentTabIDOverride(tabs[0].id)
        _ = await vm.ensureSessionReady(tabID: tabs[0].id)
        XCTAssertEqual(vm.sidebarRuntimeWorkspaceID, workspace.id)
        for tab in tabs {
            let session = vm.session(for: tab.id)
            _ = vm.test_installPersistentSessionBinding(sessionID: tab.activeAgentSessionID, on: session, updateWorkspaceMetadata: true)
            session.hasLoadedPersistedState = true
            if tab.activeAgentSessionID != nil {
                session.items = [AgentChatItem(kind: .user, text: "Hosted fixture message")]
            }
        }
        WindowStatesManager.shared.registerWindowState(state)
        addTeardownBlock {
            await MainActor.run {
                WindowStatesManager.shared.unregisterWindowState(state)
            }
        }
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        vm.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: tabs)
        // Use the real sidebar search owner to isolate the clicked row. Peers stay live in the
        // workspace/bridge and therefore remain real relationship choices, not injected props.
        vm.sessionSidebarSearchText = "Hosted overseer"
        let input = try XCTUnwrap(state.promptManager.sidebarWorkspaceSnapshot)
        let projection = vm.sidebarListProjection(
            workspaceID: input.workspaceID, composeTabs: input.composeTabs, stashedTabs: [],
            currentTabID: tabs[0].id, sidebarSnapshot: vm.ui.sessionSidebar.snapshot,
            archivedSessionsExpanded: false, showComposeTabsWithoutAgentSessions: true
        )
        XCTAssertEqual(projection.pagedSessions.map(\.tabID), [tabs[0].id], "Real search must isolate the intended row, not a sibling")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock {
            await MainActor.run {
                window.close()
            }
        }
        let host = NSHostingView(rootView: sidebar(for: state, tabID: tabs[0].id))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        return Fixture(state: state, tabs: tabs, host: host, window: window, providerAttempts: providerAttempts, hydrationAttempts: hydrationAttempts)
    }

    private func sidebar(for state: WindowState, tabID: UUID) -> AgentModeSessionsSidebarView {
        AgentModeSessionsSidebarView(
            rootsStore: AgentWorkspaceRootsSidebarStore(
                rootProjections: { [] }, rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
                workspaceManager: state.workspaceManager, windowID: state.windowID
            ),
            agentModeVM: state.agentModeViewModel, sidebarUI: state.agentModeViewModel.ui.sessionSidebar,
            promptManager: state.promptManager, apiSettingsVM: state.apiSettingsViewModel,
            currentTabID: tabID, onManageWorkspaces: {}
        )
    }

    private func add(from observer: Int, to target: Int, in fixture: Fixture) async throws {
        let observerID = try XCTUnwrap(fixture.tabs[observer].activeAgentSessionID)
        let targetID = try XCTUnwrap(fixture.tabs[target].activeAgentSessionID)
        guard case .added = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
            observerSessionID: observerID, rawTargetSessionID: targetID.uuidString
        ) else { return XCTFail("Real bridge grant failed") }
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
    }

    private func menuProps(in fixture: Fixture) throws -> AgentSidebarOversightMenuProps {
        try XCTUnwrap(try fixture.vm.agentSidebarOversightMenuProps(
            tabID: fixture.tabs[0].id, expectedSessionID: XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        ))
    }

    private func open(
        in fixture: Fixture, via opening: Opening = .rightClick,
        cancelAfterOpening: Bool = true,
        whileTracking: ((NSMenu) -> Void)? = nil
    ) async throws -> NSMenu {
        let region = try mountedRegion(in: fixture)
        let finished = expectation(description: "Native tracking observed and intentionally ended")
        var tracked: NSMenu?
        let ended = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard !cancelAfterOpening, let menu = note.object as? NSMenu, menu === tracked else { return }
                finished.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(ended) }
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu === fixture.window.stableMenuPresenter.openMenu else { return }
                tracked = menu
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        whileTracking?(menu)
                        if cancelAfterOpening {
                            menu.cancelTracking()
                            finished.fulfill()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        if opening == .accessibility {
            XCTAssertTrue(region.accessibilityPerformShowMenu())
        } else {
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            let flags: NSEvent.ModifierFlags = opening == .controlClick ? [.control] : []
            for type: NSEvent.EventType in opening == .controlClick ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
                ))
                NSApp.sendEvent(event)
            }
        }
        await fulfillment(of: [finished], timeout: 3)
        return try XCTUnwrap(tracked, "Actual native opening must track a menu")
    }

    private func mountedRegion(in fixture: Fixture) throws -> StableMenuContextView {
        fixture.host.layoutSubtreeIfNeeded()
        func regions(in view: NSView) -> [StableMenuContextView] {
            (view as? StableMenuContextView).map { [$0] } ?? view.subviews.flatMap { regions(in: $0) }
        }
        let mountedRegions = regions(in: fixture.host).filter { !$0.visibleRect.isEmpty }
        XCTAssertEqual(mountedRegions.count, 1, "The actual sidebar search must leave only the intended row region")
        return try XCTUnwrap(mountedRegions.first, "Real sidebar must mount its native row region")
    }
}
