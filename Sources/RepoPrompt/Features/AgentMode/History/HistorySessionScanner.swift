import Darwin
import Foundation
import RepoPromptShared

// MARK: - Cooperative Work Budgets

struct HistoryScanDiagnostic: Codable, Equatable {
    enum Kind: String, Codable, Hashable {
        case workspaceCount = "workspace_count"
        case workspaceDiscovery = "workspace_discovery"
        case workspaceMetadataFileBytes = "workspace_metadata_file_bytes"
        case workspaceMetadataReadFailure = "workspace_metadata_read_failure"
        case indexCount = "index_count"
        case indexBytes = "index_bytes"
        case indexFileBytes = "index_file_bytes"
        case indexReadFailure = "index_read_failure"
        case transcriptBytes = "transcript_bytes"
        case transcriptFileBytes = "transcript_file_bytes"
        case transcriptReadFailure = "transcript_read_failure"
        case turnCount = "turn_count"
        case elapsedTime = "elapsed_time"
        case diagnosticCount = "diagnostic_count"
    }

    enum Unit: String, Codable {
        case workspaces
        case indexes
        case sessions
        case bytes
        case turns
        case milliseconds
    }

    let kind: Kind
    let retryable: Bool
    let limit: Int64
    let consumed: Int64
    let unit: Unit
    let phase: String?
    let count: Int

    init(
        kind: Kind,
        limit: Int64,
        consumed: Int64,
        unit: Unit,
        retryable: Bool = true,
        phase: String? = nil,
        count: Int = 1
    ) {
        self.kind = kind
        self.retryable = retryable
        self.limit = limit
        self.consumed = consumed
        self.unit = unit
        self.phase = phase
        self.count = max(1, count)
    }

    var makesInventoryIncomplete: Bool {
        switch kind {
        case .workspaceMetadataFileBytes, .workspaceMetadataReadFailure:
            false
        case .workspaceCount, .workspaceDiscovery, .indexCount, .indexBytes,
             .indexFileBytes, .indexReadFailure, .transcriptBytes,
             .transcriptFileBytes, .transcriptReadFailure, .turnCount,
             .elapsedTime, .diagnosticCount:
            true
        }
    }
}

enum HistoryRemainingTimeDecision {
    case sufficient(remaining: Duration)
    case insufficient(HistoryScanDiagnostic)
}

final class HistoryRequestBudget: @unchecked Sendable {
    enum ReadKind {
        case index
        case transcript
    }

    let startedAt: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let maxTurns: Int
    let yieldEveryTurns: Int
    let maxIndexBytes: Int64
    let maxIndexFileBytes: Int64
    let maxTranscriptBytes: Int64
    let maxTranscriptFileBytes: Int64

    private let nowProvider: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var consumedIndexBytes: Int64 = 0
    private var consumedTranscriptBytes: Int64 = 0

    init(
        startedAt: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        maxTurns: Int,
        yieldEveryTurns: Int,
        maxIndexBytes: Int64,
        maxIndexFileBytes: Int64,
        maxTranscriptBytes: Int64,
        maxTranscriptFileBytes: Int64,
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.startedAt = startedAt
        self.deadline = deadline
        self.maxTurns = maxTurns
        self.yieldEveryTurns = yieldEveryTurns
        self.maxIndexBytes = maxIndexBytes
        self.maxIndexFileBytes = maxIndexFileBytes
        self.maxTranscriptBytes = maxTranscriptBytes
        self.maxTranscriptFileBytes = maxTranscriptFileBytes
        self.nowProvider = nowProvider
    }

    static func standalone(
        maxElapsed: Duration = .seconds(20),
        maxIndexBytes: Int64 = 128 * 1024 * 1024,
        maxIndexFileBytes: Int64 = 16 * 1024 * 1024,
        maxTranscriptBytes: Int64 = 256 * 1024 * 1024,
        maxTranscriptFileBytes: Int64 = 64 * 1024 * 1024
    ) -> HistoryRequestBudget {
        let clock = ContinuousClock()
        let startedAt = clock.now
        return HistoryRequestBudget(
            startedAt: startedAt,
            deadline: startedAt + maxElapsed,
            maxTurns: 250_000,
            yieldEveryTurns: 64,
            maxIndexBytes: maxIndexBytes,
            maxIndexFileBytes: maxIndexFileBytes,
            maxTranscriptBytes: maxTranscriptBytes,
            maxTranscriptFileBytes: maxTranscriptFileBytes,
            nowProvider: { ContinuousClock().now }
        )
    }

    var now: ContinuousClock.Instant {
        nowProvider()
    }

    func elapsedDiagnostic(phase: String) -> HistoryScanDiagnostic? {
        let current = now
        guard current >= deadline else { return nil }
        return HistoryScanDiagnostic(
            kind: .elapsedTime,
            limit: Self.durationMilliseconds(deadline - startedAt),
            consumed: Self.durationMilliseconds(current - startedAt),
            unit: .milliseconds,
            phase: phase
        )
    }

    func remainingTimeDecision(
        minimumRemaining: Duration,
        phase: String
    ) -> HistoryRemainingTimeDecision {
        let current = now
        let remaining = deadline - current
        guard current < deadline, remaining >= minimumRemaining else {
            return .insufficient(HistoryScanDiagnostic(
                kind: .elapsedTime,
                limit: Self.durationMilliseconds(deadline - startedAt),
                consumed: Self.durationMilliseconds(current - startedAt),
                unit: .milliseconds,
                phase: phase
            ))
        }
        return .sufficient(remaining: remaining)
    }

