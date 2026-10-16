import Darwin
import Foundation
import RepoPromptDomainRuntime

// Scope intent is authority, and it is crash-safe by construction. Every grant, revocation, release,
// and expiry is written durably (temp file, full fsync, rename, directory fsync) at the moment it
// happens, synchronously, before the runtime returns. Launch therefore loads whatever is on disk:
// there is nothing to seal at quit, and an unclean shutdown never discards a valid grant. A row that
// cannot be decoded is dropped on its own; the rest of the document still loads.

/// Versioned on-disk envelope.
struct DelegationScopeDocument: Codable, Equatable {
    static let currentVersion = 2
    /// Bounded tombstone list; the oldest entries drop first.
    static let maxRevokedScopeIDs = 1024

    let version: Int
    let scopes: [DomainDelegationScopeGrant]
    let revokedScopeIDs: [UUID]?
    /// Legacy launch-state field. Ignored on load. Always written `true` so an older build that still
    /// gates restoration on it keeps the grants instead of discarding them.
    let cleanShutdown: Bool

    init(
        version: Int = DelegationScopeDocument.currentVersion,
        scopes: [DomainDelegationScopeGrant],
        revokedScopeIDs: [UUID]? = nil,
        cleanShutdown: Bool = true
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

/// Decodes one array element without letting a bad element fail its siblings.
private struct LossyDecoded<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Reads v1 and v2 documents row by row. `clean_shutdown` is deliberately not read.
private struct LenientDelegationScopeDocument: Decodable {
    let scopes: [LossyDecoded<DomainDelegationScopeGrant>]
    let revokedScopeIDs: [LossyDecoded<UUID>]

    private enum CodingKeys: String, CodingKey {
        case scopes
        case revokedScopeIDs = "revoked_scope_ids"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scopes = try container.decodeIfPresent([LossyDecoded<DomainDelegationScopeGrant>].self, forKey: .scopes) ?? []
        revokedScopeIDs = try container.decodeIfPresent([LossyDecoded<UUID>].self, forKey: .revokedScopeIDs) ?? []
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
            "Saved delegations could not be read safely. They were preserved and no authority was restored. Resolve the storage problem and restart RepoPrompt."
        case .fileTooLarge, .tooManyRows:
            "Saved delegations exceed the supported storage limit. They were preserved and no authority was restored."
        case .ownershipUnavailable:
            "Delegation storage is unavailable or another RepoPrompt process owns it. Delegation persistence is blocked. Close the other process or resolve the storage problem, then restart."
        case .openingWriteFailed:
            "Delegation storage could not be written for this launch. Saved delegations were preserved but are not active. Resolve the storage problem and restart RepoPrompt."
        case .invalidLaunchState:
            "Saved delegations have an unrecognized format. They were preserved and no authority was restored."
        }
    }
}

enum DelegationScopeLoadResult: Equatable {
    enum Source: String, Equatable {
        case missing
        case loaded
        /// A v1 document whose grants were carried into v2.
        case migrated
        case quarantined
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
    /// Encoding or durable replacement failed. Old disk and memory state survive.
    case writeFailed
}

/// Durable, versioned store for delegation-scope intent.
///
/// Synchronous and lock-serialized so the MainActor runtime can make each change durable before it
/// acknowledges it. Beside `agentSessionOversightLinks.json`:
/// `~/Library/Application Support/RepoPrompt CE/delegationScopes.json`
final class DelegationScopeStore: @unchecked Sendable {
    static let filename = "delegationScopes.json"
    static let backupsDirectoryName = "Backups"
    static let maxFileByteCount = 4 * 1024 * 1024
    static let maxDecodedRowCount = 4096
    private static let maxQuarantineAttempts = 4

    private let lock = NSRecursiveLock()
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
    /// Set by the final quit write. No later write can replace it.
    private var finalizationOutcome: DelegationScopeWriteOutcome?

