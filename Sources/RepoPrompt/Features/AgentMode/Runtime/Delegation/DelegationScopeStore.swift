import Foundation
import RepoPromptDomainRuntime
import RepoPromptPersistence

/// Legacy import envelope only. Never rewritten by the transactional continuity implementation.
struct DelegationScopeDocument: Codable, Equatable {
    static let currentVersion = 2
    let version: Int
    let scopes: [DomainDelegationScopeGrant]
    let revokedScopeIDs: [UUID]?
    let cleanShutdown: Bool
    init(version: Int = currentVersion, scopes: [DomainDelegationScopeGrant], revokedScopeIDs: [UUID]? = nil, cleanShutdown: Bool = true) {
        self.version = version
        self.scopes = scopes
        self.revokedScopeIDs = revokedScopeIDs
        self.cleanShutdown = cleanShutdown
    }

    private enum CodingKeys: String, CodingKey {
        case version, scopes
        case revokedScopeIDs = "revoked_scope_ids"
        case cleanShutdown = "clean_shutdown"
    }
}

enum DelegationScopePersistenceBlockReason: Equatable {
    case unsupportedFutureSchema(onDiskVersion: Int, supportedVersion: Int)
    case unreadable, ownershipUnavailable, openingWriteFailed, invalidLaunchState
    case fileTooLarge(byteCount: Int)
    case tooManyRows(rowCount: Int)
    var diagnosticLabel: String {
        switch self {
        case .unsupportedFutureSchema: "future_schema"
        case .unreadable: "unreadable"
        case .ownershipUnavailable: "ownership_unavailable"
        case .openingWriteFailed: "opening_write_failed"
        case .invalidLaunchState: "invalid_launch_state"
        case .fileTooLarge: "file_too_large"
        case .tooManyRows: "too_many_rows"
        }
    }

    var message: String {
        "Saved delegation continuity is unavailable (\(diagnosticLabel)). Existing bytes are preserved. New explicit user approvals remain usable in this process; saving is separate and will retry."
    }
}

enum DelegationScopeLoadResult: Equatable {
    enum Source: String, Equatable { case missing, loaded, migrated, quarantined }
    case ready(source: Source, grants: [DomainDelegationScopeGrant], revokedScopeIDs: [UUID])
    case blocked(DelegationScopePersistenceBlockReason)
    case suppressed
}

enum DelegationScopeWriteOutcome: String, Equatable {
    case applied, unchanged, pending, blocked, writeFailed, rejected
}

/// Typed continuity adapter, not the live approval owner. It has no lifetime flock and no cached
/// startup failure. A failed open/transaction can be retried on this same object. All mutations are
/// row deltas with stable operation receipts; neither missing rows nor a stale snapshot imply revoke.
final class DelegationScopeStore: @unchecked Sendable {
    static let filename = "delegationScopes.json"
    static let backupsDirectoryName = "Backups"
    let repository: OverseerContinuityRepository
    private let mode: AgentSessionOversightPersistenceMode
    private let beforeCommit: @Sendable () throws -> Void
    private let lock = NSLock()
    private var closed = false
    private var cachedGrants: [DomainDelegationScopeGrant] = []
    private var failure: String?
    private var recoveryWarning: String?
    private var receipt: OverseerContinuityReceipt?
    var lastReceipt: OverseerContinuityReceipt? {
        lock.withLock { receipt }
    }

    init(
        fileURL: URL,
        backupsDirectoryURL _: URL,
        mode: AgentSessionOversightPersistenceMode,
        beforeCommit: @escaping @Sendable () throws -> Void = {},
        databaseURL: URL? = nil,
        profile: String = "temporary-overseer",
        legacyPolicy: OverseerLegacyPolicy = .sameProfile
    ) {
        self.mode = mode
        self.beforeCommit = beforeCommit
        repository = OverseerContinuityRepository(databaseURL: databaseURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("Overseer/continuity.sqlite"), profile: profile, legacyURL: fileURL, kind: .scope, mode: mode, legacyPolicy: legacyPolicy)
    }

    static func production(mode: AgentSessionOversightPersistenceMode, fileManager: FileManager = .default) -> DelegationScopeStore {
        let locations = OverseerContinuityRepository.production(fileManager: fileManager)
        return .init(
            fileURL: locations.legacyDirectory.appendingPathComponent(filename),
            backupsDirectoryURL: locations.legacyDirectory,
            mode: mode,
            databaseURL: locations.databaseURL,
            profile: locations.profile,
            legacyPolicy: .userReview
        )
    }

