import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorExternalMCPProviderAdapterTests: XCTestCase {
    func testDefaultAdapterDoesNotTreatHumanReadableCLITextAsProofForStatusOrRuntime() async {
        let adapter = CursorExternalMCPProviderAdapter()
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

    func testAcceptedApprovalLeaseUsesProviderTeardownReceipt() async throws {
        let cleanup = CleanupProbe()
        let adapter = CursorExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                CursorExternalMCPApprovalProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    approvalID: "approval-1"
                )
            },
            teardownOperation: { _, _, approvalID in
                await cleanup.record(approvalID: approvalID)
                return .init(outcome: .completed, detail: "approval removed")
            }
        )
        let current = context()
        let prepared = await adapter.prepareRuntimeAccess(
            in: current,
            integration: .figma(),
            decision: decision(for: current)
        )
        let binding = try XCTUnwrap(prepared.cursorBinding)
        XCTAssertEqual(binding.approvalID, "approval-1")

        let receipt = await binding.lease.revoke()
        let approvalID = await cleanup.approvalID()
        XCTAssertEqual(receipt, .init(outcome: .completed, detail: "approval removed"))
        XCTAssertEqual(approvalID, "approval-1")
    }

    func testInvalidAndUnauthenticatedDisconnectsFailClosed() async {
        let adapter = CursorExternalMCPProviderAdapter { _, _ in
            CursorExternalMCPApprovalProof(
                isCapabilityProven: true,
                isAuthenticated: true,
                approvalID: "approval-1"
            )
        }
        let invalid = await adapter.disconnect(
            in: context(sessionClass: .managedChild),
            integration: .figma()
        )
        XCTAssertEqual(invalid.receipt.outcome, .unsupported)

        let unauthenticated = CursorExternalMCPProviderAdapter { _, _ in
            CursorExternalMCPApprovalProof(
                isCapabilityProven: true,
                isAuthenticated: false,
                approvalID: "approval-1"
            )
        }
        let disconnected = await unauthenticated.disconnect(in: context(), integration: .figma())
        XCTAssertEqual(disconnected.receipt.outcome, .unsupported)
    }

    func testPreparationWithoutTeardownIsDenied() async {
        let adapter = CursorExternalMCPProviderAdapter { _, _ in
            CursorExternalMCPApprovalProof(
                isCapabilityProven: true,
                isAuthenticated: true,
                approvalID: "approval-1"
            )
        }
        let current = context()
        let capabilities = await adapter.capabilities(in: current)
        XCTAssertEqual(capabilities, .unsupported)
        let prepared = await adapter.prepareRuntimeAccess(
            in: current,
            integration: .figma(),
            decision: decision(for: current)
        )
        XCTAssertNil(prepared.cursorBinding)
        XCTAssertNil(prepared.neutralResult.lease)
        XCTAssertFalse(prepared.neutralResult.decision.isAllowed)
    }

    func testCancellationAfterSuspendingProofPreventsStatusAndRuntimeAuthority() async {
        let statusGate = CursorAdapterSuspensionGate()
        let runtimeGate = CursorAdapterSuspensionGate()
        let token = ExternalMCPCancellationToken()
        let adapter = CursorExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                await statusGate.wait()
                return CursorExternalMCPApprovalProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    approvalID: "approval-1"
                )
            },
            teardownOperation: { _, _, _ in .init(outcome: .completed) }
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
        let runtimeAdapter = CursorExternalMCPProviderAdapter(
            proofProvider: { _, _ in
                await runtimeGate.wait()
                return CursorExternalMCPApprovalProof(
                    isCapabilityProven: true,
                    isAuthenticated: true,
                    approvalID: "approval-1"
                )
            },
            teardownOperation: { _, _, _ in .init(outcome: .completed) }
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

    private func context(
        sessionClass: ExternalMCPSessionClass = .topLevel,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) -> ExternalMCPProviderRuntimeContext {
        .init(
            identity: .init(
                provider: .cursor,
                runtimeKind: .acp,
                executableIdentity: "/usr/local/bin/cursor-agent"
            ),
            sessionClass: sessionClass,
            isolation: .ceIsolated,
            coordinatorRevision: 11,
            cancellationToken: cancellationToken
        )
    }

    private func decision(for context: ExternalMCPProviderRuntimeContext) -> ExternalMCPAccessDecision {
        .init(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: context.identity,
            revision: context.coordinatorRevision,
            isAllowed: true,
            reason: .granted
        )
    }
}

private actor CursorAdapterSuspensionGate {
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

private actor CleanupProbe {
    private var lastApprovalID: String?

    func record(approvalID: String) {
        lastApprovalID = approvalID
    }

    func approvalID() -> String? {
        lastApprovalID
    }
}