    func reserveRead(_ bytes: Int64, kind: ReadKind, phase: String) -> HistoryScanDiagnostic? {
        let normalizedBytes = max(0, bytes)
        let perFileLimit = kind == .index ? maxIndexFileBytes : maxTranscriptFileBytes
        let fileKind: HistoryScanDiagnostic.Kind = kind == .index ? .indexFileBytes : .transcriptFileBytes
        if normalizedBytes > perFileLimit {
            return HistoryScanDiagnostic(
                kind: fileKind,
                limit: perFileLimit,
                consumed: normalizedBytes,
                unit: .bytes,
                retryable: false,
                phase: phase
            )
        }

        return lock.withLock {
            let cumulativeLimit = kind == .index ? maxIndexBytes : maxTranscriptBytes
            let consumed = kind == .index ? consumedIndexBytes : consumedTranscriptBytes
            guard normalizedBytes <= cumulativeLimit - consumed else {
                return HistoryScanDiagnostic(
                    kind: kind == .index ? .indexBytes : .transcriptBytes,
                    limit: cumulativeLimit,
                    consumed: consumed + normalizedBytes,
                    unit: .bytes,
                    phase: phase
                )
            }
            if kind == .index {
                consumedIndexBytes += normalizedBytes
            } else {
                consumedTranscriptBytes += normalizedBytes
            }
            return nil
        }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000
            + components.attoseconds / 1_000_000_000_000_000
    }
}

struct HistoryInventoryScan: Equatable {
    let workspaces: [HistoryWorkspaceScanResult]
    let diagnostics: [HistoryScanDiagnostic]

    init(workspaces: [HistoryWorkspaceScanResult], diagnostics: [HistoryScanDiagnostic] = []) {
        self.workspaces = workspaces
        self.diagnostics = diagnostics
    }

    var isTruncated: Bool {
        diagnostics.contains(where: \.makesInventoryIncomplete)
    }
}

struct HistoryInventoryBudget: Equatable {
    let maxWorkspaces: Int
    let maxIndexDecodes: Int
    let maxIndexBytes: Int64
    let maxIndexFileBytes: Int64
    let maxWorkspaceMetadataFileBytes: Int64
    let maxIndexCacheEntries: Int
    let maxIndexCacheBytes: Int64
    let maxTranscriptFileBytes: Int64
    let maxTranscriptCacheBytes: Int64

    static let `default` = HistoryInventoryBudget(
        maxWorkspaces: 5000,
        maxIndexDecodes: 2000,
        maxIndexBytes: 128 * 1024 * 1024,
        maxIndexFileBytes: 16 * 1024 * 1024,
        maxWorkspaceMetadataFileBytes: 1024 * 1024,
        maxIndexCacheEntries: 4096,
        maxIndexCacheBytes: 128 * 1024 * 1024,
        maxTranscriptFileBytes: 64 * 1024 * 1024,
        maxTranscriptCacheBytes: 128 * 1024 * 1024
    )

    init(
        maxWorkspaces: Int,
        maxIndexDecodes: Int,
        maxIndexBytes: Int64,
        maxIndexFileBytes: Int64 = 16 * 1024 * 1024,
        maxWorkspaceMetadataFileBytes: Int64 = 1024 * 1024,
        maxIndexCacheEntries: Int = 4096,
        maxIndexCacheBytes: Int64 = 128 * 1024 * 1024,
        maxTranscriptFileBytes: Int64 = 64 * 1024 * 1024,
        maxTranscriptCacheBytes: Int64 = 128 * 1024 * 1024,
        maxElapsed _: Duration? = nil
    ) {
        self.maxWorkspaces = maxWorkspaces
        self.maxIndexDecodes = maxIndexDecodes
        self.maxIndexBytes = maxIndexBytes
        self.maxIndexFileBytes = maxIndexFileBytes
        self.maxWorkspaceMetadataFileBytes = maxWorkspaceMetadataFileBytes
        self.maxIndexCacheEntries = max(1, maxIndexCacheEntries)
        self.maxIndexCacheBytes = max(1, maxIndexCacheBytes)
        self.maxTranscriptFileBytes = maxTranscriptFileBytes
        self.maxTranscriptCacheBytes = maxTranscriptCacheBytes
    }
}

struct HistoryLoadedSession {
    let name: String?
    let transcript: AgentTranscript
}

struct HistoryDirectSessionLocation: Equatable {
    let record: AgentSessionMetadataRecord?
    let workspaceName: String
    let workspaceDir: URL
}

struct HistoryDirectSessionLookup: Equatable {
    let location: HistoryDirectSessionLocation?
    let diagnostics: [HistoryScanDiagnostic]
    let isComplete: Bool

