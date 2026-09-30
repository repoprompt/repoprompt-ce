import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenCodeExternalMCPProviderAdapterTests: XCTestCase {
    func testDefaultAdapterDoesNotTreatHumanReadableCLITextAsProofForStatusOrRuntime() async {
        let adapter = OpenCodeExternalMCPProviderAdapter()
        let current = context()

        let capabilities = await adapter.capabilities(in: current)
        XCTAssertEqual(capabilities, .unsupported)

        let status = await adapter.refreshStatus(in: current, integration: .figma())
        XCTAssertEqual(status.connection, .unavailable)
        XCTAssertEqual(status.authentication, .unsupported)

        let authentication = await adapter.authenticate(in: current, integration: .figma())
        XCTAssertEqual(authentication.status, .unsupported)

        let runtime = await adapter.applyRuntimeAccess(in: current, decision: decision(for: current))
        XCTAssertNil(runtime.lease)
        XCTAssertFalse(runtime.decision.isAllowed)
    }

    func testCapabilitiesAndAuthenticationAreProviderOwnedAndTopLevelOnly() async {
        let adapter = OpenCodeExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                OpenCodeExternalMCPInjectionProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    resolvedServerName: "figma",
                    resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
                )
            },
            teardownOperation: { _, _ in .init(outcome: .completed) }
        )
        let topLevel = context()
        let capabilities = await adapter.capabilities(in: topLevel)
        XCTAssertEqual(capabilities.runtimeInjection, .requiresPersistentApproval)
        XCTAssertEqual(capabilities.childSessionInheritance, .unsupported)

        let authentication = await adapter.authenticate(in: topLevel, integration: .figma())
        XCTAssertEqual(authentication.status, .authenticated)
        XCTAssertEqual(authentication.snapshot.authentication, .providerOwned)
        XCTAssertNil(authentication.handoffURL)

        for sessionClass: ExternalMCPSessionClass in [.managedChild, .providerNativeChild, .headless, .cloudChild, .discovery] {
            let child = context(sessionClass: sessionClass)
            let capabilities = await adapter.capabilities(in: child)
            XCTAssertEqual(capabilities, .unsupported)
            let result = await adapter.applyRuntimeAccess(in: child, decision: decision(for: child))
            XCTAssertNil(result.lease)
            XCTAssertFalse(result.decision.isAllowed)
        }
    }

    func testPreparationRequiresExactProofDecisionAndCancellation() async throws {
        let adapter = OpenCodeExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                OpenCodeExternalMCPInjectionProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    resolvedServerName: "figma",
                    resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
                )
            },
            teardownOperation: { _, _ in
                .init(outcome: .completed, detail: "ephemeral overlay removed")
            }
        )
        let current = context()
        let prepared = await adapter.prepareEphemeralRuntimeAccess(
            in: current,
            integration: .figma(),
            decision: decision(for: current)
        )
        let binding = try XCTUnwrap(prepared.openCodeBinding)
        XCTAssertTrue(prepared.neutralResult.decision.isAllowed)
        XCTAssertEqual(binding.externalMCP, .figma(serverName: "figma"))
        let firstReceipt = await binding.lease.revoke()
        let secondReceipt = await binding.lease.revoke()
        XCTAssertEqual(firstReceipt.outcome, .completed)
        XCTAssertEqual(firstReceipt.detail, "ephemeral overlay removed")
        XCTAssertEqual(secondReceipt.outcome, .completed)

        let invalidDisconnect = await adapter.disconnect(
            in: context(sessionClass: .managedChild),
            integration: .figma()
        )
        XCTAssertEqual(invalidDisconnect.receipt.outcome, .unsupported)

        var stale = decision(for: current)
        stale = ExternalMCPAccessDecision(
            integrationID: stale.integrationID,
            runtimeIdentity: stale.runtimeIdentity,
            revision: stale.revision + 1,
            isAllowed: true,
            reason: .granted
        )
        let denied = await adapter.applyRuntimeAccess(in: current, decision: stale)
        XCTAssertNil(denied.lease)
        XCTAssertFalse(denied.decision.isAllowed)

        let cancelled = context(cancellationToken: ExternalMCPCancellationToken())
        cancelled.cancellationToken.cancel()
        let canceledResult = await adapter.applyRuntimeAccess(in: cancelled, decision: decision(for: cancelled))
        XCTAssertNil(canceledResult.lease)
        XCTAssertEqual(canceledResult.decision.reason, .cancelled)
    }

    func testPreparationWithoutTeardownIsDenied() async {
        let adapter = OpenCodeExternalMCPProviderAdapter { _, _ in
            OpenCodeExternalMCPInjectionProof(
                isCapabilityProven: true,
                isAuthenticated: true,
                resolvedServerName: "figma",
                resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
            )
        }
        let current = context()
        let capabilities = await adapter.capabilities(in: current)
        XCTAssertEqual(capabilities, .unsupported)
        let prepared = await adapter.prepareEphemeralRuntimeAccess(
            in: current,
            integration: .figma(),
            decision: decision(for: current)
        )
        XCTAssertNil(prepared.openCodeBinding)
        XCTAssertNil(prepared.neutralResult.lease)
        XCTAssertFalse(prepared.neutralResult.decision.isAllowed)
    }

    func testCancellationAfterSuspendingProofPreventsStatusAndRuntimeAuthority() async {
        let statusGate = OpenCodeAdapterSuspensionGate()
        let runtimeGate = OpenCodeAdapterSuspensionGate()
        let token = ExternalMCPCancellationToken()
        let adapter = OpenCodeExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                await statusGate.wait()
                return OpenCodeExternalMCPInjectionProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    resolvedServerName: "figma",
                    resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
                )
            },
            teardownOperation: { _, _ in .init(outcome: .completed) }
        )
        let current = context(cancellationToken: token)
        let statusTask = Task { await adapter.refreshStatus(in: current, integration: .figma()) }
        await statusGate.waitUntilStarted()
        token.cancel()
        await statusGate.resume()

        let status = await statusTask.value
        XCTAssertEqual(status.connection, .unavailable)
        XCTAssertEqual(status.authentication, .unsupported)

        let runtimeToken = ExternalMCPCancellationToken()
        let runtimeAdapter = OpenCodeExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                await runtimeGate.wait()
                return OpenCodeExternalMCPInjectionProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    resolvedServerName: "figma",
                    resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
                )
            },
            teardownOperation: { _, _ in .init(outcome: .completed) }
        )
        let runtimeContext = context(cancellationToken: runtimeToken)
        let runtimeTask = Task {
            await runtimeAdapter.applyRuntimeAccess(
                in: runtimeContext,
                decision: decision(for: runtimeContext)
            )
        }
        await runtimeGate.waitUntilStarted()
        runtimeToken.cancel()
        await runtimeGate.resume()

        let runtime = await runtimeTask.value
        XCTAssertNil(runtime.lease)
        XCTAssertEqual(runtime.decision.reason, .cancelled)
    }

    func testEphemeralConfigAddsCanonicalRemoteAndRejectsCollisionsAndBadSchema() throws {
        let json = try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(
            includeRepoPromptMCPServer: true,
            externalMCP: .figma(serverName: "figma")
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let mcp = try XCTUnwrap(object["mcp"] as? [String: Any])
        let figma = try XCTUnwrap(mcp["figma"] as? [String: Any])
        XCTAssertEqual(figma["type"] as? String, "remote")
        XCTAssertEqual(figma["url"] as? String, OpenCodeIntegrationConfiguration.figmaRemoteMCPURL)
        XCTAssertEqual(figma["enabled"] as? Bool, true)
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("Authorization"))

        let collisionInput = """
        {"$schema":"https://opencode.ai/config.json","agent":{},"mcp":{"FIGMA":{"type":"remote","url":"https://other.invalid","enabled":true}}}
        """
        XCTAssertThrowsError(try OpenCodeIntegrationConfiguration.mergingExternalMCP(.figma(serverName: "figma"), intoConfigContent: collisionInput)) { error in
            XCTAssertEqual(error as? OpenCodeIntegrationConfiguration.ExternalMCPConfigurationError, .caseInsensitiveCollision(["FIGMA", "figma"]))
        }

        let badSchema = "{\"$schema\":\"wrong\",\"agent\":{},\"mcp\":{}}"
        XCTAssertThrowsError(try OpenCodeIntegrationConfiguration.mergingExternalMCP(.figma(serverName: "figma"), intoConfigContent: badSchema)) { error in
            XCTAssertEqual(error as? OpenCodeIntegrationConfiguration.ExternalMCPConfigurationError, .invalidSchema)
        }
    }

    private func proof() -> OpenCodeExternalMCPInjectionProof {
        OpenCodeExternalMCPInjectionProof(
            isCapabilityProven: true,
            isAuthenticated: true,
            resolvedServerName: "figma",
            resolvedRemoteURL: OpenCodeIntegrationConfiguration.figmaRemoteMCPURL
        )
    }

    private func context(
        sessionClass: ExternalMCPSessionClass = .topLevel,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) -> ExternalMCPProviderRuntimeContext {
        ExternalMCPProviderRuntimeContext(
            identity: ExternalMCPProviderRuntimeIdentity(
                provider: .openCode,
                runtimeKind: .acp,
                executableIdentity: "/usr/local/bin/opencode"
            ),
            sessionClass: sessionClass,
            isolation: .ceIsolated,
            coordinatorRevision: 7,
            cancellationToken: cancellationToken
        )
    }

    private func decision(for context: ExternalMCPProviderRuntimeContext) -> ExternalMCPAccessDecision {
        ExternalMCPAccessDecision(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: context.identity,
            revision: context.coordinatorRevision,
            isAllowed: true,
            reason: .granted
        )
    }
}

private actor OpenCodeAdapterSuspensionGate {
    private var started = false
    private var resumed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !resumed else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        resumed = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