    init(
        fileURL: URL,
        backupsDirectoryURL: URL,
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default,
        writer: @escaping @Sendable (Data, URL) throws -> Void = DurableAtomicFileWriter.write,
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

    /// Claims this path for the launch and loads whatever is on disk, regardless of how the previous
    /// launch ended. Repeat calls report the settled classification.
    func loadForLaunch() -> DelegationScopeLoadResult {
        lock.withLock { loadLocked() }
    }

    private func loadLocked() -> DelegationScopeLoadResult {
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
        guard header.version >= 1 else { return block(.invalidLaunchState) }
        guard let document = try? decoder.decode(LenientDelegationScopeDocument.self, from: data) else {
            return quarantineAndStartEmpty()
        }
        guard document.scopes.count <= maxDecodedRowCount else {
            return block(.tooManyRows(rowCount: document.scopes.count))
        }
        // An undecodable row drops alone; duplicate IDs keep the first occurrence.
        var seen: Set<UUID> = []
        let uniqueGrants = document.scopes.compactMap(\.value).filter { seen.insert($0.id).inserted }
        let revoked = document.revokedScopeIDs.compactMap(\.value)
        // v1 grants carry the same grant schema. Tombstones, expiry, and attenuation invariants are
        // still enforced by `reactivate`, so migration cannot widen or resurrect anything.
        let source: DelegationScopeLoadResult.Source = header.version == 1 ? .migrated : .loaded
        return openLaunch(source: source, grants: uniqueGrants, revoked: revoked)
    }

    /// Verifies the location is writable before authority is installed. It rewrites exactly the
    /// loaded rows (normalized to v2), never an empty list in place of loaded grants.
    private func openLaunch(
        source: DelegationScopeLoadResult.Source,
        grants candidates: [DomainDelegationScopeGrant],
        revoked: [UUID]
    ) -> DelegationScopeLoadResult {
        guard writeSnapshot(grants: candidates, revoked: revoked) == .applied else {
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

    /// Durably records the complete current authority. Returns only after the bytes reached disk.
    func replace(
        with newGrants: [DomainDelegationScopeGrant],
        revokedScopeIDs newRevoked: [UUID] = []
    ) -> DelegationScopeWriteOutcome {
        lock.withLock {
            guard canWriteOpenLaunch else { return .blocked }
            let ordered = newGrants.sorted { $0.id.uuidString < $1.id.uuidString }
            let tombstones = Array(newRevoked.suffix(DelegationScopeDocument.maxRevokedScopeIDs))
            guard ordered != grants || tombstones != revokedScopeIDs else { return .unchanged }
            return writeSnapshot(grants: ordered, revoked: tombstones)
        }
    }

    /// Final write at quit. Not required for correctness (every change is already durable); it only
    /// guarantees no late write can follow it.
    func finishLaunch(
        with newGrants: [DomainDelegationScopeGrant],
        revokedScopeIDs newRevoked: [UUID] = []
    ) -> DelegationScopeWriteOutcome {
        lock.withLock {
            if let finalizationOutcome { return finalizationOutcome }
            let mayFinish = canWriteOpenLaunch
            finalizationOutcome = .blocked
            guard mayFinish else { return .blocked }
            let ordered = newGrants.sorted { $0.id.uuidString < $1.id.uuidString }
            let tombstones = Array(newRevoked.suffix(DelegationScopeDocument.maxRevokedScopeIDs))
            let outcome = ordered == grants && tombstones == revokedScopeIDs
                ? .unchanged
                : writeSnapshot(grants: ordered, revoked: tombstones)
            finalizationOutcome = outcome
            return outcome
        }
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
        revoked newRevoked: [UUID]
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
                revokedScopeIDs: tombstones.isEmpty ? nil : tombstones
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
        lock.withLock { grants }
    }

    #if DEBUG
        /// Simulates a process kill: no final write, and the path lock is released so a restart test
        /// can acquire the same real path without depending on ARC timing.
        func closeWithoutSealingForTesting() {
            lock.withLock {
                if finalizationOutcome == nil { finalizationOutcome = .blocked }
                ownership?.release()
                ownership = nil
            }
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