    init(
        location: HistoryDirectSessionLocation?,
        diagnostics: [HistoryScanDiagnostic] = [],
        isComplete: Bool = true
    ) {
        self.location = location
        self.diagnostics = diagnostics
        self.isComplete = isComplete
    }
}

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

    /// Budget-aware inventory entry point used by the MCP history service. Implementations
    /// may pre-narrow exact workspace UUID/storage-directory scopes before opening indexes.
    func scanWorkspaces(matching workspace: String?) async throws -> HistoryInventoryScan
    func scanWorkspaces(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan

    /// Cache-bypassed budget-aware inventory used by the just-saved session fallback.
    func scanWorkspacesRefreshing(matching workspace: String?) async throws -> HistoryInventoryScan
    func scanWorkspacesRefreshing(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan

    /// Resolve an exact session file without hydrating the cross-workspace inventory.
    func locateSession(sessionID: UUID) async throws -> HistoryDirectSessionLookup
    func locateSession(
        sessionID: UUID,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryDirectSessionLookup

    /// Load the session name and transcript through the same signature-checked cache.
    func loadSessionForHistory(sessionID: UUID, workspaceDir: URL) async throws -> HistoryLoadedSession
    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryLoadedSession

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
    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> AgentTranscript

    /// Whether the session file for `record` has changed since its stored observed
    /// signature was recorded — i.e., persisted transcript-derived fields may be
    /// stale and should be recomputed from the live transcript.
    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL
    ) async -> Bool
    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> Bool
}

extension HistorySessionScanning {
    func scanWorkspaces(matching _: String?) async throws -> HistoryInventoryScan {
        try await HistoryInventoryScan(workspaces: scanAllWorkspaces())
    }

    func scanWorkspaces(
        matching workspace: String?,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try await scanWorkspaces(matching: workspace)
    }

    func scanWorkspacesRefreshing(matching _: String?) async throws -> HistoryInventoryScan {
        try await HistoryInventoryScan(workspaces: scanAllWorkspacesRefreshing())
    }

    func scanWorkspacesRefreshing(
        matching workspace: String?,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try await scanWorkspacesRefreshing(matching: workspace)
    }

    func locateSession(sessionID _: UUID) async throws -> HistoryDirectSessionLookup {
        HistoryDirectSessionLookup(location: nil)
    }

    func locateSession(
        sessionID: UUID,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryDirectSessionLookup {
        try await locateSession(sessionID: sessionID)
    }

    func loadSessionForHistory(sessionID: UUID, workspaceDir: URL) async throws -> HistoryLoadedSession {
        try await HistoryLoadedSession(
            name: nil,
            transcript: loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir)
        )
    }

    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryLoadedSession {
        try await loadSessionForHistory(sessionID: sessionID, workspaceDir: workspaceDir)
    }

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> AgentTranscript {
        try await loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir)
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> Bool {
        await transcriptDerivedFieldsAreStale(
            for: record,
            sessionID: sessionID,
            workspaceDir: workspaceDir
        )
    }
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
    case workBudgetExceeded(HistoryScanDiagnostic)

    var errorDescription: String? {
        switch self {
        case let .sessionFileNotFound(sessionID, workspaceDir):
            "Session file not found for \(sessionID) in \(workspaceDir.lastPathComponent)"
        case let .transcriptDecodingFailed(sessionID, underlying):
            "Failed to decode transcript for session \(sessionID): \(underlying)"
        case let .workBudgetExceeded(diagnostic):
            "History work budget exceeded during \(diagnostic.phase ?? diagnostic.kind.rawValue)"
        }
    }

    var scanDiagnostic: HistoryScanDiagnostic? {
        guard case let .workBudgetExceeded(diagnostic) = self else { return nil }
        return diagnostic
    }
}

actor HistoryInventoryScanGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var holderID: UUID?
    private var waiters: [Waiter] = []

    func acquire() async throws -> UUID {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if holderID == nil {
                    holderID = id
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            release(id)
            throw error
        }
        return id
    }

    func release(_ id: UUID) {
        guard holderID == id else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            holderID = next.id
            next.continuation.resume()
            return
        }
        holderID = nil
    }

    private func cancelWaiter(_ id: UUID) {
        if holderID == id { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func snapshotForTesting() -> (hasHolder: Bool, waiterCount: Int) {
        (holderID != nil, waiters.count)
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

    private struct InventoryCounters {
        var workspaces = 0
        var indexDecodes = 0
        var indexBytes: Int64 = 0
    }

    private enum ExactWorkspaceScope {
        case id(UUID)
        case directoryName(String)

        func matches(_ workspaceDir: URL) -> Bool {
            switch self {
            case let .id(id):
                WorkspaceDirectoryName.parse(workspaceDir.lastPathComponent).id == id
            case let .directoryName(name):
                workspaceDir.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    private struct InventoryPass {
        let scan: HistoryInventoryScan
        let completedDiscovery: Bool
    }

    private struct WorkspaceIdentityResolution {
        let identity: (name: String, id: UUID?)
        let diagnostic: HistoryScanDiagnostic?
    }

    private enum WorkspaceScanOutcome {
        case result(HistoryWorkspaceScanResult, InventoryCounters, [HistoryScanDiagnostic] = [])
        case stopped(HistoryScanDiagnostic, InventoryCounters)
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
            let estimatedByteCount: Int64
            var accessOrdinal: UInt64
        }

        var entries: [String: Entry]
        var estimatedByteCount: Int64
        var accessOrdinal: UInt64
    }

    /// Cached decode of a single session's transcript, invalidated when the session
    /// file's size or modification time changes. Bounds repeated decoding across
    /// iterative list/search/time queries that re-hydrate the same stub records.
    private struct TranscriptCacheEntry {
        let signature: FileSignature
        let sessionName: String?
        let transcript: AgentTranscript
        let byteCount: Int64
        let accessOrdinal: UInt64
    }

    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let inventoryBudget: HistoryInventoryBudget
    private let workspaceDirectoryProvider: (@Sendable (URL) throws -> [URL])?

    /// Base URL for application support. Defaults to ``MCPFilesystemIdentity.applicationSupportRootURL()``.
    /// Injectable for testing.
    private let applicationSupportRoot: URL
    private let scanCacheTTL: TimeInterval
    private var cachedScanResults: [HistoryWorkspaceScanResult]?
    private var cachedScanDiagnostics: [HistoryScanDiagnostic] = []
    private var cachedScanResultsAt: Date?
    private var indexScanCache: IndexScanCache?
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]
    private var transcriptCacheBytes: Int64 = 0
    private var transcriptCacheAccessOrdinal: UInt64 = 0
    private let inventoryScanGate = HistoryInventoryScanGate()
    /// Observability counters for focused cache, cold-shape, cancellation, and direct-ID tests.
    private(set) var transcriptDecodeCountForTesting: Int = 0
    private(set) var indexDecodeCountForTesting: Int = 0
    private(set) var workspaceInspectionCountForTesting: Int = 0
    private(set) var directSessionFileStatCountForTesting: Int = 0
    var indexScanCacheEntryCountForTesting: Int {
        indexScanCache?.entries.count ?? 0
    }

    var indexScanCacheBytesForTesting: Int64 {
        indexScanCache?.estimatedByteCount ?? 0
    }

    init(
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder(),
        applicationSupportRoot: URL? = nil,
        scanCacheTTL: TimeInterval = HistorySessionScanner.defaultScanCacheTTL,
        inventoryBudget: HistoryInventoryBudget = .default,
        workspaceDirectoryProvider: (@Sendable (URL) throws -> [URL])? = nil
    ) {
        self.fileManager = fileManager
        self.decoder = decoder
        self.applicationSupportRoot = applicationSupportRoot
            ?? MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fileManager)
        self.scanCacheTTL = scanCacheTTL
        self.inventoryBudget = inventoryBudget
        self.workspaceDirectoryProvider = workspaceDirectoryProvider
    }

    // MARK: - Workspace Discovery

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        try await scanWorkspaces(matching: nil, requestBudget: .standalone()).workspaces
    }

    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult] {
        try await scanWorkspacesRefreshing(matching: nil, requestBudget: .standalone()).workspaces
    }

    func scanWorkspacesRefreshing(matching workspace: String?) async throws -> HistoryInventoryScan {
        try await scanWorkspacesRefreshing(matching: workspace, requestBudget: .standalone())
    }

    func scanWorkspaces(matching workspace: String?) async throws -> HistoryInventoryScan {
        try await scanWorkspaces(matching: workspace, requestBudget: .standalone())
    }

    func scanWorkspacesRefreshing(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try await withInventoryScanGate {
            try await performInventoryScan(
                cacheDate: Date(),
                workspace: workspace,
                cacheCompletedFullScan: true,
                requestBudget: requestBudget
            )
        }
    }

    func scanWorkspaces(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        let now = Date()
        // A completed full inventory is authoritative for every workspace filter.
        if let cachedScanResults,
           let cachedScanResultsAt,
           now.timeIntervalSince(cachedScanResultsAt) < scanCacheTTL
        {
            return HistoryInventoryScan(
                workspaces: cachedScanResults,
                diagnostics: cachedScanDiagnostics
            )
        }

        return try await withInventoryScanGate {
            // Another caller may have populated the cache while this caller waited.
            if let cachedScanResults,
               let cachedScanResultsAt,
               now.timeIntervalSince(cachedScanResultsAt) < scanCacheTTL
            {
                return HistoryInventoryScan(
                    workspaces: cachedScanResults,
                    diagnostics: cachedScanDiagnostics
                )
            }
            return try await performInventoryScan(
                cacheDate: now,
                workspace: workspace,
                cacheCompletedFullScan: true,
                requestBudget: requestBudget
            )
        }
    }

    private func withInventoryScanGate<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let leaseID = try await inventoryScanGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await inventoryScanGate.release(leaseID)
            return result
        } catch {
            await inventoryScanGate.release(leaseID)
            throw error
        }
    }

    private func performInventoryScan(
        cacheDate: Date,
        workspace: String?,
        cacheCompletedFullScan: Bool,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_discovery") {
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }

        if let exactScope = exactWorkspaceScope(workspace) {
            let scopedPass = try await performInventoryPass(
                cacheDate: cacheDate,
                scope: exactScope,
                cacheCompletedFullScan: false,
                requestBudget: requestBudget
            )
            if !scopedPass.scan.workspaces.isEmpty
                || scopedPass.scan.isTruncated
                || !scopedPass.completedDiscovery
            {
                return scopedPass.scan
            }
            // Exact directory/UUID narrowing is only an optimization. A zero-result
            // pass must fall back to canonical workspace identity resolution under the
            // same absolute request deadline.
        }

        return try await performInventoryPass(
            cacheDate: cacheDate,
            scope: nil,
            cacheCompletedFullScan: cacheCompletedFullScan,
            requestBudget: requestBudget
        ).scan
    }

    private func performInventoryPass(
        cacheDate: Date,
        scope: ExactWorkspaceScope?,
        cacheCompletedFullScan: Bool,
        requestBudget: HistoryRequestBudget
    ) async throws -> InventoryPass {
        let workspacesRoot = applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_discovery") {
            return InventoryPass(
                scan: HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic]),
                completedDiscovery: false
            )
        }
        guard directoryExists(at: workspacesRoot) || workspaceDirectoryProvider != nil else {
            if cacheCompletedFullScan {
                cachedScanResults = []
                cachedScanDiagnostics = []
                cachedScanResultsAt = cacheDate
            }
            return InventoryPass(scan: HistoryInventoryScan(workspaces: []), completedDiscovery: true)
        }

        var seenIndexCacheKeys = Set<String>()
        var counters = InventoryCounters()
        var results: [HistoryWorkspaceScanResult] = []
        var diagnostics: [HistoryScanDiagnostic] = []
        results.reserveCapacity(min(256, inventoryBudget.maxWorkspaces))
        var completedDiscovery = true

        func visit(_ workspaceDir: URL) async throws -> Bool {
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_discovery") {
                diagnostics.append(diagnostic)
                completedDiscovery = false
                return false
            }
            let isDirectory = directoryExists(at: workspaceDir)
            let isInjectedVirtualDirectory = workspaceDirectoryProvider != nil
                && !fileManager.fileExists(atPath: workspaceDir.path)
            guard isDirectory || isInjectedVirtualDirectory else { return true }
            if let scope, !scope.matches(workspaceDir) {
                return true
            }
            if counters.workspaces >= inventoryBudget.maxWorkspaces {
                diagnostics.append(HistoryScanDiagnostic(
                    kind: .workspaceCount,
                    limit: Int64(inventoryBudget.maxWorkspaces),
                    consumed: Int64(counters.workspaces),
                    unit: .workspaces,
                    phase: "workspace_scan"
                ))
                completedDiscovery = false
                return false
            }

            counters.workspaces += 1
            workspaceInspectionCountForTesting += 1

            switch try await scanWorkspace(
                workspaceDir,
                seenIndexCacheKeys: &seenIndexCacheKeys,
                counters: counters,
                requestBudget: requestBudget
            ) {
            case let .result(result, updatedCounters, workspaceDiagnostics):
                counters = updatedCounters
                results.append(result)
                diagnostics.append(contentsOf: workspaceDiagnostics)
            case let .stopped(diagnostic, updatedCounters):
                counters = updatedCounters
                diagnostics.append(diagnostic)
                completedDiscovery = false
                return false
            }
            if counters.workspaces.isMultiple(of: 16) {
                await Task.yield()
            }
            return true
        }

        do {
            if let workspaceDirectoryProvider {
                for workspaceDir in try workspaceDirectoryProvider(workspacesRoot) {
                    if try await visit(workspaceDir) == false { break }
                }
            } else if let enumerator = fileManager.enumerator(
                at: workspacesRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) {
                while let workspaceDir = enumerator.nextObject() as? URL {
                    if try await visit(workspaceDir) == false { break }
                }
            } else {
                diagnostics.append(HistoryScanDiagnostic(
                    kind: .workspaceDiscovery,
                    limit: 0,
                    consumed: Int64(counters.workspaces),
                    unit: .workspaces,
                    phase: "workspace_discovery"
                ))
                completedDiscovery = false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.append(HistoryScanDiagnostic(
                kind: .workspaceDiscovery,
                limit: 0,
                consumed: Int64(counters.workspaces),
                unit: .workspaces,
                phase: "workspace_discovery"
            ))
            completedDiscovery = false
        }

        try Task.checkCancellation()
        if diagnostics.isEmpty,
           let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_discovery")
        {
            diagnostics.append(diagnostic)
            completedDiscovery = false
        }
        let completed = completedDiscovery
        if completed, cacheCompletedFullScan {
            pruneIndexScanCache(keeping: seenIndexCacheKeys)
            cachedScanResults = results
            cachedScanDiagnostics = diagnostics
            cachedScanResultsAt = cacheDate
        }
        return InventoryPass(
            scan: HistoryInventoryScan(workspaces: results, diagnostics: diagnostics),
            completedDiscovery: completedDiscovery
        )
    }

    private func exactWorkspaceScope(_ workspace: String?) -> ExactWorkspaceScope? {
        guard let workspace = workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty else {
            return nil
        }
        if let id = UUID(uuidString: workspace) { return .id(id) }
        if workspace.lowercased().hasPrefix("workspace-") { return .directoryName(workspace) }
        return nil
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

    // MARK: - Direct Session Resolution

    func locateSession(sessionID: UUID) async throws -> HistoryDirectSessionLookup {
        try await locateSession(sessionID: sessionID, requestBudget: .standalone())
    }

    func locateSession(
        sessionID: UUID,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryDirectSessionLookup {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "direct_session_lookup") {
            return HistoryDirectSessionLookup(location: nil, diagnostics: [diagnostic], isComplete: false)
        }
        let now = Date()
        if let cachedScanResults,
           let cachedScanResultsAt,
           now.timeIntervalSince(cachedScanResultsAt) < scanCacheTTL,
           let cached = filteredRecord(sessionID: sessionID, in: cachedScanResults)
        {
            return HistoryDirectSessionLookup(location: HistoryDirectSessionLocation(
                record: cached.record,
                workspaceName: cached.workspaceName,
                workspaceDir: cached.workspaceDir
            ))
        }

        let workspacesRoot = applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let filename = "AgentSession-\(sessionID.uuidString).json"
        var inspected = 0

        func inspect(_ workspaceDir: URL) async throws -> HistoryDirectSessionLocation? {
            try Task.checkCancellation()
            if requestBudget.elapsedDiagnostic(phase: "direct_session_lookup") != nil {
                return nil
            }
            inspected += 1
            directSessionFileStatCountForTesting += 1

            let sessionFile = workspaceDir
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent(filename)
            guard fileSignature(for: sessionFile) != nil else {
                if inspected.isMultiple(of: 32) { await Task.yield() }
                return nil
            }

            try Task.checkCancellation()
            let indexFile = workspaceDir
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent("AgentSessionIndex.json")
            let cacheKey = indexScanCacheKey(for: indexFile)
            let cachedEntry = indexScanCache?.entries[cacheKey]
            let cachedRecord = cachedEntry?.records.first { $0.id == sessionID }
            let identity: (name: String, id: UUID?)
            if let cachedEntry {
                identity = (name: cachedEntry.workspaceName, id: cachedEntry.workspaceID)
                touchCachedIndexScan(cacheKey)
            } else {
                identity = try await resolveWorkspaceNameAndID(
                    from: workspaceDir,
                    dirName: workspaceDir.lastPathComponent,
                    requestBudget: requestBudget
                ).identity
            }
            try Task.checkCancellation()
            return HistoryDirectSessionLocation(
                record: cachedRecord,
                workspaceName: identity.name,
                workspaceDir: workspaceDir
            )
        }

        do {
            if let workspaceDirectoryProvider {
                for workspaceDir in try workspaceDirectoryProvider(workspacesRoot) {
                    if let location = try await inspect(workspaceDir) {
                        return HistoryDirectSessionLookup(location: location)
                    }
                    if let diagnostic = requestBudget.elapsedDiagnostic(phase: "direct_session_lookup") {
                        return HistoryDirectSessionLookup(
                            location: nil,
                            diagnostics: [diagnostic],
                            isComplete: false
                        )
                    }
                }
            } else if let enumerator = fileManager.enumerator(
                at: workspacesRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) {
                while let workspaceDir = enumerator.nextObject() as? URL {
                    if let location = try await inspect(workspaceDir) {
                        return HistoryDirectSessionLookup(location: location)
                    }
                    if let diagnostic = requestBudget.elapsedDiagnostic(phase: "direct_session_lookup") {
                        return HistoryDirectSessionLookup(
                            location: nil,
                            diagnostics: [diagnostic],
                            isComplete: false
                        )
                    }
                }
            } else if directoryExists(at: workspacesRoot) {
                return HistoryDirectSessionLookup(
                    location: nil,
                    diagnostics: [HistoryScanDiagnostic(
                        kind: .workspaceDiscovery,
                        limit: 0,
                        consumed: Int64(inspected),
                        unit: .workspaces,
                        phase: "direct_session_lookup"
                    )],
                    isComplete: false
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HistorySessionScannerError {
            if let diagnostic = error.scanDiagnostic {
                return HistoryDirectSessionLookup(location: nil, diagnostics: [diagnostic], isComplete: false)
            }
            return HistoryDirectSessionLookup(location: nil, diagnostics: [HistoryScanDiagnostic(
                kind: .workspaceDiscovery,
                limit: 0,
                consumed: Int64(inspected),
                unit: .workspaces,
                phase: "direct_session_lookup"
            )], isComplete: false)
        } catch {
            return HistoryDirectSessionLookup(
                location: nil,
                diagnostics: [HistoryScanDiagnostic(
                    kind: .workspaceDiscovery,
                    limit: 0,
                    consumed: Int64(inspected),
                    unit: .workspaces,
                    phase: "direct_session_lookup"
                )],
                isComplete: false
            )
        }
        return HistoryDirectSessionLookup(location: nil)
    }

    private func filteredRecord(
        sessionID: UUID,
        in scanResults: [HistoryWorkspaceScanResult]
    ) -> HistoryFilteredSessionRecord? {
        for scan in scanResults {
            if let record = scan.records.first(where: { $0.id == sessionID }) {
                return HistoryFilteredSessionRecord(
                    record: record,
                    workspaceName: scan.workspaceName,
                    workspaceDir: scan.workspaceDir
                )
            }
        }
        return nil
    }

    // MARK: - Transcript Loading

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript {
        try await loadTranscriptForSearch(
            sessionID: sessionID,
            workspaceDir: workspaceDir,
            requestBudget: .standalone()
        )
    }

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> AgentTranscript {
        try await loadSessionForHistory(
            sessionID: sessionID,
            workspaceDir: workspaceDir,
            requestBudget: requestBudget
        ).transcript
    }

    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> HistoryLoadedSession {
        try await loadSessionForHistory(
            sessionID: sessionID,
            workspaceDir: workspaceDir,
            requestBudget: .standalone()
        )
    }

    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryLoadedSession {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_stat") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let filename = "AgentSession-\(sessionID.uuidString).json"
        let sessionFile = agentSessionsDir.appendingPathComponent(filename)
        let cacheKey = sessionFile.standardizedFileURL.path

        guard let signature = fileSignature(for: sessionFile) else {
            removeTranscriptCacheEntry(cacheKey)
            throw HistorySessionScannerError.sessionFileNotFound(
                sessionID: sessionID,
                workspaceDir: workspaceDir
            )
        }

        if let cached = transcriptCache[cacheKey], cached.signature == signature {
            transcriptCacheAccessOrdinal &+= 1
            transcriptCache[cacheKey] = TranscriptCacheEntry(
                signature: cached.signature,
                sessionName: cached.sessionName,
                transcript: cached.transcript,
                byteCount: cached.byteCount,
                accessOrdinal: transcriptCacheAccessOrdinal
            )
            return HistoryLoadedSession(name: cached.sessionName, transcript: cached.transcript)
        }

        let effectiveFileLimit = min(
            requestBudget.maxTranscriptFileBytes,
            inventoryBudget.maxTranscriptFileBytes
        )
        if signature.fileSize > effectiveFileLimit {
            throw HistorySessionScannerError.workBudgetExceeded(HistoryScanDiagnostic(
                kind: .transcriptFileBytes,
                limit: effectiveFileLimit,
                consumed: signature.fileSize,
                unit: .bytes,
                retryable: false,
                phase: "transcript_read"
            ))
        }
        if let diagnostic = requestBudget.reserveRead(
            signature.fileSize,
            kind: .transcript,
            phase: "transcript_read"
        ) {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }

        do {
            let data = try Data(contentsOf: sessionFile, options: .mappedIfSafe)
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_read") {
                throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
            }
            if case let .insufficient(diagnostic) = requestBudget.remainingTimeDecision(
                minimumRemaining: minimumTranscriptDecodeRemaining(for: Int64(data.count)),
                phase: "transcript_decode"
            ) {
                throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
            }
            transcriptDecodeCountForTesting += 1
            // JSONDecoder is synchronous, so cancellation is checked immediately before
            // and after the single bounded-by-file decode rather than being silently lost.
            let session = try decoder.decode(AgentSession.self, from: data)
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_decode") {
                throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
            }
            let transcript = session.transcript ?? .empty
            insertTranscriptCacheEntry(
                cacheKey,
                signature: signature,
                sessionName: session.name,
                transcript: transcript,
                byteCount: Int64(data.count)
            )
            return HistoryLoadedSession(name: session.name, transcript: transcript)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HistorySessionScannerError {
            removeTranscriptCacheEntry(cacheKey)
            throw error
        } catch {
            removeTranscriptCacheEntry(cacheKey)
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
        await (try? transcriptDerivedFieldsAreStale(
            for: record,
            sessionID: sessionID,
            workspaceDir: workspaceDir,
            requestBudget: .standalone()
        )) ?? true
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> Bool {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_stat") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
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

    private func removeTranscriptCacheEntry(_ key: String) {
        guard let removed = transcriptCache.removeValue(forKey: key) else { return }
        transcriptCacheBytes = max(0, transcriptCacheBytes - removed.byteCount)
    }

    private func insertTranscriptCacheEntry(
        _ key: String,
        signature: FileSignature,
        sessionName: String?,
        transcript: AgentTranscript,
        byteCount: Int64
    ) {
        removeTranscriptCacheEntry(key)
        transcriptCacheAccessOrdinal &+= 1
        let normalizedBytes = max(0, byteCount)
        transcriptCache[key] = TranscriptCacheEntry(
            signature: signature,
            sessionName: sessionName,
            transcript: transcript,
            byteCount: normalizedBytes,
            accessOrdinal: transcriptCacheAccessOrdinal
        )
        transcriptCacheBytes += normalizedBytes

        while transcriptCacheBytes > inventoryBudget.maxTranscriptCacheBytes,
              let evictionKey = transcriptCache.min(by: { lhs, rhs in
                  if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                      return lhs.value.accessOrdinal < rhs.value.accessOrdinal
                  }
                  return lhs.key < rhs.key
              })?.key
        {
            removeTranscriptCacheEntry(evictionKey)
        }
    }

    private func scanWorkspace(
        _ workspaceDir: URL,
        seenIndexCacheKeys: inout Set<String>,
        counters: InventoryCounters,
        requestBudget: HistoryRequestBudget
    ) async throws -> WorkspaceScanOutcome {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "index_stat") {
            return .stopped(diagnostic, counters)
        }
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

        // A single exact index stat replaces the former AgentSessions-directory stat
        // followed by an index stat. Missing directories and missing indexes retain the
        // same empty-workspace result.
        let indexFile = workspaceDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSessionIndex.json")
        guard let indexSignature = fileSignature(for: indexFile) else {
            return .result(result(), counters)
        }
        try Task.checkCancellation()

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
            return .result(cachedResult, counters)
        }

        if counters.indexDecodes >= inventoryBudget.maxIndexDecodes {
            return .stopped(HistoryScanDiagnostic(
                kind: .indexCount,
                limit: Int64(inventoryBudget.maxIndexDecodes),
                consumed: Int64(counters.indexDecodes),
                unit: .indexes,
                phase: "index_decode"
            ), counters)
        }
        let indexBytes = max(0, indexSignature.fileSize)
        let effectiveFileLimit = min(requestBudget.maxIndexFileBytes, inventoryBudget.maxIndexFileBytes)
        if indexBytes > effectiveFileLimit {
            return .result(result(indexReadFailed: true), counters, [HistoryScanDiagnostic(
                kind: .indexFileBytes,
                limit: effectiveFileLimit,
                consumed: indexBytes,
                unit: .bytes,
                retryable: false,
                phase: "index_read"
            )])
        }
        if indexBytes > inventoryBudget.maxIndexBytes - counters.indexBytes {
            return .stopped(HistoryScanDiagnostic(
                kind: .indexBytes,
                limit: inventoryBudget.maxIndexBytes,
                consumed: counters.indexBytes,
                unit: .bytes,
                phase: "index_read"
            ), counters)
        }
        if let diagnostic = requestBudget.reserveRead(indexBytes, kind: .index, phase: "index_read") {
            return .stopped(diagnostic, counters)
        }

        var updatedCounters = counters
        updatedCounters.indexDecodes += 1
        updatedCounters.indexBytes += indexBytes
        indexDecodeCountForTesting += 1

        do {
            let data = try Data(contentsOf: indexFile, options: .mappedIfSafe)
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "index_read") {
                return .stopped(diagnostic, updatedCounters)
            }
            guard let schemaVersion = schemaVersionSniff(from: data) else {
                removeCachedIndexScan(cacheKey)
                return .result(result(indexReadFailed: true), updatedCounters, [HistoryScanDiagnostic(
                    kind: .indexReadFailure,
                    limit: 1,
                    consumed: 1,
                    unit: .indexes,
                    retryable: false,
                    phase: "index_decode"
                )])
            }

            let identityResolution = try await resolveWorkspaceNameAndID(
                from: workspaceDir,
                dirName: dirName,
                requestBudget: requestBudget
            )
            let identity = identityResolution.identity
            let identityDiagnostics = identityResolution.diagnostic.map { [$0] } ?? []
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_identity") {
                return .stopped(diagnostic, updatedCounters)
            }
            guard schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                rememberIndexScan(
                    cacheKey,
                    indexSignature: indexSignature,
                    workspaceSignature: workspaceSignature,
                    identity: identity,
                    indexSchemaVersion: schemaVersion,
                    records: [],
                    estimatedByteCount: indexBytes
                )
                return .result(
                    result(indexSchemaVersion: schemaVersion, identity: identity),
                    updatedCounters,
                    identityDiagnostics
                )
            }

            if case let .insufficient(diagnostic) = requestBudget.remainingTimeDecision(
                minimumRemaining: minimumTranscriptDecodeRemaining(for: indexBytes),
                phase: "index_decode"
            ) {
                return .stopped(diagnostic, updatedCounters)
            }
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "index_decode") {
                return .stopped(diagnostic, updatedCounters)
            }
            rememberIndexScan(
                cacheKey,
                indexSignature: indexSignature,
                workspaceSignature: workspaceSignature,
                identity: identity,
                indexSchemaVersion: nil,
                records: index.entries,
                estimatedByteCount: indexBytes
            )
            return .result(result(records: index.entries, identity: identity), updatedCounters, identityDiagnostics)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HistorySessionScannerError {
            if let diagnostic = error.scanDiagnostic {
                return .stopped(diagnostic, updatedCounters)
            }
            removeCachedIndexScan(cacheKey)
            return .result(result(indexReadFailed: true), updatedCounters, [HistoryScanDiagnostic(
                kind: .indexReadFailure,
                limit: 1,
                consumed: 1,
                unit: .indexes,
                retryable: true,
                phase: "index_read"
            )])
        } catch is DecodingError {
            removeCachedIndexScan(cacheKey)
            return .result(result(indexReadFailed: true), updatedCounters, [HistoryScanDiagnostic(
                kind: .indexReadFailure,
                limit: 1,
                consumed: 1,
                unit: .indexes,
                retryable: false,
                phase: "index_decode"
            )])
        } catch {
            removeCachedIndexScan(cacheKey)
            return .result(result(indexReadFailed: true), updatedCounters, [HistoryScanDiagnostic(
                kind: .indexReadFailure,
                limit: 1,
                consumed: 1,
                unit: .indexes,
                retryable: true,
                phase: "index_read"
            )])
        }
    }

    private func pruneIndexScanCache(keeping liveKeys: Set<String>) {
        guard var cache = indexScanCache else { return }
        let originalCount = cache.entries.count
        cache.entries = cache.entries.filter { liveKeys.contains($0.key) }
        if cache.entries.count != originalCount {
            cache.estimatedByteCount = cache.entries.values.reduce(0) { $0 + $1.estimatedByteCount }
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

        touchCachedIndexScan(cacheKey)

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
        records: [AgentSessionMetadataRecord],
        estimatedByteCount: Int64
    ) {
        var cache = indexScanCache ?? IndexScanCache(
            entries: [:],
            estimatedByteCount: 0,
            accessOrdinal: 0
        )
        cache.accessOrdinal &+= 1
        let normalizedBytes = max(0, estimatedByteCount)
        let entry = IndexScanCache.Entry(
            indexSignature: indexSignature,
            workspaceSignature: workspaceSignature,
            readerSchemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            workspaceName: identity.name,
            workspaceID: identity.id,
            indexSchemaVersion: indexSchemaVersion,
            records: records,
            estimatedByteCount: normalizedBytes,
            accessOrdinal: cache.accessOrdinal
        )
        if let replaced = cache.entries.updateValue(entry, forKey: cacheKey) {
            cache.estimatedByteCount -= replaced.estimatedByteCount
        }
        cache.estimatedByteCount += normalizedBytes
        while cache.entries.count > inventoryBudget.maxIndexCacheEntries
            || cache.estimatedByteCount > inventoryBudget.maxIndexCacheBytes
        {
            guard let evictionKey = cache.entries.min(by: { lhs, rhs in
                if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                    return lhs.value.accessOrdinal < rhs.value.accessOrdinal
                }
                return lhs.key < rhs.key
            })?.key,
                let removed = cache.entries.removeValue(forKey: evictionKey)
            else { break }
            cache.estimatedByteCount = max(0, cache.estimatedByteCount - removed.estimatedByteCount)
        }
        indexScanCache = cache
    }

    private func touchCachedIndexScan(_ cacheKey: String) {
        guard var cache = indexScanCache, var entry = cache.entries[cacheKey] else { return }
        cache.accessOrdinal &+= 1
        entry.accessOrdinal = cache.accessOrdinal
        cache.entries[cacheKey] = entry
        indexScanCache = cache
    }

    private func removeCachedIndexScan(_ cacheKey: String) {
        guard var cache = indexScanCache, let removed = cache.entries.removeValue(forKey: cacheKey) else { return }
        cache.estimatedByteCount = max(0, cache.estimatedByteCount - removed.estimatedByteCount)
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

    private nonisolated func minimumTranscriptDecodeRemaining(for bytes: Int64) -> Duration {
        let boundedMilliseconds = min(2000, 50 + max(0, bytes) / (64 * 1024))
        return .milliseconds(boundedMilliseconds)
    }

    /// Resolve workspace name and ID from the directory. The optional workspace.json
    /// optimization is size/deadline bounded; an unusable file falls back to the
    /// storage-directory identity with a typed diagnostic.
    private func resolveWorkspaceNameAndID(
        from workspaceDir: URL,
        dirName: String,
        requestBudget: HistoryRequestBudget
    ) async throws -> WorkspaceIdentityResolution {
        let fallback = WorkspaceDirectoryName.parse(dirName)
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_metadata_stat") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
        let workspaceJSON = workspaceDir.appendingPathComponent("workspace.json")
        guard let signature = fileSignature(for: workspaceJSON) else {
            return WorkspaceIdentityResolution(identity: fallback, diagnostic: nil)
        }
        if signature.fileSize > inventoryBudget.maxWorkspaceMetadataFileBytes {
            return WorkspaceIdentityResolution(
                identity: fallback,
                diagnostic: HistoryScanDiagnostic(
                    kind: .workspaceMetadataFileBytes,
                    limit: inventoryBudget.maxWorkspaceMetadataFileBytes,
                    consumed: signature.fileSize,
                    unit: .bytes,
                    retryable: false,
                    phase: "workspace_metadata_read"
                )
            )
        }
        do {
            let data = try Data(contentsOf: workspaceJSON, options: .mappedIfSafe)
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_metadata_read") {
                throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String
            else {
                return WorkspaceIdentityResolution(
                    identity: fallback,
                    diagnostic: HistoryScanDiagnostic(
                        kind: .workspaceMetadataReadFailure,
                        limit: 1,
                        consumed: 1,
                        unit: .workspaces,
                        retryable: false,
                        phase: "workspace_metadata_decode"
                    )
                )
            }
            let id = (json["id"] as? String).flatMap { UUID(uuidString: $0) }
            return WorkspaceIdentityResolution(identity: (name: name, id: id), diagnostic: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HistorySessionScannerError {
            throw error
        } catch {
            return WorkspaceIdentityResolution(
                identity: fallback,
                diagnostic: HistoryScanDiagnostic(
                    kind: .workspaceMetadataReadFailure,
                    limit: 1,
                    consumed: 1,
                    unit: .workspaces,
                    phase: "workspace_metadata_read"
                )
            )
        }
    }
}
