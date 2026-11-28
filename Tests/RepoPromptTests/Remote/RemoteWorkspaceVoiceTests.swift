import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptCodexProvider
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteWorkspaceVoiceTests: XCTestCase {
    func testVoiceReportsSavedConfigurationWhenSendingFails() async {
        let selection = RemoteAgentSelection(agentID: "codexExec", modelID: "gpt-6-astra")
        var sendAttempts = 0
        do {
            _ = try await WindowRemoteAgentControlService.configureThenSendVoiceInstruction {
                .init(commandID: UUID(), accepted: true, resolvedSelection: selection)
            } send: { configured in
                XCTAssertEqual(configured.agentID, selection.agentID)
                XCTAssertEqual(configured.modelID, selection.modelID)
                sendAttempts += 1
                throw RemoteAgentControlServiceError.commandRejected("Chat became busy")
            }
            XCTFail("The instruction failed to send")
        } catch let RemoteAgentControlServiceError.partialSuccess(message) {
            XCTAssertEqual(message, "The chat configuration was applied, but the instruction could not be sent. Check the chat before retrying.")
        } catch {
            XCTFail("Expected partial success, got \(error)")
        }
        XCTAssertEqual(sendAttempts, 1)
    }

    func testVoiceDoesNotSendOrReportSavedConfigurationWhenConfigurationFails() async {
        do {
            _ = try await WindowRemoteAgentControlService.configureThenSendVoiceInstruction {
                throw RemoteAgentControlServiceError.commandRejected("Model unavailable")
            } send: { _ in
                XCTFail("Sending requires a successful configuration")
                throw RemoteWorkspaceVoiceError.unavailable
            }
            XCTFail("Configuration failed")
        } catch let RemoteAgentControlServiceError.commandRejected(message) {
            XCTAssertEqual(message, "Model unavailable")
        } catch {
            XCTFail("Expected the configuration error, got \(error)")
        }
    }

    func testPickerKeepsOpenWorkspacesAndUsesANewWindowIfWelcomeIsOccupied() {
        let picker = RemoteWorkspacePresentationController.OpenSource.picker
        XCTAssertEqual(picker.destination(welcomeWindowID: nil, voiceWindowID: nil), .newWindow)
        XCTAssertEqual(picker.destination(welcomeWindowID: nil, voiceWindowID: 2), .newWindow)
        XCTAssertEqual(picker.destination(welcomeWindowID: 3, voiceWindowID: 2), .reuseWindow(3))
    }

    func testVoiceOnlyUsesItsOwnOrWelcomeWindow() {
        let voice = RemoteWorkspacePresentationController.OpenSource.voice
        XCTAssertEqual(voice.destination(welcomeWindowID: 3, voiceWindowID: 2), .reuseWindow(2))
        XCTAssertEqual(voice.destination(welcomeWindowID: 3, voiceWindowID: nil), .reuseWindow(3))
        XCTAssertEqual(voice.destination(welcomeWindowID: nil, voiceWindowID: nil), .needsPicker)
    }

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
            dispatch: { request, authorized in
                let id = try XCTUnwrap(request.sessionID)
                XCTAssertEqual(request.operation, .followUp)
                XCTAssertEqual(request.message, "Run the regression test.")
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
            dispatch: { request, authorized in
                XCTAssertNil(request.sessionID)
                XCTAssertEqual(request.operation, .startRun)
                XCTAssertEqual(request.modelID, "gpt-6-astra")
                XCTAssertEqual(request.reasoningEffort, "high")
                XCTAssertTrue(authorized())
                try starts.append(XCTUnwrap(request.message))
                return .init(
                    commandID: UUID(), accepted: true,
                    workspaceID: workspaceID.uuidString, sessionID: newChatID, runState: .working
                )
            }
        )
        var leaseIsValid = true
        let tools = RemoteWorkspaceVoiceChatTools(workspace: access, leaseIsValid: { leaseIsValid })
        let reply = try await tools.execute("start_chat", arguments: [
            "message": .string("  Review my changes.  "), "model_id": .string("gpt-6-astra"), "effort": .string("high")
        ])
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
            dispatch: { _, _ in throw RemoteWorkspaceVoiceError.unavailable }
        )
        func request(
            _ action: RemoteWorkspaceVoiceRequest.Action, id: UUID, peer: String = "paired-phone",
            openWorkspace: @escaping @MainActor () async throws -> RemoteWorkspaceVoiceAccess
        ) throws -> RemoteWorkspaceVoiceStatus {
            try service.handle(.init(
                action: action, callID: id, workspaceID: workspaceID,
                offerSDP: action == .start ? "v=0\r\n" : nil
            ), peerEndpointID: peer, isAuthorized: { true }, openWorkspace: openWorkspace)
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
        ), peerEndpointID: "paired-phone", isAuthorized: { true }) {
            XCTFail("End must not open the workspace.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        let delayed = try service.handle(.init(
            action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0\r\n"
        ), peerEndpointID: "paired-phone", isAuthorized: { true }) {
            XCTFail("A delayed start reopened an ended call.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        XCTAssertEqual(delayed, end)
    }

    func testWorkspaceVoiceReportsOpeningAndSharesOneAsynchronousAttempt() async throws {
        let service = RemoteWorkspaceVoiceService()
        defer { service.invalidate() }
        let callID = UUID()
        let workspaceID = UUID()
        let start = RemoteWorkspaceVoiceRequest(
            action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0\r\n"
        )
        var attempts = 0
        let opening = try service.handle(start, peerEndpointID: "paired-phone", isAuthorized: { true }) {
            attempts += 1
            throw RemoteAgentControlServiceError.commandRejected("The workspace is still being restored.")
        }
        let duplicate = try service.handle(start, peerEndpointID: "paired-phone", isAuthorized: { true }) {
            XCTFail("A repeated start must share the pending opening attempt.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        XCTAssertEqual(opening, duplicate)
        XCTAssertEqual(opening.phase, .connecting)
        XCTAssertEqual(opening.message, "Opening workspace on the Mac…")

        let poll = RemoteWorkspaceVoiceRequest(action: .status, callID: callID, workspaceID: workspaceID)
        var settled = opening
        for _ in 0 ..< 100 {
            await Task.yield()
            settled = try service.handle(poll, peerEndpointID: "paired-phone", isAuthorized: { true }) {
                XCTFail("A status request must not open a workspace.")
                throw RemoteWorkspaceVoiceError.unavailable
            }
            if settled.phase == .failed { break }
        }
        XCTAssertEqual(settled.phase, .failed)
        XCTAssertEqual(settled.message, "The workspace is still being restored.")
        XCTAssertEqual(attempts, 1)
    }

    func testEndingWorkspaceVoiceImmediatelyCancelsOpening() async throws {
        let service = RemoteWorkspaceVoiceService()
        let callID = UUID()
        let workspaceID = UUID()
        let start = RemoteWorkspaceVoiceRequest(
            action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0\r\n"
        )
        func unexpectedOpen() throws -> RemoteWorkspaceVoiceAccess {
            XCTFail("An ended call cannot open a workspace.")
            throw RemoteWorkspaceVoiceError.unavailable
        }
        _ = try service.handle(
            start, peerEndpointID: "paired-phone", isAuthorized: { true }, openWorkspace: unexpectedOpen
        )
        let ended = try service.handle(.init(
            action: .end, callID: callID, workspaceID: workspaceID
        ), peerEndpointID: "paired-phone", isAuthorized: { true }, openWorkspace: unexpectedOpen)
        await Task.yield()
        XCTAssertEqual(ended.phase, .ended)
    }

    func testVoiceConfiguresTheMostRecentWorkspaceChatAndSendsOneCommand() async throws {
        let workspaceID = UUID()
        let chatID = UUID()
        let entry = RemoteHistoryEntry(
            id: chatID, workspaceID: workspaceID.uuidString, sessionName: "Todo", lastActivityAt: Date()
        )
        var requests: [RemoteCommandRequest] = []
        var dispatched: [UUID] = []
        let tools = RemoteWorkspaceVoiceChatTools(
            workspace: .init(
                workspaceID: workspaceID, name: "Garden Notes", isAuthorized: { true }, liveSessions: { [] },
                history: { request in
                    XCTAssertEqual(request.workspaceID, workspaceID)
                    XCTAssertEqual(request.limit, 1)
                    return .init(entries: [entry], workspaceID: workspaceID)
                },
                transcript: { id, _ in .init(sessionID: id, items: []) },
                dispatch: { request, _ in
                    requests.append(request)
                    return .init(
                        commandID: request.commandID, accepted: true, workspaceID: workspaceID.uuidString, sessionID: chatID,
                        resolvedSelection: .init(agentID: "codexExec", modelID: "gpt-6-astra", reasoningEffort: "high")
                    )
                }
            ),
            leaseIsValid: { true },
            didDispatch: { dispatched.append($0) }
        )
        let result = try await tools.execute("send_to_chat", arguments: [
            "chat_id": .string("most_recent"), "model_id": .string("gpt-6-astra"),
            "effort": .string("high"), "message": .string("Build a todo list.")
        ])
        XCTAssertTrue(result.contains("gpt-6-astra"))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, chatID)
        XCTAssertEqual(requests.first?.reasoningEffort, "high")
        XCTAssertEqual(requests.first?.message, "Build a todo list.")
        XCTAssertEqual(dispatched, [chatID])
    }

    func testVoiceToolChangeRequiresDangerAndUsesTheCurrentMacWideRevision() async throws {
        let workspaceID = UUID()
        var hasDanger = false
        var requests: [RemoteCommandRequest] = []
        let search = RemoteToolSettingDescriptor(id: "search", displayName: "Search", category: "tools", isEnabled: true)
        let access = RemoteWorkspaceVoiceAccess(
            workspaceID: workspaceID, name: "Garden Notes", isAuthorized: { true }, liveSessions: { [] },
            history: { _ in .init(entries: [], workspaceID: workspaceID) },
            transcript: { id, _ in .init(sessionID: id, items: []) },
            dispatch: { request, _ in
                requests.append(request)
                return .init(
                    commandID: request.commandID, accepted: true, workspaceID: workspaceID.uuidString,
                    resolvedToolCatalog: .init(
                        providerID: "codexExec", revision: 8,
                        settings: [.init(id: "search", displayName: "Search", category: "tools", isEnabled: false)], isMutable: true
                    )
                )
            },
            catalog: {
                .init(
                    workflows: [], agents: [],
                    metadata: .init(toolCatalog: .init(providerID: "codexExec", revision: 7, settings: [search], isMutable: true))
                )
            },
            canConfigureTools: { hasDanger }
        )
        let tools = RemoteWorkspaceVoiceChatTools(workspace: access, leaseIsValid: { true })
        let arguments: [String: CodexJSONValue] = ["setting_id": .string("search"), "enabled": .bool(false)]
        do {
            _ = try await tools.execute("set_tool", arguments: arguments)
            XCTFail("Control permission cannot change Mac-wide tools.")
        } catch RemoteAgentControlServiceError.commandRejected {
            XCTAssertTrue(requests.isEmpty)
        }
        hasDanger = true
        _ = try await tools.execute("set_tool", arguments: arguments)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.operation, .configureTools)
        XCTAssertNil(requests.first?.sessionID)
        XCTAssertEqual(requests.first?.toolMutation, .init(settingID: "search", enabled: false, expectedRevision: 7))
    }
}
