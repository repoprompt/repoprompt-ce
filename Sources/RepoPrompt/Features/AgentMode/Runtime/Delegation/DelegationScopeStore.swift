import Darwin
import Foundation
import RepoPromptDomainRuntime

// Scope intent is authority. A launch must durably mark the document open before restoring any
// grant, and only a final, frozen snapshot may seal it for the next launch. Atomic replacement
// protects against process interruption; this does not claim power-loss durability.

/// Versioned on-disk envelope. Version 2 requires an explicit launch-state field when decoding.
struct DelegationScopeDocument: Codable, Equatable {
    static let currentVersion = 2
    /// Bounded tombstone list; the oldest entries drop first.
    static let maxRevokedScopeIDs = 1024

    let version: Int
    let scopes: [DomainDelegationScopeGrant]
    let revokedScopeIDs: [UUID]?
    let cleanShutdown: Bool

    init(
        version: Int = DelegationScopeDocument.currentVersion,
        scopes: [DomainDelegationScopeGrant],
        revokedScopeIDs: [UUID]? = nil,
        cleanShutdown: Bool = false
    ) {
        self.version = version
        self.scopes = scopes
        self.revokedScopeIDs = revokedScopeIDs
        self.cleanShutdown = cleanShutdown
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case scopes
        case revokedScopeIDs = "revoked_scope_ids"
        case cleanShutdown = "clean_shutdown"
    }
}

private struct DelegationScopeDocumentHeader: Decodable {
    let version: Int
}

/// Kept separate so a missing v2 launch-state field can never acquire the legacy default.
private struct LegacyDelegationScopeDocument: Decodable {
    let scopes: [DomainDelegationScopeGrant]
    let revokedScopeIDs: [UUID]?

    private enum CodingKeys: String, CodingKey {
        case scopes
        case revokedScopeIDs = "revoked_scope_ids"
    }
}

private struct DelegationScopeLaunchState: Decodable {
    let cleanShutdown: Bool

    private enum CodingKeys: String, CodingKey {
        case cleanShutdown = "clean_shutdown"
    }
}

enum DelegationScopePersistenceBlockReason: Equatable {
    case unsupportedFutureSchema(onDiskVersion: Int, supportedVersion: Int)
    case unreadable
    case fileTooLarge(byteCount: Int)
    case tooManyRows(rowCount: Int)
    case ownershipUnavailable
    case openingWriteFailed
    case invalidLaunchState

    var diagnosticLabel: String {
        switch self {
        case .unsupportedFutureSchema: "future_schema"
        case .unreadable: "unreadable"
        case .fileTooLarge: "file_too_large"
        case .tooManyRows: "too_many_rows"
        case .ownershipUnavailable: "ownership_unavailable"
        case .openingWriteFailed: "opening_write_failed"
        case .invalidLaunchState: "invalid_launch_state"
        }
    }

    var message: String {
        switch self {
        case .unsupportedFutureSchema:
            "Saved delegations require a newer version of RepoPrompt. They were preserved and no authority was restored."
        case .unreadable:
            "Saved delegations could not be read safely. No authority was restored. Resolve the storage problem and restart RepoPrompt."
        case .fileTooLarge, .tooManyRows:
            "Saved delegations exceed the supported storage limit. They were preserved and no authority was restored."
        case .ownershipUnavailable:
            "Delegation storage is unavailable or another RepoPrompt process owns it. Delegation persistence is blocked. Close the other process or resolve the storage problem, then restart."
        case .openingWriteFailed:
            "Delegation storage could not be prepared safely for this launch. No authority was restored. Resolve the storage problem and restart RepoPrompt."
        case .invalidLaunchState:
            "Delegation storage has no valid state for this launch. No authority was restored. Restart RepoPrompt; if this persists, restore a valid backup."
        }
    }
}

enum DelegationScopeLoadResult: Equatable {
    enum Source: String, Equatable {
        case missing
        case loaded
        case quarantined
        case legacyRequiresApproval
        case uncleanRequiresApproval
    }

