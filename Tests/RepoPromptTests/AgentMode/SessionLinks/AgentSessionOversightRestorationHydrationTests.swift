import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionOversightRestorationHydrationTests: XCTestCase {
    func testQueuedRequestCannotHydrateUnderSuccessorDiscoveryOwner() async throws {
        let fixture = try await makeFixture()
        let gate = TestReleaseFence(name: "queued restoration hydration")
        defer { gate.release() }
        let finished = expectation(description: "old owner task exits")
        fixture.vm.test_beforeRestorationHydrationAdmission = { await gate.enterAndWait() }
        fixture.vm.test_restorationHydrationTaskDidFinish = { finished.fulfill() }
        fixture.vm.agentSessionLinkRequestRestorationHydration(sessionIDs: [fixture.sessionID])
        guard await gate.waitUntilEntered() else { return }
        let successor = fixture.vm.beginAgentSessionLinkDiscoveryEpoch(workspaceID: fixture.manager.activeWorkspaceID)
        fixture.vm.completeAgentSessionLinkDiscoveryEpoch(successor)
        gate.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(fixture.vm.sessions[fixture.tabID], "Obsolete queued work must not create runtime state")
        fixture.vm.test_beforeRestorationHydrationAdmission = nil
        let loaded = expectation(description: "successor passive load finishes")
        fixture.vm.test_restorationHydrationTaskDidFinish = { loaded.fulfill() }
        fixture.vm.agentSessionLinkRequestRestorationHydration(sessionIDs: [fixture.sessionID])
        await fulfillment(of: [loaded], timeout: 5)
        let session = try XCTUnwrap(fixture.vm.sessions[fixture.tabID])
        XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertEqual(session.activeAgentSessionID, fixture.sessionID)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
    }

    func testRepeatedLoadsJoinAndDiscardedLoadCannotPublishSuccessorBindings() async throws {
        for discard in [false, true] {
            let fixture = try await makeFixture()
            let gate = TestReleaseFence(name: "persisted restoration read")
            defer { gate.release() }
            let preparations = LifecycleRecorder()
            await AgentSessionDataService.shared.test_setBeforeLoadRepairWriteHook { url in
                guard url == fixture.fileURL.standardizedFileURL else { return }
                preparations.record("prepare")
                await gate.enterAndWait()
            }
            let finished = expectation(description: "passive load completes, discard=\(discard)")
            let queuedRequests = discard ? 1 : 5
            finished.expectedFulfillmentCount = queuedRequests
            fixture.vm.test_restorationHydrationTaskDidFinish = { finished.fulfill() }
            // Queue before yielding: wrappers that pass the fast path must join the loader task.
            for _ in 0 ..< queuedRequests {
                fixture.vm.agentSessionLinkRequestRestorationHydration(sessionIDs: [fixture.sessionID])
            }
            guard await gate.waitUntilEntered() else { return }
            let original = try XCTUnwrap(fixture.vm.sessions[fixture.tabID])
            XCTAssertNotNil(original.persistedLoadTask)
            for _ in 0 ..< 5 {
                fixture.vm.agentSessionLinkRequestRestorationHydration(sessionIDs: [fixture.sessionID])
            }
            if discard {
                let replacement = AgentModeViewModel.TabSession(tabID: fixture.tabID)
                fixture.vm.test_replaceSessionForDeferredHydration(tabID: fixture.tabID, with: replacement)
                _ = fixture.vm.test_installPersistentSessionBinding(
                    sessionID: fixture.sessionID, on: replacement, updateWorkspaceMetadata: false
                )
            }
            gate.release()
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(preparations.events, ["prepare"], "Queued wrappers must share one gated preparation")
            let current = try XCTUnwrap(fixture.vm.sessions[fixture.tabID])
            if discard {
                XCTAssertFalse(current === original)
                XCTAssertFalse(current.hasLoadedPersistedState)
                XCTAssertFalse(current.qualifiedRestorationReadiness.isAuthoritative)
                XCTAssertFalse(original.qualifiedRestorationReadiness.isAuthoritative)
            } else {
                XCTAssertTrue(current === original)
                XCTAssertTrue(current.qualifiedRestorationReadiness.isAuthoritative)
                XCTAssertEqual(current.activeAgentSessionID, fixture.sessionID)
            }
            XCTAssertTrue(fixture.providerRequests.events.isEmpty)
            await AgentSessionDataService.shared.test_setBeforeLoadRepairWriteHook(nil)
        }
    }

    private struct Fixture {
        let vm: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let tabID: UUID
        let sessionID: UUID
        let fileURL: URL
        let providerRequests: LifecycleRecorder
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RestorationHydration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let requests = LifecycleRecorder()
        let vm = AgentModeViewModel(
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                requests.record("codex")
                return LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in
                requests.record("claude")
                return MonitorFakeNativeController()
            },
            headlessProviderFactory: { _, _ in
                requests.record("headless")
                return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            },
            acpProviderFactory: { _, _ in
                requests.record("acp-provider")
                throw CocoaError(.featureUnsupported)
            },
            acpControllerFactory: { _, _ in
                requests.record("acp-controller")
                throw CocoaError(.featureUnsupported)
            },
            mcpServerEnabler: { false }
        )
        addTeardownBlock {
            await AgentSessionDataService.shared.test_setBeforeLoadRepairWriteHook(nil)
            await vm.prepareForWindowClose()
            XCTAssertTrue(requests.events.isEmpty, "Hydration must never request a provider")
        }
        let tabID = UUID(), sessionID = UUID()
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "Hydration")
        await manager.awaitInitialized()
        var workspace = try XCTUnwrap(manager.activeWorkspace)
        workspace.customStoragePath = root
        workspace.composeTabs[0].activeAgentSessionID = sessionID
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        var persisted = AgentSession(id: sessionID, workspaceID: workspace.id, name: "Cold endpoint", autoEditEnabled: false)
        let fileURL = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: workspace)
        // Existing load-repair seam gates a real temporary-file preparation, with no new loader hook.
        persisted.serializationVersion = AgentSession.currentSerializationVersion - 1
        try JSONEncoder().encode(persisted).write(to: fileURL, options: .atomic)
        vm.completeAgentSessionLinkDiscoveryEpoch(vm.beginAgentSessionLinkDiscoveryEpoch(workspaceID: workspace.id))
        return Fixture(vm: vm, manager: manager, tabID: tabID, sessionID: sessionID, fileURL: fileURL, providerRequests: requests)
    }
}
