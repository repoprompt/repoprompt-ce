import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionDataServiceDeletionTests: XCTestCase {
    func testBatchDeleteIgnoresTraversalAndAbsoluteMetadataIndexFilenames() async throws {
        let cases: [(String, (URL) -> String)] = [
            ("traversal", { _ in "../external-sentinel.json" }),
            ("absolute", { storageURL in
                storageURL.appendingPathComponent("external-sentinel.json").path
            })
        ]

        for (label, filenameForStorageURL) in cases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
            let sentinelURL = fixture.storageURL.appendingPathComponent("external-sentinel.json")
            try Data("sentinel-\(label)".utf8).write(to: sentinelURL, options: .atomic)
            try writeMetadataIndex(filename: filenameForStorageURL(fixture.storageURL), fixture: fixture)

            let failures = await fixture.service.deleteAgentSessions(
                forComposeTabIDs: [fixture.tabID],
                for: fixture.workspace
            )

            XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path), label)
        }
    }

    func testBatchDeleteIgnoresNestedAndMalformedMetadataIndexFilenames() async throws {
        let cases: [(String, String, String)] = [
            ("nested", "nested/nested-sentinel.json", "nested/nested-sentinel.json"),
            ("malformed", "AgentSession-not-a-uuid.json", "AgentSession-not-a-uuid.json")
        ]

        for (label, indexFilename, targetRelativePath) in cases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
            let targetURL = fixture.agentSessionsFolder.appendingPathComponent(targetRelativePath)
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("sentinel-\(label)".utf8).write(to: targetURL, options: .atomic)
            try writeMetadataIndex(filename: indexFilename, fixture: fixture)

            let failures = await fixture.service.deleteAgentSessions(
                forComposeTabIDs: [fixture.tabID],
                for: fixture.workspace
            )

            XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), label)
        }
    }

    func testBatchDeleteRejectsMismatchedFilenameAndDecodedSessionID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let otherSessionID = UUID()
        let mismatchedFilename = agentSessionFilename(for: otherSessionID)
        let mismatchedURL = fixture.agentSessionsFolder.appendingPathComponent(mismatchedFilename)
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Mismatched session identity",
                itemCount: 0
            ),
            to: mismatchedURL
        )
        try writeMetadataIndex(filename: mismatchedFilename, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatchedURL.path))
    }

    func testBatchDeleteRejectsMismatchedComposeTabID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let otherTabID = UUID()
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: otherTabID,
                name: "Mismatched tab identity",
                itemCount: 0
            ),
            to: sessionURL
        )
        try writeMetadataIndex(filename: sessionURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testBatchDeleteRejectsSymlinkedSessionFileAndPreservesExternalSentinel() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sentinelURL = fixture.storageURL.appendingPathComponent("symlink-sentinel.json")
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Symlink sentinel",
                itemCount: 0
            ),
            to: sentinelURL
        )
        let symlinkURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sentinelURL)
        try writeMetadataIndex(filename: symlinkURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    func testBatchDeleteRemovesValidIndexedSessionFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageURL) }
        let sessionURL = fixture.agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: fixture.sessionID))
        try writeSession(
            AgentSession(
                id: fixture.sessionID,
                workspaceID: fixture.workspace.id,
                composeTabID: fixture.tabID,
                name: "Valid session",
                itemCount: 0
            ),
            to: sessionURL
        )
        try writeMetadataIndex(filename: sessionURL.lastPathComponent, fixture: fixture)

        let failures = await fixture.service.deleteAgentSessions(
            forComposeTabIDs: [fixture.tabID],
            for: fixture.workspace
        )

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    private struct BatchDeleteFixture {
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let storageURL: URL
        let agentSessionsFolder: URL
        let sessionID: UUID
        let tabID: UUID
    }

    private func makeFixture() throws -> BatchDeleteFixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionDataServiceDeletionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentSessionsFolder = storageURL.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(
            name: "Agent Session Deletion",
            repoPaths: ["/tmp/repo"],
            customStoragePath: storageURL
        )
        return BatchDeleteFixture(
            service: AgentSessionDataService(),
            workspace: workspace,
            storageURL: storageURL,
            agentSessionsFolder: agentSessionsFolder,
            sessionID: UUID(),
            tabID: UUID()
        )
    }

    private func writeMetadataIndex(filename: String, fixture: BatchDeleteFixture) throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 1)
        let record = AgentSessionMetadataRecord(
            id: fixture.sessionID,
            filename: filename,
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Indexed session",
            savedAt: timestamp,
            lastUserMessageAt: nil,
            itemCount: 0,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: timestamp
        )
        let index = AgentSessionMetadataIndex(entries: [record])
        let indexURL = fixture.agentSessionsFolder.appendingPathComponent("AgentSessionIndex.json")
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func writeSession(_ session: AgentSession, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
    }

    private func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }
}
