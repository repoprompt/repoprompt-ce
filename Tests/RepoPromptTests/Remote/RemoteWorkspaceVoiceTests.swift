import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteWorkspaceVoiceTests: XCTestCase {
    func testVoiceReadsAndMessagesRunningAndSavedChatsInItsOwnWorkspace() async throws {
        let workspaceID = UUID()
        let otherWorkspace = UUID()
        let runningID = UUID()
        let savedID = UUID()
        let foreignID = UUID()
        let now = Date()
        let saved = RemoteHistoryEntry(
            id: savedID, workspaceID: workspaceID.uuidString, sessionName: "Share sheet", lastActivityAt: now
        )
        let foreign = RemoteHistoryEntry(
            id: foreignID, workspaceID: otherWorkspace.uuidString, sessionName: "Other workspace", lastActivityAt: now
        )
        var reads: [UUID] = []
        var messages: [UUID] = []
        let access = RemoteWorkspaceVoiceAccess(
            workspaceID: workspaceID,
            name: "Garden Notes",
            isAuthorized: { true },
            liveSessions: {
                [
                    .init(sessionID: runningID, workspaceID: workspaceID.uuidString, sessionName: "Note search", runState: .working, isLive: true),
                    .init(sessionID: foreignID, workspaceID: otherWorkspace.uuidString, sessionName: "Other workspace", runState: .working, isLive: true)
                ]
            },
            history: { request in
                XCTAssertEqual(request.workspaceID, workspaceID)
                // Include a foreign entry to verify that the tool enforces the scope
                // even if the lower layer returns an incorrect history projection.
                return .init(entries: [saved, foreign], workspaceID: workspaceID)
            },
            transcript: { id, _ in
                reads.append(id)
                return .init(sessionID: id, items: [])
            },
            message: { id, text, authorized in
                XCTAssertEqual(text, "Run the regression test.")
                XCTAssertTrue(authorized())
                messages.append(id)
                return .init(commandID: UUID(), accepted: true, workspaceID: workspaceID.uuidString, sessionID: id)
            }
        )
        let tools = RemoteWorkspaceVoiceChatTools(workspace: access, leaseIsValid: { true })
        let listing = try await tools.execute("list_chats", arguments: [:])
        XCTAssertTrue(listing.contains("Note search"))
        XCTAssertTrue(listing.contains("Share sheet"))
        XCTAssertFalse(listing.contains("Other workspace"))

        for id in [runningID, savedID] {
            _ = try await tools.execute("read_chat", arguments: ["chat_id": .string(id.uuidString)])
            _ = try await tools.execute("send_to_chat", arguments: [
                "chat_id": .string(id.uuidString), "message": .string("Run the regression test.")
            ])
        }
        for tool in ["read_chat", "send_to_chat"] {
            do {
                _ = try await tools.execute(tool, arguments: [
                    "chat_id": .string(foreignID.uuidString), "message": .string("Run the regression test.")
                ])
                XCTFail("A voice tool accepted a chat from a different workspace.")
            } catch RemoteWorkspaceVoiceError.unknownChat {
                // Expected.
            }
        }
        XCTAssertEqual(reads, [runningID, savedID])
        XCTAssertEqual(messages, [runningID, savedID])
    }

    func testDelayedStartForEndedCallNeverOpensCodex() throws {
        let service = RemoteWorkspaceVoiceService()
        let callID = UUID()
        let workspaceID = UUID()
        let end = try service.handle(.init(action: .end, callID: callID, workspaceID: workspaceID)) {
            XCTFail("End must not open the workspace.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        let delayed = try service.handle(.init(
            action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0\r\n"
        )) {
            XCTFail("A delayed start reopened an ended call.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        XCTAssertEqual(delayed, end)
    }
}
