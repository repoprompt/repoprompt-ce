import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Pure authority matrix for delegation scopes: grant validation, membership proofs, capabilities,
/// attenuation, expiry, cascade revocation, guardrails, confirmation, and the operation-authorizer
/// integration across administrative, spawn, link, scope, and unresolved callers.
final class DomainDelegationScopeAuthorityTests: XCTestCase {
    private let overseer = UUID()
    private let child = UUID()
    private let grandchild = UUID()
    private let outsider = UUID()
    private let workspaceID = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private var caller: DomainAgentSessionCallerIdentity {
        .agentSession(overseer)
    }

    private func grantTree(
        _ authority: inout DomainDelegationScopeAuthority,
        capabilities: Set<DomainDelegationScopeCapability> = DomainDelegationScopeCapability.fullPreset,
        guardrails: DomainDelegationScopeGuardrails = .init(),
        grantee: UUID? = nil
    ) throws -> DomainDelegationScopeRecord {
        let grantee = grantee ?? overseer
        return try authority.grant(
            DomainDelegationScopeGrantRequest(
                granteeSessionID: grantee,
                kind: .tree(rootSessionID: grantee),
                capabilities: capabilities,
                guardrails: guardrails
            ),
            scopeID: UUID(),
            now: now
        ).get()
    }

    private func treeProof(
        _ scope: DomainDelegationScopeRecord,
        _ path: [UUID]
    ) -> DomainDelegationScopeMembershipProof {
        DomainDelegationScopeMembershipProof(scopeID: scope.id, targetSessionID: path[0], basis: .treePath(path))
    }

    private func lease(
        _ authority: DomainDelegationScopeAuthority,
        _ scope: DomainDelegationScopeRecord,
        _ operation: DomainAgentSessionTargetOperation,
        target: UUID,
        proof: DomainDelegationScopeMembershipProof?,
        ancestorProofs: [DomainDelegationScopeMembershipProof] = [],
        caller: DomainAgentSessionCallerIdentity? = nil,
        generation: UInt64? = nil,
        at time: Date? = nil
    ) -> Result<DomainDelegationScopeLease, DomainDelegationScopeDenial> {
        authority.lease(
            scopeID: scope.id,
            presentedGeneration: generation ?? scope.generation,
            caller: caller ?? self.caller,
            operation: operation,
            targetSessionID: target,
            memberships: (proof.map { [$0] } ?? []) + ancestorProofs,
            now: time ?? now
        )
    }

    private func denial(
        _ result: Result<some Any, DomainDelegationScopeDenial>
    ) -> DomainDelegationScopeDenial? {
        guard case let .failure(denial) = result else { return nil }
        return denial
    }

    // MARK: - Grant validation

    func testGrantRejectsEmptyCapabilitiesMalformedGuardrailsAndPastExpiry() {
        var authority = DomainDelegationScopeAuthority()
        func attempt(_ caps: Set<DomainDelegationScopeCapability>, _ guardrails: DomainDelegationScopeGuardrails) -> DomainDelegationScopeDenial? {
            denial(authority.grant(
                .init(granteeSessionID: overseer, kind: .tree(rootSessionID: overseer), capabilities: caps, guardrails: guardrails),
                scopeID: UUID(),
                now: now
            ))
        }
        XCTAssertEqual(attempt([], .init()), .capabilitiesEmpty)
        XCTAssertEqual(attempt([.observe], .init(maxLiveSessions: -1)), .guardrailsMalformed)
        XCTAssertEqual(attempt([.observe], .init(bulkConfirmationThreshold: 0)), .guardrailsMalformed)
        XCTAssertEqual(attempt([.observe], .init(expiresAt: now)), .expiryInPast)
        XCTAssertNil(attempt([.observe], .init(expiresAt: now.addingTimeInterval(60))))
        XCTAssertNil(attempt([.observe], .init(maxDepth: 2)), "depth is meaningful for a tree")
        let workspaceDepth = authority.grant(
            .init(granteeSessionID: overseer, kind: .workspace(workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(maxDepth: 2)),
            scopeID: UUID(), now: now
        )
        XCTAssertEqual(denial(workspaceDepth), .guardrailsMalformed, "depth could never be evaluated outside a tree")
    }

    func testAllSessionsScopeHoldsOnlyObserveOrganizeAndRestructure() {
        var authority = DomainDelegationScopeAuthority()
        XCTAssertEqual(
            DomainDelegationScopeCapability.allSessionsPermitted,
            [.observe, .organize, .restructure]
        )
        for capability in DomainDelegationScopeCapability.allCases {
            let result = authority.grant(
                .init(granteeSessionID: overseer, kind: .allSessions, capabilities: [capability], guardrails: .init()),
                scopeID: UUID(),
                now: now
            )
            if DomainDelegationScopeCapability.allSessionsPermitted.contains(capability) {
                XCTAssertNotNil(try? result.get(), capability.rawValue)
            } else {
                XCTAssertEqual(denial(result), .capabilityNotPermittedForKind(capability), capability.rawValue)
            }
        }
    }

    func testPresetsMatchTheDesignDefaults() {
        XCTAssertFalse(DomainDelegationScopeCapability.manageTreePreset.contains(.destructive))
        XCTAssertEqual(DomainDelegationScopeCapability.manageTreePreset.count, 6)
        XCTAssertEqual(DomainDelegationScopeCapability.fullPreset, Set(DomainDelegationScopeCapability.allCases))
        XCTAssertEqual(DomainDelegationScopeGuardrails().bulkConfirmationThreshold, 25)
    }

    func testHumanOnlyActionsAreNeverGrantableOrRepresentableAsCapabilities() {
        let capabilityNames = Set(DomainDelegationScopeCapability.allCases.map(\.rawValue))
        for action in DomainDelegationScopeHumanOnlyAction.allCases {
            XCTAssertFalse(action.isGrantable, action.rawValue)
            XCTAssertFalse(capabilityNames.contains(action.rawValue), action.rawValue)
        }
        // Session deletion has no scope identity; the existing delete operation is human-only.
        XCTAssertNil(DomainAgentSessionTargetOperation.manageCleanup.requiredScopeCapability)
    }

    // MARK: - Leases: decision steps 1–3

    func testTreeMemberLeaseCarriesScopeGenerationAndCapability() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        let issued = try lease(authority, scope, .adminRename, target: grandchild, proof: treeProof(scope, [grandchild, child, overseer])).get()
        XCTAssertEqual(issued.scopeID, scope.id)
        XCTAssertEqual(issued.generation, scope.generation)
        XCTAssertEqual(issued.capability, .organize)
        XCTAssertEqual(issued.targetSessionID, grandchild)
        XCTAssertTrue(authority.isCurrent(issued, now: now))
    }

