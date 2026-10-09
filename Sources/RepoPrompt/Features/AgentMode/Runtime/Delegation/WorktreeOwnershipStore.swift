import Foundation

/// Who created a worktree under delegation, and whether it has been released for human cleanup.
///
/// Bindings only carry `source` and `boundAt`; this record is the durable answer to "which session,
/// under which scope, created this worktree, and is it stale?". It never authorizes anything and
/// never removes a worktree: removing or pruning worktrees stays human-only.
struct WorktreeOwnershipRecord: Codable, Equatable {
    let worktreeID: String
    var repositoryID: String?
    var path: String
    var repoRootPath: String?
    var branch: String?
    var createdBySessionID: UUID?
    var delegationScopeID: UUID?
    var createdAt: Date
    /// Set by `worktree_release` (unbind + mark stale). A released worktree no longer counts toward
    /// `maxWorktrees` and is flagged `released` in `worktree_inventory`.
    var releasedAt: Date?
    var releasedBySessionID: UUID?

    private enum CodingKeys: String, CodingKey {
        case worktreeID = "worktree_id"
        case repositoryID = "repository_id"
        case path
        case repoRootPath = "repo_root_path"
        case branch
        case createdBySessionID = "created_by_session_id"
        case delegationScopeID = "delegation_scope_id"
        case createdAt = "created_at"
        case releasedAt = "released_at"
        case releasedBySessionID = "released_by_session_id"
    }
}

struct WorktreeOwnershipDocument: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let worktrees: [WorktreeOwnershipRecord]
}

private struct WorktreeOwnershipDocumentHeader: Decodable {
    let version: Int
}

/// App-wide durable worktree ownership, beside `delegationScopes.json`:
/// `~/Library/Application Support/RepoPrompt CE/delegationWorktreeOwnership.json`.
///
/// Main-actor in-memory state with serialized write-through. Loading follows the delegation-scope
/// store's rules: a missing file starts empty, a malformed supported-version file is quarantined into
/// `Backups/`, and a future schema is preserved and blocks writes. Until app composition installs a
/// file (`bootstrap`), and for suppressed launches, state is kept in memory only.
@MainActor
final class WorktreeOwnershipStore {
    static let filename = "delegationWorktreeOwnership.json"
    /// Rows this store ever writes. Kept well below `maxDecodedRecords`, so a file this store wrote can
    /// never trip the decode guard and be quarantined.
    static let maxRecords = 4096
    /// Released (stale-marked) rows kept for cleanup visibility; the oldest are pruned first.
    static let maxReleasedRecords = 1024
    static let maxDecodedRecords = 8192
    static let maxFileByteCount = 4 * 1024 * 1024

    enum LoadState: Equatable {
        case unloaded
        case ready
        case blocked(String)
    }

    private(set) var records: [String: WorktreeOwnershipRecord] = [:]
    /// In-memory stores are `.ready` immediately; a file-backed store is `.unloaded` until loaded.
    private(set) var loadState: LoadState = .ready
    private var fileURL: URL?
    private var backupsDirectoryURL: URL?
    private let writer: @Sendable (Data, URL) throws -> Void
    private var persistChain: Task<Void, Never>?

    init(
        writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.writer = writer
    }

    // MARK: - Load

    /// Production location, beside `delegationScopes.json`. Suppressed launches stay in memory.
    func bootstrapProduction(mode: AgentSessionOversightPersistenceMode) async {
        guard mode.performsProductionFileIO,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
              .appendingPathComponent("RepoPrompt CE", isDirectory: true)
        else { return }
        await bootstrap(
            fileURL: base.appendingPathComponent(Self.filename),
            backupsDirectoryURL: base.appendingPathComponent(DelegationScopeStore.backupsDirectoryName, isDirectory: true)
        )
    }

    /// Installs the durable file once and loads it. Rows recorded before the load win.
    func bootstrap(fileURL: URL, backupsDirectoryURL: URL?) async {
        guard self.fileURL == nil else { return }
        self.fileURL = fileURL
        self.backupsDirectoryURL = backupsDirectoryURL
        loadState = .unloaded
        let backups = backupsDirectoryURL
        let result = await Task.detached { Self.read(fileURL: fileURL, backupsDirectoryURL: backups) }.value
        switch result {
        case let .loaded(rows):
            let preLoad = records
            records = Dictionary(rows.map { ($0.worktreeID, $0) }, uniquingKeysWith: { first, _ in first })
            for (worktreeID, pending) in preLoad {
                guard var stored = records[worktreeID] else {
                    records[worktreeID] = pending
                    continue
                }
                if pending.createdBySessionID != nil {
                    // A creation recorded this launch describes the current worktree.
                    stored = pending
                } else {
                    // A pre-load release mark is merged onto the durable ownership row, never lost.
                    stored.releasedAt = pending.releasedAt ?? stored.releasedAt
                    stored.releasedBySessionID = pending.releasedBySessionID ?? stored.releasedBySessionID
                }
                records[worktreeID] = stored
            }
            loadState = .ready
            if !preLoad.isEmpty { trimAndPersist() }
        case let .blocked(reason):
            loadState = .blocked(reason)
        }
    }

