import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class MCPRuntimeLifecycleTests: XCTestCase {
    func testAdmittedRuntimeWorkDrainsOnOriginalRuntimeAndNeverRetargetsReplacement() async throws {
        let lifecycle = WorkspaceRuntimeLifecycleRegistry()
        let adapters = MCPAppRuntimeAdapterRegistry()
        let oldRuntimeID = WorkspaceRuntimeID()
        let oldSessionID = WorkspaceSessionID()
        let oldActivationID = UUID()
        let shutdown = RuntimeShutdownProbe()
        let oldRuntimeSnapshot = snapshot(sessionID: oldSessionID)
        let oldHandle = makeHandle(
            sessionID: oldSessionID,
            activationID: oldActivationID,
            currentSnapshot: oldRuntimeSnapshot,
            shutdown: shutdown
        )
        let registration = await lifecycle.register(runtimeID: oldRuntimeID, sessionHandle: oldHandle)
        XCTAssertEqual(registration, .registered)
        let activation = await lifecycle.activate(
            runtimeID: oldRuntimeID,
            initialAdmission: Self.admission(sessionID: oldSessionID, activationID: oldActivationID)
        )
        XCTAssertEqual(activation, .activated)

        let oldAdapter = MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: nil)
        guard case let .staged(oldTicket) = adapters.stage(
            windowID: 8,
            runtimeID: oldRuntimeID,
            sessionID: oldSessionID,
            authoritativeSnapshot: snapshot(sessionID: oldSessionID),
            adapter: oldAdapter
        ) else { return XCTFail("old mapping did not stage") }
        _ = adapters.activate(ticket: oldTicket)
        let oldRouting = try XCTUnwrap(adapters.routingSnapshot(windowID: 8))

        guard case let .success(lease) = await MCPRuntimeRequestCoordinator.admit(
            routingSnapshot: oldRouting,
            lifetimeClass: .runtimeCapable,
            lifecycleRegistry: lifecycle,
            adapterRegistry: adapters
        ) else { return XCTFail("old runtime did not admit") }
        let admitted = await lease.context
        XCTAssertEqual(admitted.runtimeID, oldRuntimeID)

        XCTAssertEqual(adapters.beginClosing(ticket: oldTicket), .closing)
        let drain = await lifecycle.beginDraining(runtimeID: oldRuntimeID)
        XCTAssertEqual(drain, .draining(activeAdmissionCount: 1))
        adapters.confirmRuntimeDraining(runtimeID: oldRuntimeID)
        let replacementRuntimeID = WorkspaceRuntimeID()
        let replacementSessionID = WorkspaceSessionID()
        let replacementAdapter = MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: nil)
        guard case let .staged(replacementTicket) = adapters.stage(
            windowID: 8,
            runtimeID: replacementRuntimeID,
            sessionID: replacementSessionID,
            authoritativeSnapshot: snapshot(sessionID: replacementSessionID),
            adapter: replacementAdapter
        ) else { return XCTFail("replacement mapping did not stage") }
        _ = adapters.activate(ticket: replacementTicket)

        XCTAssertEqual(admitted.runtimeID, oldRuntimeID)
        XCTAssertEqual(admitted.routingSnapshot.ticket, oldTicket)
        let capturedRuntimeSnapshot = await admitted.admittedRuntime.currentSnapshot()
        XCTAssertEqual(capturedRuntimeSnapshot?.sessionID, oldSessionID)
        XCTAssertEqual(adapters.routingSnapshot(windowID: 8)?.runtimeID, replacementRuntimeID)
        XCTAssertNil(adapters.adapter(for: oldTicket))
        XCTAssertTrue(adapters.adapter(for: replacementTicket) === replacementAdapter)

        let release = await lease.release()
        XCTAssertEqual(release, .releasedAndRemoved)
        let shutdownCount = await shutdown.value()
        XCTAssertEqual(shutdownCount, 1)
        let oldSnapshot = await lifecycle.snapshot(runtimeID: oldRuntimeID)
        XCTAssertEqual(oldSnapshot?.activeAdmissionCount, 0)
    }

    func testUIRequiredAdmissionFailsAfterAdapterClosesWithoutChangingRuntimeCount() async throws {
        let lifecycle = WorkspaceRuntimeLifecycleRegistry()
        let adapters = MCPAppRuntimeAdapterRegistry()
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let handle = makeHandle(
            sessionID: sessionID,
            activationID: activationID,
            shutdown: RuntimeShutdownProbe()
        )
        _ = await lifecycle.register(runtimeID: runtimeID, sessionHandle: handle)
        _ = await lifecycle.activate(
            runtimeID: runtimeID,
            initialAdmission: Self.admission(sessionID: sessionID, activationID: activationID)
        )
        let adapter = MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: nil)
        guard case let .staged(ticket) = adapters.stage(
            windowID: 2,
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: snapshot(sessionID: sessionID),
            adapter: adapter
        ) else { return XCTFail("mapping did not stage") }
        _ = adapters.activate(ticket: ticket)
        let routing = try XCTUnwrap(adapters.routingSnapshot(windowID: 2))
        _ = adapters.beginClosing(ticket: ticket)

        let result = await MCPRuntimeRequestCoordinator.admit(
            routingSnapshot: routing,
            lifetimeClass: .uiRequired,
            lifecycleRegistry: lifecycle,
            adapterRegistry: adapters
        )
        XCTAssertEqual(result.failure, .adapterUnavailable)
        let lifecycleSnapshot = await lifecycle.snapshot(runtimeID: runtimeID)
        XCTAssertEqual(lifecycleSnapshot?.activeAdmissionCount, 0)
    }

    func testRuntimeCapableAdmissionDoesNotConsultWeakAdapterAfterCoreAdmission() async throws {
        let lifecycle = WorkspaceRuntimeLifecycleRegistry()
        let adapters = MCPAppRuntimeAdapterRegistry()
        let hook = RuntimeAdmissionHook()
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let handle = makeHandle(
            sessionID: sessionID,
            activationID: activationID,
            shutdown: RuntimeShutdownProbe(),
            onAdmit: { await hook.run() }
        )
        _ = await lifecycle.register(runtimeID: runtimeID, sessionHandle: handle)
        _ = await lifecycle.activate(
            runtimeID: runtimeID,
            initialAdmission: Self.admission(sessionID: sessionID, activationID: activationID)
        )

        let adapter = MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: nil)
        guard case let .staged(ticket) = adapters.stage(
            windowID: 12,
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: snapshot(sessionID: sessionID),
            adapter: adapter
        ) else { return XCTFail("mapping did not stage") }
        _ = adapters.activate(ticket: ticket)
        let routing = try XCTUnwrap(adapters.routingSnapshot(windowID: 12))
        await hook.install {
            await MainActor.run {
                _ = adapters.beginClosing(ticket: ticket)
            }
        }

        guard case let .success(lease) = await MCPRuntimeRequestCoordinator.admit(
            routingSnapshot: routing,
            lifetimeClass: .runtimeCapable,
            lifecycleRegistry: lifecycle,
            adapterRegistry: adapters
        ) else { return XCTFail("runtime admission reconsulted the closed adapter") }
        let context = await lease.context
        XCTAssertEqual(context.runtimeID, runtimeID)
        XCTAssertNil(adapters.adapter(for: ticket))
        _ = await lease.release()
    }

    private func makeHandle(
        sessionID: WorkspaceSessionID,
        activationID: UUID,
        currentSnapshot: WorkspaceSessionSnapshot? = nil,
        shutdown: RuntimeShutdownProbe,
        onAdmit: @escaping @Sendable () async -> Void = {}
    ) -> WorkspaceRuntimeSessionHandle {
        WorkspaceRuntimeSessionHandle(
            sessionID: sessionID,
            query: Self.emptyQuery(),
            currentSnapshot: { currentSnapshot },
            admit: {
                await onAdmit()
                return .admitted(Self.admission(sessionID: sessionID, activationID: activationID))
            },
            execute: { _ in .notReady(.active) },
            shutdown: { await shutdown.increment() }
        )
    }

    private nonisolated static func admission(
        sessionID: WorkspaceSessionID,
        activationID: UUID
    ) -> WorkspaceSessionAdmissionToken {
        WorkspaceSessionAdmissionToken(
            sessionID: sessionID,
            activationID: activationID,
            admittedGeneration: 1,
            snapshotSequence: 1
        )
    }

    private func snapshot(sessionID: WorkspaceSessionID) -> WorkspaceSessionSnapshot {
        let tab = ComposeTabState(name: "Runtime")
        let workspace = WorkspaceModel(
            name: "Runtime",
            repoPaths: ["/logical/runtime"],
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        return WorkspaceSessionSnapshot(
            sessionID: sessionID,
            snapshotSequence: 1,
            stateGeneration: 1,
            workspaces: [workspace],
            activeWorkspaceID: workspace.id,
            selectionRevisions: [:],
            dirtyGenerations: [workspace.id: 0],
            savedGenerations: [workspace.id: 0],
            switchState: .idle,
            readiness: WorkspaceSessionReadiness(generation: 1, isReady: true),
            availability: .active
        )
    }

    private nonisolated static func emptyQuery() -> WorkspaceSessionQueryCapability {
        WorkspaceSessionQueryCapability(
            roots: { [] },
            rootScopeAvailability: { _ in .available },
            catalogGeneration: { _ in 0 },
            catalogDiagnostics: { scope in
                WorkspaceCatalogDiagnostics(
                    generation: 0,
                    rootScope: scope,
                    rootCount: 0,
                    folderCount: 0,
                    fileCount: 0
                )
            },
            searchCatalogAccess: { _, _ in
                .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
            },
            lookupPath: { _ in nil }
        )
    }
}

private actor RuntimeShutdownProbe {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor RuntimeAdmissionHook {
    private var operation: (@Sendable () async -> Void)?

    func install(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func run() async {
        await operation?()
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(failure) = self else { return nil }
        return failure
    }
}
