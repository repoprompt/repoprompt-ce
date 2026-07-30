import Foundation
import SwiftUI

/// Error definitions analogous to ChatSessionError:
enum ChatDataError: Error {
    case invalidFilename(String)
    case decodingFailed(Error)
    case loadFailed(Error)
    case saveFailed(Error)
}

/// Lightweight metadata for chat session listing
struct ChatSessionMeta {
    let id: UUID
    let shortID: String
    let composeTabID: UUID?
    let name: String
    let lastModified: Date
    let selectedFilePaths: [String]
    let messageCount: Int
}

/// Failure information for a chat session stub load in a batch.
struct ChatSessionStubLoadFailure {
    let index: Int
    let fileURL: URL
    let message: String
}

/// Ordered result for bounded concurrent chat session stub loading.
struct ChatSessionStubLoadBatchResult {
    let sessions: [ChatSession]
    let failures: [ChatSessionStubLoadFailure]
    let requestedCount: Int

    var loadedCount: Int {
        sessions.count
    }

    var failedCount: Int {
        failures.count
    }
}

enum ChatSessionLookupResult {
    case notFound
    case unique(ChatSession)
    case ambiguous
}

enum ChatLogicalHistoryKey: Hashable {
    case session(UUID)
    case oraclePair(UUID)
}

struct ChatSessionFileRecord {
    let fileURL: URL
    let sessionID: UUID
    let oraclePairID: UUID?
    let oracleLane: OracleLane?
    let modificationDate: Date
}

struct ChatLogicalHistoryGroup {
    let key: ChatLogicalHistoryKey
    let records: [ChatSessionFileRecord]

    var newestModificationDate: Date {
        records.map(\.modificationDate).max() ?? .distantPast
    }

    var weight: Int {
        records.count
    }
}

/// Chat history limit options
public enum ChatHistoryLimit: Int, CaseIterable {
    case fifty = 50
    case twoHundred = 200
    case unlimited = -1

    public var displayName: String {
        switch self {
        case .fifty:
            "50 sessions"
        case .twoHundred:
            "200 sessions"
        case .unlimited:
            "No limit"
        }
    }

    public static func from(rawValue: Int) -> ChatHistoryLimit {
        ChatHistoryLimit(rawValue: rawValue) ?? .unlimited
    }
}

