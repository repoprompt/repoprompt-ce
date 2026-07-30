import Foundation
@testable import RepoPromptApp

/// Small fixture generator for history MCP integration tests.
///
/// The helper writes a real application-support style layout:
/// `Workspaces/Workspace-{name}-{uuid}/AgentSessions/{AgentSession,AgentSessionIndex}.json`.
/// Tests provide compact `SessionSpec` values; the helper serializes full `AgentSession`
/// files and builds the index by calling `AgentSessionMetadataRecord.record(from:)`, so
/// scanner/service tests exercise the same metadata derivation used by the app.
final class HistoryTestFixture {
    struct WorkspaceContext {
        let dir: URL
        let name: String
        let uuid: UUID
    }

    struct SessionSpec {
        let session: AgentSession
        let expectedKeyPaths: Set<String>
        let expectedDurationSeconds: Int
        let expectedToolCallCount: Int
        let expectedFirstActivityAt: Date?
        let expectedLastActivityAt: Date?

        var id: UUID {
            session.id
        }

        var name: String {
            session.name
        }
    }

    struct RawSessionFixture {
        let filename: String
        let expectedKeyPaths: Set<String>
        let expectedDurationSeconds: Int
        let expectedToolCallCount: Int
        let expectedFirstActivityAt: Date?
        let expectedLastActivityAt: Date?
    }

    struct InstalledRawSession {
        let fixture: RawSessionFixture
        let session: AgentSession

        var id: UUID {
            session.id
        }

        var name: String {
            session.name
        }
    }