    private enum ReadResult {
        case loaded([WorktreeOwnershipRecord])
        case blocked(String)
    }

    private nonisolated static func read(fileURL: URL, backupsDirectoryURL: URL?) -> ReadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .loaded([]) }
        guard let data = try? Data(contentsOf: fileURL) else { return .blocked("unreadable") }
        guard data.count <= maxFileByteCount else { return .blocked("file_too_large") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let header = try? decoder.decode(WorktreeOwnershipDocumentHeader.self, from: data),
           header.version > WorktreeOwnershipDocument.currentVersion
        {
            return .blocked("unsupported_future_schema")
        }
        if let document = try? decoder.decode(WorktreeOwnershipDocument.self, from: data),
           document.worktrees.count <= maxDecodedRecords
        {
            return .loaded(document.worktrees)
        }
        // Malformed supported-version file: move it aside and start empty, or stay blocked.
        guard let backupsDirectoryURL else { return .blocked("unreadable") }
        try? fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let destination = backupsDirectoryURL.appendingPathComponent(
            "delegationWorktreeOwnership.corrupt.\(UUID().uuidString).json"
        )
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
            return .loaded([])
        } catch {
            return .blocked("unreadable")
        }
    }

    // MARK: - Queries

    func record(worktreeID: String) -> WorktreeOwnershipRecord? {
        records[worktreeID]
    }

    func records(createdBy sessionIDs: Set<UUID>) -> [WorktreeOwnershipRecord] {
        records.values
            .filter { $0.createdBySessionID.map(sessionIDs.contains) ?? false }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func ownedUnreleasedWorktreeIDs(createdBy sessionIDs: Set<UUID>) -> Set<String> {
        Set(records(createdBy: sessionIDs).filter { $0.releasedAt == nil }.map(\.worktreeID))
    }

    // MARK: - Mutation

    func recordCreation(
        _ info: SessionAdminWorktreeInfo,
        createdBySessionID: UUID,
        delegationScopeID: UUID,
        at date: Date
    ) {
        records[info.worktreeID] = WorktreeOwnershipRecord(
            worktreeID: info.worktreeID,
            repositoryID: info.repositoryID,
            path: info.path,
            repoRootPath: info.repoRootPath,
            branch: info.branch,
            createdBySessionID: createdBySessionID,
            delegationScopeID: delegationScopeID,
            createdAt: date
        )
        trimAndPersist()
    }

    /// Marks worktrees stale for human cleanup. Worktrees this store never saw are recorded with no
    /// creator so the stale mark still survives relaunch.
    func markReleased(
        _ worktrees: [AgentSessionWorktreeBindingSummary],
        bySessionID releasedBy: UUID,
        at date: Date
    ) {
        guard !worktrees.isEmpty else { return }
        for summary in worktrees {
            var row = records[summary.worktreeID] ?? WorktreeOwnershipRecord(
                worktreeID: summary.worktreeID,
                repositoryID: summary.repositoryID,
                path: summary.worktreeRootPath,
                repoRootPath: summary.logicalRootPath,
                branch: summary.branch,
                createdAt: summary.boundAt
            )
            row.releasedAt = row.releasedAt ?? date
            row.releasedBySessionID = row.releasedBySessionID ?? releasedBy
            records[summary.worktreeID] = row
        }
        trimAndPersist()
    }

    /// Waits for queued writes; tests and shutdown use this as a linearization point.
    func flushPersistence() async {
        await persistChain?.value
    }

    /// A worktree bound again is in use: its stale mark is cleared (a row that existed only for the
    /// mark is dropped).
    func clearReleased(worktreeID: String) {
        guard var row = records[worktreeID], row.releasedAt != nil else { return }
        if row.createdBySessionID == nil {
            records.removeValue(forKey: worktreeID)
        } else {
            row.releasedAt = nil
            row.releasedBySessionID = nil
            records[worktreeID] = row
        }
        persist()
    }

    private func trimAndPersist() {
        // Oldest released rows go first, then (only past the hard cap) the oldest owned rows: losing
        // a very old ownership row only makes `maxWorktrees` less strict for that worktree.
        let released = records.values.filter { $0.releasedAt != nil }
            .sorted { ($0.releasedAt ?? $0.createdAt) < ($1.releasedAt ?? $1.createdAt) }
        for row in released.prefix(max(0, released.count - Self.maxReleasedRecords)) {
            records.removeValue(forKey: row.worktreeID)
        }
        if records.count > Self.maxRecords {
            let oldest = records.values.sorted { $0.createdAt < $1.createdAt }
            for row in oldest.prefix(records.count - Self.maxRecords) {
                records.removeValue(forKey: row.worktreeID)
            }
        }
        persist()
    }

    private func persist() {
        guard let fileURL, loadState == .ready else { return }
        let document = WorktreeOwnershipDocument(
            version: WorktreeOwnershipDocument.currentVersion,
            worktrees: records.values.sorted { $0.worktreeID < $1.worktreeID }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return }
        let writer = writer
        let previous = persistChain
        persistChain = Task {
            await previous?.value
            await Task.detached { try? writer(data, fileURL) }.value
        }
    }
}