/// An actor that reads/writes ChatSessions from each workspace's "Chats" folder.
/// (Refactored to remove Task.detached usage but keep method signatures & behavior identical.)
actor ChatDataService {
    init() {}

    private static let fileSaveQueue = DispatchQueue(label: "com.repoprompt.chatDataServiceFileSaveQueue")
    private var deletedSessionIDs: Set<UUID> = []

    // MARK: - Lightweight decode helpers

    private struct ChatSessionHeader: Decodable {
        struct StoredMessageHeader: Decodable {
            let id: UUID
        }

        let id: UUID
        let workspaceID: UUID?
        let composeTabID: UUID?
        let agentModeSessionID: UUID?
        let agentModeRunID: UUID?
        let oraclePairID: UUID?
        let oracleLane: OracleLane?
        let oracleHistoryDiverged: Bool?
        let name: String
        let savedAt: Date
        let shortID: String?
        let selectedFilePaths: [String]?
        let selectedPromptIDs: [UUID]?
        let preferredAIModel: String?
        let selectedChatPresetID: UUID?
        let messageCount: Int?
        let messages: [StoredMessageHeader]?
    }

    /// Read the chat history limit setting
    private var chatHistoryLimit: ChatHistoryLimit {
        let rawValue = UserDefaults.standard.integer(forKey: "chatHistoryLimit")
        // Default to 50 sessions if no setting exists
        return rawValue == 0 ? .fifty : ChatHistoryLimit.from(rawValue: rawValue)
    }

    // MARK: - Public API

    /// Save a ChatSession for a given workspace, returning the file URL on success.
    /// Performs file I/O inline (still off the main thread due to actor isolation).
    func saveChatSession(
        _ session: ChatSession,
        for workspace: WorkspaceModel
    ) async throws -> URL {
        guard !deletedSessionIDs.contains(session.id) else {
            throw ChatDataError.saveFailed(NSError(
                domain: "ChatDataService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The chat session was deleted."]
            ))
        }
        // 1) Get "Chats" folder
        let chatsFolder = try ensureChatsFolder(for: workspace)

        // 2) Build file URL
        let filename = "ChatSession-\(session.id.uuidString).json"
        let fileURL = chatsFolder.appendingPathComponent(filename)

        // 3) Update session with file path & timestamp and capture it as a constant copy
        var sessionToSave = session
        sessionToSave.fileURL = fileURL
        sessionToSave.savedAt = Date()
        let sessionCopy = sessionToSave // constant copy to capture in the closure

        // Keep the actor non-reentrant for the complete filesystem operation, and
        // share the same critical section with nonisolated batch readers.
        return try Self.fileSaveQueue.sync {
            let data = try JSONEncoder().encode(sessionCopy)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    /// Saves a logical chat group as one in-process transaction. Each JSON replacement
    /// is atomic; if any member fails, every earlier member is restored before returning.
    func saveChatSessions(
        _ sessions: [ChatSession],
        for workspace: WorkspaceModel
    ) async throws -> [UUID: URL] {
        guard !sessions.isEmpty else { return [:] }
        guard sessions.allSatisfy({ !deletedSessionIDs.contains($0.id) }) else {
            throw ChatDataError.saveFailed(NSError(
                domain: "ChatDataService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A chat session in the logical group was deleted."]
            ))
        }
        let chatsFolder = try ensureChatsFolder(for: workspace)
        let savedAt = Date()
        let prepared = sessions.map { session -> (ChatSession, URL) in
            var copy = session
            let fileURL = chatsFolder.appendingPathComponent("ChatSession-\(session.id.uuidString).json")
            copy.fileURL = fileURL
            copy.savedAt = savedAt
            return (copy, fileURL)
        }

        return try Self.fileSaveQueue.sync {
            var originals: [URL: Data] = [:]
            var originallyMissing: Set<URL> = []
            var written: [URL] = []
            do {
                let encoder = JSONEncoder()
                for (session, fileURL) in prepared {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        originals[fileURL] = try Data(contentsOf: fileURL)
                    } else {
                        originallyMissing.insert(fileURL)
                    }
                    try encoder.encode(session).write(to: fileURL, options: .atomic)
                    written.append(fileURL)
                }
                return Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.id, $0.1) })
            } catch {
                var rollbackError: Error?
                for fileURL in written.reversed() {
                    do {
                        if let original = originals[fileURL] {
                            try original.write(to: fileURL, options: .atomic)
                        } else if originallyMissing.contains(fileURL) {
                            try FileManager.default.removeItem(at: fileURL)
                        }
                    } catch {
                        rollbackError = rollbackError ?? error
                    }
                }
                if let rollbackError {
                    throw ChatDataError.saveFailed(NSError(
                        domain: "ChatDataService",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Logical chat save and rollback failed.",
                            NSUnderlyingErrorKey: rollbackError
                        ]
                    ))
                }
                throw error
            }
        }
    }

    /// Load a current ChatSession from disk.
    func loadChatSession(
        from fileURL: URL
    ) async throws -> ChatSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "ChatSession-"), filename.hasSuffix(".json") else {
            throw ChatDataError.invalidFilename(filename)
        }

        do {
            return try Self.fileSaveQueue.sync {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                var session = try JSONDecoder().decode(ChatSession.self, from: data)
                session.fileURL = fileURL
                return session
            }
        } catch {
            throw ChatDataError.loadFailed(error)
        }
    }

    private enum ChatSessionStubLoadOutcome {
        case success(index: Int, session: ChatSession)
        case failure(index: Int, fileURL: URL, message: String)
    }

    private struct ChatSessionStubSnapshot {
        let data: Data?
        let readFailure: String?
    }

    /// Load a lightweight `ChatSession` suitable for session lists without decoding full message text.
    func loadChatSessionStub(from fileURL: URL) async throws -> ChatSession {
        try Self.loadChatSessionStubFromDisk(from: fileURL)
    }

    /// Load multiple lightweight `ChatSession` stubs with bounded concurrency, preserving input order.
    nonisolated func loadChatSessionStubs(
        from files: [URL],
        maxConcurrent: Int
    ) async -> ChatSessionStubLoadBatchResult {
        guard !files.isEmpty else {
            return ChatSessionStubLoadBatchResult(sessions: [], failures: [], requestedCount: 0)
        }

        let snapshots = Self.fileSaveQueue.sync {
            files.map { fileURL in
                do {
                    return try ChatSessionStubSnapshot(
                        data: Data(contentsOf: fileURL, options: .mappedIfSafe),
                        readFailure: nil
                    )
                } catch {
                    return ChatSessionStubSnapshot(data: nil, readFailure: String(describing: error))
                }
            }
        }
        let effectiveLimit = min(max(1, maxConcurrent), files.count)
        var outcomes = [ChatSessionStubLoadOutcome?](repeating: nil, count: files.count)
        var nextIndexToSchedule = 0

        await withTaskGroup(of: ChatSessionStubLoadOutcome.self) { group in
            func schedule(_ index: Int) {
                let fileURL = files[index]
                let snapshot = snapshots[index]
                group.addTask {
                    if let readFailure = snapshot.readFailure {
                        return .failure(index: index, fileURL: fileURL, message: readFailure)
                    }
                    do {
                        let session = try Self.decodeChatSessionStub(
                            from: snapshot.data ?? Data(),
                            fileURL: fileURL
                        )
                        return .success(index: index, session: session)
                    } catch {
                        return .failure(index: index, fileURL: fileURL, message: String(describing: error))
                    }
                }
            }

            while nextIndexToSchedule < effectiveLimit {
                schedule(nextIndexToSchedule)
                nextIndexToSchedule += 1
            }

            while let outcome = await group.next() {
                switch outcome {
                case let .success(index, _), let .failure(index, _, _):
                    outcomes[index] = outcome
                }

                if nextIndexToSchedule < files.count {
                    schedule(nextIndexToSchedule)
                    nextIndexToSchedule += 1
                }
            }
        }

        var sessions: [ChatSession] = []
        var failures: [ChatSessionStubLoadFailure] = []
        sessions.reserveCapacity(files.count)
        failures.reserveCapacity(files.count)

        for outcome in outcomes {
            guard let outcome else { continue }
            switch outcome {
            case let .success(_, session):
                sessions.append(session)
            case let .failure(index, fileURL, message):
                failures.append(ChatSessionStubLoadFailure(index: index, fileURL: fileURL, message: message))
            }
        }

        return ChatSessionStubLoadBatchResult(
            sessions: sessions,
            failures: failures,
            requestedCount: files.count
        )
    }

    private nonisolated static func loadChatSessionStubFromDisk(from fileURL: URL) throws -> ChatSession {
        let data: Data
        do {
            data = try fileSaveQueue.sync {
                try Data(contentsOf: fileURL, options: .mappedIfSafe)
            }
        } catch {
            throw ChatDataError.loadFailed(error)
        }
        return try decodeChatSessionStub(from: data, fileURL: fileURL)
    }

    private nonisolated static func decodeChatSessionStub(
        from data: Data,
        fileURL: URL
    ) throws -> ChatSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "ChatSession-"), filename.hasSuffix(".json") else {
            throw ChatDataError.invalidFilename(filename)
        }

        do {
            let header = try JSONDecoder().decode(ChatSessionHeader.self, from: data)
            let count = header.messageCount ?? header.messages?.count ?? 0
            let shortID = header.shortID ?? ChatSession.makeShortID(name: header.name, uuid: header.id)
            return ChatSession(
                id: header.id,
                workspaceID: header.workspaceID,
                composeTabID: header.composeTabID,
                agentModeSessionID: header.agentModeSessionID,
                agentModeRunID: header.agentModeRunID,
                oraclePairID: header.oraclePairID,
                oracleLane: header.oracleLane,
                oracleHistoryDiverged: header.oracleHistoryDiverged ?? false,
                name: header.name,
                savedAt: header.savedAt,
                fileURL: fileURL,
                messages: [],
                selectedFilePaths: header.selectedFilePaths ?? [],
                selectedPromptIDs: header.selectedPromptIDs ?? [],
                preferredAIModel: header.preferredAIModel,
                selectedChatPresetID: header.selectedChatPresetID,
                messageCount: count,
                shortID: shortID
            )
        } catch {
            throw ChatDataError.loadFailed(error)
        }
    }

    private func rawChatSessionFiles(for workspace: WorkspaceModel) throws -> [URL] {
        let chatsFolder = try ensureChatsFolder(for: workspace)
        return try Self.fileSaveQueue.sync {
            try FileManager.default.contentsOfDirectory(
                at: chatsFolder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.pathExtension.lowercased() == "json" &&
                    $0.lastPathComponent.starts(with: "ChatSession-")
            }
        }
    }

    private nonisolated static func fileRecord(from fileURL: URL) -> ChatSessionFileRecord? {
        fileSaveQueue.sync {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  let header = try? JSONDecoder().decode(ChatSessionHeader.self, from: data)
            else { return nil }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? header.savedAt
            return ChatSessionFileRecord(
                fileURL: fileURL,
                sessionID: header.id,
                oraclePairID: header.oraclePairID,
                oracleLane: header.oracleLane,
                modificationDate: modified
            )
        }
    }

    nonisolated static func logicalHistoryGroups(
        from records: [ChatSessionFileRecord]
    ) -> [ChatLogicalHistoryGroup] {
        let grouped = Dictionary(grouping: records) { record in
            record.oraclePairID.map(ChatLogicalHistoryKey.oraclePair) ?? .session(record.sessionID)
        }
        return grouped.map { key, records in
            let ordered = records.sorted { lhs, rhs in
                let leftLane = lhs.oracleLane == .primary ? 0 : lhs.oracleLane == .secondary ? 1 : 2
                let rightLane = rhs.oracleLane == .primary ? 0 : rhs.oracleLane == .secondary ? 1 : 2
                if leftLane != rightLane { return leftLane < rightLane }
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return ChatLogicalHistoryGroup(key: key, records: ordered)
        }.sorted { lhs, rhs in
            if lhs.newestModificationDate != rhs.newestModificationDate {
                return lhs.newestModificationDate > rhs.newestModificationDate
            }
            return String(describing: lhs.key) < String(describing: rhs.key)
        }
    }

    nonisolated static func retentionPartition(
        groups: [ChatLogicalHistoryGroup],
        limit: Int
    ) -> (kept: [ChatLogicalHistoryGroup], dropped: [ChatLogicalHistoryGroup]) {
        guard limit >= 0 else { return (groups, []) }
        var used = 0
        var splitIndex = groups.endIndex
        for (index, group) in groups.enumerated() {
            guard used + group.weight <= limit else {
                splitIndex = index
                break
            }
            used += group.weight
        }
        return (Array(groups[..<splitIndex]), Array(groups[splitIndex...]))
    }

    /// Returns chat files newest-first. Oracle pairs are one logical retention unit:
    /// a history cutoff may retain fewer than the configured physical-session limit,
    /// but it never retains or deletes only one member of a pair.
    func listChatSessions(for workspace: WorkspaceModel) async throws -> [URL] {
        let files = try rawChatSessionFiles(for: workspace)
        let records = files.compactMap(Self.fileRecord(from:))
        let readableURLs = Set(records.map(\.fileURL))
        let unreadable = files.filter { !readableURLs.contains($0) }
        let groups = Self.logicalHistoryGroups(from: records)
        let partition = Self.retentionPartition(
            groups: groups,
            limit: chatHistoryLimit == .unlimited ? -1 : chatHistoryLimit.rawValue
        )
        let droppedRecords = partition.dropped.flatMap(\.records)
        if !droppedRecords.isEmpty {
            try await deleteChatSessionFiles(
                droppedRecords.map(\.fileURL),
                sessionIDs: Set(droppedRecords.map(\.sessionID))
            )
        }
        return (partition.kept.flatMap(\.records).map(\.fileURL) + unreadable).sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    /// Reads persisted pair metadata without triggering history retention.
    func oraclePairSessionStubs(
        for workspace: WorkspaceModel,
        pairID: UUID
    ) async throws -> [ChatSession] {
        try rawChatSessionFiles(for: workspace).compactMap { fileURL in
            guard let record = Self.fileRecord(from: fileURL), record.oraclePairID == pairID else { return nil }
            return try Self.loadChatSessionStubFromDisk(from: fileURL)
        }
    }

    /// Get metadata for recent chat sessions without loading full content
    func recentSessions(
        for workspace: WorkspaceModel,
        limit: Int = 10,
        composeTabID: UUID? = nil
    ) async throws -> [ChatSessionMeta] {
        let files = try await listChatSessions(for: workspace)
        let clampedLimit = max(limit, 0)
        guard clampedLimit > 0 else { return [] }

        var metadataList: [ChatSessionMeta] = []
        metadataList.reserveCapacity(clampedLimit)

        for fileURL in files {
            do {
                let session = try await loadChatSessionStub(from: fileURL)
                if let composeTabID, session.composeTabID != composeTabID {
                    continue
                }

                let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? session.savedAt
                let meta = ChatSessionMeta(
                    id: session.id,
                    shortID: session.shortID,
                    composeTabID: session.composeTabID,
                    name: session.name,
                    lastModified: lastModified,
                    selectedFilePaths: session.selectedFilePaths,
                    messageCount: session.effectiveMessageCount
                )
                metadataList.append(meta)

                if metadataList.count >= clampedLimit {
                    break
                }
            } catch {
                // Skip files that can't be loaded
                continue
            }
        }

        return metadataList
    }

    /// Find a specific chat session by UUID or short ID without mutating OracleViewModel state.
    func findSession(
        for workspace: WorkspaceModel,
        id rawID: String,
        composeTabID: UUID? = nil
    ) async throws -> ChatSession? {
        switch try await findSessionResult(for: workspace, id: rawID, composeTabID: composeTabID) {
        case .notFound, .ambiguous:
            nil
        case let .unique(session):
            session
        }
    }

    func findSessionResult(
        for workspace: WorkspaceModel,
        id rawID: String,
        composeTabID: UUID? = nil
    ) async throws -> ChatSessionLookupResult {
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return .notFound }

        let targetUUID = UUID(uuidString: trimmedID)
        let files = try await listChatSessions(for: workspace)
        var matchingFileURL: URL?

        for fileURL in files {
            do {
                let stub = try await loadChatSessionStub(from: fileURL)
                if let composeTabID, stub.composeTabID != composeTabID {
                    continue
                }
                let matchesID = if let targetUUID {
                    stub.id == targetUUID
                } else {
                    stub.shortID == trimmedID
                }
                guard matchesID else { continue }
                guard matchingFileURL == nil else { return .ambiguous }
                matchingFileURL = fileURL
            } catch {
                continue
            }
        }

        guard let matchingFileURL else { return .notFound }
        return try await .unique(loadChatSession(from: matchingFileURL))
    }

    /// Load the most recent chat session, optionally restricted to a specific compose tab.
    func mostRecentSession(
        for workspace: WorkspaceModel,
        composeTabID: UUID? = nil
    ) async throws -> ChatSession? {
        let files = try await listChatSessions(for: workspace)

        for fileURL in files {
            do {
                let stub = try await loadChatSessionStub(from: fileURL)
                if let composeTabID, stub.composeTabID != composeTabID {
                    continue
                }
                return try await loadChatSession(from: fileURL)
            } catch {
                continue
            }
        }

        return nil
    }

    /// Deletes a logical group without exposing a half-deleted pair to actor clients.
    /// Files are first moved into a hidden same-directory transaction folder; any
    /// staging failure restores every prior move before the error is returned.
    func deleteChatSessionFiles(
        _ fileURLs: [URL],
        sessionIDs: Set<UUID> = []
    ) async throws {
        deletedSessionIDs.formUnion(sessionIDs)
        var seenURLs = Set<URL>()
        let uniqueURLs = fileURLs.filter { seenURLs.insert($0).inserted }
        guard !uniqueURLs.isEmpty else { return }
        guard let parent = uniqueURLs.first?.deletingLastPathComponent(),
              uniqueURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL })
        else {
            deletedSessionIDs.subtract(sessionIDs)
            throw ChatDataError.invalidFilename("Logical chat deletion must stay within one Chats folder.")
        }
        do {
            try Self.fileSaveQueue.sync {
                let transaction = parent.appendingPathComponent(".chat-delete-\(UUID().uuidString)", isDirectory: true)
                var staged: [(source: URL, destination: URL)] = []
                do {
                    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
                    for source in uniqueURLs {
                        let destination = transaction.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.moveItem(at: source, to: destination)
                        staged.append((source, destination))
                    }
                    try FileManager.default.removeItem(at: transaction)
                } catch {
                    var rollbackError: Error?
                    for move in staged.reversed() {
                        do {
                            try FileManager.default.moveItem(at: move.destination, to: move.source)
                        } catch {
                            rollbackError = rollbackError ?? error
                        }
                    }
                    if rollbackError == nil {
                        try? FileManager.default.removeItem(at: transaction)
                    }
                    if let rollbackError {
                        throw ChatDataError.saveFailed(NSError(
                            domain: "ChatDataService",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Logical chat deletion and rollback failed; staged files were preserved at \(transaction.path).",
                                NSUnderlyingErrorKey: rollbackError
                            ]
                        ))
                    }
                    throw error
                }
            }
        } catch {
            deletedSessionIDs.subtract(sessionIDs)
            throw error
        }
    }

    func existingChatSessionFileURLs(
        for workspace: WorkspaceModel,
        sessionIDs: Set<UUID>
    ) throws -> [URL] {
        let chatsFolder = try ensureChatsFolder(for: workspace)
        return Self.fileSaveQueue.sync {
            sessionIDs.compactMap { sessionID in
                let fileURL = chatsFolder.appendingPathComponent("ChatSession-\(sessionID.uuidString).json")
                return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
            }
        }
    }

    func logicalSessionStubs(
        for workspace: WorkspaceModel,
        matching session: ChatSession
    ) async throws -> [ChatSession] {
        if let pairID = session.oraclePairID {
            return try await oraclePairSessionStubs(for: workspace, pairID: pairID)
        }
        return try rawChatSessionFiles(for: workspace).compactMap { fileURL in
            guard let stub = try? Self.loadChatSessionStubFromDisk(from: fileURL) else { return nil }
            return stub.id == session.id ? stub : nil
        }
    }

    /// Low-level compatibility entry point for unpaired callers.
    func deleteChatSessionFile(_ fileURL: URL) async throws {
        try await deleteChatSessionFiles([fileURL])
    }

    // MARK: - Folder Helpers

    /// Creates (if needed) and returns the "Chats" subfolder for the given workspace.
    /// Uses workspace.customStoragePath if set, else the default ~Library location.
    private func ensureChatsFolder(for workspace: WorkspaceModel) throws -> URL {
        let baseFolder = try workspaceFolderURL(for: workspace)
        let chatsFolder = baseFolder.appendingPathComponent("Chats")

        if !FileManager.default.fileExists(atPath: chatsFolder.path) {
            try FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: true)
        }
        return chatsFolder
    }

    /// Return the main folder for the workspace (with custom or default path).
    private func workspaceFolderURL(for workspace: WorkspaceModel) throws -> URL {
        if let customURL = workspace.customStoragePath {
            return customURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let root = supportDir
                .appendingPathComponent("RepoPrompt CE", isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let folderName = "Workspace-\(workspace.name)-\(workspace.id.uuidString)"
            let workspaceDir = root.appendingPathComponent(folderName)
            if !FileManager.default.fileExists(atPath: workspaceDir.path) {
                try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            }
            return workspaceDir
        }
    }
}
