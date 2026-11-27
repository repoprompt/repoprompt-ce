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
            dispatch: { id, text, authorized in
                let id = try XCTUnwrap(id)
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

    func testVoiceStartsACodexChatWithTheCallersFirstInstruction() async throws {
        let workspaceID = UUID()
        let newChatID = UUID()
        var starts: [String] = []
        let access = RemoteWorkspaceVoiceAccess(
            workspaceID: workspaceID,
            name: "Garden Notes",
            isAuthorized: { true },
            liveSessions: { [] },
            history: { _ in
                XCTFail("Starting a chat should not search existing chats.")
                return .init(entries: [], workspaceID: workspaceID)
            },
            transcript: { id, _ in .init(sessionID: id, items: []) },
            dispatch: { id, text, authorized in
                XCTAssertNil(id)
                XCTAssertTrue(authorized())
                starts.append(text)
                return .init(
                    commandID: UUID(), accepted: true,
                    workspaceID: workspaceID.uuidString, sessionID: newChatID, runState: .working
                )
            }
        )
        var leaseIsValid = true
        let tools = RemoteWorkspaceVoiceChatTools(workspace: access, leaseIsValid: { leaseIsValid })
        let reply = try await tools.execute("start_chat", arguments: ["message": .string("  Review my changes.  ")])
        XCTAssertTrue(reply.contains(newChatID.uuidString))
        do {
            _ = try await tools.execute("start_chat", arguments: [:])
            XCTFail("A new chat needs a first instruction.")
        } catch RemoteWorkspaceVoiceError.invalidToolArguments {
            // Expected.
        }
        leaseIsValid = false
        do {
            _ = try await tools.execute("start_chat", arguments: ["message": .string("Review my changes.")])
            XCTFail("A closed voice call cannot start a chat.")
        } catch RemoteWorkspaceVoiceError.unavailable {
            // Expected.
        }
        XCTAssertEqual(starts, ["Review my changes."])
    }

    func testNewCallFromPairedPhoneReplacesItsPreviousCall() throws {
        let service = RemoteWorkspaceVoiceService()
        defer { service.invalidate() }
        let workspaceID = UUID()
        let oldID = UUID()
        let newID = UUID()
        let access = RemoteWorkspaceVoiceAccess(
            workspaceID: workspaceID, name: "Garden Notes", isAuthorized: { true },
            liveSessions: { [] },
            history: { _ in .init(entries: [], workspaceID: workspaceID) },
            transcript: { id, _ in .init(sessionID: id, items: []) },
            dispatch: { _, _, _ in throw RemoteWorkspaceVoiceError.unavailable }
        )
        func request(
            _ action: RemoteWorkspaceVoiceRequest.Action, id: UUID, peer: String = "paired-phone",
            openWorkspace: () throws -> RemoteWorkspaceVoiceAccess
        ) throws -> RemoteWorkspaceVoiceStatus {
            try service.handle(.init(
                action: action, callID: id, workspaceID: workspaceID,
                offerSDP: action == .start ? "v=0\r\n" : nil
            ), peerEndpointID: peer, openWorkspace: openWorkspace)
        }
        func unexpectedWorkspaceOpen() throws -> RemoteWorkspaceVoiceAccess {
            XCTFail("This request must not open a workspace.")
            throw RemoteWorkspaceVoiceError.unavailable
        }

        XCTAssertEqual(try request(.start, id: oldID) { access }.phase, .connecting)
        XCTAssertThrowsError(try request(.start, id: newID, peer: "other-phone", openWorkspace: unexpectedWorkspaceOpen))
        XCTAssertEqual(try request(.start, id: newID) { access }.phase, .connecting)
        XCTAssertEqual(try request(.start, id: newID, openWorkspace: unexpectedWorkspaceOpen).phase, .connecting)

        for action: RemoteWorkspaceVoiceRequest.Action in [.status, .start, .end] {
            XCTAssertEqual(try request(action, id: oldID, openWorkspace: unexpectedWorkspaceOpen).phase, .ended)
        }
        XCTAssertEqual(try request(.status, id: newID, openWorkspace: unexpectedWorkspaceOpen).phase, .connecting)
    }

    func testDelayedStartForEndedCallNeverOpensCodex() throws {
        let service = RemoteWorkspaceVoiceService()
        let callID = UUID()
        let workspaceID = UUID()
        let end = try service.handle(.init(
            action: .end, callID: callID, workspaceID: workspaceID
        ), peerEndpointID: "paired-phone") {
            XCTFail("End must not open the workspace.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        let delayed = try service.handle(.init(
            action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0\r\n"
        ), peerEndpointID: "paired-phone") {
            XCTFail("A delayed start reopened an ended call.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        XCTAssertEqual(delayed, end)
    }
}