    case ready(source: Source, grants: [DomainDelegationScopeGrant], revokedScopeIDs: [UUID])
    case blocked(DelegationScopePersistenceBlockReason)
    case suppressed
}

enum DelegationScopeWriteOutcome: String, Equatable {
    case applied
    case unchanged
    /// Persistence is suppressed, not open, finalized, or preserved/blocked.
    case blocked
    /// Encoding or atomic replacement failed. Old disk and memory state survive.
    case writeFailed
}

/// Atomic, versioned store for durable delegation-scope intent.
///
/// Beside `agentSessionOversightLinks.json`:
/// `~/Library/Application Support/RepoPrompt CE/delegationScopes.json`
actor DelegationScopeStore {
    static let filename = "delegationScopes.json"
    static let backupsDirectoryName = "Backups"
    static let maxFileByteCount = 4 * 1024 * 1024
    static let maxDecodedRowCount = 4096
    private static let maxQuarantineAttempts = 4

    private let fileURL: URL
    private let backupsDirectoryURL: URL
    private let mode: AgentSessionOversightPersistenceMode
    private let maxFileByteCount: Int
    private let maxDecodedRowCount: Int
    private let fileManager: FileManager
    private let writer: @Sendable (Data, URL) throws -> Void
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    private var didLoad = false
    private var settledSource: DelegationScopeLoadResult.Source?
    private var blockReason: DelegationScopePersistenceBlockReason?
    private var grants: [DomainDelegationScopeGrant] = []
    private var revokedScopeIDs: [UUID] = []
    private var ownership: DelegationScopeFileOwnership?
    /// Set before final I/O, including failures. No queued snapshot can write after finalization.
    private var finalizationOutcome: DelegationScopeWriteOutcome?

    init(
        fileURL: URL,
        backupsDirectoryURL: URL,
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default,
        writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        maxFileByteCount: Int = DelegationScopeStore.maxFileByteCount,
        maxDecodedRowCount: Int = DelegationScopeStore.maxDecodedRowCount
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.backupsDirectoryURL = backupsDirectoryURL
        self.mode = mode
        self.fileManager = fileManager
        self.writer = writer
        self.now = now
        self.makeUUID = makeUUID
        self.maxFileByteCount = maxFileByteCount
        self.maxDecodedRowCount = maxDecodedRowCount
    }

    deinit {
        ownership?.release()
    }

    /// Production location, beside `agentSessionOversightLinks.json`.
    static func production(
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default
    ) -> DelegationScopeStore {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
        return DelegationScopeStore(
            fileURL: base.appendingPathComponent(filename),
            backupsDirectoryURL: base.appendingPathComponent(backupsDirectoryName, isDirectory: true),
            mode: mode,
            fileManager: fileManager
        )
    }

    // MARK: - Load

    /// Claims this path for the launch and writes an open document before returning any authority.
    /// Repeat calls report the settled classification without another opening write.
    func loadForLaunch() -> DelegationScopeLoadResult {
        guard mode.performsProductionFileIO else { return .suppressed }
        guard finalizationOutcome == nil else { return .blocked(.invalidLaunchState) }
        if didLoad {
            if let blockReason { return .blocked(blockReason) }
            guard ownership?.isCurrent == true else { return block(.ownershipUnavailable) }
            return .ready(source: settledSource ?? .loaded, grants: grants, revokedScopeIDs: revokedScopeIDs)
        }
        didLoad = true

        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            ownership = try DelegationScopeFileOwnership.acquire(for: fileURL)
        } catch {
            return block(.ownershipUnavailable)
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return openLaunch(source: .missing, grants: [], revoked: [])
        }
        if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
           size.intValue > maxFileByteCount
        {
            return block(.fileTooLarge(byteCount: size.intValue))
        }
        guard let data = try? Data(contentsOf: fileURL) else { return block(.unreadable) }
        guard data.count <= maxFileByteCount else { return block(.fileTooLarge(byteCount: data.count)) }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(DelegationScopeDocumentHeader.self, from: data) else {
            return quarantineAndStartEmpty()
        }
        guard header.version <= DelegationScopeDocument.currentVersion else {
            return block(.unsupportedFutureSchema(
                onDiskVersion: header.version,
                supportedVersion: DelegationScopeDocument.currentVersion
            ))
        }
        switch header.version {
        case 1:
            guard let legacy = try? decoder.decode(LegacyDelegationScopeDocument.self, from: data) else {
                return quarantineAndStartEmpty()
            }
            guard legacy.scopes.count <= maxDecodedRowCount else {
                return block(.tooManyRows(rowCount: legacy.scopes.count))
            }
            // Legacy bytes cannot prove whether their last revocation reached disk. Explicit user
            // approval is required; reading a v1 grant never reactivates it.
            return openLaunch(source: .legacyRequiresApproval, grants: [], revoked: legacy.revokedScopeIDs ?? [])
        case DelegationScopeDocument.currentVersion:
            guard (try? decoder.decode(DelegationScopeLaunchState.self, from: data)) != nil else {
                return block(.invalidLaunchState)
            }
            guard let document = try? decoder.decode(DelegationScopeDocument.self, from: data) else {
                return quarantineAndStartEmpty()
            }
            guard document.scopes.count <= maxDecodedRowCount else {
                return block(.tooManyRows(rowCount: document.scopes.count))
            }
            guard document.cleanShutdown else {
                return openLaunch(source: .uncleanRequiresApproval, grants: [], revoked: document.revokedScopeIDs ?? [])
            }
            var seen: Set<UUID> = []
            let uniqueGrants = document.scopes.filter { seen.insert($0.id).inserted }
            return openLaunch(source: .loaded, grants: uniqueGrants, revoked: document.revokedScopeIDs ?? [])
        default:
            return block(.invalidLaunchState)
        }
    }

    private func openLaunch(
        source: DelegationScopeLoadResult.Source,
        grants candidates: [DomainDelegationScopeGrant],
        revoked: [UUID]
    ) -> DelegationScopeLoadResult {
        // Required even for an empty or otherwise unchanged document: restoration cannot precede
        // the durable fence which makes a failed later revocation safe across process restart.
        guard writeSnapshot(grants: candidates, revoked: revoked, cleanShutdown: false) == .applied else {
            return block(blockReason ?? .openingWriteFailed)
        }
        settledSource = source
        return .ready(source: source, grants: grants, revokedScopeIDs: revokedScopeIDs)
    }

    private func block(_ reason: DelegationScopePersistenceBlockReason) -> DelegationScopeLoadResult {
        blockReason = reason
        return .blocked(reason)
    }

    /// Moves the intact source aside with no-replace semantics, then opens an empty v2 document. If
    /// the file cannot be moved it stays where it is and mutation stays blocked.
    private func quarantineAndStartEmpty() -> DelegationScopeLoadResult {
        guard ownership?.isCurrent == true else { return block(.ownershipUnavailable) }
        try? fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "")
        for _ in 0 ..< Self.maxQuarantineAttempts {
            let destination = backupsDirectoryURL.appendingPathComponent(
                "delegationScopes.corrupt.\(stamp).\(makeUUID().uuidString).json"
            )
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.moveItem(at: fileURL, to: destination)
                return openLaunch(source: .quarantined, grants: [], revoked: [])
            } catch {
                guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
                break
            }
        }
        return block(.unreadable)
    }

    // MARK: - Mutation

    /// Ordinary writes keep the launch open, including grants approved during this process.
    func replace(
        with newGrants: [DomainDelegationScopeGrant],
        revokedScopeIDs newRevoked: [UUID] = []
    ) -> DelegationScopeWriteOutcome {
        guard canWriteOpenLaunch else { return .blocked }
        let ordered = newGrants.sorted { $0.id.uuidString < $1.id.uuidString }
        let tombstones = Array(newRevoked.suffix(DelegationScopeDocument.maxRevokedScopeIDs))
        guard ordered != grants || tombstones != revokedScopeIDs else { return .unchanged }
        return writeSnapshot(grants: ordered, revoked: tombstones, cleanShutdown: false)
    }

    /// Seals exactly the caller's frozen final snapshot. The first attempt is terminal even when
    /// writing fails; late queued writes and repeated finalization cannot overwrite its outcome.
    func finishLaunch(
        with newGrants: [DomainDelegationScopeGrant],
        revokedScopeIDs newRevoked: [UUID] = []
    ) -> DelegationScopeWriteOutcome {
        if let finalizationOutcome { return finalizationOutcome }
        let mayFinish = canWriteOpenLaunch
        finalizationOutcome = .blocked
        guard mayFinish else { return .blocked }
        let outcome = writeSnapshot(grants: newGrants, revoked: newRevoked, cleanShutdown: true)
        finalizationOutcome = outcome
        return outcome
    }

    private var canWriteOpenLaunch: Bool {
        guard mode.performsProductionFileIO, didLoad, settledSource != nil,
              blockReason == nil, finalizationOutcome == nil
        else { return false }
        guard ownership?.isCurrent == true else {
            blockReason = .ownershipUnavailable
            return false
        }
        return true
    }

    private func writeSnapshot(
        grants newGrants: [DomainDelegationScopeGrant],
        revoked newRevoked: [UUID],
        cleanShutdown: Bool
    ) -> DelegationScopeWriteOutcome {
        guard ownership?.isCurrent == true else {
            blockReason = .ownershipUnavailable
            return .blocked
        }
        guard newGrants.count <= maxDecodedRowCount else { return .blocked }
        let ordered = newGrants.sorted { $0.id.uuidString < $1.id.uuidString }
        let tombstones = Array(newRevoked.suffix(DelegationScopeDocument.maxRevokedScopeIDs))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(DelegationScopeDocument(
                scopes: ordered,
                revokedScopeIDs: tombstones.isEmpty ? nil : tombstones,
                cleanShutdown: cleanShutdown
            ))
            guard data.count <= maxFileByteCount else { return .blocked }
            try writer(data, fileURL)
        } catch {
            return .writeFailed
        }
        grants = ordered
        revokedScopeIDs = tombstones
        return .applied
    }

    var currentGrants: [DomainDelegationScopeGrant] {
        grants
    }

    #if DEBUG
        /// Simulates process exit without a clean final snapshot. Also releases a normally finished
        /// store so restart tests can acquire the same real path without depending on ARC timing.
        func closeWithoutSealingForTesting() {
            if finalizationOutcome == nil { finalizationOutcome = .blocked }
            ownership?.release()
            ownership = nil
        }
    #endif
}

