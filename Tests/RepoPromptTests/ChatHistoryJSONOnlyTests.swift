@testable import RepoPromptApp
import XCTest

final class ChatHistoryJSONOnlyTests: XCTestCase {
    func testCurrentChatSessionSaveLoadUsesCEWorkspaceRoot() async throws {
        let message = StoredMessage(
            isUser: false,
            rawText: "assistant reply",
            sequenceIndex: 0
        )
        let workspace = WorkspaceModel(name: "Chat JSON Only", repoPaths: ["/tmp/root"])
        let session = ChatSession(name: "Current Session", messages: [message])
        let service = ChatDataService()

        let fileURL = try await service.saveChatSession(session, for: workspace)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }

        XCTAssertTrue(fileURL.path.contains("/Application Support/RepoPrompt CE/Workspaces/"), fileURL.path)
        XCTAssertFalse(fileURL.path.contains("/Application Support/RepoPrompt/Workspaces/"), fileURL.path)

        let loaded = try await service.loadChatSession(from: fileURL)
        XCTAssertEqual(loaded.name, "Current Session")
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.messages[0].rawText, "assistant reply")
    }

    func testStoredMessageOmitsLegacyDelegateAndCombinedTextFields() throws {
        let original = StoredMessage(
            isUser: false,
            rawText: "base",
            sequenceIndex: 2
        )

        let encoded = try JSONEncoder().encode(original)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: encoded)
        XCTAssertEqual(decoded.rawText, "base")
    }

    func testLegacyDelegateResultPayloadIsIgnoredInsteadOfFlattened() throws {
        let delegateID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(messageID.uuidString)",
          "isUser": false,
          "rawText": "base",
          "combinedRawText": "stale combined should not persist",
          "timestamp": 0,
          "sequenceIndex": 0,
          "delegateResults": [
            { "id": "\(delegateID.uuidString)", "text": "legacy delegate" }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.rawText, "base")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("legacy delegate"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
    }

    func testLogicalRetentionNeverSplitsOraclePairs() {
        let pairID = UUID()
        let pairDate = Date()
        let singleDate = pairDate.addingTimeInterval(-1)
        let primary = ChatSessionFileRecord(
            fileURL: URL(fileURLWithPath: "/tmp/primary.json"),
            sessionID: UUID(),
            oraclePairID: pairID,
            oracleLane: .primary,
            modificationDate: pairDate
        )
        let secondary = ChatSessionFileRecord(
            fileURL: URL(fileURLWithPath: "/tmp/secondary.json"),
            sessionID: UUID(),
            oraclePairID: pairID,
            oracleLane: .secondary,
            modificationDate: pairDate
        )
        let single = ChatSessionFileRecord(
            fileURL: URL(fileURLWithPath: "/tmp/single.json"),
            sessionID: UUID(),
            oraclePairID: nil,
            oracleLane: nil,
            modificationDate: singleDate
        )

        let groups = ChatDataService.logicalHistoryGroups(from: [single, secondary, primary])
        let twoSlots = ChatDataService.retentionPartition(groups: groups, limit: 2)
        XCTAssertEqual(twoSlots.kept.count, 1)
        XCTAssertEqual(twoSlots.kept.first?.records.map(\.oracleLane), [.primary, .secondary])
        XCTAssertEqual(twoSlots.dropped.flatMap(\.records).map(\.sessionID), [single.sessionID])

        let oneSlot = ChatDataService.retentionPartition(groups: groups, limit: 1)
        XCTAssertTrue(oneSlot.kept.isEmpty)
        XCTAssertEqual(Set(oneSlot.dropped.flatMap(\.records).map(\.sessionID)), Set([
            primary.sessionID,
            secondary.sessionID,
            single.sessionID
        ]))
    }

    func testPairSaveAndDeleteOperateAsLogicalTransactions() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Transaction")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        let primary = ChatSession(
            workspaceID: fixture.workspace.id,
            oraclePairID: pairID,
            oracleLane: .primary,
            name: "Primary"
        )
        let secondary = ChatSession(
            workspaceID: fixture.workspace.id,
            oraclePairID: pairID,
            oracleLane: .secondary,
            name: "Secondary"
        )

        let urls = try await service.saveChatSessions([primary, secondary], for: fixture.workspace)
        let primaryURL = try XCTUnwrap(urls[primary.id])
        let secondaryURL = try XCTUnwrap(urls[secondary.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondaryURL.path))
        let stubs = try await service.oraclePairSessionStubs(for: fixture.workspace, pairID: pairID)
        XCTAssertEqual(Set(stubs.map(\.id)), Set([primary.id, secondary.id]))

        try await service.deleteChatSessionFiles(
            [primaryURL, secondaryURL],
            sessionIDs: Set([primary.id, secondary.id])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondaryURL.path))
    }

    func testPairSaveRollsBackEarlierMemberAndCanRetry() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Save Rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        var primary = ChatSession(
            workspaceID: fixture.workspace.id,
            oraclePairID: pairID,
            oracleLane: .primary,
            name: "Original Primary"
        )
        let secondary = ChatSession(
            workspaceID: fixture.workspace.id,
            oraclePairID: pairID,
            oracleLane: .secondary,
            name: "Secondary"
        )
        let primaryURL = try await service.saveChatSession(primary, for: fixture.workspace)
        let chatsFolder = primaryURL.deletingLastPathComponent()
        let blockedSecondaryURL = chatsFolder.appendingPathComponent("ChatSession-\(secondary.id.uuidString).json")
        try FileManager.default.createDirectory(at: blockedSecondaryURL, withIntermediateDirectories: false)
        primary.name = "Updated Primary"

        do {
            _ = try await service.saveChatSessions([primary, secondary], for: fixture.workspace)
            XCTFail("Expected the second pair member write to fail")
        } catch {
            let restored = try await service.loadChatSession(from: primaryURL)
            XCTAssertEqual(restored.name, "Original Primary")
        }

        try FileManager.default.removeItem(at: blockedSecondaryURL)
        let retryURLs = try await service.saveChatSessions([primary, secondary], for: fixture.workspace)
        let retriedPrimary = try await service.loadChatSession(from: XCTUnwrap(retryURLs[primary.id]))
        let retriedSecondary = try await service.loadChatSession(from: XCTUnwrap(retryURLs[secondary.id]))
        XCTAssertEqual(retriedPrimary.name, "Updated Primary")
        XCTAssertEqual(retriedSecondary.name, "Secondary")
    }

    func testLogicalDeleteRollsBackStagedMembersAndAllowsRetry() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Delete Rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let session = ChatSession(workspaceID: fixture.workspace.id, name: "Keep Me")
        let fileURL = try await service.saveChatSession(session, for: fixture.workspace)
        let missingURL = fileURL.deletingLastPathComponent().appendingPathComponent("ChatSession-\(UUID().uuidString).json")

        do {
            try await service.deleteChatSessionFiles([fileURL, missingURL], sessionIDs: [session.id])
            XCTFail("Expected logical deletion to roll back")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }

        _ = try await service.saveChatSession(session, for: fixture.workspace)
        try await service.deleteChatSessionFiles([fileURL], sessionIDs: [session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLegacyChatSessionEditPayloadsAreIgnoredOnDecodeAndOmittedOnEncode() throws {
        let sessionID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(sessionID.uuidString)",
          "name": "Legacy Edit Session",
          "savedAt": 0,
          "messages": [
            {
              "id": "\(messageID.uuidString)",
              "isUser": false,
              "rawText": "assistant text",
              "timestamp": 0,
              "sequenceIndex": 0
            }
          ],
          "changedFilesByMessage": {
            "\(messageID.uuidString)": []
          },
          "delegateEditItemsByMessage": {
            "\(messageID.uuidString)": []
          }
        }
        """

        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.messages.first?.rawText, "assistant text")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("changedFilesByMessage"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateEditItemsByMessage"), encodedString)
    }

    private func makeTemporaryWorkspace(named name: String) throws -> (root: URL, workspace: WorkspaceModel) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryJSONOnlyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            WorkspaceModel(
                name: name,
                repoPaths: [root.path],
                customStoragePath: root
            )
        )
    }
}
