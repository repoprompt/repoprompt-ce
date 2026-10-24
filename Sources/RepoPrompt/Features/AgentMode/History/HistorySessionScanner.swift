import Darwin
import Foundation
import RepoPromptFileSystem
import RepoPromptShared

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

struct HistoryLoadedSession {
    let name: String?
    let transcript: AgentTranscript
    let providerTokenUsageByTurn: [AgentTokenUsagePersist]
    let codexLastTotalTokens: Int?
    let codexTotalTotalTokens: Int?

    init(
        name: String?,
        transcript: AgentTranscript,
        providerTokenUsageByTurn: [AgentTokenUsagePersist] = [],
        codexLastTotalTokens: Int? = nil,
        codexTotalTotalTokens: Int? = nil
    ) {
        self.name = name
        self.transcript = transcript
        self.providerTokenUsageByTurn = providerTokenUsageByTurn
        self.codexLastTotalTokens = codexLastTotalTokens
        self.codexTotalTotalTokens = codexTotalTotalTokens
    }
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
    /// Owner evidence travels with selected rows, independent of scanner cache eviction.
    var registeredLocation: HistoryWorkspaceLocation?
    var quarantinedFileCount: Int = 0
}

/// A metadata record paired with its workspace context, ready for filtering.
struct HistoryFilteredSessionRecord: Equatable {
    let record: AgentSessionMetadataRecord
    let workspaceName: String
    let workspaceDir: URL
    var registeredLocation: HistoryWorkspaceLocation?

    var sessionID: UUID {
        record.id
    }
}

// MARK: - Scanner Errors

enum HistorySessionScannerError: Error, Equatable, LocalizedError {
    case sessionFileNotFound(sessionID: UUID, workspaceDir: URL)
    case transcriptDecodingFailed(sessionID: UUID, underlying: String)
    /// The session path or decoded identity is outside history authority (symlinked/non-regular
    /// component, or embedded session ID differs from the requested ID). Never retryable.
    case sessionAuthorityViolation(sessionID: UUID, reason: String)
    case workBudgetExceeded(HistoryScanDiagnostic)

