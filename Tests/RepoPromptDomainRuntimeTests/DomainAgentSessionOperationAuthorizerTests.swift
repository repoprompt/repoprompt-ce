import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// The common execution-time matrix that keeps a disclosed sibling UUID from bypassing monitor
/// capabilities through the existing `agent_run` / `agent_manage` control surfaces.
final class DomainAgentSessionOperationAuthorizerTests: XCTestCase {
    private let callerSessionID = UUID()
    private let childSessionID = UUID()
    private let siblingSessionID = UUID()

    private var sessionControlOperations: [DomainAgentSessionTargetOperation] {
        DomainAgentSessionTargetOperation.allCases.filter { $0.family == .sessionControl }
    }

    private var monitorOperations: [DomainAgentSessionTargetOperation] {
        DomainAgentSessionTargetOperation.allCases.filter { $0.family == .monitor }
    }

    private var targetBearingMonitorOperations: [DomainAgentSessionTargetOperation] {
        monitorOperations.filter { !$0.isObserverScoped }
    }

    private func monitorProof(
        capability: DomainAgentSessionLinkCapability,
        observerSessionID: UUID? = nil,
        targetSessionID: UUID? = nil
    ) -> DomainAgentSessionMonitorGrantProof {
        DomainAgentSessionMonitorGrantProof(
            linkID: UUID(),
            generation: 7,
            capability: capability,
            observerSessionID: observerSessionID ?? callerSessionID,
            targetSessionID: targetSessionID ?? siblingSessionID
        )
    }

    // MARK: - Control operations

