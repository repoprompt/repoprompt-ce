import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Pure structural policies: the link capability ceiling (S8), organizational placement for
/// re-parent and adopt (S9: scopes can never grow or shrink outside the caller's chain, unknown
/// chains are unresolved, scope anchors are never adopted), chain and subtree walks, placement depth,
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

    private func complete(_ chain: UUID...) -> DomainDelegationOrganizationalAncestry {
        DomainDelegationOrganizationalAncestry(chain: chain, isTruncated: false)
    }

    private func truncated(_ chain: UUID...) -> DomainDelegationOrganizationalAncestry {
        DomainDelegationOrganizationalAncestry(chain: chain, isTruncated: true)
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

    // MARK: - Chain and subtree walks

    func testAncestryDistinguishesRootFromUnknownAndRejectsCycles() {
        let a = UUID(), b = UUID(), c = UUID(), unloaded = UUID()
        let known: [UUID: DomainDelegationOrganizationalParent] = [c: .parent(b), b: .parent(a), a: .root]
        XCTAssertEqual(
            DomainDelegationOrganizationalChain.ancestry(of: c) { known[$0] ?? .unknown },
            complete(c, b, a)
        )
        // b's parent is a session whose provenance is not loaded: the chain stops there, truncated.
        let partial: [UUID: DomainDelegationOrganizationalParent] = [c: .parent(b), b: .parent(unloaded)]
        XCTAssertEqual(
            DomainDelegationOrganizationalChain.ancestry(of: c) { partial[$0] ?? .unknown },
            truncated(c, b, unloaded)
        )
        let cyclic: [UUID: DomainDelegationOrganizationalParent] = [a: .parent(b), b: .parent(a)]
        XCTAssertNil(DomainDelegationOrganizationalChain.ancestry(of: a) { cyclic[$0] ?? .unknown })
    }

    func testSubtreeIsBreadthFirstWithDepthsAndRejectsCycles() throws {
        let root = UUID(), child = UUID(), grandchild = UUID()
        let children = [root: [child], child: [grandchild]]
        let nodes = try XCTUnwrap(DomainDelegationOrganizationalChain.subtree(of: root) { children[$0] ?? [] })
        XCTAssertEqual(nodes.map(\.sessionID), [root, child, grandchild])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2])
        XCTAssertNil(DomainDelegationOrganizationalChain.subtree(of: root) { $0 == root ? [child] : [root] })
    }

    // MARK: - S9 reparent

    func testReparentWithinTheScopeIsAllowedAndCyclesAreRefused() {
        let root = UUID(), a = UUID(), a1 = UUID(), b = UUID()
        let scope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a1, destination: b, sourceAncestry: complete(a1, a, root), destinationAncestry: complete(b, root),
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ))
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: a1, sourceAncestry: complete(a, root), destinationAncestry: complete(a1, a, root),
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle, "a session cannot move under its own descendant")
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: a, sourceAncestry: complete(a, root), destinationAncestry: complete(a, root),
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: b, sourceAncestry: complete(a, root), destinationAncestry: nil,
            liveTreeScopes: [scope], callerScopeChain: [scope.scopeID]
        ), .cycle, "a cyclic chain fails closed")
    }

    func testReparentUnderAnotherOverseerWouldSilentlyGrowItsScopeAndIsRefused() {
        let root = UUID(), a = UUID(), r = UUID()
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: r)
        let denial = DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: r, sourceAncestry: complete(a, root), destinationAncestry: complete(r, root),
            liveTreeScopes: [callerScope, otherScope], callerScopeChain: [callerScope.scopeID]
        )
        XCTAssertEqual(denial, .affectsOtherScopes(count: 1))
        XCTAssertEqual(denial?.affectedScopeCount, 1, "a count only; other scopes' IDs are never disclosed")
        XCTAssertEqual(denial?.publicCode, "placement_affects_other_scopes")
    }

    func testReparentOutOfAnotherScopeIsRefusedToo() {
        // a currently sits under r, which holds scope R; moving it to b would shrink R.
        let root = UUID(), r = UUID(), a = UUID(), b = UUID()
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: root)
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: r)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: b, sourceAncestry: complete(a, r, root), destinationAncestry: complete(b, root),
            liveTreeScopes: [callerScope, otherScope], callerScopeChain: [callerScope.scopeID]
        ), .affectsOtherScopes(count: 1))
    }

    func testReparentIntoANestedScopeIsRefusedButAncestorChainScopesNeverCount() {
        // Caller holds nested scope N (rooted at n) attenuated from P (rooted at p). Moving a under
        // m, who holds an unrelated nested scope M, would change M; P and N are on the caller chain.
        let p = UUID(), n = UUID(), m = UUID(), a = UUID()
        let parent = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: p)
        let nested = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: n)
        let sibling = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: m)
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: m, sourceAncestry: complete(a, n, p), destinationAncestry: complete(m, n, p),
            liveTreeScopes: [parent, nested, sibling], callerScopeChain: [nested.scopeID, parent.scopeID]
        ), .affectsOtherScopes(count: 1))
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateReparent(
            source: a, destination: n, sourceAncestry: complete(a, m, n, p), destinationAncestry: complete(n, p),
            liveTreeScopes: [parent, nested], callerScopeChain: [nested.scopeID, parent.scopeID]
        ), "only live scopes count; the caller chain never changes for members")
    }

    /// A `.workspace` caller: the source's organizational parent lives in a closed workspace, so a
    /// live tree scope could be rooted above it. Moving it under a fully known destination cannot be
    /// decided and is refused; moving it between two sessions behind the same unknown tail is fine.
    func testTruncatedChainsAreUnresolvedUnlessTheyShareTheSameUnknownTail() {
        let source = UUID(), closedParent = UUID(), destination = UUID(), sibling = UUID()
        let workspaceScopeID = UUID()
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: source, destination: destination,
            sourceAncestry: truncated(source, closedParent), destinationAncestry: complete(destination),
            liveTreeScopes: [], callerScopeChain: [workspaceScopeID]
        ), .unresolved)
        XCTAssertEqual(DomainDelegationScopePlacementDenial.unresolved.publicCode, "placement_unresolved")
        XCTAssertNil(DomainDelegationScopePlacementPolicy.validateReparent(
            source: source, destination: sibling,
            sourceAncestry: truncated(source, closedParent), destinationAncestry: truncated(sibling, closedParent),
            liveTreeScopes: [], callerScopeChain: [workspaceScopeID]
        ), "the same unknown tail cannot change membership")
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateReparent(
            source: source, destination: sibling,
            sourceAncestry: truncated(source, closedParent), destinationAncestry: truncated(sibling, UUID()),
            liveTreeScopes: [], callerScopeChain: [workspaceScopeID]
        ), .unresolved, "different unknown tails")
    }

    func testAffectedScopesListsEveryChangedScopeSorted() {
        let root = UUID(), x = UUID(), y = UUID(), a = UUID()
        let scopes = [x, y].map { DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: $0) }
        let affected = DomainDelegationScopePlacementPolicy.affectedTreeScopes(
            movedSessionID: a, previousAncestry: complete(a, x, root), destinationAncestry: complete(y, root),
            liveTreeScopes: scopes
        )
        XCTAssertEqual(affected, scopes.map(\.scopeID).sorted { $0.uuidString < $1.uuidString })
    }

    func testPlacementDepthCountsTheMovedSubtree() {
        let root = UUID(), destination = UUID()
        let limit = DomainDelegationTreeDepthLimit(rootSessionID: root, maxDepth: 3)
        XCTAssertNil(DomainDelegationScopePlacementPolicy.depthViolation(
            destinationAncestry: complete(destination, root), movedSubtreeHeight: 1, limits: [limit]
        ))
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.depthViolation(
            destinationAncestry: complete(destination, root), movedSubtreeHeight: 2, limits: [limit]
        ), .guardrailExceeded(guardrail: .maxDepth, limit: 3, current: 4))
        XCTAssertNil(DomainDelegationScopePlacementPolicy.depthViolation(
            destinationAncestry: complete(destination), movedSubtreeHeight: 9, limits: [limit]
        ), "a scope not on the destination's chain is not affected")
    }

    func testAdoptionGuardrailsCountTheWholeAdoptedSubtree() {
        let usage = DomainDelegationScopeUsage(scopeID: UUID(), liveSessionCount: 3, worktreeCount: 1)
        XCTAssertNil(DomainDelegationScopePlacementPolicy.adoptionGuardrailViolation(
            guardrails: .init(maxLiveSessions: 5, maxWorktrees: 2), usage: usage, addedLiveSessions: 2, addedWorktrees: 1
        ))
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.adoptionGuardrailViolation(
            guardrails: .init(maxLiveSessions: 4), usage: usage, addedLiveSessions: 2, addedWorktrees: 0
        ), .guardrailExceeded(guardrail: .maxLiveSessions, limit: 4, current: 3))
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.adoptionGuardrailViolation(
            guardrails: .init(maxWorktrees: 1), usage: usage, addedLiveSessions: 0, addedWorktrees: 1
        ), .guardrailExceeded(guardrail: .maxWorktrees, limit: 1, current: 1))
    }

    // MARK: - S9 adopt

    func testAdoptJoinsOnlyTheCallersUserGrantedScope() {
        let root = UUID(), dest = UUID(), outsider = UUID(), outsiderParent = UUID()
        let callerGrant = grant(.tree(rootSessionID: root), [.restructure])
        let callerScope = DomainDelegationTreeScopeRoot(scopeID: callerGrant.id, rootSessionID: root)
        func adopt(
            _ adoptee: UUID,
            ancestry: DomainDelegationOrganizationalAncestry,
            destination: DomainDelegationOrganizationalAncestry? = nil,
            subtree: Set<UUID>? = [],
            anchors: Set<UUID> = [],
            scopes: [DomainDelegationTreeScopeRoot]
        ) -> DomainDelegationScopePlacementDenial? {
            DomainDelegationScopePlacementPolicy.validateAdopt(
                adoptee: adoptee, destination: dest, adopteeAncestry: ancestry,
                destinationAncestry: destination ?? complete(dest, root),
                adopteeSubtree: subtree, scopeAnchors: anchors.union([root]), liveTreeScopes: scopes, callerScope: callerGrant
            )
        }
        XCTAssertNil(adopt(outsider, ancestry: complete(outsider, outsiderParent), scopes: [callerScope]))
        // The adoptee currently belongs to another overseer's scope: adopting it would shrink that.
        let otherScope = DomainDelegationTreeScopeRoot(scopeID: UUID(), rootSessionID: outsiderParent)
        XCTAssertEqual(
            adopt(outsider, ancestry: complete(outsider, outsiderParent), scopes: [callerScope, otherScope]),
            .affectsOtherScopes(count: 1)
        )
        // Adopting an ancestor of the scope root would be a cycle.
        XCTAssertEqual(
            adopt(outsiderParent, ancestry: complete(outsiderParent), destination: complete(dest, root, outsiderParent), scopes: [callerScope]),
            .cycle
        )
        // An adoptee reached only through an unloaded session cannot be decided.
        XCTAssertEqual(adopt(outsider, ancestry: truncated(outsider, UUID()), scopes: [callerScope]), .unresolved)
        XCTAssertEqual(adopt(outsider, ancestry: complete(outsider), subtree: nil, scopes: [callerScope]), .unresolved)
    }

    func testAdoptNeverCapturesAScopeAnchorInTheSubtree() {
        let root = UUID(), dest = UUID(), outsider = UUID(), descendantOverseer = UUID()
        let callerGrant = grant(.tree(rootSessionID: root), [.restructure])
        let denial = DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: outsider, destination: dest, adopteeAncestry: complete(outsider), destinationAncestry: complete(dest, root),
            adopteeSubtree: [descendantOverseer], scopeAnchors: [root, descendantOverseer],
            liveTreeScopes: [], callerScope: callerGrant
        )
        XCTAssertEqual(denial, .adopteeAnchorsScope)
        XCTAssertEqual(denial?.publicCode, "adopt_target_anchors_scope")
        XCTAssertEqual(DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: outsider, destination: dest, adopteeAncestry: complete(outsider), destinationAncestry: complete(dest, root),
            adopteeSubtree: [], scopeAnchors: [root, outsider], liveTreeScopes: [], callerScope: callerGrant
        ), .adopteeAnchorsScope, "a scope's own grantee is never adopted")
    }

    func testAdoptIsRefusedForAttenuatedScopes() {
        let nestedRoot = UUID()
        let nested = grant(.tree(rootSessionID: nestedRoot), [.restructure], origin: .attenuatedFrom(scopeID: UUID()))
        let denial = DomainDelegationScopePlacementPolicy.validateAdopt(
            adoptee: UUID(), destination: nestedRoot, adopteeAncestry: nil, destinationAncestry: complete(nestedRoot),
            adopteeSubtree: [], scopeAnchors: [], liveTreeScopes: [], callerScope: nested
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
        XCTAssertEqual(DomainDelegationWorktreeStaleness.flags(
            isReleased: true, boundSessionCount: 1, isPrunable: false,
            lastActivityAt: now, idleThresholdDays: nil, now: now
        ), [], "a worktree bound again is not reported as released")
        XCTAssertEqual(
            DomainDelegationWorktreeStaleness.guardrailCount(boundWorktreeIDs: ["a", "b"], ownedUnreleasedWorktreeIDs: ["b", "c"]),
            3
        )
    }
}
