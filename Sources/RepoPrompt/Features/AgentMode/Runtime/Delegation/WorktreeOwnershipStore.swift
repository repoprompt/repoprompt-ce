import Foundation
import RepoPromptPersistence

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

/// Live delegation provenance with asynchronous per-row, revision-checked continuity saving.
/// Legacy ownership sources are read-only. Saving can fail without invalidating current provenance;
/// no whole-file replacement, clean-shutdown marker, or arbitrary release-history pruning exists.
@MainActor
final class WorktreeOwnershipStore {
    static let filename = "delegationWorktreeOwnership.json"
    enum LoadState: Equatable { case unloaded, ready, blocked(String) }
    private(set) var records: [String: WorktreeOwnershipRecord] = [:]
    private(set) var loadState: LoadState = .ready
    private(set) var saveState = "not_persisted"
    private(set) var persistenceDiagnostic: String?
    private var repository: OverseerContinuityRepository?
    private let beforeCommit: @Sendable () throws -> Void
    private var savedRevisions: [String: Int64] = [:]
    private struct Pending {
        let id: UUID
        var row: WorktreeOwnershipRecord
        var mutation: OverseerContinuityMutation?
        var needsBaseline = false
    }

    private var pending: [Pending] = []
    private var rejectedOperations: [UUID: String] = [:]
    private var recoveryWarning: String?
    private var persistChain: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 1
    init(beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.beforeCommit = beforeCommit
    }

    func bootstrapProduction(mode: AgentSessionOversightPersistenceMode) async {
        guard mode.performsProductionFileIO else { return }
        let locations = OverseerContinuityRepository.production()
        await bootstrap(
            fileURL: locations.legacyDirectory.appendingPathComponent(Self.filename),
            backupsDirectoryURL: nil,
            databaseURL: locations.databaseURL,
            profile: locations.profile,
            legacyPolicy: locations.legacyFactsPolicy
        )
    }

    func bootstrap(
        fileURL: URL,
        backupsDirectoryURL _: URL?,
        databaseURL: URL? = nil,
        profile: String = "temporary-overseer",
        legacyPolicy: OverseerLegacyPolicy = .sameProfile
    ) async {
        guard repository == nil else { return }
        repository = OverseerContinuityRepository(
            databaseURL: databaseURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("Overseer/continuity.sqlite"),
            profile: profile,
            legacyURL: fileURL,
            kind: .worktree,
            mode: .enabled,
            legacyPolicy: legacyPolicy
        )
        await recover()
    }

    private func recover() async {
        guard let repository else { return }
        loadState = .unloaded
        do {
            let loaded = try await Task.detached { try repository.load() }.value
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var invalidIDs: [String] = []
            let validated = loaded.compactMap { saved -> (OverseerContinuityRow, WorktreeOwnershipRecord)? in
                do {
                    let row = try decoder.decode(WorktreeOwnershipRecord.self, from: saved.payload)
                    guard row.worktreeID == saved.id, row.createdBySessionID?.uuidString == saved.ownerID else { throw OverseerContinuityError.invalidRecord }
                    return (saved, row)
                } catch {
                    invalidIDs.append(saved.id)
                    return nil
                }
            }
            recoveryWarning = invalidIDs.isEmpty ? nil : "Invalid ownership entries remain preserved for recovery: \(invalidIDs.joined(separator: ", ")). Other valid ownership rows restore normally."
            for (saved, row) in validated {
                savedRevisions[row.worktreeID] = max(savedRevisions[row.worktreeID] ?? 0, saved.revision)
                // Existing current-process creation/release decisions always win over continuity.
                if records[row.worktreeID] == nil { records[row.worktreeID] = row }
                else if let live = records[row.worktreeID], live.createdBySessionID == nil, live.releasedAt != nil {
                    // A pre-load release knew the binding, not its creator. Preserve saved creator
                    // provenance while keeping the newer live release decision and current path.
                    var merged = row
                    merged.path = live.path
                    merged.releasedAt = live.releasedAt
                    merged.releasedBySessionID = live.releasedBySessionID
                    records[row.worktreeID] = merged
                    for index in pending.indices where pending[index].row.worktreeID == row.worktreeID && pending[index].row.createdBySessionID == nil {
                        pending[index].row = merged
                    }
                }
            }
            loadState = .ready
            persistenceDiagnostic = rejectedOperations.values.sorted().first ?? recoveryWarning ?? repository.diagnostic
            if pending.isEmpty { saveState = rejectedOperations.isEmpty ? "saved" : "failed" }
            persist()
        } catch {
            loadState = .blocked("Continuity open failed: \(error)")
            saveState = "failed"
            persistenceDiagnostic = "Worktree ownership saving is unavailable; current live provenance remains local and unsaved. Saving will retry: \(error)"
            scheduleRetry()
        }
    }