    var diagnostic: String? {
        lock.withLock { failure ?? recoveryWarning } ?? repository.diagnostic
    }

    /// Successfully decoded continuity descriptions, never an authorization input.
    var restoredDescriptions: [DomainDelegationScopeGrant] {
        lock.withLock { cachedGrants }
    }

    func loadForLaunch() -> DelegationScopeLoadResult {
        guard mode.performsProductionFileIO else { return .suppressed }
        do {
            let rows = try repository.load()
            var grants: [DomainDelegationScopeGrant] = []
            var revoked: [UUID] = []
            var invalidIDs: [String] = []
            for row in rows {
                do {
                    guard let id = UUID(uuidString: row.id) else { throw OverseerContinuityError.invalidRecord }
                    if row.terminal { revoked.append(id)
                        continue
                    }
                    let grant = try JSONDecoder().decode(DomainDelegationScopeGrant.self, from: row.payload)
                    let canonical = try OverseerContinuityRepository.scopeRow(grant)
                    guard canonical.id == row.id, canonical.ownerID == row.ownerID, canonical.parentID == row.parentID,
                          canonical.anchorID == row.anchorID, canonical.workspaceID == row.workspaceID,
                          canonical.capabilities == row.capabilities,
                          canonical.expiresAt?.timeIntervalSince1970 == row.expiresAt?.timeIntervalSince1970 else { throw OverseerContinuityError.invalidRecord }
                    grants.append(grant)
                } catch { invalidIDs.append(row.id) }
            }
            lock.withLock { cachedGrants = grants
                failure = nil
                recoveryWarning = invalidIDs.isEmpty ? nil : "Invalid scope entries remain preserved and inactive for recovery: \(invalidIDs.joined(separator: ", ")). Other valid committed grants restore normally."
            }
            return .ready(source: rows.isEmpty ? .missing : .loaded, grants: grants, revokedScopeIDs: revoked)
        } catch {
            lock.withLock { failure = "Continuity open failed: \(error). New user-approved authority still works in this process. Retry saving; no saved data was replaced." }
            if case let OverseerContinuityError.incompatibleSchema(version) = error {
                return .blocked(.unsupportedFutureSchema(onDiskVersion: version, supportedVersion: 1))
            }
            return .blocked(.unreadable)
        }
    }

    func record(operationID: UUID, grants: [DomainDelegationScopeGrant], revoked: [UUID], deletedSessions: [UUID] = []) -> DelegationScopeWriteOutcome {
        guard mode.performsProductionFileIO, !lock.withLock({ closed }) else { return .blocked }
        do {
            try beforeCommit()
            let mutations = try deletedSessions.map { OverseerContinuityMutation.deletedSession($0.uuidString) }
                + revoked.map { OverseerContinuityMutation.revokeScope($0.uuidString) }
                + grants.filter { !revoked.contains($0.id) }.map { try .grant(OverseerContinuityRepository.scopeRow($0)) }
            guard !mutations.isEmpty else { return .unchanged }
            let receipt = try repository.commit(operationID: operationID, mutations: mutations, origin: "live-scope-owner")
            lock.withLock { self.receipt = receipt
                failure = nil
            }
            return .applied
        } catch {
            let rejected = (error as? OverseerContinuityError)?.isPermanentTransitionFailure == true
            lock.withLock { failure = "Continuity save failed: \(error). The live user decision still applies; this change is not durably saved. " + (rejected ? "These exact bytes cannot be retried; inspect the conflicting saved identity and make a fresh user decision." : "Saving will retry.") }
            return rejected ? .rejected : .writeFailed
        }
    }

    /// Compatibility entry point for callers/tests. This is additive, not a snapshot replacement:
    /// only explicit terminal IDs revoke; omitted rows belong to other owners and remain untouched.
    func replace(with grants: [DomainDelegationScopeGrant], revokedScopeIDs: [UUID] = []) -> DelegationScopeWriteOutcome {
        record(operationID: UUID(), grants: grants, revoked: revokedScopeIDs)
    }

    var currentGrants: [DomainDelegationScopeGrant] {
        if case let .ready(_, grants, _) = loadForLaunch() { return grants }
        return lock.withLock { cachedGrants }
    }

    #if DEBUG
        func closeWithoutSealingForTesting() {
            lock.withLock { closed = true }
        }
    #endif
}
