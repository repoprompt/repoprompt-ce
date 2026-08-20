import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainProtectedMutationSecurityTests: XCTestCase {
    func testFinalRuntimeClassifiesAllProtectedMutationActions() {
        XCTAssertNil(operation("manage_selection", ["op": .string("get")]))
        XCTAssertEqual(operation("manage_selection", ["op": .string("set")])?.action, "set")
        XCTAssertNil(operation("prompt", ["op": .string("get")]))
        XCTAssertEqual(operation("prompt", ["op": .string("append")])?.action, "append")
        XCTAssertNil(operation("workspace_context", ["op": .string("snapshot")]))
        XCTAssertEqual(operation("workspace_context", ["op": .string("select_preset")])?.action, "select_preset")
        XCTAssertEqual(operation("bind_context", ["op": .string("bind")])?.action, "bind")
        XCTAssertEqual(operation("manage_workspaces", ["action": .string("create")])?.action, "create")
        XCTAssertEqual(operation("file_actions", ["action": .string("create")])?.action, "create")
        XCTAssertEqual(operation("apply_edits", ["path": .string("file.swift")])?.action, "replace")
        XCTAssertEqual(operation("manage_worktree", ["op": .string("create")])?.action, "create")
    }

    func testProtectedBindingDefaultsToDenyAndNeverCallsBackendWithoutPrincipal() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "manage_selection", calls: calls)

        do {
            _ = try await binding(["op": .string("set")])
            XCTFail("Expected missing-principal denial")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .principalMissing)
        }
        let deniedCallCount = await calls.value
        XCTAssertEqual(deniedCallCount, 0)

        let readResult = try await binding(["op": .string("get")])
        XCTAssertEqual(readResult.stringValue, "ok")
        let readCallCount = await calls.value
        XCTAssertEqual(readCallCount, 1)
    }

    func testVerifiedAppProxyPreservesCompatibilityWhileUnverifiedPrincipalIsDenied() async throws {
        let fixture = try RuntimeFixture(mode: .app)
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "prompt", calls: calls)

        let unverified = fixture.context(
            kind: .appProxy,
            assurance: .displayNameOnly,
            ephemeralGrantedToolNames: []
        )
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(unverified) {
                try await binding(["op": .string("set")])
            }
            XCTFail("Expected unverified-principal denial")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .principalUnverified)
        }

        let verified = fixture.context(
            kind: .appProxy,
            assurance: .verifiedProcess,
            ephemeralGrantedToolNames: []
        )
        let result = try await MCPDomainInvocationSecurityContext.$current.withValue(verified) {
            try await binding(["op": .string("set")])
        }
        XCTAssertEqual(result.stringValue, "ok")
        let appCallCount = await calls.value
        XCTAssertEqual(appCallCount, 1)
    }

    func testRunScopedGrantIsRevalidatedBeforeBackendExecution() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "bind_context", calls: calls)
        let denied = fixture.context(
            kind: .runScoped,
            assurance: .verifiedProcess,
            ephemeralGrantedToolNames: []
        )
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(denied) {
                try await binding(["op": .string("bind")])
            }
            XCTFail("Expected missing-grant denial")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .grantMissing)
        }

        let allowed = fixture.context(
            kind: .runScoped,
            assurance: .verifiedProcess,
            ephemeralGrantedToolNames: ["bind_context"]
        )
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(allowed) {
            try await binding(["op": .string("bind")])
        }
        let runCallCount = await calls.value
        XCTAssertEqual(runCallCount, 1)
    }

    func testExactRunScopedOperationGrantAllowsNamedActionAndDeniesSiblingAction() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "prompt", calls: calls)
        let exactOperation = fixture.context(
            kind: .runScoped,
            assurance: .verifiedProcess,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: ["prompt.set"]
        )

        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(exactOperation) {
            try await binding(["op": .string("set")])
        }
        await XCTAssertThrowsErrorAsync(
            try await MCPDomainInvocationSecurityContext.$current.withValue(exactOperation) {
                try await binding(["op": .string("append")])
            }
        ) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testVersionedGrantReloadsAcrossRunningPolicyStoresAndRevocationIsImmediate() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let first = try RuntimeFixture(mode: .standalone, storage: storage)
        let administrator = Self.ttyAdministrator()
        let grant = DomainHeadlessMutationGrant(
            principalKey: "client:test",
            allowedOperations: ["manage_selection.set"],
            expiresAt: Date().addingTimeInterval(3600)
        )
        let added = try await first.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: administrator
        )
        XCTAssertEqual(added.version, DomainMutationPolicyDocument.schemaVersion)
        XCTAssertEqual(added.revision, 1)

        let second = try RuntimeFixture(mode: .standalone, storage: storage)
        let loaded = await second.runtime.mutationPolicyStore.snapshot()
        XCTAssertEqual(loaded.0.revision, 1)
        let calls = CallCounter()
        let binding = second.protectedBinding(toolName: "manage_selection", calls: calls)
        let principal = second.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            stableKey: "client:test",
            ephemeralGrantedToolNames: []
        )
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(principal) {
            try await binding(["op": .string("set")])
        }
        let grantedCallCount = await calls.value
        XCTAssertEqual(grantedCallCount, 1)

        // Model the TTY policy CLI as a distinct process/store while the broker above remains live.
        let administratorProcess = try RuntimeFixture(mode: .standalone, storage: storage)
        let revoked = try await administratorProcess.runtime.mutationPolicyStore.revokeGrant(
            id: grant.id,
            expectedRevision: 1,
            administrator: administrator
        )
        XCTAssertEqual(revoked.revision, 2)
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(principal) {
                try await binding(["op": .string("set")])
            }
            XCTFail("Expected revoked-grant denial")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .grantRevoked)
        }
        let revokedCallCount = await calls.value
        XCTAssertEqual(revokedCallCount, 1)

        let replacement = DomainHeadlessMutationGrant(
            principalKey: "client:test",
            allowedOperations: ["manage_selection.set"],
            expiresAt: Date().addingTimeInterval(3600)
        )
        _ = try await administratorProcess.runtime.mutationPolicyStore.addGrant(
            replacement,
            expectedRevision: 2,
            administrator: administrator
        )
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(principal) {
            try await binding(["op": .string("set")])
        }
        let replacementCallCount = await calls.value
        XCTAssertEqual(replacementCallCount, 2)

        let restartedRuntime = try RuntimeFixture(mode: .standalone, storage: storage)
        let restarted = await restartedRuntime.runtime.mutationPolicyStore.snapshot()
        XCTAssertEqual(restarted.0.revision, 3)
        XCTAssertNotNil(restarted.0.headlessGrants.first?.revokedAt)
    }

    func testPersistentGrantUsesVerifiedFingerprintNotSpoofableDisplayIdentity() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let administrator = Self.ttyAdministrator()
        let grant = DomainHeadlessMutationGrant(
            principalKey: "verified:fingerprint:one",
            allowedOperations: ["manage_selection.set"],
            expiresAt: Date().addingTimeInterval(3600)
        )
        _ = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: administrator
        )
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "manage_selection", calls: calls)
        let spoofed = fixture.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            stableKey: "same-display-name",
            verifiedIdentityFingerprint: "verified:fingerprint:other",
            ephemeralGrantedToolNames: []
        )
        await XCTAssertThrowsErrorAsync(
            try await MCPDomainInvocationSecurityContext.$current.withValue(spoofed) {
                try await binding(["op": .string("set")])
            }
        ) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }

        let verified = fixture.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            stableKey: "same-display-name",
            verifiedIdentityFingerprint: "verified:fingerprint:one",
            ephemeralGrantedToolNames: []
        )
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(verified) {
            try await binding(["op": .string("set")])
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testWorkspaceRootMutationRequiresCanonicalScopeAndAuthoritativeRouting() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "manage_workspaces", calls: calls)
        let allowedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-allowed-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.path
        let inside = URL(fileURLWithPath: allowedRoot).appendingPathComponent("child").path
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-outside-\(UUID().uuidString)", isDirectory: true).path
        let allowed = fixture.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            authorizedCanonicalRoots: [allowedRoot],
            ephemeralGrantedToolNames: ["manage_workspaces"]
        )
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(allowed) {
            try await binding(["action": .string("add_folder"), "folder_path": .string(inside)])
        }
        await XCTAssertThrowsErrorAsync(
            try await MCPDomainInvocationSecurityContext.$current.withValue(allowed) {
                try await binding(["action": .string("add_folder"), "folder_path": .string(outside)])
            }
        ) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }

        let staleRouting = fixture.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            authorizedCanonicalRoots: [allowedRoot],
            hasAuthoritativeRoutingContext: false,
            ephemeralGrantedToolNames: ["manage_workspaces"]
        )
        await XCTAssertThrowsErrorAsync(
            try await MCPDomainInvocationSecurityContext.$current.withValue(staleRouting) {
                try await binding(["action": .string("add_folder"), "folder_path": .string(inside)])
            }
        ) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .routingContextUnavailable)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testGrantRootContainmentResolvesSymlinksBeforeAuthorization() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-symlink-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let grantedRoot = storage.appendingPathComponent("granted", isDirectory: true)
        let outsideRoot = storage.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: grantedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let fixture = try RuntimeFixture(mode: .standalone, storage: storage)
        let grant = DomainHeadlessMutationGrant(
            principalKey: "client:test",
            allowedOperations: ["manage_selection.set"],
            canonicalRoots: [grantedRoot.path],
            expiresAt: Date().addingTimeInterval(3600)
        )
        let added = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: Self.ttyAdministrator()
        )
        XCTAssertEqual(added.headlessGrants.first?.canonicalRoots, [grantedRoot.path])

        try FileManager.default.removeItem(at: grantedRoot)
        try FileManager.default.createSymbolicLink(at: grantedRoot, withDestinationURL: outsideRoot)
        let requestedPath = grantedRoot.appendingPathComponent("secret.txt").path
        let calls = CallCounter()
        let binding = fixture.protectedBinding(toolName: "manage_selection", calls: calls)
        let context = fixture.context(
            kind: .runScoped,
            assurance: .hostLaunchToken,
            authorizedCanonicalRoots: [requestedPath],
            ephemeralGrantedToolNames: []
        )

        await XCTAssertThrowsErrorAsync(
            try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
                try await binding(["op": .string("set")])
            }
        ) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testPolicyAdministrationRequiresLocalTTYPrincipalAndRejectsStaleRevision() async throws {
        let fixture = try RuntimeFixture(mode: .standalone)
        let grant = DomainHeadlessMutationGrant(
            principalKey: "client:test",
            allowedOperations: ["prompt.set"],
            expiresAt: Date().addingTimeInterval(3600)
        )
        let nonAdministrator = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: "client",
            displayName: "client",
            kind: .runScoped,
            assurance: .verifiedProcess,
            processID: 42,
            runID: nil,
            provider: nil
        )
        do {
            _ = try await fixture.runtime.mutationPolicyStore.addGrant(
                grant,
                expectedRevision: 0,
                administrator: nonAdministrator
            )
            XCTFail("Expected TTY-only administration denial")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .administratorTTYRequired)
        }

        _ = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: Self.ttyAdministrator()
        )
        do {
            _ = try await fixture.runtime.mutationPolicyStore.revokeGrant(
                id: grant.id,
                expectedRevision: 0,
                administrator: Self.ttyAdministrator()
            )
            XCTFail("Expected revision conflict")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .policyRevisionConflict(expected: 0, actual: 1))
        }
    }

    private func operation(_ toolName: String, _ arguments: [String: Value]) -> DomainProtectedMutationOperation? {
        MCPDomainProtectedMutationToolProvider.operation(
            toolName: toolName,
            arguments: arguments
        )
    }

    private static func ttyAdministrator() -> DomainClientPrincipal {
        DomainClientPrincipal(
            principalID: UUID(),
            stableKey: nil,
            displayName: "local tty",
            kind: .ttyAdministrator,
            assurance: .localTTY,
            processID: 42,
            runID: nil,
            provider: nil
        )
    }
}

