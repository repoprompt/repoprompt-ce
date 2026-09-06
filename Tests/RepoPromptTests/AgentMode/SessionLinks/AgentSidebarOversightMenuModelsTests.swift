import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSidebarOversightMenuModelsTests: XCTestCase {
    private struct Linked {
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let linkID: UUID
        let generation: UInt64
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

    private func inputs(
        target: AgentSessionLinkEndpointCandidate,
        linked: [Linked] = [],
        activeOutboundObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    ) -> DomainAgentSessionLinkEndpointProjectionInputs {
        let inboundItems = linked.map { relationship in
            DomainAgentSessionLinkInventoryItem(
                linkID: relationship.linkID,
                generation: relationship.generation,
                observerSessionID: relationship.endpoint.sessionID,
                targetSessionID: target.sessionID,
                displayName: nil,
                capabilities: DomainAgentSessionLinkCapability.version1
            )
        }
        return DomainAgentSessionLinkEndpointProjectionInputs(
            outbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: 0,
                authorityRevision: 1,
                items: []
            ),
            inbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: UInt64(linked.count),
                authorityRevision: 1,
                items: inboundItems
            ),
            outboundTargetEndpoints: [:],
            inboundObserverEndpoints: Dictionary(
                uniqueKeysWithValues: linked.map { ($0.linkID, $0.endpoint) }
            ),
            activeOutboundObserverEndpoints: activeOutboundObserverEndpoints,
            notices: []
        )
    }

    func testProjectionPartitionsAvailableAndRetainsUnavailableAndIneligibleLinkedObservers() throws {
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

        let menu = try XCTUnwrap(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: linked,
                activeOutboundObserverEndpoints: Set(
                    linked.map(\.endpoint) + [available.domainEndpoint]
                )
            ),
            candidates: [available, target, ineligibleLinked]
        ))

        XCTAssertEqual(menu.targetEndpoint, target.domainEndpoint)
        XCTAssertEqual(menu.targetSessionID, target.sessionID)
        XCTAssertEqual(menu.targetDisplayName, "Target")
        XCTAssertEqual(menu.linkedObservers.map(\.displayName), ["Éclair", AgentMonitorSessionIDFormatter.short(
            unavailableEndpoint.sessionID
        )])
        XCTAssertEqual(menu.availableObservers.map(\.observerEndpoint), [available.domainEndpoint])
        XCTAssertNil(menu.availableObservers.first?.providerDisplayName)
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

    func testAvailableProjectionRequiresActiveOverseerAndExcludesIneligibleSelfAndLinkedEndpoints() throws {
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

        let menu = try XCTUnwrap(AgentSidebarOversightMenuProjection.make(
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
        ))

        XCTAssertEqual(menu.linkedObservers.map(\.observerEndpoint), [linked.domainEndpoint])
        XCTAssertEqual(menu.availableObservers.map(\.observerEndpoint), [eligibleOverseer.domainEndpoint])
    }

    func testEligibleTargetWithNoObserversProducesDiscoverableEmptyMenuButIneligibleTargetProducesNil() throws {
        let target = candidate(windowID: 1, displayName: "Target")
        let empty = try XCTUnwrap(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target]
        ))
        XCTAssertTrue(empty.isEmpty)

        let loading = candidate(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: target.sessionID,
            bindingID: target.persistentBindingGeneration,
            hasLoadedPersistedState: false,
            displayName: target.displayName
        )
        XCTAssertNil(AgentSidebarOversightMenuProjection.make(
            target: loading,
            inputs: inputs(target: loading),
            candidates: [loading]
        ))
    }

    func testMenuLabelsPrefixLiveObserverLocationAndFallBackWhenUnavailable() throws {
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

        let menu = try XCTUnwrap(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: relationships,
                activeOutboundObserverEndpoints: [linked.domainEndpoint, available.domainEndpoint]
            ),
            candidates: [target, linked, available]
        ))

        XCTAssertEqual(
            menu.linkedObservers.first { $0.observerEndpoint == linked.domainEndpoint }?.menuLabel,
            "release-main: Existing overseer"
        )
        XCTAssertEqual(
            menu.availableObservers.first?.menuLabel,
            "kidfriendly-nova: Coordinate PIN-boundary design review"
        )
        XCTAssertEqual(
            menu.linkedObservers.first { $0.observerEndpoint == unavailableEndpoint }?.menuLabel,
            AgentMonitorSessionIDFormatter.short(unavailableEndpoint.sessionID)
        )
    }

    func testStopCopyDelimitsCompoundObserverLabelAndNamesOversight() {
        let observer = "release-main: Existing overseer"
        XCTAssertEqual(
            AgentSidebarOversightMenuCopy.stopTitle(observerMenuLabel: observer),
            "Stop oversight by “release-main: Existing overseer”"
        )
        XCTAssertEqual(
            AgentSidebarOversightMenuCopy.stopAccessibilityLabel(
                observerMenuLabel: observer,
                targetDisplayName: "Target"
            ),
            "Stop oversight of Target by “release-main: Existing overseer”"
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

        let menu = try XCTUnwrap(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                activeOutboundObserverEndpoints: Set(candidates.map(\.domainEndpoint))
            ),
            candidates: candidates
        ))
        let byEndpoint = Dictionary(
            uniqueKeysWithValues: menu.availableObservers.map { ($0.observerEndpoint, $0) }
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
}
