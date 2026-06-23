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
    /// The JSON decoder we'll use
    private let decoder = JSONDecoder()

    init() {
        // Customize encoder/decoder if desired (dates, etc.)
    }

    private static let fileSaveQueue = DispatchQueue(label: "com.repoprompt.chatDataServiceFileSaveQueue")

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

        // 4) Encode & write using a fresh encoder inside the shared static queue
        return try await withCheckedThrowingContinuation { continuation in
            Self.fileSaveQueue.async {
                do {
                    let freshEncoder = JSONEncoder() // Use a fresh encoder
                    let data = try freshEncoder.encode(sessionCopy)
                    try data.write(to: fileURL, options: .atomic)
                    continuation.resume(returning: fileURL)
                } catch {
                    continuation.resume(throwing: error)
                }
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
            // Use memory-mapped reads to reduce peak memory pressure for large sessions
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            var session = try decoder.decode(ChatSession.self, from: data)
            session.fileURL = fileURL
            return session
        } catch {
            throw ChatDataError.loadFailed(error)
        }
    }

    private enum ChatSessionStubLoadOutcome {
        case success(index: Int, session: ChatSession)
        case failure(index: Int, fileURL: URL, message: String)
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

        let effectiveLimit = min(max(1, maxConcurrent), files.count)
        var outcomes = [ChatSessionStubLoadOutcome?](repeating: nil, count: files.count)
        var nextIndexToSchedule = 0

        await withTaskGroup(of: ChatSessionStubLoadOutcome.self) { group in
            func schedule(_ index: Int) {
                let fileURL = files[index]
                group.addTask {
                    do {
                        let session = try Self.loadChatSessionStubFromDisk(from: fileURL)
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
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "ChatSession-"), filename.hasSuffix(".json") else {
            throw ChatDataError.invalidFilename(filename)
        }

        do {
            // Use memory-mapped reads to reduce peak memory pressure when listing many sessions
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let header = try JSONDecoder().decode(ChatSessionHeader.self, from: data)
            let count = header.messageCount ?? header.messages?.count ?? 0

            let shortID = header.shortID ?? ChatSession.makeShortID(name: header.name, uuid: header.id)

            return ChatSession(
                id: header.id,
                workspaceID: header.workspaceID,
                composeTabID: header.composeTabID,
                agentModeSessionID: header.agentModeSessionID,
                agentModeRunID: header.agentModeRunID,
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

    /// Returns a list of "ChatSession-xxx.json" files in the workspace’s Chats folder, sorted by mod date desc.
    func listChatSessions(for workspace: WorkspaceModel) async throws -> [URL] {
        let chatsFolder = try ensureChatsFolder(for: workspace)

        let contents = try FileManager.default.contentsOfDirectory(
            at: chatsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let jsonFiles = contents.filter {
            $0.pathExtension.lowercased() == "json" &&
                $0.lastPathComponent.starts(with: "ChatSession-")
        }

        let sortedFiles = jsonFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        // Apply chat history limit based on user setting
        let limit = chatHistoryLimit
        if limit != .unlimited, sortedFiles.count > limit.rawValue {
            let filesToDelete = sortedFiles.dropFirst(limit.rawValue)
            for url in filesToDelete {
                // Best-effort delete; ignore individual failures
                try? FileManager.default.removeItem(at: url)
            }
            return Array(sortedFiles.prefix(limit.rawValue))
        }

        // If unlimited or under limit, return all files
        return sortedFiles
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

    /// Delete a particular chat session file.
    func deleteChatSessionFile(_ fileURL: URL) async throws {
        try FileManager.default.removeItem(at: fileURL)
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
