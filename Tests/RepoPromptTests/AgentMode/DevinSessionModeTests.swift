import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class DevinSessionModeTests: XCTestCase {
    func testAdvertisedModesApplyBeforeNewAndLoadedPrompts() async throws {
        for resume in [nil, "fixture-session"] as [String?] {
            let directory = try makeTestDirectory(name: "DevinModes")
            let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
            let initial = request(directory, resume: resume)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: initial)
            do {
                _ = try await controller.bootstrap()
                let value = await controller.currentSessionModeSnapshot()
                let snapshot = try XCTUnwrap(value)
                XCTAssertEqual(snapshot.configID, "permission-profile")
                XCTAssertEqual(snapshot.currentValue, "ask")
                XCTAssertEqual(snapshot.options.map(\.rawValue), ["ask", "code", "novel-mode", "bypass", "unconfirmed"])
                XCTAssertEqual(snapshot.options[2].displayName, "Mode novel-mode")
                XCTAssertEqual(snapshot.options[2].description, "Description novel-mode")
                // An untouched default sends no configuration RPC.
                try await ACPIntegratedAgentModeRunner.applyRequestedSessionModeIfNeeded(initial, controller: controller)
                XCTAssertFalse(try provider.records().contains { $0["method"] as? String == "session/set_config_option" })
                let explicit = request(directory, resume: resume, mode: "novel-mode")
                try await ACPIntegratedAgentModeRunner.applyRequestedSessionModeIfNeeded(explicit, controller: controller)
                try await controller.prompt(AgentMessage(userMessage: "initial"), request: explicit)
                let reusable = await controller.prepareForNextTurn()
                XCTAssertTrue(reusable)
                let followup = request(directory, resume: "fixture-session", mode: "code")
                try await ACPIntegratedAgentModeRunner.applyRequestedSessionModeIfNeeded(followup, controller: controller)
                try await controller.prompt(AgentMessage(userMessage: "follow-up"), request: followup)
                await controller.shutdown()
                let records = try provider.records()
                XCTAssertEqual(records.filter { $0["method"] as? String == "session/prompt" }.compactMap { $0["mode"] as? String }, ["novel-mode", "code"])
                XCTAssertEqual(records.filter { $0["method"] as? String == "session/set_config_option" }.compactMap { $0["configId"] as? String }, ["permission-profile", "permission-profile"])
                XCTAssertEqual(records.count(where: { $0["method"] as? String == (resume == nil ? "session/new" : "session/load") }), 1)
            } catch {
                await controller.shutdown()
                throw error
            }
        }
    }

    func testMissingAcknowledgementInvalidatesAuthorityAndBlocksPrompt() async throws {
        let directory = try makeTestDirectory(name: "DevinUnconfirmedMode")
        let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request(directory))
        do {
            _ = try await controller.bootstrap()
            let explicit = request(directory, mode: "unconfirmed")
            do {
                try await ACPIntegratedAgentModeRunner.applyRequestedSessionModeIfNeeded(explicit, controller: controller)
                XCTFail("Expected missing acknowledgement failure")
            } catch {}
            let snapshot = await controller.currentSessionModeSnapshot()
            XCTAssertNil(snapshot)
            do {
                try await controller.prompt(AgentMessage(userMessage: "must not send"), request: explicit)
                XCTFail("Unconfirmed selection must block the prompt")
            } catch {}
            XCTAssertFalse(try provider.records().contains { $0["method"] as? String == "session/prompt" })
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    func testManagedBypassIsBlockedButDirectNativeDefaultIsNotChanged() async throws {
        for restricted in [true, false] {
            let directory = try makeTestDirectory(name: "DevinModePolicy")
            try "bypass".write(to: directory.appendingPathComponent("initial-mode.txt"), atomically: true, encoding: .utf8)
            let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
            let run = request(directory, restricted: restricted)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: run)
            do {
                _ = try await controller.bootstrap()
                do {
                    try await controller.prompt(AgentMessage(userMessage: "fixture"), request: run)
                    XCTAssertFalse(restricted)
                } catch {
                    XCTAssertTrue(restricted, "\(error)")
                }
                let records = try provider.records()
                XCTAssertEqual(records.contains { $0["method"] as? String == "session/prompt" }, !restricted)
                XCTAssertFalse(records.contains { $0["method"] as? String == "session/set_config_option" })
                XCTAssertFalse(run.autoApproveAllToolPermissions)
                await controller.shutdown()
            } catch {
                await controller.shutdown()
                throw error
            }
        }
    }

    func testIdleModeUpdatesSurvivePromptStreamReplacement() async throws {
        let directory = try makeTestDirectory(name: "DevinIdleModes")
        let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request(directory))
        do {
            _ = try await controller.bootstrap()
            var updates = await controller.sessionModeUpdates().makeAsyncIterator()
            let initial = await updates.next()
            XCTAssertEqual(initial??.currentValue, "ask")
            let prepared = await controller.prepareForNextTurn()
            XCTAssertTrue(prepared)
            try "novel-mode".write(to: directory.appendingPathComponent("push-mode.txt"), atomically: true, encoding: .utf8)
            try await controller.setSessionModel("model-b")
            let pushed = await updates.next()
            XCTAssertEqual(pushed??.currentValue, "novel-mode")
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    func testRebindingInvalidatesOldControllerModeProjection() async throws {
        let directory = try makeTestDirectory(name: "DevinReboundModes")
        let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request(directory))
        let session = AgentTabSession(tabID: UUID())
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.acpController = controller
        let received = expectation(description: "Initial mode observed")
        session.observeACPSessionModes(from: controller) {
            if session.acpSessionModeSnapshot != nil { received.fulfill() }
        }
        do {
            _ = try await controller.bootstrap()
            await fulfillment(of: [received], timeout: 3)
            XCTAssertEqual(session.acpSessionModeSnapshot?.currentValue, "ask")
            session.acpSessionModeIntent = "novel-mode"
            session.testInstallPersistentSessionBinding(sessionID: UUID())
            XCTAssertNil(session.acpModeObservationTask)
            XCTAssertNil(session.acpSessionModeSnapshot)
            XCTAssertNil(session.acpSessionModeIntent)
            try "novel-mode".write(to: directory.appendingPathComponent("push-mode.txt"), atomically: true, encoding: .utf8)
            try await controller.setSessionModel("model-b")
            await controller.shutdown()
            XCTAssertNil(session.acpSessionModeSnapshot)
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    func testChromeShowsActualAndRequestedModesWithInheritedLocks() {
        let snapshot = ACPSessionModeSnapshot(configID: "arbitrary", currentValue: "ask", options: [
            .init(rawValue: "ask", displayName: "Ask", description: "Questions"),
            .init(rawValue: "novel", displayName: "Novel", description: "Provider description"),
            .init(rawValue: "bypass", displayName: "Bypass", description: "Provider approvals")
        ])
        for lock in [nil, "Inherited policy"] as [String?] {
            let chrome = AgentProviderPreferenceSnapshotStore.devinModeBinding(snapshot: snapshot, intent: "novel", lockReason: lock)
            XCTAssertEqual(chrome.displayName, "Ask")
            XCTAssertEqual(chrome.externallyManagedReason, lock)
            XCTAssertEqual(chrome.options.map(\.id), [.devinMode("ask"), .devinMode("novel"), .devinMode("bypass")])
            XCTAssertTrue(chrome.options[0].isSelected)
            XCTAssertFalse(chrome.options[1].isSelected)
            XCTAssertTrue(chrome.options[1].title.contains("requested"))
            XCTAssertTrue(chrome.options[2].isWarning)
            XCTAssertEqual(chrome.options.allSatisfy(\.isEnabled), lock == nil)
        }
    }

    private func request(_ directory: URL, resume: String? = nil, mode: String? = nil, restricted: Bool = false) -> ACPRunRequest {
        ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: directory.path, resumeSessionID: resume, attachments: [], taskLabelKind: nil, sessionModeID: mode, requiresNonBypassSessionMode: restricted)
    }
}
