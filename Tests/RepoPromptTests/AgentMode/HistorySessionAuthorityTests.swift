import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// History reads must stay inside the saved Workspaces root (no symlinked components below
/// it) and must only return a session whose embedded ID matches the requested ID (#864).
final class HistorySessionAuthorityTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HistorySessionAuthorityTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? fileManager.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testNormalWorkspaceBehindSymlinkedStorageRootIsScannedLocatedAndLoaded() async throws {
        let realAppSupport = tempRoot.appendingPathComponent("real-app-support", isDirectory: true)
        let linkedAppSupport = tempRoot.appendingPathComponent("linked-app-support", isDirectory: true)
        let workspaceDir = realAppSupport
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("Workspace-Normal", isDirectory: true)
        let sessionID = UUID()
        try seedWorkspaceContents(at: workspaceDir, sessions: [(sessionID, "Normal session")])
        try fileManager.createSymbolicLink(at: linkedAppSupport, withDestinationURL: realAppSupport)
        let scanner = makeScanner(applicationSupportRoot: linkedAppSupport)

        let scan = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(scan.flatMap(\.records).map(\.id), [sessionID])
        XCTAssertEqual(scan.map(\.indexReadFailed), [false])

        let lookup = try await scanner.locateSession(sessionID: sessionID)
        let location = try XCTUnwrap(lookup.location)
        let loaded = try await scanner.loadSessionForHistory(sessionID: sessionID, workspaceDir: location.workspaceDir)
        XCTAssertEqual(loaded.name, "Normal session")