private final class RuntimeFixture: @unchecked Sendable {
    let runtime: MCPDomainRuntime
    private let storage: URL

    init(mode: DomainRuntimeMode, storage: URL? = nil) throws {
        let storage = storage ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-runtime-\(UUID().uuidString)", isDirectory: true)
        self.storage = storage
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        runtime = MCPDomainRuntime(
            configuration: .init(
                mode: mode,
                profileIdentifier: "m4-test",
                storageDirectory: storage,
                eventDirectory: storage.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storage.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ),
            runtimeID: UUID(),
            lifecycleGeneration: 7,
            processID: 42
        )
    }

    func protectedBinding(toolName: String, calls: CallCounter) -> MCPDomainToolBinding {
        let binding = MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: toolName,
                description: "fixture",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            operation: { _ in
                try await MCPDomainMutationCommitContext.willCommit()
                await calls.increment()
                return .string("ok")
            }
        )
        return runtime.protectedMutationProvider.protectedBinding(binding)
    }

    func context(
        kind: DomainClientPrincipalKind,
        assurance: DomainClientPrincipalAssurance,
        stableKey: String? = "client:test",
        verifiedIdentityFingerprint: String? = nil,
        authorizedCanonicalRoots: Set<String> = [],
        hasAuthoritativeRoutingContext: Bool = true,
        ephemeralGrantedToolNames: Set<String>,
        ephemeralGrantedOperations: Set<String> = []
    ) -> DomainToolInvocationSecurityContext {
        DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: stableKey,
                displayName: "test client",
                kind: kind,
                assurance: assurance,
                processID: assurance == .displayNameOnly ? nil : 42,
                runID: UUID(),
                provider: "test",
                verifiedIdentityFingerprint: assurance == .displayNameOnly
                    ? nil
                    : (verifiedIdentityFingerprint ?? stableKey)
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            authorizedCanonicalRoots: authorizedCanonicalRoots,
            hasAuthoritativeRoutingContext: hasAuthoritativeRoutingContext,
            ephemeralGrantedToolNames: ephemeralGrantedToolNames,
            ephemeralGrantedOperations: ephemeralGrantedOperations
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
