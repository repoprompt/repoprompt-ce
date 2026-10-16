import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentSessionLaneAuthorizationTests: XCTestCase {
    func testCreationRequiresAnAgentCallerWithALinkInEitherDirection() {
        let caller = DomainAgentSessionCallerIdentity.agentSession(UUID())
        let inboundOnly = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorCreateLane,
            caller: caller,
            hasActiveOutboundLink: false,
            hasActiveInboundLink: true
        )
        XCTAssertEqual(inboundOnly.basis, .observerGrantSet)
        let outboundOnly = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorCreateLane,
            caller: caller,
            hasActiveOutboundLink: true
        )
        XCTAssertEqual(outboundOnly.basis, .observerGrantSet)
        let unlinked = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorCreateLane,
            caller: caller,
            hasActiveOutboundLink: false
        )
        XCTAssertEqual(unlinked.denial, .noActiveLink)
        let listInboundOnly = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorList,
            caller: caller,
            hasActiveOutboundLink: false,
            hasActiveInboundLink: true
        )
        XCTAssertEqual(listInboundOnly.denial, .noActiveOutboundLink)
        let administrative = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: .monitorCreateLane,
            caller: .administrativePrincipal,
            hasActiveOutboundLink: true
        )
        XCTAssertEqual(administrative.denial, .monitorRequiresAgentCaller)
    }

    func testLaneOperationTableRows() {
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorCreateLane.family, .monitor)
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorCreateLane.isObserverScoped)
        XCTAssertNil(DomainAgentSessionTargetOperation.monitorCreateLane.requiredMonitorCapability)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorCreateLane.mutatesTarget)
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorRetireLane.family, .monitor)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorRetireLane.isObserverScoped)
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorRetireLane.requiredMonitorCapability, .manage)
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorRetireLane.mutatesTarget)
    }
}