        let reply = try await HistoryMCPToolService.execute(
            args: ["op": .string("get_session"), "session_id": .string(sessionID.uuidString)],
            scanner: scanner
        )
        guard case .getSession = reply else {
            return XCTFail("Expected get_session reply, got \(reply)")
        }
    }

    func testSymlinkedWorkspaceDirectoryCannotEscapeHistoryRoot() async throws {
        let appSupport = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        let workspacesRoot = appSupport.appendingPathComponent("Workspaces", isDirectory: true)
        try fileManager.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let outsideWorkspace = tempRoot.appendingPathComponent("outside-workspace", isDirectory: true)
        let sessionID = UUID()
        try seedWorkspaceContents(at: outsideWorkspace, sessions: [(sessionID, "Outside session")])
        let linkedWorkspace = workspacesRoot.appendingPathComponent("Workspace-Linked", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedWorkspace, withDestinationURL: outsideWorkspace)
        let scanner = makeScanner(applicationSupportRoot: appSupport)

        let scan = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(scan.flatMap(\.records).isEmpty)
        let lookup = try await scanner.locateSession(sessionID: sessionID)
        XCTAssertNil(lookup.location)
        try await assertAuthorityViolation(scanner, sessionID: sessionID, workspaceDir: linkedWorkspace)
        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 0)
    }

    func testSymlinkedAgentSessionsDirectoryCannotEscapeHistoryRoot() async throws {
        let appSupport = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        let workspaceDir = appSupport
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("Workspace-Real", isDirectory: true)
        try fileManager.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let outsideWorkspace = tempRoot.appendingPathComponent("outside-workspace", isDirectory: true)
        let sessionID = UUID()
        try seedWorkspaceContents(at: outsideWorkspace, sessions: [(sessionID, "Outside session")])
        try fileManager.createSymbolicLink(
            at: workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true),
            withDestinationURL: outsideWorkspace.appendingPathComponent("AgentSessions", isDirectory: true)
        )
        let scanner = makeScanner(applicationSupportRoot: appSupport)

        let scan = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(scan.flatMap(\.records).isEmpty)
        XCTAssertEqual(scan.map(\.indexReadFailed), [true])
        let lookup = try await scanner.locateSession(sessionID: sessionID)
        XCTAssertNil(lookup.location)
        try await assertAuthorityViolation(scanner, sessionID: sessionID, workspaceDir: workspaceDir)
        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 0)
    }

    func testSymlinkedSessionFileIsRejectedForLookupLoadListAndSearch() async throws {
        let appSupport = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        let workspaceDir = appSupport
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("Workspace-Real", isDirectory: true)
        let sessionID = UUID()
        try seedWorkspaceContents(at: workspaceDir, sessions: [(sessionID, "Indexed name")])
        let sessionFile = sessionFileURL(sessionID, in: workspaceDir)
        try fileManager.removeItem(at: sessionFile)
        let outsideFile = tempRoot.appendingPathComponent("outside-session.json")
        try writeSession(id: sessionID, name: "Outside session", to: outsideFile)
        try fileManager.createSymbolicLink(at: sessionFile, withDestinationURL: outsideFile)
        let scanner = makeScanner(applicationSupportRoot: appSupport)

        let lookup = try await scanner.locateSession(sessionID: sessionID)
        XCTAssertNil(lookup.location)
        try await assertAuthorityViolation(scanner, sessionID: sessionID, workspaceDir: workspaceDir)
        try await assertListAndSearchReportNonRetryableReadFailure(scanner, rejectedSessionID: sessionID)
        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 0)
    }

    func testSessionCopiedUnderAnotherIDIsRejectedEverywhereAndNeverCached() async throws {
        let appSupport = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        let workspaceDir = appSupport
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("Workspace-Real", isDirectory: true)
        let realID = UUID()
        let copiedID = UUID()
        try seedWorkspaceContents(at: workspaceDir, sessions: [(realID, "Real session"), (copiedID, "Indexed copy")])
        // Overwrite the copied ID's file with the real session's JSON.
        try writeSession(id: realID, name: "Impostor", to: sessionFileURL(copiedID, in: workspaceDir))
        let scanner = makeScanner(applicationSupportRoot: appSupport)

        try await assertAuthorityViolation(scanner, sessionID: copiedID, workspaceDir: workspaceDir)
        try await assertAuthorityViolation(scanner, sessionID: copiedID, workspaceDir: workspaceDir)
        var decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 2, "A mismatched decode must never be served from the transcript cache")

        let realLoaded = try await scanner.loadSessionForHistory(sessionID: realID, workspaceDir: workspaceDir)
        XCTAssertEqual(realLoaded.name, "Real session")

        let getReply = try await HistoryMCPToolService.execute(
            args: ["op": .string("get_session"), "session_id": .string(copiedID.uuidString)],
            scanner: scanner
        )
        guard case let .error(error) = getReply else {
            return XCTFail("Expected an authority error for get_session, got \(getReply)")
        }
        XCTAssertEqual(error.retryable, false)
        XCTAssertTrue(error.error.contains("failed history authority checks"), error.error)
        XCTAssertFalse(error.error.contains("Impostor"))

        try await assertListAndSearchReportNonRetryableReadFailure(scanner, rejectedSessionID: copiedID)
        decodeCount = await scanner.transcriptDecodeCountForTesting
        let decodesAfter = decodeCount
        try await assertAuthorityViolation(scanner, sessionID: copiedID, workspaceDir: workspaceDir)
        decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, decodesAfter + 1)
    }

    // MARK: - Helpers

    private func makeScanner(applicationSupportRoot: URL) -> HistorySessionScanner {
        HistorySessionScanner(applicationSupportRoot: applicationSupportRoot, scanCacheTTL: 0)
    }

    private func assertAuthorityViolation(
        _ scanner: HistorySessionScanner,
        sessionID: UUID,
        workspaceDir: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await scanner.loadSessionForHistory(sessionID: sessionID, workspaceDir: workspaceDir)
            XCTFail("Expected an authority violation", file: file, line: line)
        } catch let error as HistorySessionScannerError {
            guard case let .sessionAuthorityViolation(rejectedID, _) = error else {
                return XCTFail("Expected sessionAuthorityViolation, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(rejectedID, sessionID, file: file, line: line)
        }
    }

    private func assertListAndSearchReportNonRetryableReadFailure(
        _ scanner: HistorySessionScanner,
        rejectedSessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        func hasNonRetryableReadFailure(_ diagnostics: [HistoryScanDiagnostic]?) -> Bool {
            (diagnostics ?? []).contains { $0.kind == .transcriptReadFailure && !$0.retryable }
        }

        let listReply = try await HistoryMCPToolService.execute(args: ["op": .string("list_sessions")], scanner: scanner)
        guard case let .listSessions(list) = listReply else {
            return XCTFail("Expected list_sessions reply, got \(listReply)", file: file, line: line)
        }
        XCTAssertTrue(hasNonRetryableReadFailure(list.scanDiagnostics), file: file, line: line)
        let listed = list.sessions.first { $0.sessionID == rejectedSessionID.uuidString }
        XCTAssertNotEqual(listed?.sessionName, "Impostor", file: file, line: line)
        XCTAssertNotEqual(listed?.sessionName, "Outside session", file: file, line: line)

        let searchReply = try await HistoryMCPToolService.execute(
            args: ["op": .string("search"), "query": .string("session")],
            scanner: scanner
        )
        guard case let .search(search) = searchReply else {
            return XCTFail("Expected search reply, got \(searchReply)", file: file, line: line)
        }
        XCTAssertTrue(hasNonRetryableReadFailure(search.scanDiagnostics), file: file, line: line)
        XCTAssertFalse(
            search.results.contains { $0.sessionID == rejectedSessionID.uuidString },
            file: file,
            line: line
        )
    }

    private func sessionFileURL(_ sessionID: UUID, in workspaceDir: URL) -> URL {
        workspaceDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
    }

    private func seedWorkspaceContents(at workspaceDir: URL, sessions: [(id: UUID, name: String)]) throws {
        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try fileManager.createDirectory(at: agentSessionsDir, withIntermediateDirectories: true)
        for session in sessions {
            try writeSession(id: session.id, name: session.name, to: sessionFileURL(session.id, in: workspaceDir))
        }
        let index = AgentSessionMetadataIndex(entries: sessions.map { makeStubRecord(id: $0.id, name: $0.name) })
        try JSONEncoder().encode(index)
            .write(to: agentSessionsDir.appendingPathComponent("AgentSessionIndex.json"))
    }

    private func writeSession(id: UUID, name: String, to url: URL) throws {
        try JSONEncoder().encode(AgentSession(id: id, name: name)).write(to: url)
    }

    private func makeStubRecord(id: UUID, name: String) -> AgentSessionMetadataRecord {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: name,
            savedAt: date,
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
            isMCPOriginated: true,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: date,
            lastIndexedAt: date
        )
    }
}
