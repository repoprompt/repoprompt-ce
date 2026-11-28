import Foundation
import RepoPromptAgentRuntime
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionAdmissionTests: XCTestCase {
    func testReinstallAndRebindReplaceTheExactIncarnation() throws {
        var index = AgentSessionIncarnationIndex()
        let tab = UUID()
        let otherTab = UUID()
        let originalSession = UUID()
        let replacementSession = UUID()
        index.install(tabID: tab, sessionID: nil)
        let unbound = try XCTUnwrap(index.claim(for: tab)?.incarnationID)

        index.install(tabID: tab, sessionID: originalSession)
        index.install(tabID: otherTab, sessionID: originalSession)
        let firstBinding = try XCTUnwrap(index.claim(for: tab)?.incarnationID)
        XCTAssertNotEqual(unbound, firstBinding)
        XCTAssertEqual(index.tabIDs(for: originalSession), [tab, otherTab])

        index.install(tabID: tab, sessionID: replacementSession)
        XCTAssertNotEqual(index.claim(for: tab)?.incarnationID, firstBinding)
        XCTAssertEqual(index.tabIDs(for: originalSession), [otherTab])
        XCTAssertEqual(index.tabIDs(for: replacementSession), [tab])

        index.remove(tabID: tab)
        XCTAssertNil(index.claim(for: tab))
        XCTAssertTrue(index.tabIDs(for: replacementSession).isEmpty)
        index.install(tabID: tab, sessionID: originalSession)
        XCTAssertNotEqual(index.claim(for: tab)?.incarnationID, firstBinding)
    }

    func testComposerAndManagedSteeringShareProviderDispatchPolicy() {
        func routing(
            _ provider: AgentProviderKind, _ state: AgentSessionRunState,
            continuation: Bool = false, images: Bool = false, approval: Bool = false
        ) -> AgentSessionInputRouting {
            .init(
                provider: provider, state: state, hasContinuation: continuation,
                hasImages: images, hasApproval: approval, acpPromptAvailable: true
            )
        }

        let runningCodex = routing(.codexExec, .running)
        XCTAssertEqual(runningCodex.composer, .codex)
        XCTAssertEqual(runningCodex.managedSteering, .codex)
        let waitingCodex = routing(.codexExec, .waitingForUser, continuation: true)
        XCTAssertEqual(waitingCodex.composer, .waitingInstruction)
        XCTAssertEqual(waitingCodex.managedSteering, .waitingInstruction)

        let runningACP = routing(.cursor, .running)
        XCTAssertEqual(runningACP.composer, .steer(.acpPrompt))
        XCTAssertEqual(runningACP.managedSteering, .acpQueued)
        XCTAssertEqual(routing(.cursor, .running, images: true).composer, .followUp)
        XCTAssertNil(routing(.cursor, .running, approval: true).managedSteering)
        XCTAssertEqual(routing(.claudeCode, .waitingForUser, continuation: true, images: true).composer, .restartClaudeForImages)

        let idleACP = routing(.cursor, .idle)
        XCTAssertEqual(idleACP.composer, .start)
        XCTAssertNil(idleACP.managedSteering)
    }
}