    func testNonAgentAndUnknownCallersFailClosed() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        let proof = treeProof(scope, [child, overseer])
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof, caller: .administrativePrincipal)), .callerNotAgentSession)
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof, caller: .unresolvedAgentRun)), .callerNotAgentSession)
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof, caller: .agentSession(outsider))), .granteeMismatch)
        let missing = authority.lease(
            scopeID: UUID(), presentedGeneration: 1, caller: caller, operation: .adminRename,
            targetSessionID: child, memberships: [proof], now: now
        )
        XCTAssertEqual(denial(missing), .unknownScope)
    }

    func testMembershipProofsMustDescribeThisScopeAndTarget() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: nil)), .membershipProofMissing)
        let invalidProofs: [DomainDelegationScopeMembershipProof] = [
            // Chain never reaches the root.
            treeProof(scope, [child, outsider]),
            // Cycle.
            treeProof(scope, [child, overseer, child, overseer]),
            // Wrong target first.
            DomainDelegationScopeMembershipProof(scopeID: scope.id, targetSessionID: child, basis: .treePath([grandchild, overseer])),
            // Wrong basis for the kind.
            DomainDelegationScopeMembershipProof(scopeID: scope.id, targetSessionID: child, basis: .allSessions)
        ]
        for proof in invalidProofs {
            XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof)), .membershipProofInvalid)
        }
        // Another scope's proof is simply not a proof for this scope.
        let foreign = DomainDelegationScopeMembershipProof(scopeID: UUID(), targetSessionID: child, basis: .treePath([child, overseer]))
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: foreign)), .membershipProofMissing)
    }

    func testWorkspaceAndAllSessionsMembership() throws {
        var authority = DomainDelegationScopeAuthority()
        let workspaceScope = try authority.grant(
            .init(granteeSessionID: overseer, kind: .workspace(workspaceID: workspaceID), capabilities: [.organize], guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        let inWorkspace = DomainDelegationScopeMembershipProof(scopeID: workspaceScope.id, targetSessionID: outsider, basis: .workspace(workspaceID))
        XCTAssertNotNil(try? lease(authority, workspaceScope, .adminSetPin, target: outsider, proof: inWorkspace).get())
        let otherWorkspace = DomainDelegationScopeMembershipProof(scopeID: workspaceScope.id, targetSessionID: outsider, basis: .workspace(UUID()))
        XCTAssertEqual(denial(lease(authority, workspaceScope, .adminSetPin, target: outsider, proof: otherWorkspace)), .membershipProofInvalid)

        let everything = try authority.grant(
            .init(granteeSessionID: overseer, kind: .allSessions, capabilities: [.restructure], guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        let anyone = DomainDelegationScopeMembershipProof(scopeID: everything.id, targetSessionID: outsider, basis: .allSessions)
        XCTAssertNotNil(try? lease(authority, everything, .adminUnlink, target: outsider, proof: anyone).get())
        // `.allSessions` never reaches control, even for a member.
        XCTAssertEqual(denial(lease(authority, everything, .adminSetModel, target: outsider, proof: anyone)), .capabilityMissing(.control))
    }

    func testCapabilityIsCheckedBeforeMembershipSoItCannotProbeMembers() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority, capabilities: [.observe])
        let proof = treeProof(scope, [child, overseer])
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof)), .capabilityMissing(.organize))
        XCTAssertEqual(DomainDelegationScopeDenial.capabilityMissing(.organize).publicCode, "scope_capability_missing")
        // Member and non-member get the same answer when the capability is missing.
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: outsider, proof: nil)), .capabilityMissing(.organize))
        // With the capability held, a non-member is the uniform denial.
        XCTAssertEqual(denial(lease(authority, scope, .adminGet, target: outsider, proof: nil)), .membershipProofMissing)
        XCTAssertNil(DomainDelegationScopeDenial.membershipProofMissing.publicCode)
    }

    func testControlAndDestructiveRefuseSelfTargetButOrganizeDoesNot() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        let selfProof = treeProof(scope, [overseer])
        XCTAssertEqual(denial(lease(authority, scope, .adminSetModel, target: overseer, proof: selfProof)), .selfTarget)
        XCTAssertEqual(denial(lease(authority, scope, .adminRetire, target: overseer, proof: selfProof)), .selfTarget)
        XCTAssertNotNil(try? lease(authority, scope, .adminRename, target: overseer, proof: selfProof).get())
    }

    func testScopeLifecycleAndScopeLevelOperationsAreNotLeased() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        for operation in [DomainAgentSessionTargetOperation.adminRequestScope, .adminScopeStatus, .adminReleaseScope, .adminInventory] {
            XCTAssertEqual(
                denial(lease(authority, scope, operation, target: child, proof: treeProof(scope, [child, overseer]))),
                .operationNotScopeAuthorizable,
                operation.rawValue
            )
        }
    }

    // MARK: - Expiry, revocation, generations

    func testExpiryStopsAuthorityAndIsReportedAsScopeExpired() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority, guardrails: .init(expiresAt: now.addingTimeInterval(600)))
        let proof = treeProof(scope, [child, overseer])
        let later = now.addingTimeInterval(601)
        XCTAssertEqual(denial(lease(authority, scope, .adminRename, target: child, proof: proof, at: later)), .expired)
        XCTAssertEqual(DomainDelegationScopeDenial.expired.publicCode, "scope_expired")
        XCTAssertFalse(authority.hasLiveScope(grantedTo: overseer, now: later))
        let expired = authority.expire(now: later)
        XCTAssertEqual(expired.map(\.id), [scope.id])
        XCTAssertEqual(authority.record(id: scope.id)?.state, .expired)
    }

    func testRevokeCascadesBumpsGenerationsAndInvalidatesLeases() throws {
        var authority = DomainDelegationScopeAuthority()
        let parent = try grantTree(&authority)
        let childScope = try authority.attenuate(
            parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller,
            newGranteeSessionID: child, newGranteeMemberships: [treeProof(parent, [child, overseer])],
            capabilities: [.observe, .spawn], guardrails: .init(), childScopeID: UUID(), now: now
        ).get()
        let grandScope = try authority.attenuate(
            parentScopeID: childScope.id, presentedGeneration: childScope.generation, caller: .agentSession(child),
            newGranteeSessionID: grandchild,
            newGranteeMemberships: [treeProof(childScope, [grandchild, child]), treeProof(parent, [grandchild, child, overseer])],
            capabilities: [.observe], guardrails: .init(), childScopeID: UUID(), now: now
        ).get()
        let issued = try lease(authority, parent, .adminRename, target: child, proof: treeProof(parent, [child, overseer])).get()

        let revoked = authority.revoke(scopeID: parent.id)
        XCTAssertEqual(Set(revoked.map(\.id)), [parent.id, childScope.id, grandScope.id])
        XCTAssertTrue(revoked.allSatisfy { $0.state == .revoked })
        XCTAssertGreaterThan(authority.record(id: parent.id)?.generation ?? 0, parent.generation)
        XCTAssertFalse(authority.isCurrent(issued, now: now))
        XCTAssertEqual(denial(lease(authority, parent, .adminRename, target: child, proof: treeProof(parent, [child, overseer]))), .expired)
        XCTAssertTrue(authority.activeGrants.isEmpty)
        // Revoking again changes nothing.
        XCTAssertTrue(authority.revoke(scopeID: parent.id).isEmpty)
    }

    func testStaleGenerationIsRefused() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        XCTAssertEqual(
            denial(lease(authority, scope, .adminRename, target: child, proof: treeProof(scope, [child, overseer]), generation: scope.generation + 99)),
            .generationStale
        )
    }

    func testReleaseIsGranteeOnlyAndCascades() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority)
        XCTAssertEqual(denial(authority.release(scopeID: scope.id, caller: .agentSession(outsider))), .granteeMismatch)
        XCTAssertEqual(denial(authority.release(scopeID: scope.id, caller: .administrativePrincipal)), .callerNotAgentSession)
        let released = try authority.release(scopeID: scope.id, caller: caller).get()
        XCTAssertEqual(released.map(\.id), [scope.id])
        XCTAssertFalse(authority.hasLiveScope(grantedTo: overseer, now: now))
    }

    func testReactivateUsesFreshGenerationsAndDropsExpiredAndOrphanedGrants() throws {
        var original = DomainDelegationScopeAuthority()
        let parent = try grantTree(&original, guardrails: .init(expiresAt: now.addingTimeInterval(3600)))
        let childScope = try original.attenuate(
            parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller,
            newGranteeSessionID: child, newGranteeMemberships: [treeProof(parent, [child, overseer])],
            capabilities: [.observe], guardrails: .init(expiresAt: now.addingTimeInterval(1800)), childScopeID: UUID(), now: now
        ).get()
        let orphan = DomainDelegationScopeGrant(
            id: UUID(), granteeSessionID: grandchild, kind: .tree(rootSessionID: grandchild), capabilities: [.observe],
            guardrails: .init(), origin: .attenuatedFrom(scopeID: UUID()), grantedAt: now
        )

        // Children listed before parents still reactivate.
        var relaunched = DomainDelegationScopeAuthority()
        _ = relaunched.reactivate([childScope.grant, parent.grant, orphan], now: now.addingTimeInterval(60))
        XCTAssertNotNil(relaunched.liveRecord(id: parent.id, now: now.addingTimeInterval(60)))
        XCTAssertNotNil(relaunched.liveRecord(id: childScope.id, now: now.addingTimeInterval(60)))
        XCTAssertNil(relaunched.record(id: orphan.id))

        // Past expiry: nothing reactivates.
        var late = DomainDelegationScopeAuthority()
        XCTAssertTrue(late.reactivate([parent.grant], now: now.addingTimeInterval(7200)).isEmpty)
    }

    // MARK: - Attenuation

    func testAttenuationIsASubsetWithNoLooserGuardrailsAndNoLaterExpiry() throws {
        var authority = DomainDelegationScopeAuthority()
        let parent = try grantTree(
            &authority,
            capabilities: [.observe, .organize, .spawn],
            guardrails: .init(maxLiveSessions: 10, maxDepth: 3, expiresAt: now.addingTimeInterval(3600), bulkConfirmationThreshold: 20)
        )
        let proof = treeProof(parent, [child, overseer])
        func attempt(
            _ caps: Set<DomainDelegationScopeCapability>,
            _ guardrails: DomainDelegationScopeGuardrails,
            caller: DomainAgentSessionCallerIdentity? = nil,
            membership: DomainDelegationScopeMembershipProof? = nil
        ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
            let membership = membership ?? proof
            return authority.attenuate(
                parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller ?? self.caller,
                newGranteeSessionID: membership.targetSessionID, newGranteeMemberships: [membership],
                capabilities: caps, guardrails: guardrails, childScopeID: UUID(), now: now
            )
        }
        let tight = DomainDelegationScopeGuardrails(maxLiveSessions: 5, maxDepth: 2, expiresAt: now.addingTimeInterval(1800), bulkConfirmationThreshold: 10)
        XCTAssertEqual(denial(attempt([.observe, .control], tight)), .attenuationWidensCapabilities)
        XCTAssertEqual(denial(attempt([.observe], .init(maxDepth: 2, expiresAt: tight.expiresAt))), .attenuationLoosensGuardrails, "unlimited live sessions is looser")
        XCTAssertEqual(denial(attempt([.observe], .init(maxLiveSessions: 11, maxDepth: 2, expiresAt: tight.expiresAt))), .attenuationLoosensGuardrails)
        XCTAssertEqual(denial(attempt([.observe], .init(maxLiveSessions: 5, maxDepth: 2, expiresAt: nil))), .attenuationLoosensGuardrails, "no expiry is later")
        XCTAssertEqual(denial(attempt([.observe], .init(maxLiveSessions: 5, maxDepth: 2, expiresAt: now.addingTimeInterval(7200)))), .attenuationLoosensGuardrails)
        XCTAssertEqual(denial(attempt([.observe], .init(maxLiveSessions: 5, maxDepth: 2, expiresAt: tight.expiresAt, bulkConfirmationThreshold: 50))), .attenuationLoosensGuardrails)
        XCTAssertEqual(denial(attempt([.observe], tight, caller: .agentSession(child))), .granteeMismatch)
        XCTAssertEqual(denial(attempt([.observe], tight, membership: treeProof(parent, [overseer]))), .selfTarget)

        let childScope = try attempt([.observe, .spawn], tight).get()
        XCTAssertEqual(childScope.grant.kind, .tree(rootSessionID: child))
        XCTAssertEqual(childScope.grant.granteeSessionID, child)
        XCTAssertEqual(childScope.grant.parentScopeID, parent.id)
    }

    func testAttenuationRequiresSpawnInTheParent() throws {
        var authority = DomainDelegationScopeAuthority()
        let parent = try grantTree(&authority, capabilities: [.observe, .organize])
        let result = authority.attenuate(
            parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller,
            newGranteeSessionID: child, newGranteeMemberships: [treeProof(parent, [child, overseer])],
            capabilities: [.observe], guardrails: .init(), childScopeID: UUID(), now: now
        )
        XCTAssertEqual(denial(result), .capabilityMissing(.spawn))
    }

    func testAttenuatedScopeNeverReachesBeyondItsAncestors() throws {
        var authority = DomainDelegationScopeAuthority()
        let parent = try authority.grant(
            .init(granteeSessionID: overseer, kind: .workspace(workspaceID: workspaceID), capabilities: [.observe, .organize, .spawn], guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        let childScope = try authority.attenuate(
            parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller,
            newGranteeSessionID: child,
            newGranteeMemberships: [DomainDelegationScopeMembershipProof(scopeID: parent.id, targetSessionID: child, basis: .workspace(workspaceID))],
            capabilities: [.organize], guardrails: .init(), childScopeID: UUID(), now: now
        ).get()
        let childCaller = DomainAgentSessionCallerIdentity.agentSession(child)
        // `grandchild` is in the child's tree but lives in another workspace.
        let treeOnly = treeProof(childScope, [grandchild, child])
        XCTAssertEqual(
            denial(lease(authority, childScope, .adminRename, target: grandchild, proof: treeOnly, caller: childCaller)),
            .membershipProofMissing,
            "the parent never covered this session, so the child cannot either"
        )
        let otherWorkspace = DomainDelegationScopeMembershipProof(scopeID: parent.id, targetSessionID: grandchild, basis: .workspace(UUID()))
        XCTAssertEqual(
            denial(lease(authority, childScope, .adminRename, target: grandchild, proof: treeOnly, ancestorProofs: [otherWorkspace], caller: childCaller)),
            .membershipProofInvalid
        )
        let inWorkspace = DomainDelegationScopeMembershipProof(scopeID: parent.id, targetSessionID: grandchild, basis: .workspace(workspaceID))
        XCTAssertNotNil(try? lease(authority, childScope, .adminRename, target: grandchild, proof: treeOnly, ancestorProofs: [inWorkspace], caller: childCaller).get())
    }

    // MARK: - Guardrails

    func testGuardrailsCountTheWholeChainAndReportLimitAndCurrent() throws {
        var authority = DomainDelegationScopeAuthority()
        let parent = try grantTree(&authority, guardrails: .init(maxLiveSessions: 3, maxDepth: 2, maxWorktrees: 1))
        let childScope = try authority.attenuate(
            parentScopeID: parent.id, presentedGeneration: parent.generation, caller: caller,
            newGranteeSessionID: child, newGranteeMemberships: [treeProof(parent, [child, overseer])],
            capabilities: [.spawn, .worktree], guardrails: .init(maxLiveSessions: 3, maxDepth: 2, maxWorktrees: 1),
            childScopeID: UUID(), now: now
        ).get()
        // The child scope itself has room, but the parent's subtree is full.
        let full = authority.evaluateGuardrails(
            scopeID: childScope.id,
            operation: .adminSpawn,
            usageByScopeID: [
                childScope.id: .init(scopeID: childScope.id, liveSessionCount: 1, worktreeCount: 0, spawnParentDepth: 0),
                parent.id: .init(scopeID: parent.id, liveSessionCount: 3, worktreeCount: 0, spawnParentDepth: 1)
            ]
        )
        XCTAssertEqual(full, .guardrailExceeded(guardrail: .maxLiveSessions, limit: 3, current: 3))
        XCTAssertEqual(full?.publicCode, "scope_guardrail_exceeded")

        let tooDeep = authority.evaluateGuardrails(
            scopeID: parent.id,
            operation: .adminSpawn,
            usageByScopeID: [parent.id: .init(scopeID: parent.id, liveSessionCount: 0, worktreeCount: 0, spawnParentDepth: 2)]
        )
        XCTAssertEqual(tooDeep, .guardrailExceeded(guardrail: .maxDepth, limit: 2, current: 3))

        let worktrees = authority.evaluateGuardrails(
            scopeID: parent.id,
            operation: .adminWorktreeCreate,
            usageByScopeID: [parent.id: .init(scopeID: parent.id, liveSessionCount: 0, worktreeCount: 1)]
        )
        XCTAssertEqual(worktrees, .guardrailExceeded(guardrail: .maxWorktrees, limit: 1, current: 1))

        XCTAssertEqual(
            authority.evaluateGuardrails(scopeID: parent.id, operation: .adminSpawn, usageByScopeID: [:]),
            .usageProofMissing,
            "a limited guardrail without usage fails closed"
        )
        XCTAssertNil(authority.evaluateGuardrails(scopeID: parent.id, operation: .adminRename, usageByScopeID: [:]))
    }

    // MARK: - Confirmation

    func testConfirmationRequirementByClassAndThreshold() {
        let guardrails = DomainDelegationScopeGuardrails(bulkConfirmationThreshold: 25)
        XCTAssertEqual(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminRetire, itemCount: 1, guardrails: guardrails), .destructive)
        XCTAssertEqual(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminWorktreeRelease, itemCount: 1, guardrails: guardrails), .destructive)
        XCTAssertEqual(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminAdopt, itemCount: 1, guardrails: guardrails), .adoption)
        XCTAssertNil(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminSetPin, itemCount: 25, guardrails: guardrails))
        XCTAssertEqual(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminSetPin, itemCount: 26, guardrails: guardrails), .bulkThreshold)
        XCTAssertNil(DomainDelegationScopeAuthority.confirmationRequirement(operation: .adminGet, itemCount: 500, guardrails: guardrails))
    }

    func testAuthorizeRunsAllFiveStepsAndBindsTheConfirmation() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority, guardrails: .init(bulkConfirmationThreshold: 1))
        let targets = [child, grandchild]
        let memberships: [UUID: [DomainDelegationScopeMembershipProof]] = [
            child: [treeProof(scope, [child, overseer])],
            grandchild: [treeProof(scope, [grandchild, child, overseer])]
        ]
        let base = DomainDelegationScopeAuthorizationRequest(
            operation: .adminSetPin, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: targets, memberships: memberships, idempotencyKey: "k1"
        )
        XCTAssertEqual(authority.authorize(base, now: now).denial, .confirmationRequired(reason: .bulkThreshold))
        XCTAssertEqual(DomainDelegationScopeDenial.confirmationRequired(reason: .bulkThreshold).publicCode, "confirmation_required")

        let approved = DomainDelegationScopeConfirmation(
            confirmationID: UUID(), scopeID: scope.id, scopeGeneration: scope.generation,
            operation: .adminSetPin, idempotencyKey: "k1", approvedSessionIDs: Set(targets)
        )
        let withCard = DomainDelegationScopeAuthorizationRequest(
            operation: .adminSetPin, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: targets, memberships: memberships, idempotencyKey: "k1", confirmation: approved
        )
        guard case let .authorized(items) = authority.authorize(withCard, now: now) else {
            return XCTFail("approved card must authorize")
        }
        XCTAssertEqual(items.admittedSessionIDs, targets)
        XCTAssertEqual(items.bases, Array(repeating: .delegationScope(scopeID: scope.id, generation: scope.generation, capability: .organize), count: 2))
        XCTAssertTrue(items.itemsRequiringControl.isEmpty)

        let wrongKey = DomainDelegationScopeAuthorizationRequest(
            operation: .adminSetPin, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: targets, memberships: memberships, idempotencyKey: "other", confirmation: approved
        )
        XCTAssertEqual(authority.authorize(wrongKey, now: now).denial, .confirmationMismatch)

        // Per-item untick: the card approved only `child`, so acting on both is refused.
        let unticked = DomainDelegationScopeConfirmation(
            confirmationID: approved.confirmationID, scopeID: scope.id, scopeGeneration: scope.generation,
            operation: .adminSetPin, idempotencyKey: "k1", approvedSessionIDs: [child]
        )
        let overreach = DomainDelegationScopeAuthorizationRequest(
            operation: .adminSetPin, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: targets, memberships: memberships, idempotencyKey: "k1", confirmation: unticked
        )
        XCTAssertEqual(authority.authorize(overreach, now: now).denial, .confirmationMismatch)
    }

    func testAuthorizeReportsTheFailingTargetAndScopeLevelOperations() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority, capabilities: [.observe, .organize])
        let outcome = authority.authorize(.init(
            operation: .adminRename, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: [child, outsider], memberships: [child: [treeProof(scope, [child, overseer])]]
        ), now: now)
        XCTAssertEqual(outcome, .denied(.membershipProofMissing, sessionID: outsider))

        let inventory = authority.authorize(.init(
            operation: .adminInventory, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation
        ), now: now)
        XCTAssertEqual(inventory, .authorized(DomainDelegationScopeAuthorizedItems()))

        let worktreeInventoryWithoutCapability = authority.authorize(.init(
            operation: .adminWorktreeInventory, caller: .agentSession(outsider), scopeID: scope.id,
            presentedGeneration: scope.generation
        ), now: now)
        XCTAssertEqual(worktreeInventoryWithoutCapability.denial, .granteeMismatch)
    }

    // MARK: - Retire and worktree release

    private func retireRequest(
        _ scope: DomainDelegationScopeRecord,
        targets: [UUID: DomainDelegationScopeTargetState?],
        order: [UUID],
        basis: (UUID) -> DomainDelegationScopeMembershipProof.Basis,
        confirmation: DomainDelegationScopeConfirmation? = nil,
        operation: DomainAgentSessionTargetOperation = .adminRetire
    ) -> DomainDelegationScopeAuthorizationRequest {
        var states: [UUID: DomainDelegationScopeTargetState] = [:]
        for (id, state) in targets {
            if let state { states[id] = state }
        }
        return .init(
            operation: operation, caller: caller, scopeID: scope.id, presentedGeneration: scope.generation,
            targetSessionIDs: order,
            memberships: Dictionary(uniqueKeysWithValues: order.map {
                ($0, [DomainDelegationScopeMembershipProof(scopeID: scope.id, targetSessionID: $0, basis: basis($0))])
            }),
            targetStates: states, idempotencyKey: "retire-key", confirmation: confirmation
        )
    }

    private func approval(
        _ scope: DomainDelegationScopeRecord,
        _ ids: Set<UUID>,
        operation: DomainAgentSessionTargetOperation = .adminRetire
    ) -> DomainDelegationScopeConfirmation {
        .init(
            confirmationID: UUID(), scopeID: scope.id, scopeGeneration: scope.generation,
            operation: operation, idempotencyKey: "retire-key", approvedSessionIDs: ids
        )
    }

    func testAllSessionsScopeCanRetireIdleMembers() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try authority.grant(
            .init(granteeSessionID: overseer, kind: .allSessions, capabilities: DomainDelegationScopeCapability.organizeEverythingPreset, guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        let request = retireRequest(scope, targets: [child: .idle], order: [child], basis: { _ in .allSessions })
        // Always carded, even for one item under the threshold.
        XCTAssertEqual(
            authority.authorize(request, now: now),
            .confirmationRequired(.destructive, .init(
                leases: [DomainDelegationScopeLease(scopeID: scope.id, generation: scope.generation, capability: .restructure, granteeSessionID: overseer, targetSessionID: child)],
                bases: [.delegationScope(scopeID: scope.id, generation: scope.generation, capability: .restructure)]
            ))
        )
        let approved = retireRequest(scope, targets: [child: .idle], order: [child], basis: { _ in .allSessions }, confirmation: approval(scope, [child]))
        guard case let .authorized(items) = authority.authorize(approved, now: now) else {
            return XCTFail("an .allSessions scope retires idle members")
        }
        XCTAssertEqual(items.admittedSessionIDs, [child])
        XCTAssertTrue(items.itemsRequiringControl.isEmpty)
    }

    func testAllSessionsScopeReportsRunningMembersAsRequiresControl() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try authority.grant(
            .init(granteeSessionID: overseer, kind: .allSessions, capabilities: DomainDelegationScopeCapability.organizeEverythingPreset, guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        // A mixed batch: the idle member is carded, the running and unknown-state ones are set aside.
        let mixed = retireRequest(
            scope, targets: [child: .idle, grandchild: .running, outsider: nil],
            order: [child, grandchild, outsider], basis: { _ in .allSessions }
        )
        guard case let .confirmationRequired(reason, items) = authority.authorize(mixed, now: now) else {
            return XCTFail("the idle member still needs its card")
        }
        XCTAssertEqual(reason, .destructive)
        XCTAssertEqual(items.admittedSessionIDs, [child])
        XCTAssertEqual(items.itemsRequiringControl, [grandchild, outsider], "unknown state counts as running")

        // All running: nothing to confirm or apply, every item is reported, the batch does not fail.
        let running = retireRequest(scope, targets: [grandchild: .running], order: [grandchild], basis: { _ in .allSessions })
        XCTAssertEqual(authority.authorize(running, now: now), .authorized(.init(itemsRequiringControl: [grandchild])))
        XCTAssertEqual(DomainDelegationScopeDenial.requiresControl.publicCode, "requires_control")
    }

    func testTreeScopeWithControlRetiresRunningMembersAndWithoutItDoesNot() throws {
        var authority = DomainDelegationScopeAuthority()
        let withControl = try grantTree(&authority, capabilities: [.organize, .restructure, .control])
        let request = retireRequest(
            withControl, targets: [child: .running], order: [child], basis: { _ in .treePath([self.child, self.overseer]) },
            confirmation: approval(withControl, [child])
        )
        guard case let .authorized(items) = authority.authorize(request, now: now) else {
            return XCTFail("control authorizes stopping a running member")
        }
        XCTAssertEqual(items.admittedSessionIDs, [child])
        XCTAssertTrue(items.itemsRequiringControl.isEmpty)

        var other = DomainDelegationScopeAuthority()
        let withoutControl = try grantTree(&other, capabilities: [.organize, .restructure])
        let refused = retireRequest(
            withoutControl, targets: [child: .running], order: [child], basis: { _ in .treePath([self.child, self.overseer]) }
        )
        XCTAssertEqual(other.authorize(refused, now: now), .authorized(.init(itemsRequiringControl: [child])))

        // `organize` + `restructure` are both required even for idle targets.
        var partial = DomainDelegationScopeAuthority()
        let restructureOnly = try grantTree(&partial, capabilities: [.restructure])
        let missing = retireRequest(
            restructureOnly, targets: [child: .idle], order: [child], basis: { _ in .treePath([self.child, self.overseer]) }
        )
        XCTAssertEqual(partial.authorize(missing, now: now).denial, .capabilityMissing(.organize))
    }

    func testWorktreeReleaseNeedsWorktreeAndAlwaysConfirms() throws {
        var authority = DomainDelegationScopeAuthority()
        let scope = try grantTree(&authority, capabilities: [.worktree], guardrails: .init(bulkConfirmationThreshold: 25))
        let one = retireRequest(
            scope, targets: [child: .running], order: [child], basis: { _ in .treePath([self.child, self.overseer]) },
            operation: .adminWorktreeRelease
        )
        guard case let .confirmationRequired(reason, items) = authority.authorize(one, now: now) else {
            return XCTFail("worktree_release is always carded")
        }
        XCTAssertEqual(reason, .destructive)
        XCTAssertEqual(items.admittedSessionIDs, [child], "run state does not matter for worktree_release")
        let approved = retireRequest(
            scope, targets: [child: .running], order: [child], basis: { _ in .treePath([self.child, self.overseer]) },
            confirmation: approval(scope, [child], operation: .adminWorktreeRelease), operation: .adminWorktreeRelease
        )
        XCTAssertTrue(authority.authorize(approved, now: now).isAuthorized)

        var everything = DomainDelegationScopeAuthority()
        let allSessions = try everything.grant(
            .init(granteeSessionID: overseer, kind: .allSessions, capabilities: DomainDelegationScopeCapability.organizeEverythingPreset, guardrails: .init()),
            scopeID: UUID(), now: now
        ).get()
        let refused = retireRequest(
            allSessions, targets: [child: .idle], order: [child], basis: { _ in .allSessions }, operation: .adminWorktreeRelease
        )
        XCTAssertEqual(everything.authorize(refused, now: now).denial, .capabilityMissing(.worktree))
    }

    // MARK: - Operation authorizer integration

    func testOperationCapabilityMapIsExplicitForEveryDelegationOperation() {
        let expected: [DomainAgentSessionTargetOperation: DomainDelegationScopeCapability?] = [
            .adminRequestScope: nil, .adminScopeStatus: nil, .adminReleaseScope: nil,
            .adminInventory: .observe, .adminGet: .observe, .adminTree: .observe, .adminLinks: .observe,
            .adminWorktreeInventory: .observe,
            .adminRename: .organize, .adminSetPin: .organize, .adminReorderPins: .organize,
            .adminSetGroup: .organize, .adminReorderGroups: .organize, .adminArchive: .organize, .adminUnarchive: .organize,
            .adminLink: .restructure, .adminUnlink: .restructure, .adminReparent: .restructure,
            .adminAdopt: .restructure, .adminRelease: .restructure,
            .adminSetModel: .control, .adminSetEffort: .control,
            .adminSpawn: .spawn, .adminFork: .spawn, .adminAttenuate: .spawn,
            .adminWorktreeCreate: .worktree, .adminWorktreeBind: .worktree, .adminWorktreeUnbind: .worktree,
            .adminMergePreview: .worktree, .adminMergeApply: .worktree, .adminWorktreeRelease: .worktree,
            .adminRetire: .restructure
        ]
        let delegation = DomainAgentSessionTargetOperation.allCases.filter { $0.family == .delegation }
        XCTAssertEqual(Set(delegation), Set(expected.keys))
        for operation in delegation {
            XCTAssertEqual(operation.requiredScopeCapability, expected[operation] ?? nil, operation.rawValue)
            XCTAssertNil(operation.requiredMonitorCapability, operation.rawValue)
            XCTAssertFalse(operation.isObserverScoped, operation.rawValue)
            XCTAssertTrue(operation.rawValue.hasPrefix("session_admin."), operation.rawValue)
            // `destructive` is a reserved always-card flag: no operation requires it in any state.
            for state in [DomainDelegationScopeTargetState.idle, .running, .unknown] {
                XCTAssertFalse(operation.requiredScopeCapabilities(for: state).contains(.destructive), operation.rawValue)
            }
        }
        for operation in DomainAgentSessionTargetOperation.allCases {
            XCTAssertNotEqual(operation.requiredScopeCapability, .destructive, operation.rawValue)
        }
        XCTAssertEqual(DomainAgentSessionTargetOperation.adminRetire.requiredScopeCapabilities(for: .idle), [.organize, .restructure])
        XCTAssertEqual(DomainAgentSessionTargetOperation.adminRetire.requiredScopeCapabilities(for: .running), [.organize, .restructure, .control])
        XCTAssertEqual(DomainAgentSessionTargetOperation.adminRetire.requiredScopeCapabilities(for: .unknown), [.organize, .restructure, .control])
        XCTAssertEqual(DomainAgentSessionTargetOperation.adminRetire.scopeConfirmationClass, .alwaysCarded)
        XCTAssertEqual(DomainAgentSessionTargetOperation.adminWorktreeRelease.scopeConfirmationClass, .alwaysCarded)
    }

    func testDelegationOperationsAcceptOnlyAnExactScopeLease() {
        let leaseFor = { (capability: DomainDelegationScopeCapability, target: UUID, grantee: UUID) in
            DomainDelegationScopeLease(scopeID: UUID(), generation: 3, capability: capability, granteeSessionID: grantee, targetSessionID: target)
        }
        let target = DomainAgentSessionTargetProvenance.known(targetSessionID: child, parentSessionID: overseer)
        let exact = leaseFor(.organize, child, overseer)
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target, scopeLease: exact).basis,
            .delegationScope(scopeID: exact.scopeID, generation: 3, capability: .organize)
        )
        // Spawn provenance alone never authorizes a delegation op.
        XCTAssertEqual(DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target).denial, .missingScopeLease)
        // A monitor grant never authorizes a delegation op.
        let monitor = DomainAgentSessionMonitorGrantProof(linkID: UUID(), generation: 1, capability: .manage, observerSessionID: overseer, targetSessionID: child)
        XCTAssertEqual(DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target, monitorGrant: monitor).denial, .missingScopeLease)
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target, scopeLease: leaseFor(.observe, child, overseer)).denial,
            .scopeCapabilityMismatch
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target, scopeLease: leaseFor(.organize, outsider, overseer)).denial,
            .scopeLeaseTargetMismatch
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: caller, target: target, scopeLease: leaseFor(.organize, child, outsider)).denial,
            .scopeLeaseGranteeMismatch
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: .administrativePrincipal, target: target, scopeLease: exact).denial,
            .delegationRequiresAgentCaller,
            "administrative principals never act through a scope"
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminRename, caller: .unresolvedAgentRun, target: target, scopeLease: exact).denial,
            .delegationRequiresAgentCaller
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .adminInventory, caller: caller, target: target, scopeLease: exact).denial,
            .delegationScopeLevelOperation
        )
    }

    func testControlOperationsAcceptAScopeLeaseOnlyAsAFallbackAndNeverForDeletion() {
        let sibling = DomainAgentSessionTargetProvenance.known(targetSessionID: outsider, parentSessionID: UUID())
        let control = DomainDelegationScopeLease(scopeID: UUID(), generation: 9, capability: .control, granteeSessionID: overseer, targetSessionID: outsider)
        let observe = DomainDelegationScopeLease(scopeID: UUID(), generation: 9, capability: .observe, granteeSessionID: overseer, targetSessionID: outsider)
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .runSteer, caller: caller, target: sibling, scopeLease: control).basis,
            .delegationScope(scopeID: control.scopeID, generation: 9, capability: .control)
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .manageGetLog, caller: caller, target: sibling, scopeLease: observe).basis,
            .delegationScope(scopeID: observe.scopeID, generation: 9, capability: .observe)
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .runSteer, caller: caller, target: sibling, scopeLease: observe).denial,
            .scopeCapabilityMismatch
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .manageCleanup, caller: caller, target: sibling, scopeLease: control).denial,
            .humanOnlyOperation,
            "deleting sessions is human-only"
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .runSteer, caller: caller, target: sibling).denial,
            .notDirectChild,
            "no lease leaves the pre-scope matrix unchanged"
        )
        // Direct spawn provenance still wins without consulting the lease.
        let direct = DomainAgentSessionTargetProvenance.known(targetSessionID: child, parentSessionID: overseer)
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .runSteer, caller: caller, target: direct, scopeLease: control).basis,
            .directSpawnProvenance(parentSessionID: overseer)
        )
        // Administrative routing is unchanged and never needs a lease.
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .manageCleanup, caller: .administrativePrincipal, target: sibling).basis,
            .administrativePrincipal
        )
        // Unresolved callers fail closed before any lease is read.
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.authorize(operation: .runSteer, caller: .unresolvedAgentRun, target: sibling, scopeLease: control).denial,
            .callerRoutingUnresolved
        )
    }

    // MARK: - Durable coding

    func testGrantRoundTripsThroughCodableAndRejectsUnknownCapabilities() throws {
        let grant = DomainDelegationScopeGrant(
            id: UUID(), granteeSessionID: overseer, kind: .workspace(workspaceID: workspaceID),
            capabilities: [.observe, .organize], guardrails: .init(maxDepth: 2, expiresAt: now),
            origin: .attenuatedFrom(scopeID: UUID()), grantedAt: now
        )
        let data = try JSONEncoder().encode(grant)
        XCTAssertEqual(try JSONDecoder().decode(DomainDelegationScopeGrant.self, from: data), grant)
        let tampered = try XCTUnwrap(String(data: data, encoding: .utf8)).replacingOccurrences(of: "\"organize\"", with: "\"keys\"")
        XCTAssertThrowsError(try JSONDecoder().decode(DomainDelegationScopeGrant.self, from: Data(tampered.utf8)))
    }
}
