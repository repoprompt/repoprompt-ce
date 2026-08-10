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

private enum ChatSessionFile {
    static func filename(for id: UUID) -> String {
        "ChatSession-\(id.uuidString).json"
    }

    static func sessionID(from filename: String) -> UUID? {
        guard filename.hasPrefix("ChatSession-"), filename.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(filename.dropFirst(12).dropLast(5)))
    }
}

/// Current-format crash recovery for installing exactly one Oracle pair.
private enum OraclePairWriteTransaction {
    private struct Manifest: Codable {
        struct Entry: Codable {
            let sessionID: UUID
            let originallyExisted: Bool
        }

        let entries: [Entry]
    }

    private static let prefix = ".oracle-pair-save-"
    private static let quarantinePrefix = ".oracle-pair-quarantine-"
    private static let manifestName = "manifest.json"
    private static let temporaryManifestName = "manifest.tmp"
    private static let commitName = "committed"

    static func save(_ replacements: [(id: UUID, data: Data)], in folder: URL) throws {
        guard replacements.count == 2, Set(replacements.map(\.id)).count == 2 else {
            throw ChatDataError.invalidFilename("An Oracle pair save requires exactly two distinct sessions.")
        }
        try recover(in: folder)

        let replacements = replacements.sorted { $0.id.uuidString < $1.id.uuidString }
        let entries = try replacements.map { replacement -> Manifest.Entry in
            let destination = folder.appendingPathComponent(ChatSessionFile.filename(for: replacement.id))
            let existed = FileManager.default.fileExists(atPath: destination.path)
            if existed { try requireRegular(destination) }
            return .init(sessionID: replacement.id, originallyExisted: existed)
        }
        let transaction = folder.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)

