import Darwin
import Foundation
import RepoPromptShared

// MARK: - Scanner Protocol

/// Protocol for cross-workspace session metadata scanning.
/// Used for dependency injection in the MCP tool service (WI-3).
protocol HistorySessionScanning: Sendable {
    /// Discover all workspace directories and read their session metadata indexes.
    /// Returns one result per workspace that has an AgentSessions directory.
    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult]

    /// Same as ``scanAllWorkspaces()`` but force a fresh scan, bypassing the
    /// cross-workspace inventory TTL cache. Used to resolve a session id that was
    /// saved after the cache was populated (e.g. a `get_session` lookup that missed).
    /// The per-workspace index signature cache still applies, so unchanged indexes
    /// are not re-decoded, and the result repopulates the TTL cache.
    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult]

    /// Filter metadata records across all workspaces.
    /// Calls ``scanAllWorkspaces()`` internally, then applies the given filters.
    func sessionsMatchingFilters(
        _ records: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord]

    /// Lazily load a full transcript for a specific session.
    /// Used by the ``search`` operation to walk turns for text matching.
    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript

    /// Whether the session file for `record` has changed since its stored observed
    /// signature was recorded — i.e., persisted transcript-derived fields may be
    /// stale and should be recomputed from the live transcript.
    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL
    ) async -> Bool
}

// MARK: - Scan Results

/// Result of scanning a single workspace's session metadata.
struct HistoryWorkspaceScanResult: Equatable {
    /// The workspace directory URL (e.g. `.../Workspaces/Workspace-MyProject-UUID/`).
    let workspaceDir: URL
    /// Human-readable workspace name resolved from directory structure or workspace.json.
    let workspaceName: String
    /// The workspace UUID extracted from the directory name, if parseable.
    let workspaceID: UUID?
    /// Session metadata records from this workspace's index.
    let records: [AgentSessionMetadataRecord]
    /// Whether the index file was missing or unreadable (records will be empty).
    let indexReadFailed: Bool
    /// Non-nil when the index decoded successfully but its schema version doesn't match
    /// ``AgentSessionMetadataIndex/currentSchemaVersion``. Records are empty in this case.
    let indexSchemaVersion: Int?
}

/// A metadata record paired with its workspace context, ready for filtering.
struct HistoryFilteredSessionRecord: Equatable {
    let record: AgentSessionMetadataRecord
    let workspaceName: String
    let workspaceDir: URL

    var sessionID: UUID {
        record.id
    }
}

// MARK: - Scanner Errors

enum HistorySessionScannerError: Error, Equatable, LocalizedError {
    case sessionFileNotFound(sessionID: UUID, workspaceDir: URL)
    case transcriptDecodingFailed(sessionID: UUID, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .sessionFileNotFound(sessionID, workspaceDir):
            "Session file not found for \(sessionID) in \(workspaceDir.lastPathComponent)"
        case let .transcriptDecodingFailed(sessionID, underlying):
            "Failed to decode transcript for session \(sessionID): \(underlying)"
        }
    }
}

// MARK: - Scanner Actor