    func record(worktreeID: String) -> WorktreeOwnershipRecord? {
        records[worktreeID]
    }

    func records(createdBy sessionIDs: Set<UUID>) -> [WorktreeOwnershipRecord] {
        records.values.filter { $0.createdBySessionID.map(sessionIDs.contains) ?? false }.sorted { $0.createdAt < $1.createdAt }
    }

    func ownedUnreleasedWorktreeIDs(createdBy sessionIDs: Set<UUID>) -> Set<String> {
        Set(records(createdBy: sessionIDs).filter { $0.releasedAt == nil }.map(\.worktreeID))
    }

    func recordCreation(_ info: SessionAdminWorktreeInfo, createdBySessionID: UUID, delegationScopeID: UUID, at date: Date) {
        let row = WorktreeOwnershipRecord(
            worktreeID: info.worktreeID,
            repositoryID: info.repositoryID,
            path: info.path,
            repoRootPath: info.repoRootPath,
            branch: info.branch,
            createdBySessionID: createdBySessionID,
            delegationScopeID: delegationScopeID,
            createdAt: date
        )
        record(row)
    }

    func markReleased(_ worktrees: [AgentSessionWorktreeBindingSummary], bySessionID releasedBy: UUID, at date: Date) {
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
            record(row)
        }
    }

    func clearReleased(worktreeID: String) {
        guard var row = records[worktreeID], row.releasedAt != nil else { return }
        row.releasedAt = nil
        row.releasedBySessionID = nil
        record(row) // Keep history/identity; never arbitrarily prune terminal ownership records.
    }

    private func record(_ row: WorktreeOwnershipRecord) {
        records[row.worktreeID] = row
        pending.append(.init(id: UUID(), row: row))
        saveState = repository == nil ? "not_persisted" : "pending"
        persist()
    }

    private func persist() {
        guard persistChain == nil, loadState != .unloaded, let repository, !pending.isEmpty else { return }
        persistChain = Task { @MainActor [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                do {
                    if pending[0].needsBaseline, loadState == .ready {
                        let operation = pending[0].id, database = repository.database
                        let prior = try await Task.detached { try database.receipt(operationID: operation) }.value
                        if prior == nil { pending[0].mutation = nil }
                        pending[0].needsBaseline = false
                    }
                    let mutation: OverseerContinuityMutation
                    if let captured = pending[0].mutation { mutation = captured }
                    else {
                        let row = pending[0].row
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        mutation = try .put(.init(
                            kind: .worktree,
                            id: row.worktreeID,
                            ownerID: row.createdBySessionID?.uuidString,
                            payload: encoder.encode(row),
                            terminal: row.releasedAt != nil
                        ), expectedRevision: savedRevisions[row.worktreeID])
                        pending[0].mutation = mutation
                        pending[0].needsBaseline = loadState != .ready
                    }
                    let operation = pending[0].id, hook = beforeCommit
                    let receipt = try await Task.detached {
                        try hook()
                        return try repository.commit(operationID: operation, mutations: [mutation], origin: "live-worktree-owner")
                    }.value
                    savedRevisions[pending[0].row.worktreeID] = receipt.revision
                    pending.removeFirst()
                    saveState = rejectedOperations.isEmpty ? (pending.isEmpty ? "saved" : "pending") : "failed"
                    persistenceDiagnostic = rejectedOperations.values.sorted().first ?? recoveryWarning
                    retryDelay = 1
                } catch {
                    if (error as? OverseerContinuityError)?.isPermanentTransitionFailure == true {
                        let rejected = pending.removeFirst()
                        let detail = "Worktree continuity operation \(rejected.id) was rejected and is not durable: \(error). Inspect the conflicting saved identity before a fresh decision; other saves continue."
                        rejectedOperations[rejected.id] = detail
                        saveState = "failed"
                        persistenceDiagnostic = detail
                        continue
                    }
                    saveState = "failed"
                    persistenceDiagnostic = "Worktree ownership continuity is not saved or shared; current live provenance remains. Saving will retry: \(error)"
                    scheduleRetry()
                    break
                }
            }
            persistChain = nil
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(30, delay * 2)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self else { return }
            retryTask = nil
            if case .blocked = loadState { await recover() }
            persist()
        }
    }

    func flushPersistence() async {
        persist()
        await persistChain?.value
    }
}