    var errorDescription: String? {
        switch self {
        case let .sessionFileNotFound(sessionID, workspaceDir):
            "Session file not found for \(sessionID) in \(workspaceDir.lastPathComponent)"
        case let .transcriptDecodingFailed(sessionID, underlying):
            "Failed to decode transcript for session \(sessionID): \(underlying)"
        case let .sessionAuthorityViolation(sessionID, reason):
            "Session file for \(sessionID) failed history authority checks: \(reason)"
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
/// Uses the compiled build-flavor application-state root as the base path and discovers
/// workspaces under `Workspaces/*/`. Each workspace directory is expected to contain an
/// `AgentSessions/AgentSessionIndex.json` file.
actor HistorySessionScanner: HistorySessionScanning {
    private static let defaultScanCacheTTL: TimeInterval = 90

    struct FileSignature: Equatable {
        let fileSize: Int64
        let modificationTime: TimeInterval
    }

    private enum HistoryPathAuthorization {
        case authorized(FileSignature)
        case missing
        case rejected(String)
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
            let quarantinedFileCount: Int
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
        let workspaceID: UUID?
        let transcript: AgentTranscript
        let providerTokenUsageByTurn: [AgentTokenUsagePersist]
        let codexLastTotalTokens: Int?
        let codexTotalTotalTokens: Int?
        let byteCount: Int64
        let accessOrdinal: UInt64
    }

    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let inventoryBudget: HistoryInventoryBudget
    private let workspaceDirectoryProvider: (@Sendable (URL) throws -> [URL])?
    private let workspaceLocations: HistoryWorkspaceLocationResolver?

    /// Base URL for application support. Defaults to the compiled build-flavor application-state root.
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
    private(set) var indexCacheEvictionVisitsForTesting: Int = 0
    private(set) var workspaceDirectoryStatCountForTesting: Int = 0
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
        workspaceDirectoryProvider: (@Sendable (URL) throws -> [URL])? = nil,
        workspaceLocations: HistoryWorkspaceLocationResolver? = nil
    ) {
        self.fileManager = fileManager
        self.decoder = decoder
        self.applicationSupportRoot = applicationSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MCPFilesystemConstants.identity.applicationStateDirectoryName, isDirectory: true)
        self.scanCacheTTL = scanCacheTTL
        self.inventoryBudget = inventoryBudget
        self.workspaceDirectoryProvider = workspaceDirectoryProvider
        self.workspaceLocations = workspaceLocations
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
        if let selected = try await scanRegisteredWorkspace(matching: workspace, requestBudget: requestBudget) {
            return selected
        }
        return try await withInventoryScanGate {
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
        if let selected = try await scanRegisteredWorkspace(matching: workspace, requestBudget: requestBudget) {
            return selected
        }
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

    /// A registered selection bypasses both the full-inventory cache and its root-scan gate.
    private func scanRegisteredWorkspace(
        matching workspace: String?, requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan? {
        guard let workspaceLocations, let raw = workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }
        let selector: HistoryWorkspaceSelector = UUID(uuidString: raw).map(HistoryWorkspaceSelector.id) ?? .exactName(raw)
        let selection = await workspaceLocations.resolve(selector)
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }
        let location: HistoryWorkspaceLocation
        switch selection {
        case let .matched(value): location = value
        case .notRegistered:
            if case .exactName = selector { return nil } // Preserve legacy partial-name discovery.
            return selectionFailure("not_registered", retryable: false)
        case .ambiguous: return selectionFailure("ambiguous", retryable: false)
        case .unavailable: return selectionFailure("unavailable")
        case .notReady: return selectionFailure("not_ready")
        }
        guard case .authorized = authorizeHistoryPath([], in: location.directory, location: location) else {
            return selectionFailure("location_unavailable")
        }
        workspaceInspectionCountForTesting += 1
        var seen: Set<String> = []
        var counters = InventoryCounters()
        counters.workspaces = 1
        let outcome = try await scanWorkspace(
            location.directory, seenIndexCacheKeys: &seen, counters: counters,
            requestBudget: requestBudget, location: location
        )
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }
        let current = await workspaceLocations.resolve(selector)
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }
        guard current == .matched(location) else { return selectionFailure("changed") }
        guard case .authorized = authorizeHistoryPath([], in: location.directory, location: location) else {
            return selectionFailure("location_unavailable")
        }
        switch outcome {
        case let .result(result, _, diagnostics):
            return HistoryInventoryScan(workspaces: [result], diagnostics: diagnostics)
        case let .stopped(diagnostic, _):
            return HistoryInventoryScan(workspaces: [], diagnostics: [diagnostic])
        }
    }

    private func selectionFailure(_ phase: String, retryable: Bool = true) -> HistoryInventoryScan {
        HistoryInventoryScan(workspaces: [], diagnostics: [selectionDiagnostic(phase, retryable: retryable)])
    }

    private func selectionDiagnostic(_ phase: String, retryable: Bool = true) -> HistoryScanDiagnostic {
        HistoryScanDiagnostic(
            kind: .workspaceDiscovery, limit: 1, consumed: 0, unit: .workspaces,
            retryable: retryable, phase: "workspace_selection_\(phase)"
        )
    }

