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

    func testPairSaveReplacesBothMembers() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Save")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        var primary = pairSession(.primary, pairID: pairID, workspace: fixture.workspace, name: "Original Primary")
        var secondary = pairSession(.secondary, pairID: pairID, workspace: fixture.workspace, name: "Original Secondary")
        let urls = try await service.saveOraclePairSessions([primary, secondary], for: fixture.workspace)

        primary.name = "Updated Primary"
        secondary.name = "Updated Secondary"
        _ = try await service.saveOraclePairSessions([primary, secondary], for: fixture.workspace)

        let updatedPrimary = try await service.loadChatSession(from: XCTUnwrap(urls[primary.id]))
        let updatedSecondary = try await service.loadChatSession(from: XCTUnwrap(urls[secondary.id]))
        XCTAssertEqual(updatedPrimary.name, "Updated Primary")
        XCTAssertEqual(updatedSecondary.name, "Updated Secondary")
    }

    func testOracleGroupSaveAcceptsEverySupportedSizeInLaneOrder() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Oracle Group Sizes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()

        for groupSize in 2 ... 5 {
            let groupID = UUID()
            let lanes = try OracleLane.orderedPrefix(count: groupSize)
            var members = lanes.map { lane in
                pairSession(
                    lane,
                    pairID: groupID,
                    groupSize: groupSize,
                    workspace: fixture.workspace,
                    name: "Group \(groupSize) \(lane.rawValue)"
                )
            }
            let urls = try await service.saveOraclePairSessions(members, for: fixture.workspace)
            let stubs = try await service.oraclePairSessionStubs(for: fixture.workspace, pairID: groupID)

            XCTAssertEqual(stubs.compactMap(\.oracleLane), lanes)
            XCTAssertTrue(stubs.allSatisfy { $0.oracleGroupSize == groupSize })
            XCTAssertEqual(urls.count, groupSize)

            if groupSize == 5 {
                for index in members.indices {
                    members[index].name = "Updated \(lanes[index].rawValue)"
                }
                _ = try await service.saveOraclePairSessions(members, for: fixture.workspace)
                for member in members {
                    let loaded = try await service.loadChatSession(from: XCTUnwrap(urls[member.id]))
                    XCTAssertEqual(loaded.name, member.name)
                    XCTAssertEqual(loaded.oracleGroupSize, 5)
                }
            }
        }
    }

    func testOracleGroupSaveRejectsMismatchedMetadataAndNoncontiguousLanes() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Oracle Group Validation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        var mismatchedSize = lanes.map { lane in
            pairSession(
                lane,
                pairID: groupID,
                groupSize: 5,
                workspace: fixture.workspace,
                name: lane.rawValue
            )
        }
        mismatchedSize[mismatchedSize.count - 1].oracleGroupSize = 4

        do {
            _ = try await service.saveOraclePairSessions(mismatchedSize, for: fixture.workspace)
            XCTFail("Expected mismatched group size to fail")
        } catch is ChatDataError {}

        let noncontiguousGroupID = UUID()
        let noncontiguous = [OracleLane.primary, .secondary, .oracle4].map { lane in
            pairSession(
                lane,
                pairID: noncontiguousGroupID,
                groupSize: 3,
                workspace: fixture.workspace,
                name: lane.rawValue
            )
        }
        do {
            _ = try await service.saveOraclePairSessions(noncontiguous, for: fixture.workspace)
            XCTFail("Expected noncontiguous lanes to fail")
        } catch is ChatDataError {}

        let validThreeLaneGroupID = UUID()
        let validThreeLaneGroup = try OracleLane.orderedPrefix(count: 3).map { lane in
            pairSession(
                lane,
                pairID: validThreeLaneGroupID,
                groupSize: 3,
                workspace: fixture.workspace,
                name: lane.rawValue
            )
        }
        var mismatchedGroupID = validThreeLaneGroup
        mismatchedGroupID[2].oraclePairID = UUID()
        do {
            _ = try await service.saveOraclePairSessions(mismatchedGroupID, for: fixture.workspace)
            XCTFail("Expected mismatched group IDs to fail")
        } catch is ChatDataError {}

        var mismatchedWorkspace = validThreeLaneGroup
        mismatchedWorkspace[2].workspaceID = UUID()
        do {
            _ = try await service.saveOraclePairSessions(mismatchedWorkspace, for: fixture.workspace)
            XCTFail("Expected mismatched workspaces to fail")
        } catch is ChatDataError {}
    }

    func testMissingGroupFileCannotMasqueradeAsSmallerGroupAndCleanupDeletesRemainder() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Incomplete Oracle Group")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let members = lanes.map { lane in
            pairSession(
                lane,
                pairID: groupID,
                groupSize: 5,
                workspace: fixture.workspace,
                name: lane.rawValue
            )
        }
        let urls = try await service.saveOraclePairSessions(members, for: fixture.workspace)
        try FileManager.default.removeItem(at: XCTUnwrap(urls[members[4].id]))

        do {
            _ = try await service.oraclePairSessionStubs(for: fixture.workspace, pairID: groupID)
            XCTFail("Expected an incomplete five-member group to fail validation")
        } catch is ChatDataError {}

        let remaining = try await service.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: groupID,
            requireCompleteGroup: false
        )
        XCTAssertEqual(remaining.count, 4)
        XCTAssertTrue(remaining.allSatisfy { $0.oracleGroupSize == 5 })

        try await service.deleteOraclePairSessionFiles([members[0].id], for: fixture.workspace)
        XCTAssertTrue(urls.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testConcurrentPairAndLegacySavesQueueWithoutLosingHistory() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Concurrent Saves")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let pairs = (0 ..< 8).map { index in
            let pairID = UUID()
            return lanes.map {
                pairSession(
                    $0,
                    pairID: pairID,
                    groupSize: lanes.count,
                    workspace: fixture.workspace,
                    name: "Pair \(index) \($0.rawValue)"
                )
            }
        }
        let singles = (0 ..< 8).map {
            ChatSession(workspaceID: fixture.workspace.id, name: "Single \($0)")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    _ = try await service.saveOraclePairSessions(pair, for: fixture.workspace)
                }
            }
            for single in singles {
                group.addTask {
                    _ = try await service.saveChatSession(single, for: fixture.workspace)
                }
            }
            try await group.waitForAll()
        }

        let files = try await service.listChatSessions(for: fixture.workspace, applyRetention: false)
        let expectedIDs = Set(pairs.flatMap(\.self).map(\.id) + singles.map(\.id))
        let savedIDs = Set(files.compactMap { UUID(uuidString: String($0.deletingPathExtension().lastPathComponent.dropFirst("ChatSession-".count))) })
        XCTAssertEqual(savedIDs, expectedIDs)
    }

    func testPairedSessionCannotUseLegacySingleSave() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Single Save Guard")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pair = pairSession(.primary, pairID: UUID(), workspace: fixture.workspace, name: "Primary")

        do {
            _ = try await service.saveChatSession(pair, for: fixture.workspace)
            XCTFail("Expected a paired session to require the pair save path")
        } catch is ChatDataError {}
    }

    func testCurrentPairTransactionRecoversInterruptedAndCommittedInstalls() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        var primary = pairSession(.primary, pairID: pairID, workspace: fixture.workspace, name: "Primary")
        var secondary = pairSession(.secondary, pairID: pairID, workspace: fixture.workspace, name: "Secondary")
        let urls = try await service.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )
        let pairURLs = try [XCTUnwrap(urls[primary.id]), XCTUnwrap(urls[secondary.id])]
        let chatsFolder = pairURLs[0].deletingLastPathComponent()

        let uncommitted = try makeCurrentPairTransaction(files: pairURLs, in: chatsFolder)
        primary.name = "Interrupted Primary"
        try FileManager.default.removeItem(at: pairURLs[0])
        try FileManager.default.removeItem(at: pairURLs[1])
        try JSONEncoder().encode(primary).write(to: pairURLs[0], options: .atomic)

        _ = try await service.listChatSessions(for: fixture.workspace)
        let restoredPrimary = try await service.loadChatSession(from: pairURLs[0])
        let restoredSecondary = try await service.loadChatSession(from: pairURLs[1])
        XCTAssertEqual(restoredPrimary.name, "Primary")
        XCTAssertEqual(restoredSecondary.name, "Secondary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uncommitted.path))

        let committed = try makeCurrentPairTransaction(files: pairURLs, in: chatsFolder)
        primary.name = "Committed Primary"
        secondary.name = "Committed Secondary"
        try JSONEncoder().encode(primary).write(to: pairURLs[0], options: .atomic)
        try JSONEncoder().encode(secondary).write(to: pairURLs[1], options: .atomic)
        try Data().write(to: committed.appendingPathComponent("committed"))

        _ = try await service.listChatSessions(for: fixture.workspace)
        let committedPrimary = try await service.loadChatSession(from: pairURLs[0])
        let committedSecondary = try await service.loadChatSession(from: pairURLs[1])
        XCTAssertEqual(committedPrimary.name, "Committed Primary")
        XCTAssertEqual(committedSecondary.name, "Committed Secondary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
    }

    func testMalformedPairTransactionDebrisIsQuarantinedWithoutBlockingSaves() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Malformed Pair Debris")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let existing = ChatSession(workspaceID: fixture.workspace.id, name: "Existing")
        _ = try await service.saveChatSession(existing, for: fixture.workspace)
        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)

        let stray = chatsFolder.appendingPathComponent(".oracle-pair-save-\(UUID().uuidString) conflicted copy")
        try Data("debris".utf8).write(to: stray)
        let malformed = chatsFolder.appendingPathComponent(".oracle-pair-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: malformed.appendingPathComponent("manifest.json"))

        let newSession = ChatSession(workspaceID: fixture.workspace.id, name: "After debris")
        let newURL = try await service.saveChatSession(newSession, for: fixture.workspace)
        let files = try await service.listChatSessions(for: fixture.workspace, applyRetention: false)
        let folderEntries = try FileManager.default.contentsOfDirectory(atPath: chatsFolder.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertEqual(folderEntries.count(where: { $0.hasPrefix(".oracle-pair-quarantine-") }), 2)
    }

    func testReadOnlyHistoryQueriesDoNotApplyRetention() async throws {
        let previousLimit = UserDefaults.standard.object(forKey: "chatHistoryLimit")
        UserDefaults.standard.set(ChatHistoryLimit.fifty.rawValue, forKey: "chatHistoryLimit")
        defer {
            if let previousLimit {
                UserDefaults.standard.set(previousLimit, forKey: "chatHistoryLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatHistoryLimit")
            }
        }

        let fixture = try makeTemporaryWorkspace(named: "Read Only History")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        var sessions: [ChatSession] = []
        for index in 0 ..< 51 {
            let session = ChatSession(workspaceID: fixture.workspace.id, name: "Session \(index)")
            sessions.append(session)
            _ = try await service.saveChatSession(session, for: fixture.workspace)
        }

        _ = try await service.recentSessions(for: fixture.workspace, limit: 1)
        _ = try await service.findSessionResult(for: fixture.workspace, id: sessions[0].id.uuidString)
        _ = try await service.mostRecentSession(for: fixture.workspace)

        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)
        let fileCount = try FileManager.default.contentsOfDirectory(atPath: chatsFolder.path)
            .count(where: { $0.hasPrefix("ChatSession-") && $0.hasSuffix(".json") })

        XCTAssertEqual(fileCount, 51)
    }

    func testRetentionAndGroupDeletionFailClosedForUnreadableChatFiles() async throws {
        let previousLimit = UserDefaults.standard.object(forKey: "chatHistoryLimit")
        UserDefaults.standard.set(ChatHistoryLimit.fifty.rawValue, forKey: "chatHistoryLimit")
        defer {
            if let previousLimit {
                UserDefaults.standard.set(previousLimit, forKey: "chatHistoryLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatHistoryLimit")
            }
        }

        let fixture = try makeTemporaryWorkspace(named: "Pair Retention")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: false)
        let now = Date()
        let pairID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let pair = lanes.map {
            pairSession($0, pairID: pairID, groupSize: lanes.count, workspace: fixture.workspace, name: $0.rawValue)
        }
        let sessions = pair + (0 ..< 49).map {
            ChatSession(workspaceID: fixture.workspace.id, name: "Single \($0)")
        }
        for (index, session) in sessions.enumerated() {
            let fileURL = chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json")
            try JSONEncoder().encode(session).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(-index))],
                ofItemAtPath: fileURL.path
            )
        }
        let corruptID = UUID()
        let corruptURL = chatsFolder.appendingPathComponent("ChatSession-\(corruptID.uuidString).json")
        try Data("not json".utf8).write(to: corruptURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10000)],
            ofItemAtPath: corruptURL.path
        )

        let service = ChatDataService()
        let retained = try await service.listChatSessions(for: fixture.workspace)
        XCTAssertEqual(retained.count, sessions.count + 1)
        XCTAssertTrue(pair.allSatisfy { session in
            retained.contains { $0.lastPathComponent == "ChatSession-\(session.id.uuidString).json" }
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))

        do {
            try await service.deleteOraclePairSessionFiles([pair[0].id], for: fixture.workspace)
            XCTFail("Expected grouped deletion to fail closed while a chat file is unreadable")
        } catch is ChatDataError {}
        XCTAssertTrue(pair.allSatisfy { session in
            FileManager.default.fileExists(
                atPath: chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json").path
            )
        })

        try Data("still corrupt".utf8).write(to: corruptURL)
        let protected = try await service.listChatSessions(
            for: fixture.workspace,
            protectedSessionIDs: [corruptID]
        )
        XCTAssertTrue(protected.contains { $0.lastPathComponent == corruptURL.lastPathComponent })
    }

    func testRetentionDoesNotKeepOlderUnprotectedSingleAfterNewerPairOverflows() async throws {
        let previousLimit = UserDefaults.standard.object(forKey: "chatHistoryLimit")
        UserDefaults.standard.set(ChatHistoryLimit.fifty.rawValue, forKey: "chatHistoryLimit")
        defer {
            if let previousLimit {
                UserDefaults.standard.set(previousLimit, forKey: "chatHistoryLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatHistoryLimit")
            }
        }

        let fixture = try makeTemporaryWorkspace(named: "Pair Retention Ordering")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: false)
        let now = Date()
        let newerSingles = (0 ..< 49).map {
            ChatSession(workspaceID: fixture.workspace.id, name: "Newer \($0)")
        }
        let pairID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let pair = lanes.map {
            pairSession($0, pairID: pairID, groupSize: lanes.count, workspace: fixture.workspace, name: $0.rawValue)
        }
        let olderSingle = ChatSession(workspaceID: fixture.workspace.id, name: "Older unprotected")
        let protectedOldest = ChatSession(workspaceID: fixture.workspace.id, name: "Oldest protected")
        let orderedSessions = newerSingles + pair + [olderSingle, protectedOldest]
        for (index, session) in orderedSessions.enumerated() {
            let url = chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json")
            try JSONEncoder().encode(session).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(-index * 10))],
                ofItemAtPath: url.path
            )
        }

        let service = ChatDataService()
        let retained = try await service.listChatSessions(
            for: fixture.workspace,
            protectedSessionIDs: [protectedOldest.id]
        )
        let retainedNames = Set(retained.map(\.lastPathComponent))

        XCTAssertEqual(retained.count, 50)
        XCTAssertTrue(retainedNames.contains("ChatSession-\(protectedOldest.id.uuidString).json"))
        XCTAssertFalse(retainedNames.contains("ChatSession-\(olderSingle.id.uuidString).json"))
        XCTAssertTrue(pair.allSatisfy { session in
            !FileManager.default.fileExists(
                atPath: chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json").path
            )
        })
    }

    func testProtectingOnePairMemberRetainsBothMembers() async throws {
        let previousLimit = UserDefaults.standard.object(forKey: "chatHistoryLimit")
        UserDefaults.standard.set(ChatHistoryLimit.fifty.rawValue, forKey: "chatHistoryLimit")
        defer {
            if let previousLimit {
                UserDefaults.standard.set(previousLimit, forKey: "chatHistoryLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatHistoryLimit")
            }
        }

        let fixture = try makeTemporaryWorkspace(named: "Protected Pair Retention")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let pair = lanes.map {
            pairSession($0, pairID: pairID, groupSize: lanes.count, workspace: fixture.workspace, name: $0.rawValue)
        }
        let urls = try await service.saveOraclePairSessions(pair, for: fixture.workspace)
        for url in urls.values {
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        }
        for index in 0 ..< 49 {
            _ = try await service.saveChatSession(
                ChatSession(workspaceID: fixture.workspace.id, name: "Single \(index)"),
                for: fixture.workspace
            )
        }

        let retained = try await service.listChatSessions(
            for: fixture.workspace,
            protectedSessionIDs: [pair[0].id]
        )

        XCTAssertEqual(retained.count, 54)
        let retainedNames = Set(retained.map(\.lastPathComponent))
        XCTAssertTrue(pair.allSatisfy { session in
            guard let url = urls[session.id] else { return false }
            return retainedNames.contains(url.lastPathComponent)
        })
    }

    func testRetentionIgnoresNonRegularPathsAndDeletedIDCanBeSavedAgain() async throws {
        let previousLimit = UserDefaults.standard.object(forKey: "chatHistoryLimit")
        UserDefaults.standard.set(ChatHistoryLimit.fifty.rawValue, forKey: "chatHistoryLimit")
        defer {
            if let previousLimit {
                UserDefaults.standard.set(previousLimit, forKey: "chatHistoryLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatHistoryLimit")
            }
        }

        let fixture = try makeTemporaryWorkspace(named: "Retention Best Effort")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: false)
        let now = Date()
        for index in 0 ..< 50 {
            let session = ChatSession(workspaceID: fixture.workspace.id, name: "Kept \(index)")
            let url = chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json")
            try JSONEncoder().encode(session).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(-index))],
                ofItemAtPath: url.path
            )
        }

        let failed = ChatSession(workspaceID: fixture.workspace.id, name: "Failed retention delete")
        let failedURL = chatsFolder.appendingPathComponent("ChatSession-\(failed.id.uuidString).json")
        try FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1000)],
            ofItemAtPath: failedURL.path
        )

        let deleted = ChatSession(workspaceID: fixture.workspace.id, name: "Successful retention delete")
        let deletedURL = chatsFolder.appendingPathComponent("ChatSession-\(deleted.id.uuidString).json")
        try JSONEncoder().encode(deleted).write(to: deletedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2000)],
            ofItemAtPath: deletedURL.path
        )

        let service = ChatDataService()
        let retained = try await service.listChatSessions(for: fixture.workspace)
        XCTAssertEqual(retained.count, 50)
        XCTAssertFalse(retained.contains { $0.lastPathComponent == failedURL.lastPathComponent })
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path))

        try FileManager.default.removeItem(at: failedURL)
        let savedURL = try await service.saveChatSession(failed, for: fixture.workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
    }

    func testDeletedLegacySessionIDCanBeSavedAgain() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Legacy Resave")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let session = ChatSession(workspaceID: fixture.workspace.id, name: "Legacy")
        let firstURL = try await service.saveChatSession(session, for: fixture.workspace)
        try await service.deleteChatSessionFile(firstURL)

        let secondURL = try await service.saveChatSession(session, for: fixture.workspace)
        XCTAssertEqual(secondURL, firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testUnmergedLegacyJournalIsIgnored() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Legacy Journal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        _ = try await service.saveChatSession(
            ChatSession(workspaceID: fixture.workspace.id, name: "Existing"),
            for: fixture.workspace
        )
        let chatsFolder = fixture.root.appendingPathComponent("Chats", isDirectory: true)
        let transaction = chatsFolder.appendingPathComponent(".chat-transaction-future", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["version": 2, "entries": []])
            .write(to: transaction.appendingPathComponent("manifest.json"))

        let saved = try await service.saveChatSession(
            ChatSession(workspaceID: fixture.workspace.id, name: "After legacy journal"),
            for: fixture.workspace
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testPairDeletionUsesCanonicalWorkspaceFiles() async throws {
        let fixture = try makeTemporaryWorkspace(named: "Pair Delete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ChatDataService()
        let pairID = UUID()
        let primary = pairSession(.primary, pairID: pairID, workspace: fixture.workspace, name: "Primary")
        let secondary = pairSession(.secondary, pairID: pairID, workspace: fixture.workspace, name: "Secondary")
        let urls = try await service.saveOraclePairSessions([primary, secondary], for: fixture.workspace)
        let primaryURL = try XCTUnwrap(urls[primary.id])
        let secondaryURL = try XCTUnwrap(urls[secondary.id])

        try await service.deleteOraclePairSessionFiles([primary.id, secondary.id], for: fixture.workspace)

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondaryURL.path))
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

    private func pairSession(
        _ lane: OracleLane,
        pairID: UUID,
        groupSize: Int = 2,
        workspace: WorkspaceModel,
        name: String
    ) -> ChatSession {
        ChatSession(
            workspaceID: workspace.id,
            oraclePairID: pairID,
            oracleLane: lane,
            oracleGroupSize: groupSize,
            name: name
        )
    }

    private func makeCurrentPairTransaction(files: [URL], in chatsFolder: URL) throws -> URL {
        let transaction = chatsFolder.appendingPathComponent(".oracle-pair-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        for fileURL in files {
            try Data(contentsOf: fileURL).write(
                to: transaction.appendingPathComponent("original-\(fileURL.lastPathComponent)")
            )
        }
        let entries = try files.map { fileURL -> [String: Any] in
            let rawID = fileURL.deletingPathExtension().lastPathComponent.dropFirst("ChatSession-".count)
            return try [
                "sessionID": XCTUnwrap(UUID(uuidString: String(rawID))).uuidString,
                "originallyExisted": true
            ]
        }
        try JSONSerialization.data(withJSONObject: ["entries": entries])
            .write(to: transaction.appendingPathComponent("manifest.json"))
        return transaction
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