/// Scans all workspace directories on disk, reads their ``AgentSessionMetadataIndex`` files,
/// and returns unified metadata across workspaces. Provides lazy transcript loading for the
/// ``search`` operation.
///
/// Uses ``MCPFilesystemIdentity.applicationSupportRootURL()`` for the base path and discovers
/// workspaces under `Workspaces/*/`. Each workspace directory is expected to contain an
/// `AgentSessions/AgentSessionIndex.json` file.
actor HistorySessionScanner: HistorySessionScanning {
    private static let defaultScanCacheTTL: TimeInterval = 90

    private struct FileSignature: Equatable {
        let fileSize: Int64
        let modificationTime: TimeInterval
    }

    private struct IndexScanCache: Equatable {
        struct Entry: Equatable {
            let indexSignature: FileSignature
            let workspaceSignature: FileSignature?
            let readerSchemaVersion: Int
            let workspaceName: String
            let workspaceID: UUID?
            let indexSchemaVersion: Int?
            let records: [AgentSessionMetadataRecord]
        }

        var entries: [String: Entry]
    }

    /// Cached decode of a single session's transcript, invalidated when the session
    /// file's size or modification time changes. Bounds repeated decoding across
    /// iterative list/search/time queries that re-hydrate the same stub records.
    private struct TranscriptCacheEntry {
        let signature: FileSignature
        let transcript: AgentTranscript
    }

    private let fileManager: FileManager
    private let decoder: JSONDecoder

    /// Base URL for application support. Defaults to ``MCPFilesystemIdentity.applicationSupportRootURL()``.
    /// Injectable for testing.
    private let applicationSupportRoot: URL
    private let scanCacheTTL: TimeInterval
    private var cachedScanResults: [HistoryWorkspaceScanResult]?
    private var cachedScanResultsAt: Date?
    private var indexScanCache: IndexScanCache?
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]
    private static let transcriptCacheLimit = 512
    /// Observability counter: number of session files actually decoded (cache misses).
    /// Lets tests prove a second load hits the cache without re-reading.
    private(set) var transcriptDecodeCountForTesting: Int = 0

    init(
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder(),
        applicationSupportRoot: URL? = nil,
        scanCacheTTL: TimeInterval = HistorySessionScanner.defaultScanCacheTTL
    ) {
        self.fileManager = fileManager
        self.decoder = decoder
        self.applicationSupportRoot = applicationSupportRoot
            ?? MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fileManager)
        self.scanCacheTTL = scanCacheTTL
    }

    // MARK: - Workspace Discovery

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        let now = Date()
        // History queries are usually iterative model investigations, not live tailing.
        // Keep the expensive cross-workspace inventory warm briefly so
        // list/search/time calls in the same reasoning loop do not repeatedly reopen
        // thousands of tiny stale index files.
        if let cachedScanResults,
           let cachedScanResultsAt,
           now.timeIntervalSince(cachedScanResultsAt) < scanCacheTTL
        {
            return cachedScanResults
        }
        return try await performInventoryScan(now: now)
    }

    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult] {
        // Bypass the TTL cache and force a fresh scan. The per-workspace index
        // signature cache still applies, so unchanged indexes are not re-decoded, and
        // the result repopulates the TTL cache so subsequent cached calls see it. Used
        // to resolve a session id saved since the cache was populated.
        try await performInventoryScan(now: Date())
    }

    private func performInventoryScan(now: Date) async throws -> [HistoryWorkspaceScanResult] {
        let workspacesRoot = applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)

        guard directoryExists(at: workspacesRoot) else {
            cachedScanResults = []
            cachedScanResultsAt = now
            return []
        }

        let workspaceDirs: [URL]
        do {
            workspaceDirs = try fileManager.contentsOfDirectory(
                at: workspacesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        } catch {
            return []
        }

        var seenIndexCacheKeys = Set<String>()
        let results = workspaceDirs.map { workspaceDir in
            scanWorkspace(workspaceDir, seenIndexCacheKeys: &seenIndexCacheKeys)
        }
        pruneIndexScanCache(keeping: seenIndexCacheKeys)
        cachedScanResults = results
        cachedScanResultsAt = now
        return results
    }

    // MARK: - Filtering

    nonisolated func sessionsMatchingFilters(
        _ scanResults: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord] {
        var results: [HistoryFilteredSessionRecord] = []

        for scan in scanResults {
            // Skip workspaces whose index schema doesn't match the current version.
            if scan.indexSchemaVersion != nil { continue }

            // Workspace name filter: match against workspace name or workspace ID string
            if let workspace {
                let nameMatch = scan.workspaceName.localizedCaseInsensitiveContains(workspace)
                let idMatch = scan.workspaceID?.uuidString.caseInsensitiveCompare(workspace) == .orderedSame
                let dirNameMatch = scan.workspaceDir.lastPathComponent.localizedCaseInsensitiveContains(workspace)
                guard nameMatch || idMatch || dirNameMatch else { continue }
            }

            for record in scan.records {
                // Agent kind filter
                if let agentKind {
                    guard record.agentKindRaw?.localizedCaseInsensitiveContains(agentKind) == true else { continue }
                }

                // Model filter
                if let model {
                    guard record.agentModelRaw?.localizedCaseInsensitiveContains(model) == true else { continue }
                }

                // File path filter: match against keyPaths using basename/suffix-aware
                // semantics so callers can provide a basename, repo-relative path, or
                // absolute/worktree path without silently missing an indexed session.
                if let filePath {
                    let matchesFile = record.keyPaths.contains { keyPath in
                        HistoryMCPToolService.historyPath(keyPath, matches: filePath)
                    }
                    guard matchesFile else { continue }
                }

                // Date range filter — OVERLAP semantics: a session is included if ANY of its
                // activity falls within [from, to]. A session started before the range but still
                // active during it counts (e.g. a chat resumed days later).
                if let from {
                    guard (record.lastActivityAt ?? record.savedAt) >= from else { continue }
                }
                if let to {
                    guard (record.firstActivityAt ?? record.activityDate) <= to else { continue }
                }

                results.append(HistoryFilteredSessionRecord(
                    record: record,
                    workspaceName: scan.workspaceName,
                    workspaceDir: scan.workspaceDir
                ))
            }
        }

        return results
    }

    // MARK: - Transcript Loading

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript {
        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let filename = "AgentSession-\(sessionID.uuidString).json"
        let sessionFile = agentSessionsDir.appendingPathComponent(filename)
        let cacheKey = sessionFile.standardizedFileURL.path

        guard fileManager.fileExists(atPath: sessionFile.path) else {
            transcriptCache.removeValue(forKey: cacheKey)
            throw HistorySessionScannerError.sessionFileNotFound(
                sessionID: sessionID,
                workspaceDir: workspaceDir
            )
        }

        // Reuse a cached decode when the session file's size+mtime are unchanged
        // (same signature-invalidation approach as the per-index scan cache), so
        // iterative list/search/time queries don't re-decode the same transcripts.
        let signature = fileSignature(for: sessionFile)
        if let signature, let cached = transcriptCache[cacheKey], cached.signature == signature {
            return cached.transcript
        }

        do {
            transcriptDecodeCountForTesting += 1
            let data = try Data(contentsOf: sessionFile, options: .mappedIfSafe)

            // Decode the session and extract the transcript.
            // We decode as a full AgentSession to get the transcript field.
            let session = try decoder.decode(AgentSession.self, from: data)
            let transcript = session.transcript ?? .empty
            if let signature {
                transcriptCache[cacheKey] = TranscriptCacheEntry(signature: signature, transcript: transcript)
                if transcriptCache.count > Self.transcriptCacheLimit {
                    // Evict the surplus rather than clearing all, so a scan larger than
                    // the limit reuses most of the previous decode instead of re-decoding
                    // everything on each call.
                    let surplus = transcriptCache.count - Self.transcriptCacheLimit
                    for key in Array(transcriptCache.keys.prefix(surplus)) {
                        transcriptCache.removeValue(forKey: key)
                    }
                }
            }
            return transcript
        } catch {
            transcriptCache.removeValue(forKey: cacheKey)
            throw HistorySessionScannerError.transcriptDecodingFailed(
                sessionID: sessionID,
                underlying: String(describing: error)
            )
        }
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL
    ) async -> Bool {
        // Re-enrich when there's no observed signature to compare against, or when the
        // session file's size/mtime changed since observation. A missing/unreadable
        // file is also treated as stale so the load path can surface the failure.
        guard let observedSize = record.observedFileSize,
              let observedMod = record.observedFileModificationDate
        else { return true }
        let sessionFile = workspaceDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        guard let current = fileSignature(for: sessionFile) else { return true }
        return current.fileSize != observedSize
            || current.modificationTime != observedMod.timeIntervalSinceReferenceDate
    }

    // MARK: - Private Helpers

    private func scanWorkspace(
        _ workspaceDir: URL,
        seenIndexCacheKeys: inout Set<String>
    ) -> HistoryWorkspaceScanResult {
        let dirName = workspaceDir.lastPathComponent
        let fallbackIdentity = WorkspaceDirectoryName.parse(dirName)

        func result(
            records: [AgentSessionMetadataRecord] = [],
            indexReadFailed: Bool = false,
            indexSchemaVersion: Int? = nil,
            identity: (name: String, id: UUID?) = fallbackIdentity
        ) -> HistoryWorkspaceScanResult {
            HistoryWorkspaceScanResult(
                workspaceDir: workspaceDir,
                workspaceName: identity.name,
                workspaceID: identity.id,
                records: records,
                indexReadFailed: indexReadFailed,
                indexSchemaVersion: indexSchemaVersion
            )
        }

        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        guard directoryExists(at: agentSessionsDir) else {
            // No AgentSessions directory — this workspace has no sessions. Avoid reading
            // workspace.json on the cold scan path; the directory name is sufficient.
            return result()
        }

        let indexFile = agentSessionsDir.appendingPathComponent("AgentSessionIndex.json")
        guard let indexSignature = fileSignature(for: indexFile) else {
            // No index file — return empty records (no failure flag; index may not exist yet).
            return result()
        }

        let cacheKey = indexScanCacheKey(for: indexFile)
        seenIndexCacheKeys.insert(cacheKey)
        let workspaceJSON = workspaceDir.appendingPathComponent("workspace.json")
        let workspaceSignature = fileSignature(for: workspaceJSON)
        if let cachedResult = cachedScanResult(
            for: cacheKey,
            indexSignature: indexSignature,
            workspaceSignature: workspaceSignature,
            workspaceDir: workspaceDir
        ) {
            return cachedResult
        }

        do {
            let data = try Data(contentsOf: indexFile, options: .mappedIfSafe)
            guard let schemaVersion = schemaVersionSniff(from: data) else {
                removeCachedIndexScan(cacheKey)
                return result(indexReadFailed: true)
            }

            let identity = resolveWorkspaceNameAndID(from: workspaceDir, dirName: dirName, fileManager: fileManager)
            guard schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                rememberIndexScan(
                    cacheKey,
                    indexSignature: indexSignature,
                    workspaceSignature: workspaceSignature,
                    identity: identity,
                    indexSchemaVersion: schemaVersion,
                    records: []
                )
                return result(indexSchemaVersion: schemaVersion, identity: identity)
            }

            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            rememberIndexScan(
                cacheKey,
                indexSignature: indexSignature,
                workspaceSignature: workspaceSignature,
                identity: identity,
                indexSchemaVersion: nil,
                records: index.entries
            )
            return result(records: index.entries, identity: identity)
        } catch {
            removeCachedIndexScan(cacheKey)
            return result(indexReadFailed: true)
        }
    }

    private func pruneIndexScanCache(keeping liveKeys: Set<String>) {
        guard var cache = indexScanCache else { return }
        let originalCount = cache.entries.count
        cache.entries = cache.entries.filter { liveKeys.contains($0.key) }
        if cache.entries.count != originalCount {
            indexScanCache = cache
        }
    }

    private func cachedScanResult(
        for cacheKey: String,
        indexSignature: FileSignature,
        workspaceSignature: FileSignature?,
        workspaceDir: URL
    ) -> HistoryWorkspaceScanResult? {
        guard let entry = indexScanCache?.entries[cacheKey],
              entry.readerSchemaVersion == AgentSessionMetadataIndex.currentSchemaVersion,
              entry.indexSignature == indexSignature,
              entry.workspaceSignature == workspaceSignature
        else { return nil }

        return HistoryWorkspaceScanResult(
            workspaceDir: workspaceDir,
            workspaceName: entry.workspaceName,
            workspaceID: entry.workspaceID,
            records: entry.records,
            indexReadFailed: false,
            indexSchemaVersion: entry.indexSchemaVersion
        )
    }

    private func rememberIndexScan(
        _ cacheKey: String,
        indexSignature: FileSignature,
        workspaceSignature: FileSignature?,
        identity: (name: String, id: UUID?),
        indexSchemaVersion: Int?,
        records: [AgentSessionMetadataRecord]
    ) {
        var cache = indexScanCache ?? IndexScanCache(entries: [:])
        let entry = IndexScanCache.Entry(
            indexSignature: indexSignature,
            workspaceSignature: workspaceSignature,
            readerSchemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            workspaceName: identity.name,
            workspaceID: identity.id,
            indexSchemaVersion: indexSchemaVersion,
            records: records
        )
        if cache.entries[cacheKey] == entry {
            return
        }
        cache.entries[cacheKey] = entry
        indexScanCache = cache
    }

    private func removeCachedIndexScan(_ cacheKey: String) {
        guard var cache = indexScanCache, cache.entries.removeValue(forKey: cacheKey) != nil else { return }
        indexScanCache = cache
    }

    private func fileSignature(for fileURL: URL) -> FileSignature? {
        var statResult = Darwin.stat()
        return fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path, stat(path, &statResult) == 0 else { return nil }
            return FileSignature(
                fileSize: Int64(statResult.st_size),
                modificationTime: Date(
                    timeIntervalSince1970: TimeInterval(statResult.st_mtimespec.tv_sec)
                        + (TimeInterval(statResult.st_mtimespec.tv_nsec) / 1_000_000_000)
                ).timeIntervalSinceReferenceDate
            )
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var statResult = Darwin.stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, stat(path, &statResult) == 0 else { return false }
            return (statResult.st_mode & S_IFMT) == S_IFDIR
        }
    }

    private func indexScanCacheKey(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

    private nonisolated func schemaVersionSniff(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: "\"schemaVersion\"")
        else { return nil }
        guard let colon = text[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        var index = text.index(after: colon)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        let start = index
        while index < text.endIndex, text[index].isNumber || text[index] == "-" {
            index = text.index(after: index)
        }
        guard start < index else { return nil }
        return Int(text[start ..< index])
    }

    /// Resolve workspace name and ID from the directory.
    /// Tries workspace.json first, then parses the `Workspace-{name}-{uuid}` directory name
    /// via the shared ``WorkspaceDirectoryName`` parser.
    private nonisolated func resolveWorkspaceNameAndID(
        from workspaceDir: URL,
        dirName: String,
        fileManager: FileManager
    ) -> (name: String, id: UUID?) {
        // Try reading workspace.json for the canonical name.
        let workspaceJSON = workspaceDir.appendingPathComponent("workspace.json")
        if fileManager.fileExists(atPath: workspaceJSON.path) {
            if let data = try? Data(contentsOf: workspaceJSON, options: .mappedIfSafe),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String
            {
                let id = (json["id"] as? String).flatMap { UUID(uuidString: $0) }
                return (name: name, id: id)
            }
        }

        // Parse directory name: "Workspace-{name}-{uuid}" or fall back to directory name.
        return WorkspaceDirectoryName.parse(dirName)
    }
}