    func testAdministrativePrincipalRetainsRoutedControlForEveryTargetOperation() {
        for operation in sessionControlOperations {
            let decision = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .administrativePrincipal,
                target: .known(targetSessionID: siblingSessionID, parentSessionID: nil)
            )
            XCTAssertEqual(decision.basis, .administrativePrincipal, "\(operation.rawValue)")
        }
    }

    func testAgentCallerMayControlOnlyItsDirectChildren() {
        for operation in sessionControlOperations {
            let child = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: childSessionID, parentSessionID: callerSessionID)
            )
            XCTAssertEqual(
                child.basis,
                .directSpawnProvenance(parentSessionID: callerSessionID),
                "\(operation.rawValue)"
            )

            let sibling = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: siblingSessionID, parentSessionID: UUID())
            )
            XCTAssertEqual(sibling.denial, .notDirectChild, "\(operation.rawValue)")

            let orphan = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: siblingSessionID, parentSessionID: nil)
            )
            XCTAssertEqual(
                orphan.denial,
                .notDirectChild,
                "an unparented top-level session is never controllable by an agent: \(operation.rawValue)"
            )
        }
    }

    func testGrandchildIsNotDirectlyControllable() {
        let grandchildParent = childSessionID
        let decision = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .runSteer,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: UUID(), parentSessionID: grandchildParent)
        )
        XCTAssertEqual(decision.denial, .notDirectChild, "authority is direct, not transitive")
    }

    func testUnknownTargetProvenanceAndUnresolvedRoutingFailClosed() {
        for operation in sessionControlOperations {
            let unknownTarget = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .unknown(targetSessionID: siblingSessionID)
            )
            XCTAssertEqual(unknownTarget.denial, .targetProvenanceUnknown, "\(operation.rawValue)")

            let unresolvedCaller = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .unresolvedAgentRun,
                target: .known(targetSessionID: childSessionID, parentSessionID: callerSessionID)
            )
            XCTAssertEqual(unresolvedCaller.denial, .callerRoutingUnresolved, "\(operation.rawValue)")
        }
    }

    func testAgentCallerCannotTargetItsOwnSession() {
        let decision = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .runRespond,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: callerSessionID, parentSessionID: nil)
        )
        XCTAssertEqual(
            decision.denial,
            .selfTarget,
            "self-targeting would let an agent answer its own pending interaction"
        )
    }

    func testMonitorGrantNeverAuthorizesAnExistingControlOperation() {
        for operation in sessionControlOperations {
            let decision = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: siblingSessionID, parentSessionID: UUID()),
                monitorGrant: monitorProof(capability: .sendWhenIdle)
            )
            XCTAssertEqual(
                decision.denial,
                .notDirectChild,
                "an oversight link must not widen agent_run/agent_manage: \(operation.rawValue)"
            )
        }
    }

    // MARK: - Monitor operations

    func testMonitorOperationsRequireTheExactGrantCapability() {
        let expected: [DomainAgentSessionTargetOperation: DomainAgentSessionLinkCapability] = [
            .monitorPoll: .poll,
            .monitorWait: .wait,
            .monitorRead: .read,
            .monitorSend: .sendWhenIdle,
            // Observer-local admission policy, so it needs the read grant it already holds over the
            // lane and nothing stronger.
            .monitorSnoozeAutoWake: .poll,
        ]
        for operation in targetBearingMonitorOperations {
            guard let capability = expected[operation] else {
                XCTFail("missing expectation for \(operation.rawValue)")
                continue
            }
            XCTAssertEqual(operation.requiredMonitorCapability, capability, "\(operation.rawValue)")

            let proof = monitorProof(capability: capability)
            let matching = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
                monitorGrant: proof
            )
            XCTAssertEqual(
                matching.basis,
                .monitorGrant(linkID: proof.linkID, generation: proof.generation, capability: capability),
                "\(operation.rawValue)"
            )

            let wrongCapability: DomainAgentSessionLinkCapability = capability == .read ? .poll : .read
            let mismatched = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
                monitorGrant: monitorProof(capability: wrongCapability)
            )
            XCTAssertEqual(mismatched.denial, .monitorCapabilityMismatch, "\(operation.rawValue)")
        }
    }

    func testMonitorOperationsRejectMissingMismatchedAndNonAgentCallers() {
        let missing = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .monitorRead,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: siblingSessionID, parentSessionID: nil)
        )
        XCTAssertEqual(missing.denial, .missingMonitorGrant)

        let wrongObserver = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .monitorRead,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
            monitorGrant: monitorProof(capability: .read, observerSessionID: UUID())
        )
        XCTAssertEqual(wrongObserver.denial, .monitorGrantObserverMismatch)

        let wrongTarget = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .monitorRead,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
            monitorGrant: monitorProof(capability: .read, targetSessionID: UUID())
        )
        XCTAssertEqual(wrongTarget.denial, .monitorGrantTargetMismatch)

        let administrative = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .monitorRead,
            caller: .administrativePrincipal,
            target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
            monitorGrant: monitorProof(capability: .read)
        )
        XCTAssertEqual(administrative.denial, .monitorRequiresAgentCaller)
    }

    func testSpawnProvenanceDoesNotSilentlyCreateAMonitorGrant() {
        for operation in targetBearingMonitorOperations {
            let decision = DomainAgentSessionOperationAuthorizer.authorize(
                operation: operation,
                caller: .agentSession(callerSessionID),
                target: .known(targetSessionID: childSessionID, parentSessionID: callerSessionID)
            )
            XCTAssertEqual(decision.denial, .missingMonitorGrant, "\(operation.rawValue)")
        }
    }

    // MARK: - Observer-scoped `list`

    func testTargetlessListIsObserverScopedAndCarriesNoCapabilityProof() {
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorList.isObserverScoped)
        XCTAssertNil(
            DomainAgentSessionTargetOperation.monitorList.requiredMonitorCapability,
            "a targetless operation must not demand an arbitrary target's capability"
        )
        for operation in DomainAgentSessionTargetOperation.allCases where operation != .monitorList {
            XCTAssertFalse(operation.isObserverScoped, "\(operation.rawValue)")
        }
    }

    func testListCannotBeAuthorizedThroughTheTargetBearingPath() {
        // Routing `list` through the target path would either invent a target or authorize the wrong
        // one, so the matrix refuses it outright.
        let decision = DomainAgentSessionOperationAuthorizer.authorize(
            operation: .monitorList,
            caller: .agentSession(callerSessionID),
            target: .known(targetSessionID: siblingSessionID, parentSessionID: nil),
            monitorGrant: monitorProof(capability: .poll)
        )
        XCTAssertEqual(decision.denial, .observerScopedOperation)
    }

    func testObserverScopedAuthorizationRequiresAnAgentCallerWithAnOutboundLink() {
        let granted = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorList,
            caller: .agentSession(callerSessionID),
            hasActiveOutboundLink: true
        )
        XCTAssertEqual(granted.basis, .observerGrantSet)

        let noLinks = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorList,
            caller: .agentSession(callerSessionID),
            hasActiveOutboundLink: false
        )
        XCTAssertEqual(
            noLinks.denial,
            .noActiveOutboundLink,
            "`list` exists only while at least one outbound link remains"
        )

        let administrative = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorList,
            caller: .administrativePrincipal,
            hasActiveOutboundLink: true
        )
        XCTAssertEqual(administrative.denial, .monitorRequiresAgentCaller)

        let unresolved = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorList,
            caller: .unresolvedAgentRun,
            hasActiveOutboundLink: true
        )
        XCTAssertEqual(unresolved.denial, .monitorRequiresAgentCaller)
    }

    func testTargetBearingOperationsCannotUseTheObserverScopedPath() {
        for operation in DomainAgentSessionTargetOperation.allCases where !operation.isObserverScoped {
            let decision = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
                operation: operation,
                caller: .agentSession(callerSessionID),
                hasActiveOutboundLink: true
            )
            XCTAssertEqual(decision.denial, .targetScopedOperation, "\(operation.rawValue)")
        }
    }

    // MARK: - Discovery scope

    func testDiscoveryScopeIsDirectChildOnlyForAgentCallers() {
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.discoveryScope(for: .administrativePrincipal),
            .unrestricted
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.discoveryScope(for: .agentSession(callerSessionID)),
            .directChildren(of: callerSessionID)
        )
        XCTAssertEqual(
            DomainAgentSessionOperationAuthorizer.discoveryScope(for: .unresolvedAgentRun),
            .none
        )
    }

    // MARK: - Operation classification

    func testOperationFamiliesAndMutationClassificationAreExhaustive() {
        XCTAssertEqual(
            Set(sessionControlOperations.map(\.rawValue)),
            [
                "agent_run.poll", "agent_run.wait", "agent_run.cancel", "agent_run.steer", "agent_run.respond",
                "agent_manage.list_sessions", "agent_manage.get_log", "agent_manage.extract_handoff",
                "agent_manage.resume_session", "agent_manage.stop_session", "agent_manage.cleanup_sessions",
            ]
        )
        XCTAssertEqual(
            Set(monitorOperations.map(\.rawValue)),
            [
                "agent_session_link.list", "agent_session_link.poll", "agent_session_link.wait",
                "agent_session_link.read", "agent_session_link.send",
                "agent_session_link.snooze_auto_wake",
            ]
        )
        for operation in sessionControlOperations where operation.requiredMonitorCapability != nil {
            XCTFail("control operations must never carry an oversight capability: \(operation.rawValue)")
        }
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorSend.mutatesTarget)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorRead.mutatesTarget)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorPoll.isObserverScoped)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorPoll.mutatesTarget)
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorPoll.requiredMonitorCapability, .poll)
        XCTAssertTrue(DomainAgentSessionTargetOperation.manageCleanup.mutatesTarget)
        // Snooze names a target because the policy is per-lane, but it never reaches that target: it
        // must stay a non-observer-scoped, non-mutating `.poll` operation, or it would either be
        // authorized against the wrong thing or claim an authority it does not use.
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorSnoozeAutoWake.isObserverScoped)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorSnoozeAutoWake.mutatesTarget)
        XCTAssertEqual(
            DomainAgentSessionTargetOperation.monitorSnoozeAutoWake.requiredMonitorCapability,
            .poll
        )
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorSnoozeAutoWake.family, .monitor)
    }
}
