import Foundation
@testable import RepoPromptApp
import XCTest

private actor CleanupCountProbe {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

final class ExternalMCPContractsTests: XCTestCase {
    func testRuntimeSnapshotSanitizesAndBoundsPresentationState() {
        let snapshot = ExternalMCPRuntimeSnapshot(
            integrationID: "figma:figma",
            connection: .connected,
            authentication: .authenticated,
            toolCount: 999,
            toolLabels: ["figma_whoami", "https://secret.example", String(repeating: "x", count: 81)],
            diagnostics: ["token leaked", "https://secret.example", "safe diagnostic"]
        )

        XCTAssertEqual(snapshot.toolCount, 128)
        XCTAssertEqual(snapshot.toolLabels, ["figma_whoami"])
        XCTAssertEqual(snapshot.diagnostics, ["safe diagnostic"])
    }

    func testCoordinatorDeniesDisabledAndUnsupportedSessionClasses() async {
        let coordinator = ExternalMCPIntegrationCoordinator()
        let revision = await coordinator.beginRevision()
        let definition = ExternalMCPIntegrationDefinition.figma(repoPromptActivation: .disabled)
        let context = ExternalMCPProviderRuntimeContext(
            identity: ExternalMCPProviderRuntimeIdentity(
                provider: .codex,
                runtimeKind: .appServer,
                executableIdentity: "codex",
                executableVersion: "test"
            ),
            sessionClass: .topLevel,
            coordinatorRevision: revision
        )
        let disabled = await coordinator.decision(
            integration: definition,
            snapshot: .init(
                integrationID: definition.integrationID,
                connection: .connected,
                authentication: .authenticated
            ),
            context: context
        )
        XCTAssertFalse(disabled.isAllowed)
        XCTAssertEqual(disabled.reason, .disabled)

        let childContext = ExternalMCPProviderRuntimeContext(
            identity: context.identity,
            sessionClass: .managedChild,
            coordinatorRevision: revision
        )
        let child = await coordinator.decision(
            integration: .init(provider: .figma, serverName: "figma"),
            snapshot: .init(
                integrationID: definition.integrationID,
                connection: .connected,
                authentication: .authenticated
            ),
            context: childContext
        )
        XCTAssertFalse(child.isAllowed)
        XCTAssertEqual(child.reason, .unsupportedSessionClass)
    }

    func testLeaseRevocationIsExactlyOnceUnderConcurrency() async {
        let identity = ExternalMCPProviderRuntimeIdentity(
            provider: .codex,
            runtimeKind: .appServer,
            executableIdentity: "codex"
        )
        let probe = CleanupCountProbe()
        let lease = ExternalMCPRuntimeBindingLease(
            integrationID: "figma:figma",
            runtimeIdentity: identity,
            sessionClass: .topLevel,
            coordinatorRevision: 1,
            isAccepted: true,
            revokeOperation: {
                await probe.increment()
                try? await Task.sleep(nanoseconds: 10_000_000)
                return .init(outcome: .completed)
            }
        )
        async let first = lease.revoke()
        async let second = lease.revoke()
        _ = await (first, second)
        let cleanupCount = await probe.value()
        XCTAssertEqual(cleanupCount, 1)
    }

    func testLeaseRevocationIsIdempotentAndReportsReceipt() async {
        let identity = ExternalMCPProviderRuntimeIdentity(
            provider: .codex,
            runtimeKind: .appServer,
            executableIdentity: "codex"
        )
        let lease = ExternalMCPRuntimeBindingLease(
            integrationID: "figma:figma",
            runtimeIdentity: identity,
            sessionClass: .topLevel,
            coordinatorRevision: 1,
            isAccepted: true
        )

        let first = await lease.revoke()
        let second = await lease.revoke()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.outcome, .indeterminate)
    }

    func testInitialRevisionIsAllocatedAtomically() async {
        let coordinator = ExternalMCPIntegrationCoordinator()
        async let first = coordinator.activeRevision()
        async let second = coordinator.activeRevision()
        let revisions = await [first, second]
        XCTAssertEqual(Set(revisions), [1])
    }

    func testAllSelectableAgentsMapToOneCanonicalRuntimeFamilyWithoutGrantingAuthority() throws {
        let expected: [AgentProviderKind: ExternalMCPRuntimeProvider] = [
            .codexExec: .codex,
            .claudeCode: .claudeCode,
            .claudeCodeGLM: .claudeCode,
            .kimiCode: .claudeCode,
            .customClaudeCompatible: .claudeCode,
            .openCode: .openCode,
            .cursor: .cursor,
            .grokBuild: .grokBuild,
            .devin: .devin,
            .antigravity: .antigravity
        ]
        XCTAssertEqual(Set(expected.keys), Set(AgentProviderKind.allCases))
        for (agent, family) in expected {
            XCTAssertEqual(agent.externalMCPRuntimeProvider, family)
            XCTAssertEqual(try JSONDecoder().decode(
                ExternalMCPRuntimeProvider.self,
                from: JSONEncoder().encode(family)
            ), family)
        }
        XCTAssertEqual(ExternalMCPRuntimeProvider.codex.rawValue, "codex")
        XCTAssertEqual(ExternalMCPRuntimeProvider.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(ExternalMCPRuntimeProvider.openCode.rawValue, "openCode")
        XCTAssertEqual(ExternalMCPRuntimeProvider.cursor.rawValue, "cursor")
        XCTAssertEqual(ExternalMCPRuntimeProvider.grokBuild.rawValue, "grokBuild")
        XCTAssertEqual(ExternalMCPRuntimeProvider.devin.rawValue, "devin")
        XCTAssertEqual(ExternalMCPRuntimeProvider.antigravity.rawValue, "antigravity")
    }

    func testRegistryDoesNotInventAdapters() {
        let registry = ExternalMCPAdapterRegistry()
        XCTAssertNil(registry.adapter(for: .codex))
        XCTAssertTrue(registry.registeredProviders.isEmpty)
    }
}