/// Locks a stable sibling, never the JSON inode replaced by atomic writes. The lock file remains
/// in place after release so overlapping owners cannot acquire different inodes for the same path.
private final class DelegationScopeFileOwnership: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t

        var isRegularFile: Bool {
            mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
    }

    private enum OwnershipError: Error {
        case unavailable
    }

    private let lockURL: URL
    private let descriptor: Int32
    private let identity: FileIdentity
    private let stateLock = NSLock()
    private var released = false

    static func acquire(for fileURL: URL) throws -> DelegationScopeFileOwnership {
        let lockURL = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(fileURL.lastPathComponent + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw OwnershipError.unavailable }
        do {
            guard let initial = identity(for: descriptor), initial.isRegularFile, initial.owner == getuid(),
                  identity(at: lockURL.path) == initial,
                  fchmod(descriptor, mode_t(0o600)) == 0,
                  let secured = identity(for: descriptor), secured.isRegularFile, secured.owner == getuid(),
                  identity(at: lockURL.path) == secured,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                  identity(for: descriptor) == secured, identity(at: lockURL.path) == secured
            else { throw OwnershipError.unavailable }
            return DelegationScopeFileOwnership(lockURL: lockURL, descriptor: descriptor, identity: secured)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private init(lockURL: URL, descriptor: Int32, identity: FileIdentity) {
        self.lockURL = lockURL
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit {
        release()
    }

    var isCurrent: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !released && Self.identity(for: descriptor) == identity && Self.identity(at: lockURL.path) == identity
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func identity(for descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode)
    }

    private static func identity(at path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode)
    }
}
