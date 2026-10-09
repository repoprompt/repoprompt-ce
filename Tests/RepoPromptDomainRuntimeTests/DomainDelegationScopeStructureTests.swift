import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Pure structural policies: the link capability ceiling (S8), organizational placement for
/// re-parent and adopt (S9, scopes can never grow or shrink outside the caller's chain), chain walks,
/// and worktree staleness/guardrail counting.
final class DomainDelegationScopeStructureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func grant(
        _ kind: DomainDelegationScopeKind,
        _ capabilities: Set<DomainDelegationScopeCapability>,
        origin: DomainDelegationScopeOrigin = .user,
        id: UUID = UUID()
    ) -> DomainDelegationScopeGrant {
        DomainDelegationScopeGrant(
            id: id, granteeSessionID: UUID(), kind: kind, capabilities: capabilities,
            guardrails: .init(), origin: origin, grantedAt: now
        )
    }

    // MARK: - S8 link ceiling

    func testLinkCeilingFollowsObserveAndControl() {
        let tree = DomainDelegationScopeKind.tree(rootSessionID: UUID())
        XCTAssertEqual(
            DomainDelegationScopeLinkPolicy.ceiling(for: grant(tree, [.restructure, .observe, .control])),
            DomainAgentSessionLinkCapability.managed
        )
        XCTAssertEqual(
            DomainDelegationScopeLinkPolicy.ceiling(for: grant(tree, [.restructure, .observe])),
            [.poll, .wait, .read],
            "without control a link carries at most poll/wait/read"
        )
        XCTAssertEqual(DomainDelegationScopeLinkPolicy.ceiling(for: grant(tree, [.restructure])), [])
        XCTAssertEqual(
            DomainDelegationScopeLinkPolicy.missingCapability(
                linkCapabilities: DomainAgentSessionLinkCapability.managed,
                grant: grant(tree, [.restructure, .observe])
            ),
            .control
        )
        XCTAssertNil(DomainDelegationScopeLinkPolicy.missingCapability(
            linkCapabilities: [.poll, .read],
            grant: grant(tree, [.restructure, .observe])
        ))
    }

    func testAllSessionsScopeCanNeverCreateManageOrSendLinks() {
        let restructureOnly = grant(.allSessions, [.restructure])
        let organizeEverything = grant(.allSessions, DomainDelegationScopeCapability.organizeEverythingPreset)
        // A malformed record that somehow carries control is still re-restricted.
        let malformed = grant(.allSessions, DomainDelegationScopeCapability.fullPreset)
        for scope in [restructureOnly, organizeEverything, malformed] {
            let ceiling = DomainDelegationScopeLinkPolicy.ceiling(for: scope)
            XCTAssertFalse(ceiling.contains(.manage))
            XCTAssertFalse(ceiling.contains(.sendWhenIdle))
            for link in [DomainAgentSessionLinkCapability.managed, [.manage], [.sendWhenIdle], DomainAgentSessionLinkCapability.version1] {
                XCTAssertFalse(DomainDelegationScopeLinkPolicy.permits(linkCapabilities: link, grant: scope))
                XCTAssertNotNil(DomainDelegationScopeLinkPolicy.missingCapability(linkCapabilities: link, grant: scope))
            }
            // Control is the capability every such scope lacks, whatever else it holds.
            XCTAssertEqual(DomainDelegationScopeLinkPolicy.missingCapability(linkCapabilities: [.manage], grant: scope), .control)
        }
        XCTAssertFalse(DomainDelegationScopeLinkPolicy.permits(linkCapabilities: [.read], grant: restructureOnly))
        XCTAssertTrue(DomainDelegationScopeLinkPolicy.permits(linkCapabilities: [.read], grant: organizeEverything))
        XCTAssertFalse(DomainDelegationScopeLinkPolicy.permits(linkCapabilities: [], grant: organizeEverything))
    }

    // MARK: - Chain walk

    func testAncestryWalksToTheTopAndRejectsCycles() {
        let a = UUID(), b = UUID(), c = UUID()
        let parents = [c: b, b: a]
        XCTAssertEqual(DomainDelegationOrganizationalChain.ancestry(of: c) { parents[$0] }, [c, b, a])
        let cyclic = [a: b, b: a]
        XCTAssertNil(DomainDelegationOrganizationalChain.ancestry(of: a) { cyclic[$0] })
    }

    // MARK: - S9 reparent

    /// root ─┬─ a ── a1
    ///       └─ r (another overseer holding its own tree scope R)
    func testReparentWithinTheScopeIsAllowedAndCyclesAreRefused() {
        let root = UUID(), a = UUID(), a1 = UUID(), b = UUID()
        let scope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a1, destination: b, sourceAncestry: [a1, a, root], destinationAncestry: [b, root],
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ))
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: a1, sourceAncestry: [a, root], destinationAncestry: [a1, a, root],
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle, "a session cannot move under its own descendant")
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: a, sourceAncestry: [a, root], destinationAncestry: [a, root],
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: b, sourceAncestry: [a, root], destinationAncestry: nil,
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle, "an unresolvable chain fails closed")
    }

    func testReparentUnderAnotherOverseerWouldSilentlyGrowItsScopeAndIsRefused() {
        let root = UUID(), a = UUID(), r = UUID()
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: r)
        let denial = DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: r, sourceAncestry: [a, root], destinationAncestry: [r, root],
            liveTreeScopes: [callerScope, otherScope], callerScopeChain: [callerScope.scopeID]
        )
        XCTAssertEqual(denial, .affectsOtherScopes([otherScope.scopeID]))
        XCTAssertEqual(denial?.affectedScopeIDs, [otherScope.scopeID])
        XCTAssertEqual(denial?.publicCode, "placement_affects_other_scopes")
    }

    func testReparentOutOfAnotherScopeIsRefusedToo() {
        // a currently sits under r, which holds scope R; moving it to b would shrink R.
        let root = UUID(), r = UUID(), a = UUID(), b = UUID()
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: r)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: b, sourceAncestry: [a, r, root], destinationAncestry: [b, root],
            liveTreeScopes: [callerScope, otherScope], callerScopeChain: [callerScope.scopeID]
        ), .affectsOtherScopes([otherScope.scopeID]))
    }

    func testReparentIntoANestedScopeIsRefusedButAncestorChainScopesNeverCount() {
        // Caller holds nested scope N (rooted at n) attenuated from P (rooted at p). Moving a under
        // m, who holds an unrelated nested scope M, would change M; P and N are on the caller chain.
        let p = UUID(), n = UUID(), m = UUID(), a = UUID()
        let parent = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: p)
        let nested = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: n)
        let sibling = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: m)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: m, sourceAncestry: [a, n, p], destinationAncestry: [m, n, p],
            liveTreeScopes: [parent, nested, sibling], callerScopeChain: [nested.scopeID, parent.scopeID]
        ), .affectsOtherScopes([sibling.scopeID]))
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: n, sourceAncestry: [a, m, n, p], destinationAncestry: [n, p],
            liveTreeScopes: [parent, nested], callerScopeChain: [nested.scopeID, parent.scopeID]
        ), "only live scopes count; the caller chain never changes for members")
    }

    func testAffectedScopesListsEveryChangedScopeSorted() {
        let root = UUID(), x = UUID(), y = UUID(), a = UUID()
        let scopes = [x, y].map { DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: $0) }
        let affected = DomainDelegationScopePlacementPolicy.affectedTreeScopes(
            movedSessionID: a, previousAncestry: [a, x, root], destinationAncestry: [y, root],
            liveTreeScopes: scopes
        )
        XCTAssertEqual(affected, scopes.map(\.scopeID).sorted { $0.uuidString < $1.uuidString })
    }

    // MARK: - S9 adopt

    func testAdoptJoinsOnlyTheCallersUserGrantedScope() {
        let root = UUID(), dest = UUID(), outsider = UUID(), outsiderParent = UUID()
        let callerGrant = grant(.tree(rootSessionID: root), [.restructure])
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: callerGrant.id, rootSessionID: root)
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: outsider, destination: dest, adopteeAncestry: [outsider, outsiderParent],
            destinationAncestry: [dest, root], liveTreeScopes: [callerScope], callerScope: callerGrant
        ))
        // The adoptee currently belongs to another overseer's scope: adopting it would shrink that.
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: outsiderParent)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: outsider, destination: dest, adopteeAncestry: [outsider, outsiderParent],
            destinationAncestry: [dest, root], liveTreeScopes: [callerScope, otherScope], callerScope: callerGrant
        ), .affectsOtherScopes([otherScope.scopeID]))
        // Adopting an ancestor of the scope root would be a cycle.
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: outsiderParent, destination: dest, adopteeAncestry: [outsiderParent],
            destinationAncestry: [dest, root, outsiderParent], liveTreeScopes: [callerScope], callerScope: callerGrant
        ), .cycle)
    }

    func testAdoptIsRefusedForAttenuatedScopes() {
        let nestedRoot = UUID()
        let nested = grant(.tree(rootSessionID: nestedRoot), [.restructure], origin: .attenuatedFrom(scopeID: UUID()))
        let denial = DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: UUID(), destination: nestedRoot, adopteeAncestry: [], destinationAncestry: [nestedRoot],
            liveTreeScopes: [], callerScope: nested
        )
        XCTAssertEqual(denial, .adoptionRequiresUserGrantedScope)
        XCTAssertEqual(denial?.publicCode, "adopt_requires_user_granted_scope")
    }

    // MARK: - Worktrees

    func testWorktreeStaleFlagsAndGuardrailCount() {
        let flags = DomainDelegationWorktreeStaleness.flags(
            isReleased: true, boundSessionCount: 0, isPrunable: true,
            lastActivityAt: now.addingTimeInterval(-3 * 86400), idleThresholdDays: 2, now: now
        )
        XCTAssertEqual(flags, [.released, .unbound, .prunable, .idle])
        XCTAssertEqual(DomainDelegationWorktreeStaleness.flags(
            isReleased: false, boundSessionCount: 1, isPrunable: false,
            lastActivityAt: now, idleThresholdDays: 2, now: now
        ), [])
        XCTAssertEqual(
            DomainDelegationWorktreeStaleness.guardrailCount(boundWorktreeIDs: ["a", "b"], ownedUnreleasedWorktreeIDs: ["b", "c"]),
            3
        )
    }
}