    let tempDir: URL
    let workspacesRoot: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("HistoryTestFixture-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = tempDir.appendingPathComponent("Workspaces", isDirectory: true)
        try fileManager.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    func makeScanner() -> HistorySessionScanner {
        HistorySessionScanner(fileManager: fileManager, applicationSupportRoot: tempDir)
    }

    func createWorkspace(
        name: String,
        uuid: UUID = UUID(),
        directoryName: String? = nil
    ) throws -> WorkspaceContext {
        let resolvedDirectoryName = directoryName ?? "Workspace-\(name)-\(uuid.uuidString)"
        let wsDir = workspacesRoot.appendingPathComponent(resolvedDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let workspaceJSON: [String: Any] = ["name": name, "id": uuid.uuidString]
        let data = try JSONSerialization.data(withJSONObject: workspaceJSON)
        try data.write(to: wsDir.appendingPathComponent("workspace.json"), options: .atomic)

        return WorkspaceContext(dir: wsDir, name: name, uuid: uuid)
    }

    @discardableResult
    func install(_ specs: [SessionSpec], in workspace: WorkspaceContext) throws -> [SessionSpec] {
        for spec in specs {
            try writeSession(spec.session, in: workspace)
        }
        try buildIndex(in: workspace, specs: specs)
        return specs
    }

    func writeSession(_ session: AgentSession, in workspace: WorkspaceContext) throws {
        let agentSessions = workspace.dir.appendingPathComponent("AgentSessions", isDirectory: true)
        try fileManager.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let fileURL = agentSessions.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    func buildIndex(in workspace: WorkspaceContext, specs: [SessionSpec]) throws {
        try buildIndex(in: workspace, sessions: specs.map(\.session))
    }

    @discardableResult
    func installRawFixtures(_ fixtures: [RawSessionFixture], in workspace: WorkspaceContext) throws -> [InstalledRawSession] {
        let installed = try fixtures.map { fixture in
            let data = try Data(contentsOf: Self.rawFixtureDirectory.appendingPathComponent(fixture.filename))
            let session = try decoder.decode(AgentSession.self, from: data)
            try writeRawSessionData(data, sessionID: session.id, in: workspace)
            return InstalledRawSession(fixture: fixture, session: session)
        }
        try buildIndex(in: workspace, sessions: installed.map(\.session))
        return installed
    }

    private func buildIndex(in workspace: WorkspaceContext, sessions: [AgentSession]) throws {
        let agentSessions = workspace.dir.appendingPathComponent("AgentSessions", isDirectory: true)
        try fileManager.createDirectory(at: agentSessions, withIntermediateDirectories: true)

        let records = sessions.map { session -> AgentSessionMetadataRecord in
            let fileURL = agentSessions.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
            return AgentSessionMetadataRecord.record(
                from: session,
                fileURL: fileURL,
                observedFileSize: nil,
                observedFileModificationDate: nil,
                lastIndexedAt: session.savedAt
            )
        }

        let index = AgentSessionMetadataIndex(
            schemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            entries: records
        )
        let data = try encoder.encode(index)
        try data.write(to: agentSessions.appendingPathComponent("AgentSessionIndex.json"), options: .atomic)
    }

    private func writeRawSessionData(_ data: Data, sessionID: UUID, in workspace: WorkspaceContext) throws {
        let agentSessions = workspace.dir.appendingPathComponent("AgentSessions", isDirectory: true)
        try fileManager.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let fileURL = agentSessions.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Raw persisted-shape fixtures

    static let rawToolExecutionFixture = RawSessionFixture(
        filename: "raw-tool-execution-session.json",
        expectedKeyPaths: ["src/api/register.ts", "src/logging/log.ts"],
        expectedDurationSeconds: 120,
        expectedToolCallCount: 2,
        expectedFirstActivityAt: Date(timeIntervalSince1970: 1_700_050_000),
        expectedLastActivityAt: Date(timeIntervalSince1970: 1_700_050_120)
    )

    static let rawCompactedSummaryFixture = RawSessionFixture(
        filename: "raw-compacted-summary-session.json",
        expectedKeyPaths: ["Sources/History/RawSummary.swift"],
        expectedDurationSeconds: 90,
        expectedToolCallCount: 4,
        expectedFirstActivityAt: Date(timeIntervalSince1970: 1_700_070_000),
        expectedLastActivityAt: Date(timeIntervalSince1970: 1_700_070_090)
    )

    static let rawStartedAtOnlyFixture = RawSessionFixture(
        filename: "raw-started-at-only-session.json",
        expectedKeyPaths: [],
        expectedDurationSeconds: 200,
        expectedToolCallCount: 0,
        expectedFirstActivityAt: Date(timeIntervalSince1970: 1_700_060_000),
        expectedLastActivityAt: Date(timeIntervalSince1970: 1_700_060_200)
    )

    private static var rawFixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    // MARK: - Session specs

    static func toolExecutionSession(
        id: UUID = UUID(),
        name: String,
        files: [String],
        toolCount: Int = 1,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: Int = 60,
        savedAt: Date? = nil,
        agentKind: String = "claudeCodeGLM",
        agentModel: String = "sonnet",
        lastRunState: String? = "completed",
        activityText: String = "Edited files for the requested change"
    ) -> SessionSpec {
        let completedAt = startedAt.addingTimeInterval(TimeInterval(durationSeconds))
        let sessionSavedAt = savedAt ?? completedAt.addingTimeInterval(5)
        let activities: [AgentTranscriptActivity] = (0 ..< toolCount).map { index in
            AgentTranscriptActivity(
                id: UUID(),
                timestamp: startedAt.addingTimeInterval(TimeInterval(index + 1)),
                sequenceIndex: index,
                role: .toolExecution,
                itemKind: .assistant,
                text: activityText,
                toolExecution: AgentTranscriptToolExecution(
                    stableExecutionID: "exec-\(id.uuidString)-\(index)",
                    toolName: index == 0 ? "apply_edits" : "read_file",
                    invocationID: nil,
                    argsJSON: "{\"path\":\"\(files.first ?? "Package.swift")\"}",
                    resultJSON: nil,
                    toolIsError: nil,
                    status: .success,
                    keyPaths: index == 0 ? files : []
                )
            )
        }
        let span = AgentTranscriptProviderResponseSpan(
            lifecycle: .completed,
            startedAt: startedAt,
            completedAt: completedAt,
            activities: activities
        )
        let turn = AgentTranscriptTurn(
            responseSpans: [span],
            startedAt: startedAt,
            completedAt: completedAt
        )
        let session = AgentSession(
            id: id,
            name: name,
            savedAt: sessionSavedAt,
            transcript: AgentTranscript(turns: [turn]),
            itemCount: 1,
            lastUserMessageAt: startedAt,
            agentKind: agentKind,
            agentModel: agentModel,
            lastRunState: lastRunState
        )
        return SessionSpec(
            session: session,
            expectedKeyPaths: Set(files),
            expectedDurationSeconds: durationSeconds,
            expectedToolCallCount: toolCount,
            expectedFirstActivityAt: startedAt,
            expectedLastActivityAt: completedAt
        )
    }

    static func startedAtOnlySession(
        id: UUID = UUID(),
        name: String,
        offsets: [TimeInterval] = [0, 60, 120, 200],
        base: Date = Date(timeIntervalSince1970: 1_700_010_000),
        savedAt: Date? = nil
    ) -> SessionSpec {
        let turns = offsets.map { offset in
            AgentTranscriptTurn(startedAt: base.addingTimeInterval(offset))
        }
        let sessionSavedAt = savedAt ?? base.addingTimeInterval((offsets.last ?? 0) + 5)
        let session = AgentSession(
            id: id,
            name: name,
            savedAt: sessionSavedAt,
            transcript: AgentTranscript(turns: turns),
            itemCount: turns.count,
            lastUserMessageAt: base,
            agentKind: "codexExec",
            agentModel: "gpt-5.5",
            lastRunState: "completed"
        )
        let expectedDuration = offsets.count > 1 ? Int((offsets.last ?? 0) - (offsets.first ?? 0)) : 0
        return SessionSpec(
            session: session,
            expectedKeyPaths: [],
            expectedDurationSeconds: expectedDuration,
            expectedToolCallCount: 0,
            expectedFirstActivityAt: turns.first?.startedAt,
            expectedLastActivityAt: turns.last?.startedAt
        )
    }

    static func compactedSummarySession(
        id: UUID = UUID(),
        name: String,
        files: [String],
        toolCount: Int = 3,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_020_000),
        durationSeconds: Int = 90,
        savedAt: Date? = nil,
        summaryText: String = "Finished database refactor"
    ) -> SessionSpec {
        let completedAt = startedAt.addingTimeInterval(TimeInterval(durationSeconds))
        let summary = AgentTranscriptTurnSummary(
            requestText: "Refactor the database layer",
            conclusionText: nil,
            compactConclusionText: summaryText,
            middleSummaryText: nil,
            toolCount: toolCount,
            notableToolNames: ["apply_edits", "bash"],
            keyPaths: files,
            compactedActivityCount: 5,
            hadWarning: false,
            hadError: false
        )
        let turn = AgentTranscriptTurn(
            retentionTier: .summary,
            summary: summary,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let session = AgentSession(
            id: id,
            name: name,
            savedAt: savedAt ?? completedAt.addingTimeInterval(5),
            transcript: AgentTranscript(turns: [turn]),
            itemCount: 1,
            lastUserMessageAt: startedAt,
            agentKind: "claudeCodeGLM",
            agentModel: "opus",
            lastRunState: "completed"
        )
        return SessionSpec(
            session: session,
            expectedKeyPaths: Set(files),
            expectedDurationSeconds: durationSeconds,
            expectedToolCallCount: toolCount,
            expectedFirstActivityAt: startedAt,
            expectedLastActivityAt: completedAt
        )
    }

    static func failedSession(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_030_000),
        durationSeconds: Int = 30
    ) -> SessionSpec {
        toolExecutionSession(
            id: id,
            name: name,
            files: [],
            toolCount: 0,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            agentKind: "claudeCodeGLM",
            agentModel: "sonnet",
            lastRunState: "failed",
            activityText: "Provider failed"
        )
    }

    static func textSearchSession(
        id: UUID = UUID(),
        name: String,
        activityText: String,
        summaryText: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_040_000)
    ) -> SessionSpec {
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: startedAt.addingTimeInterval(5),
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: activityText
        )
        let span = AgentTranscriptProviderResponseSpan(
            lifecycle: .completed,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(20),
            activities: [activity]
        )
        let summary = summaryText.map {
            AgentTranscriptTurnSummary(
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: $0,
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            )
        }
        let turn = AgentTranscriptTurn(
            responseSpans: [span],
            summary: summary,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(20)
        )
        let session = AgentSession(
            id: id,
            name: name,
            savedAt: startedAt.addingTimeInterval(25),
            transcript: AgentTranscript(turns: [turn]),
            itemCount: 1,
            lastUserMessageAt: startedAt,
            agentKind: "claudeCodeGLM",
            agentModel: "sonnet",
            lastRunState: "completed"
        )
        return SessionSpec(
            session: session,
            expectedKeyPaths: [],
            expectedDurationSeconds: 20,
            expectedToolCallCount: 0,
            expectedFirstActivityAt: startedAt,
            expectedLastActivityAt: startedAt.addingTimeInterval(20)
        )
    }
}