    private func requireCurrentLocation(
        _ location: HistoryWorkspaceLocation?, requestBudget: HistoryRequestBudget
    ) async throws {
        guard let location else { return }
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
        guard let workspaceLocations else {
            throw HistorySessionScannerError.workBudgetExceeded(selectionDiagnostic("changed"))
        }
        let current = await workspaceLocations.resolve(.id(location.workspaceID))
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_selection") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
        guard current == .matched(location) else {
            throw HistorySessionScannerError.workBudgetExceeded(selectionDiagnostic("changed"))
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
            // Match the directory-derived selector before any filesystem authorization work.
            // The matching directory still passes the same no-symlink authority gate below.
            if let scope, !scope.matches(workspaceDir) { return true }
            workspaceDirectoryStatCountForTesting += 1
            let isDirectory = historyPathSignature([], in: workspaceDir) != nil
            let isInjectedVirtualDirectory = workspaceDirectoryProvider != nil
                && !fileManager.fileExists(atPath: workspaceDir.path)
            guard isDirectory || isInjectedVirtualDirectory else { return true }
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
            if let rawWorkspace = workspace {
                let workspace = rawWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    workspaceDir: scan.workspaceDir,
                    registeredLocation: scan.registeredLocation
                ))
            }
        }

        // A session may remain projected into more than one workspace index after a move,
        // restore, or consolidation. Session IDs are globally unique, so counting every
        // projection inflates time, turn, and tool totals. Retain the freshest projection;
        // callers still receive its owning workspace for exact transcript loading.
        var canonicalBySessionID: [UUID: HistoryFilteredSessionRecord] = [:]
        var orderedSessionIDs: [UUID] = []
        for candidate in results {
            guard let existing = canonicalBySessionID[candidate.record.id] else {
                canonicalBySessionID[candidate.record.id] = candidate
                orderedSessionIDs.append(candidate.record.id)
                continue
            }
            let candidateFreshness = candidate.record.observedFileModificationDate
                ?? candidate.record.lastIndexedAt
            let existingFreshness = existing.record.observedFileModificationDate
                ?? existing.record.lastIndexedAt
            if candidateFreshness > existingFreshness
                || (
                    candidateFreshness == existingFreshness
                        && candidate.record.savedAt > existing.record.savedAt
                )
            {
                canonicalBySessionID[candidate.record.id] = candidate
            }
        }
        return orderedSessionIDs.compactMap { canonicalBySessionID[$0] }
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

            // Symlinked/non-regular components are outside history authority: skip them.
            guard historyPathSignature(["AgentSessions", filename], in: workspaceDir) != nil else {
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
            // Stale-schema cache entries carry only the storage-directory identity.
            if let cachedEntry, cachedEntry.indexSchemaVersion == nil {
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
                    workspaceDir: scan.workspaceDir,
                    registeredLocation: scan.registeredLocation
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

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> AgentTranscript {
        try await loadSessionForHistory(
            sessionID: sessionID, workspaceDir: workspaceDir,
            requestBudget: requestBudget, workspaceLocation: workspaceLocation
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
        try await loadSessionForHistory(
            sessionID: sessionID, workspaceDir: workspaceDir,
            requestBudget: requestBudget, workspaceLocation: nil
        )
    }

    func loadSessionForHistory(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation location: HistoryWorkspaceLocation?
    ) async throws -> HistoryLoadedSession {
        try await requireCurrentLocation(location, requestBudget: requestBudget)
        let result = try await loadSessionAtAuthorizedLocation(
            sessionID: sessionID, workspaceDir: workspaceDir, requestBudget: requestBudget, location: location
        )
        try await requireCurrentLocation(location, requestBudget: requestBudget)
        return result
    }

    private func loadSessionAtAuthorizedLocation(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        location: HistoryWorkspaceLocation?
    ) async throws -> HistoryLoadedSession {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_stat") {
            throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
        }
        let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let filename = "AgentSession-\(sessionID.uuidString).json"
        let sessionFile = agentSessionsDir.appendingPathComponent(filename)
        let cacheKey = sessionFile.standardizedFileURL.path

        let signature: FileSignature
        switch authorizeHistoryPath(["AgentSessions", filename], in: workspaceDir, location: location) {
        case let .authorized(authorizedSignature):
            signature = authorizedSignature
        case .missing:
            removeTranscriptCacheEntry(cacheKey)
            throw HistorySessionScannerError.sessionFileNotFound(
                sessionID: sessionID,
                workspaceDir: workspaceDir
            )
        case let .rejected(reason):
            removeTranscriptCacheEntry(cacheKey)
            throw HistorySessionScannerError.sessionAuthorityViolation(sessionID: sessionID, reason: reason)
        }

        if let cached = transcriptCache[cacheKey], cached.signature == signature {
            try validateTranscriptWorkspace(cached.workspaceID, sessionID: sessionID, location: location)
            transcriptCacheAccessOrdinal &+= 1
            transcriptCache[cacheKey] = TranscriptCacheEntry(
                signature: cached.signature,
                sessionName: cached.sessionName,
                workspaceID: cached.workspaceID,
                transcript: cached.transcript,
                providerTokenUsageByTurn: cached.providerTokenUsageByTurn,
                codexLastTotalTokens: cached.codexLastTotalTokens,
                codexTotalTotalTokens: cached.codexTotalTotalTokens,
                byteCount: cached.byteCount,
                accessOrdinal: transcriptCacheAccessOrdinal
            )
            return HistoryLoadedSession(
                name: cached.sessionName,
                transcript: cached.transcript,
                providerTokenUsageByTurn: cached.providerTokenUsageByTurn,
                codexLastTotalTokens: cached.codexLastTotalTokens,
                codexTotalTotalTokens: cached.codexTotalTotalTokens
            )
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
            // A file copied under another session's filename must never be returned or
            // cached as the requested session.
            guard session.id == sessionID else {
                throw HistorySessionScannerError.sessionAuthorityViolation(
                    sessionID: sessionID,
                    reason: "embedded session id \(session.id) does not match the requested id"
                )
            }
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "transcript_decode") {
                throw HistorySessionScannerError.workBudgetExceeded(diagnostic)
            }
            try validateTranscriptWorkspace(session.workspaceID, sessionID: sessionID, location: location)
            let transcript = session.transcript ?? .empty
            insertTranscriptCacheEntry(
                cacheKey,
                signature: signature,
                sessionName: session.name,
                workspaceID: session.workspaceID,
                transcript: transcript,
                providerTokenUsageByTurn: session.providerTokenUsageByTurn,
                codexLastTotalTokens: session.codexLastTotalTokens,
                codexTotalTotalTokens: session.codexTotalTotalTokens,
                byteCount: Int64(data.count)
            )
            return HistoryLoadedSession(
                name: session.name,
                transcript: transcript,
                providerTokenUsageByTurn: session.providerTokenUsageByTurn,
                codexLastTotalTokens: session.codexLastTotalTokens,
                codexTotalTotalTokens: session.codexTotalTotalTokens
            )
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
        try await transcriptDerivedFieldsAreStale(
            for: record, sessionID: sessionID, workspaceDir: workspaceDir,
            requestBudget: requestBudget, workspaceLocation: nil
        )
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation location: HistoryWorkspaceLocation?
    ) async throws -> Bool {
        try await requireCurrentLocation(location, requestBudget: requestBudget)
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
        let current = historyPathSignature(
            ["AgentSessions", "AgentSession-\(sessionID.uuidString).json"],
            in: workspaceDir, location: location
        )
        try await requireCurrentLocation(location, requestBudget: requestBudget)
        guard let current else { return true }
        return current.fileSize != observedSize
            || current.modificationTime != observedMod.timeIntervalSinceReferenceDate
    }

    // MARK: - Private Helpers

    private func validateTranscriptWorkspace(
        _ embeddedWorkspaceID: UUID?, sessionID: UUID, location: HistoryWorkspaceLocation?
    ) throws {
        guard let location, let embeddedWorkspaceID, embeddedWorkspaceID != location.workspaceID else { return }
        throw HistorySessionScannerError.sessionAuthorityViolation(
            sessionID: sessionID, reason: "embedded workspace id does not match the selected workspace"
        )
    }

    private func removeTranscriptCacheEntry(_ key: String) {
        guard let removed = transcriptCache.removeValue(forKey: key) else { return }
        transcriptCacheBytes = max(0, transcriptCacheBytes - removed.byteCount)
    }

    private func insertTranscriptCacheEntry(
        _ key: String,
        signature: FileSignature,
        sessionName: String?,
        workspaceID: UUID?,
        transcript: AgentTranscript,
        providerTokenUsageByTurn: [AgentTokenUsagePersist],
        codexLastTotalTokens: Int?,
        codexTotalTotalTokens: Int?,
        byteCount: Int64
    ) {
        removeTranscriptCacheEntry(key)
        transcriptCacheAccessOrdinal &+= 1
        let normalizedBytes = max(0, byteCount)
        transcriptCache[key] = TranscriptCacheEntry(
            signature: signature,
            sessionName: sessionName,
            workspaceID: workspaceID,
            transcript: transcript,
            providerTokenUsageByTurn: providerTokenUsageByTurn,
            codexLastTotalTokens: codexLastTotalTokens,
            codexTotalTotalTokens: codexTotalTotalTokens,
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
        requestBudget: HistoryRequestBudget,
        location: HistoryWorkspaceLocation? = nil
    ) async throws -> WorkspaceScanOutcome {
        try Task.checkCancellation()
        if let diagnostic = requestBudget.elapsedDiagnostic(phase: "index_stat") {
            return .stopped(diagnostic, counters)
        }
        let dirName = workspaceDir.lastPathComponent
        let fallbackIdentity = location.map { (name: $0.name, id: Optional($0.workspaceID)) }
            ?? WorkspaceDirectoryName.parse(dirName)

        func result(
            records: [AgentSessionMetadataRecord] = [],
            indexReadFailed: Bool = false,
            indexSchemaVersion: Int? = nil,
            identity: (name: String, id: UUID?) = fallbackIdentity,
            quarantinedFileCount: Int = 0
        ) -> HistoryWorkspaceScanResult {
            HistoryWorkspaceScanResult(
                workspaceDir: workspaceDir,
                workspaceName: identity.name,
                workspaceID: identity.id,
                records: records,
                indexReadFailed: indexReadFailed,
                indexSchemaVersion: indexSchemaVersion,
                registeredLocation: location,
                quarantinedFileCount: quarantinedFileCount
            )
        }

        // A missing session-storage directory proves an empty workspace at this read. A missing
        // derivative index inside existing (or unreadable) storage proves nothing about sessions.
        // Inspect only that exact directory; discovery never enumerates transcript files to repair it.
        let indexFile = workspaceDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSessionIndex.json")
        let indexSignature: FileSignature
        switch authorizeHistoryPath(["AgentSessions", "AgentSessionIndex.json"], in: workspaceDir, location: location) {
        case let .authorized(signature):
            indexSignature = signature
        case .missing:
            if case .missing = authorizeHistoryPath(["AgentSessions"], in: workspaceDir, finalComponentIsDirectory: true, location: location) {
                return .result(result(), counters)
            }
            return .result(result(indexReadFailed: true), counters, [HistoryScanDiagnostic(
                kind: .indexReadFailure,
                limit: 1,
                consumed: 1,
                unit: .indexes,
                phase: "index_missing"
            )])
        case .rejected:
            return .result(result(indexReadFailed: true), counters, [HistoryScanDiagnostic(
                kind: .indexReadFailure,
                limit: 1,
                consumed: 1,
                unit: .indexes,
                retryable: false,
                phase: "index_authority"
            )])
        }
        try Task.checkCancellation()

        let cacheKey = indexScanCacheKey(for: indexFile)
        seenIndexCacheKeys.insert(cacheKey)
        let workspaceSignature = location == nil ? historyPathSignature(["workspace.json"], in: workspaceDir) : nil
        if let cachedResult = cachedScanResult(
            for: cacheKey,
            indexSignature: indexSignature,
            workspaceSignature: workspaceSignature,
            workspaceDir: workspaceDir
        ) {
            guard validIndexIdentity(cachedResult.records, location: location) else {
                return .result(result(indexReadFailed: true), counters, [indexIdentityDiagnostic()])
            }
            return .result(result(
                records: cachedResult.records, indexSchemaVersion: cachedResult.indexSchemaVersion,
                identity: location == nil ? (cachedResult.workspaceName, cachedResult.workspaceID) : fallbackIdentity,
                quarantinedFileCount: cachedResult.quarantinedFileCount
            ), counters, selectedQuarantineDiagnostics(cachedResult.quarantinedFileCount, location: location))
        }

        func indexCountDiagnostic(_ current: InventoryCounters) -> HistoryScanDiagnostic? {
            guard current.indexDecodes >= inventoryBudget.maxIndexDecodes else { return nil }
            return HistoryScanDiagnostic(
                kind: .indexCount,
                limit: Int64(inventoryBudget.maxIndexDecodes),
                consumed: Int64(current.indexDecodes),
                unit: .indexes,
                phase: "index_decode"
            )
        }

        // Stale-schema indexes are never decoded, so they must not consume the index
        // count/byte budgets or the workspace.json identity read ahead of usable ones.
        // A bounded head read answers the version question for the common writer layout
        // (`schemaVersion` first); an inconclusive head falls back to the full read below.
        let headSchemaVersion = headSchemaVersionSniff(of: indexFile)
        if let headSchemaVersion, headSchemaVersion != AgentSessionMetadataIndex.currentSchemaVersion {
            rememberStaleIndexScan(
                cacheKey,
                indexSignature: indexSignature,
                workspaceSignature: workspaceSignature,
                identity: fallbackIdentity,
                indexSchemaVersion: headSchemaVersion
            )
            return .result(result(indexSchemaVersion: headSchemaVersion), counters)
        }

        if headSchemaVersion != nil, let diagnostic = indexCountDiagnostic(counters) {
            return .stopped(diagnostic, counters)
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
        updatedCounters.indexBytes += indexBytes

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
            guard schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                rememberStaleIndexScan(
                    cacheKey,
                    indexSignature: indexSignature,
                    workspaceSignature: workspaceSignature,
                    identity: fallbackIdentity,
                    indexSchemaVersion: schemaVersion
                )
                return .result(result(indexSchemaVersion: schemaVersion), updatedCounters)
            }
            // The decode slot is charged only for current-schema indexes that will be decoded.
            if let diagnostic = indexCountDiagnostic(updatedCounters) {
                return .stopped(diagnostic, updatedCounters)
            }
            updatedCounters.indexDecodes += 1
            indexDecodeCountForTesting += 1

            let identityResolution: WorkspaceIdentityResolution = if location != nil {
                WorkspaceIdentityResolution(identity: fallbackIdentity, diagnostic: nil)
            } else {
                try await resolveWorkspaceNameAndID(
                    from: workspaceDir, dirName: dirName, requestBudget: requestBudget
                )
            }
            let identity = identityResolution.identity
            let identityDiagnostics = identityResolution.diagnostic.map { [$0] } ?? []
            try Task.checkCancellation()
            if let diagnostic = requestBudget.elapsedDiagnostic(phase: "workspace_identity") {
                return .stopped(diagnostic, updatedCounters)
            }

            if case let .insufficient(diagnostic) = requestBudget.remainingTimeDecision(
                minimumRemaining: minimumTranscriptDecodeRemaining(for: indexBytes),
                phase: "index_decode"
            ) {
                return .stopped(diagnostic, updatedCounters)
            }
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard validIndexIdentity(index.entries, location: location) else {
                return .result(result(indexReadFailed: true), updatedCounters, [indexIdentityDiagnostic()])
            }
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
                estimatedByteCount: indexBytes,
                quarantinedFileCount: index.quarantinedFiles.count
            )
            return .result(result(
                records: index.entries, identity: identity, quarantinedFileCount: index.quarantinedFiles.count
            ), updatedCounters, identityDiagnostics + selectedQuarantineDiagnostics(index.quarantinedFiles.count, location: location))
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
        indexScanCache = nil
        let originalCount = cache.entries.count
        cache.entries = cache.entries.filter { liveKeys.contains($0.key) }
        if cache.entries.count != originalCount {
            cache.estimatedByteCount = cache.entries.values.reduce(0) { $0 + $1.estimatedByteCount }
        }
        indexScanCache = cache
    }

    private func selectedQuarantineDiagnostics(_ count: Int, location: HistoryWorkspaceLocation?) -> [HistoryScanDiagnostic] {
        guard location != nil, count > 0 else { return [] }
        return [HistoryScanDiagnostic(
            kind: .indexReadFailure, limit: 1, consumed: 1, unit: .indexes,
            retryable: false, phase: "index_quarantined"
        )]
    }

    private func validIndexIdentity(_ records: [AgentSessionMetadataRecord], location: HistoryWorkspaceLocation?) -> Bool {
        guard let location else { return true }
        var seen: Set<UUID> = []
        return records.allSatisfy {
            ($0.workspaceID == nil || $0.workspaceID == location.workspaceID) && seen.insert($0.id).inserted
        }
    }

    private func indexIdentityDiagnostic() -> HistoryScanDiagnostic {
        HistoryScanDiagnostic(kind: .indexReadFailure, limit: 1, consumed: 1, unit: .indexes, retryable: false, phase: "index_identity")
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
            indexSchemaVersion: entry.indexSchemaVersion,
            quarantinedFileCount: entry.quarantinedFileCount
        )
    }

    func rememberIndexScan(
        _ cacheKey: String,
        indexSignature: FileSignature,
        workspaceSignature: FileSignature?,
        identity: (name: String, id: UUID?),
        indexSchemaVersion: Int?,
        records: [AgentSessionMetadataRecord],
        estimatedByteCount: Int64,
        quarantinedFileCount: Int = 0
    ) {
        var cache = indexScanCache ?? IndexScanCache(
            entries: [:],
            estimatedByteCount: 0,
            accessOrdinal: 0
        )
        // Transfer the actor-owned dictionary, rather than copying it on every insert.
        // There is no suspension while ownership is temporarily held by this local.
        indexScanCache = nil
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
            quarantinedFileCount: quarantinedFileCount,
            estimatedByteCount: normalizedBytes,
            accessOrdinal: cache.accessOrdinal
        )
        if let replaced = cache.entries.updateValue(entry, forKey: cacheKey) {
            cache.estimatedByteCount -= replaced.estimatedByteCount
        }
        cache.estimatedByteCount += normalizedBytes
        if cache.entries.count > inventoryBudget.maxIndexCacheEntries
            || cache.estimatedByteCount > inventoryBudget.maxIndexCacheBytes
        {
            // A cyclic history census must not run a full dictionary minimum for each
            // insertion. Sort scalar keys/ordinals once and evict to a low-water mark.
            // Bounds remain unchanged; the next overflow is amortized across new entries.
            let entryTarget = max(1, inventoryBudget.maxIndexCacheEntries * 3 / 4)
            let byteTarget = inventoryBudget.maxIndexCacheBytes - inventoryBudget.maxIndexCacheBytes / 4
            indexCacheEvictionVisitsForTesting += cache.entries.count
            let oldest = cache.entries.map { (key: $0.key, ordinal: $0.value.accessOrdinal) }
                .sorted {
                    $0.ordinal != $1.ordinal ? $0.ordinal < $1.ordinal : $0.key < $1.key
                }
            for candidate in oldest {
                guard cache.entries.count > entryTarget || cache.estimatedByteCount > byteTarget else { break }
                // Low water is an amortization target, not an admission cap. Retain the newest
                // index when it fits the hard cap, even if it alone exceeds the byte target.
                if candidate.key == cacheKey, normalizedBytes <= inventoryBudget.maxIndexCacheBytes { continue }
                guard let removed = cache.entries.removeValue(forKey: candidate.key) else { continue }
                cache.estimatedByteCount = max(0, cache.estimatedByteCount - removed.estimatedByteCount)
            }
        }
        indexScanCache = cache
    }

    private func touchCachedIndexScan(_ cacheKey: String) {
        guard var cache = indexScanCache, var entry = cache.entries[cacheKey] else { return }
        indexScanCache = nil
        cache.accessOrdinal &+= 1
        entry.accessOrdinal = cache.accessOrdinal
        cache.entries[cacheKey] = entry
        indexScanCache = cache
    }

    private func removeCachedIndexScan(_ cacheKey: String) {
        guard var cache = indexScanCache else { return }
        indexScanCache = nil
        if let removed = cache.entries.removeValue(forKey: cacheKey) {
            cache.estimatedByteCount = max(0, cache.estimatedByteCount - removed.estimatedByteCount)
        }
        indexScanCache = cache
    }

    /// Signature of an authorized history path, or nil when it is missing or rejected.
    private func historyPathSignature(
        _ components: [String], in workspaceDir: URL, location: HistoryWorkspaceLocation? = nil
    ) -> FileSignature? {
        guard case let .authorized(signature) = authorizeHistoryPath(components, in: workspaceDir, location: location) else {
            return nil
        }
        return signature
    }

    /// The single authority gate for every history read (workspace dirs, `AgentSessions`,
    /// indexes, `workspace.json`, session files). An owner-issued location may select a custom
    /// directory; the same component checks apply there. Only the saved Workspaces root is
    /// canonicalized, so a root that legitimately lives behind a symlink (`/var` →
    /// `/private/var`, a relocated storage root) keeps working. Every component below it is
    /// checked with `lstat`: the workspace dir and intermediate components must be real
    /// directories and the final component a regular file, never a symlink. An empty
    /// `components` authorizes the workspace directory itself.
    private func authorizeHistoryPath(
        _ components: [String], in workspaceDir: URL, finalComponentIsDirectory: Bool = false,
        location: HistoryWorkspaceLocation? = nil
    ) -> HistoryPathAuthorization {
        let name = workspaceDir.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !components.contains(where: { $0.contains("/") }) else {
            return .rejected("invalid history path component")
        }
        let workspacesRoot = applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let parent = workspaceDir.deletingLastPathComponent()
        if let location {
            // Directory hints can differ before and after creation without changing the path.
            // Compare file identity here; retain the supplied URL for the lstat checks below.
            guard workspaceDir.isFileURL, location.directory.isFileURL,
                  workspaceDir.host == location.directory.host,
                  workspaceDir.standardizedFileURL.path == location.directory.standardizedFileURL.path
            else {
                return .rejected("workspace directory does not match registered location")
            }
        } else if parent.standardizedFileURL.path != workspacesRoot.standardizedFileURL.path {
            guard let canonicalParent = Self.canonicalPath(parent) else { return .missing }
            guard canonicalParent == Self.canonicalPath(workspacesRoot) else {
                return .rejected("workspace directory is outside the saved Workspaces root")
            }
        }

        var current = workspaceDir
        var statResult = Darwin.stat()
        for (offset, component) in ([""] + components).enumerated() {
            if offset > 0 { current = current.appendingPathComponent(component) }
            let isFinal = offset == components.count
            let expectedType = isFinal && !components.isEmpty && !finalComponentIsDirectory ? S_IFREG : S_IFDIR
            let status = current.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return ENOENT }
                return lstat(path, &statResult) == 0 ? 0 : errno
            }
            if status == ENOENT || status == ENOTDIR { return .missing }
            guard status == 0 else { return .rejected("history path component could not be inspected") }
            let type = statResult.st_mode & S_IFMT
            if type == S_IFLNK { return .rejected("history path component is a symbolic link") }
            guard type == expectedType else {
                return .rejected("history path component has an unexpected file type")
            }
        }
        return .authorized(FileSignature(
            fileSize: Int64(statResult.st_size),
            modificationTime: Date(
                timeIntervalSince1970: TimeInterval(statResult.st_mtimespec.tv_sec)
                    + (TimeInterval(statResult.st_mtimespec.tv_nsec) / 1_000_000_000)
            ).timeIntervalSinceReferenceDate
        ))
    }

    private static func canonicalPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
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
        guard let signature = historyPathSignature(["workspace.json"], in: workspaceDir) else {
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