        do {
            for replacement in replacements {
                try write(
                    replacement.data,
                    to: transaction.appendingPathComponent("replacement-\(ChatSessionFile.filename(for: replacement.id))")
                )
            }
            let temporaryManifest = transaction.appendingPathComponent(temporaryManifestName)
            try write(JSONEncoder().encode(Manifest(entries: entries)), to: temporaryManifest)
            try FileManager.default.moveItem(
                at: temporaryManifest,
                to: transaction.appendingPathComponent(manifestName)
            )
            for entry in entries {
                let filename = ChatSessionFile.filename(for: entry.sessionID)
                let destination = folder.appendingPathComponent(filename)
                if entry.originallyExisted {
                    try FileManager.default.moveItem(
                        at: destination,
                        to: transaction.appendingPathComponent("original-\(filename)")
                    )
                }
                try FileManager.default.moveItem(
                    at: transaction.appendingPathComponent("replacement-\(filename)"),
                    to: destination
                )
            }
            try write(Data(), to: transaction.appendingPathComponent(commitName))
            try? FileManager.default.removeItem(at: transaction)
        } catch {
            do {
                try recover(transaction, in: folder)
            } catch {
                throw saveError("Oracle pair save and recovery both failed.", underlying: error)
            }
            throw error
        }
    }

    static func recover(in folder: URL) throws {
        for transaction in try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) where transaction.lastPathComponent.hasPrefix(prefix) {
            let suffix = String(transaction.lastPathComponent.dropFirst(prefix.count))
            let values = try? transaction.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard UUID(uuidString: suffix) != nil,
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true
            else {
                quarantine(transaction, in: folder)
                continue
            }
            do {
                try recover(transaction, in: folder)
            } catch ChatDataError.invalidFilename {
                quarantine(transaction, in: folder)
            } catch is DecodingError {
                quarantine(transaction, in: folder)
            }
        }
    }

    private static func quarantine(_ transaction: URL, in folder: URL) {
        let destination = folder.appendingPathComponent("\(quarantinePrefix)\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: transaction, to: destination)
            print("Quarantined malformed Oracle pair transaction \(transaction.lastPathComponent).")
        } catch {
            print("Could not quarantine malformed Oracle pair transaction \(transaction.lastPathComponent): \(error)")
        }
    }

    private static func recover(_ transaction: URL, in folder: URL) throws {
        let manifestURL = transaction.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            _ = try validatedArtifacts(in: transaction, entries: [])
            try FileManager.default.removeItem(at: transaction)
            return
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: readRegular(manifestURL))
        guard manifest.entries.count == 2,
              Set(manifest.entries.map(\.sessionID)).count == 2
        else { throw ChatDataError.invalidFilename(transaction.lastPathComponent) }
        _ = try validatedArtifacts(in: transaction, entries: manifest.entries)

        if !FileManager.default.fileExists(atPath: transaction.appendingPathComponent(commitName).path) {
            for entry in manifest.entries {
                let filename = ChatSessionFile.filename(for: entry.sessionID)
                let destination = folder.appendingPathComponent(filename)
                let original = transaction.appendingPathComponent("original-\(filename)")
                if entry.originallyExisted, FileManager.default.fileExists(atPath: original.path) {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: original, to: destination)
                } else if !entry.originallyExisted, FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
            }
        }
        try FileManager.default.removeItem(at: transaction)
    }

    private static func validatedArtifacts(
        in transaction: URL,
        entries: [Manifest.Entry]
    ) throws -> [String] {
        let allowedSessionArtifacts = Set(entries.flatMap { entry in
            let filename = ChatSessionFile.filename(for: entry.sessionID)
            return ["original-\(filename)", "replacement-\(filename)"]
        })
        return try FileManager.default.contentsOfDirectory(
            at: transaction,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).map { url in
            let name = url.lastPathComponent
            let stagingReplacement = name.hasPrefix("replacement-") &&
                ChatSessionFile.sessionID(from: String(name.dropFirst("replacement-".count))) != nil
            guard name == manifestName || name == temporaryManifestName || name == commitName ||
                allowedSessionArtifacts.contains(name) || (entries.isEmpty && stagingReplacement)
            else { throw ChatDataError.invalidFilename(name) }
            try requireRegular(url)
            return name
        }
    }

    fileprivate static func requireRegular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChatDataError.invalidFilename(url.lastPathComponent)
        }
    }

    private static func readRegular(_ url: URL) throws -> Data {
        try requireRegular(url)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func saveError(_ message: String, underlying: Error) -> ChatDataError {
        .saveFailed(NSError(
            domain: "ChatDataService",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: underlying]
        ))
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
    private let decoder = JSONDecoder()
    private static let fileSaveQueue = DispatchQueue(label: "com.repoprompt.chatDataServiceFileSaveQueue")
    private var pairMutationPending = false
    private var pairMutationWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Save a legacy single session using the established serial atomic-write path.
    func saveChatSession(
        _ session: ChatSession,
        for workspace: WorkspaceModel
    ) async throws -> URL {
        guard session.oraclePairID == nil, session.oracleLane == nil else {
            throw ChatDataError.saveFailed(NSError(
                domain: "ChatDataService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Paired Oracle sessions must be saved together."]
            ))
        }
        return try await withExclusivePairMutation {
            let chatsFolder = try ensureChatsFolder(for: workspace)
            let fileURL = chatsFolder.appendingPathComponent(ChatSessionFile.filename(for: session.id))
            var sessionToSave = session
            sessionToSave.fileURL = fileURL
            sessionToSave.savedAt = Date()
            let sessionCopy = sessionToSave

            return try await withCheckedThrowingContinuation { continuation in
                Self.fileSaveQueue.async {
                    do {
                        let data = try JSONEncoder().encode(sessionCopy)
                        try data.write(to: fileURL, options: .atomic)
                        continuation.resume(returning: fileURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func encodedOracleSessions(
        _ sessions: [ChatSession],
        chatsFolder: URL,
        workspaceID: UUID
    ) throws -> [(id: UUID, fileURL: URL, data: Data)] {
        guard sessions.count == 2,
              Set(sessions.map(\.id)).count == 2,
              let pairID = sessions.first?.oraclePairID,
              sessions.allSatisfy({ $0.oraclePairID == pairID && $0.workspaceID == workspaceID }),
              Set(sessions.compactMap(\.oracleLane)) == Set(OracleLane.allCases)
        else {
            throw ChatDataError.invalidFilename("An Oracle pair save requires one Primary and one Secondary session in the target workspace.")
        }
        return try sessions.sorted { ($0.oracleLane == .primary ? 0 : 1) < ($1.oracleLane == .primary ? 0 : 1) }.map { session in
            let fileURL = chatsFolder.appendingPathComponent(ChatSessionFile.filename(for: session.id))
            var copy = session
            copy.fileURL = fileURL
            return try (session.id, fileURL, JSONEncoder().encode(copy))
        }
    }

    /// Saves exactly one Primary/Secondary Oracle pair without exposing a half-written generation.
    func saveOraclePairSessions(
        _ sessions: [ChatSession],
        for workspace: WorkspaceModel
    ) async throws -> [UUID: URL] {
        try await withExclusivePairMutation {
            let chatsFolder = try ensureChatsFolder(for: workspace)
            let prepared = try encodedOracleSessions(
                sessions,
                chatsFolder: chatsFolder,
                workspaceID: workspace.id
            )
            try OraclePairWriteTransaction.save(prepared.map { ($0.id, $0.data) }, in: chatsFolder)
            return Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0.fileURL) })
        }
    }

    /// Load a current ChatSession from disk.
    func loadChatSession(
        from fileURL: URL
    ) async throws -> ChatSession {
        let filename = fileURL.lastPathComponent
        guard let expectedID = ChatSessionFile.sessionID(from: filename) else {
            throw ChatDataError.invalidFilename(filename)
        }

        do {
            // Use memory-mapped reads to reduce peak memory pressure for large sessions
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            var session = try decoder.decode(ChatSession.self, from: data)
            guard session.id == expectedID else { throw ChatDataError.invalidFilename(filename) }
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
        guard let expectedID = ChatSessionFile.sessionID(from: filename) else {
            throw ChatDataError.invalidFilename(filename)
        }

        do {
            // Use memory-mapped reads to reduce peak memory pressure when listing many sessions
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let header = try JSONDecoder().decode(ChatSessionHeader.self, from: data)
            guard header.id == expectedID else { throw ChatDataError.invalidFilename(filename) }
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

    private func modificationDate(for fileURL: URL) -> Date {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private struct HistoryFile {
        let url: URL
        let id: UUID
        let pairID: UUID?
        let lane: OracleLane?
        let modified: Date
    }

    private func chatFiles(in chatsFolder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: chatsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard ChatSessionFile.sessionID(from: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    /// Returns newest-first chat files. Readable pairs are retained or deleted together;
    /// unreadable exact chat files still consume one bounded-retention slot.
    func listChatSessions(
        for workspace: WorkspaceModel,
        protectedSessionIDs: Set<UUID> = [],
        applyRetention: Bool = true
    ) async throws -> [URL] {
        let chatsFolder = try ensureChatsFolder(for: workspace)
        let files = try chatFiles(in: chatsFolder).compactMap { url -> HistoryFile? in
            guard let id = ChatSessionFile.sessionID(from: url.lastPathComponent) else { return nil }
            let modified = modificationDate(for: url)
            let stub = try? Self.loadChatSessionStubFromDisk(from: url)
            return HistoryFile(
                url: url,
                id: id,
                pairID: stub?.oraclePairID,
                lane: stub?.oracleLane,
                modified: modified
            )
        }
        let groups = Dictionary(grouping: files) { file in
            file.pairID.map { "pair:\($0.uuidString)" } ?? "session:\(file.id.uuidString)"
        }.values.map { group in
            group.sorted {
                let left = $0.lane == .primary ? 0 : $0.lane == .secondary ? 1 : 2
                let right = $1.lane == .primary ? 0 : $1.lane == .secondary ? 1 : 2
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
        }.sorted {
            ($0.map(\.modified).max() ?? .distantPast) > ($1.map(\.modified).max() ?? .distantPast)
        }

        guard applyRetention, !pairMutationPending else { return groups.flatMap { $0.map(\.url) } }
        let limit = chatHistoryLimit == .unlimited ? Int.max : chatHistoryLimit.rawValue
        var kept: [[HistoryFile]] = []
        var dropped: [[HistoryFile]] = []
        var used = 0
        var retentionFull = false
        for group in groups {
            if group.contains(where: { protectedSessionIDs.contains($0.id) }) {
                kept.append(group)
                used += group.count
            } else if !retentionFull, used + group.count <= limit {
                kept.append(group)
                used += group.count
            } else {
                dropped.append(group)
                retentionFull = true
            }
        }
        for group in dropped {
            try? deleteSessionFiles(Set(group.map(\.id)), in: chatsFolder)
        }
        return kept.flatMap { $0.map(\.url) }
    }

    /// Reads persisted pair metadata without applying retention.
    func oraclePairSessionStubs(
        for workspace: WorkspaceModel,
        pairID: UUID
    ) async throws -> [ChatSession] {
        let chatsFolder = try ensureChatsFolder(for: workspace)
        return try chatFiles(in: chatsFolder).compactMap { url in
            guard let stub = try? Self.loadChatSessionStubFromDisk(from: url), stub.oraclePairID == pairID else {
                return nil
            }
            return stub
        }
    }

    /// Get metadata for recent chat sessions without loading full content
    func recentSessions(
        for workspace: WorkspaceModel,
        limit: Int = 10,
        composeTabID: UUID? = nil
    ) async throws -> [ChatSessionMeta] {
        let files = try await listChatSessions(for: workspace, applyRetention: false)
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
        let files = try await listChatSessions(for: workspace, applyRetention: false)
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
        let files = try await listChatSessions(for: workspace, applyRetention: false)

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

    /// Delete a particular legacy chat session file.
    func deleteChatSessionFile(_ fileURL: URL) async throws {
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes the known durable members of one Oracle pair as a unit.
    func deleteOraclePairSessionFiles(
        _ sessionIDs: Set<UUID>,
        for workspace: WorkspaceModel
    ) async throws {
        try await withExclusivePairMutation {
            let chatsFolder = try ensureChatsFolder(for: workspace)
            try deleteSessionFiles(sessionIDs, in: chatsFolder)
        }
    }

    /// Deletes all canonical chat files after the caller has cancelled workspace sends.
    func deleteAllChatSessionFiles(for workspace: WorkspaceModel) async throws {
        try await withExclusivePairMutation {
            let chatsFolder = try ensureChatsFolder(for: workspace)
            for fileURL in try chatFiles(in: chatsFolder) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func withExclusivePairMutation<T>(_ operation: () async throws -> T) async throws -> T {
        if pairMutationPending {
            await withCheckedContinuation { continuation in
                pairMutationWaiters.append(continuation)
            }
        } else {
            pairMutationPending = true
        }
        defer {
            if pairMutationWaiters.isEmpty {
                pairMutationPending = false
            } else {
                pairMutationWaiters.removeFirst().resume()
            }
        }
        await withCheckedContinuation { continuation in
            Self.fileSaveQueue.async { continuation.resume() }
        }
        return try await operation()
    }

    private func deleteSessionFiles(_ sessionIDs: Set<UUID>, in chatsFolder: URL) throws {
        guard !sessionIDs.isEmpty, sessionIDs.count <= 2 else {
            throw ChatDataError.invalidFilename("Oracle pair deletion requires one or two session IDs.")
        }
        let saved = try sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { id -> (URL, Data, Date?)? in
            let url = chatsFolder.appendingPathComponent(ChatSessionFile.filename(for: id))
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try OraclePairWriteTransaction.requireRegular(url)
            return try (
                url,
                Data(contentsOf: url, options: .mappedIfSafe),
                url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            )
        }
        do {
            for (url, _, _) in saved {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            for (url, data, date) in saved where !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: .atomic)
                if let date {
                    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }
            }
            throw error
        }
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
        try OraclePairWriteTransaction.recover(in: chatsFolder)
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
