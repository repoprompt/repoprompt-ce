import Foundation
import RepoPromptDomainRuntime

// Durable delegation-scope intent: the user's active scope grants (and their attenuated children)
// and nothing else.
//
// Modeled on `AgentSessionOversightIntentStore`: one actor, a versioned document, defensive size/row
// guards, quarantine of malformed supported-schema files into `Backups/`, preserve-and-block for
// future schemas, and write-through atomic replacement with no suspension between the disk write and
// the in-memory commit. Unlike oversight links, scope intent *is* authority, so revoked and expired
// scopes are removed from the file; generations are process-local and never written, and a launch
// reactivates every persisted grant under a fresh generation (`DomainDelegationScopeAuthority`).

/// Versioned on-disk envelope.
struct DelegationScopeDocument: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let scopes: [DomainDelegationScopeGrant]

    init(version: Int = DelegationScopeDocument.currentVersion, scopes: [DomainDelegationScopeGrant]) {
        self.version = version
        self.scopes = scopes
    }
}

private struct DelegationScopeDocumentHeader: Decodable {
    let version: Int
}

enum DelegationScopeLoadResult: Equatable {
    enum Source: String, Equatable {
        case missing
        case loaded
        case quarantined
    }

    case ready(source: Source, grants: [DomainDelegationScopeGrant])
    case blocked(AgentSessionOversightPersistenceBlockReason)
    case suppressed
}

enum DelegationScopeWriteOutcome: String, Equatable {
    case applied
    case unchanged
    /// Persistence is suppressed, not yet loaded, or the file is preserved/blocked.
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
    private var blockReason: AgentSessionOversightPersistenceBlockReason?
    private var grants: [DomainDelegationScopeGrant] = []

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
        self.fileURL = fileURL
        self.backupsDirectoryURL = backupsDirectoryURL
        self.mode = mode
        self.fileManager = fileManager
        self.writer = writer
        self.now = now
        self.makeUUID = makeUUID
        self.maxFileByteCount = maxFileByteCount
        self.maxDecodedRowCount = maxDecodedRowCount
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

    /// Reads the file once per launch; repeat calls report the settled classification.
    func loadForLaunch() -> DelegationScopeLoadResult {
        guard mode.performsProductionFileIO else { return .suppressed }
        if didLoad {
            if let blockReason { return .blocked(blockReason) }
            return .ready(source: settledSource ?? .loaded, grants: grants)
        }
        didLoad = true

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return settle(.missing)
        }
        if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
           size.intValue > maxFileByteCount
        {
            return block(.fileTooLarge(byteCount: size.intValue))
        }
        guard let data = try? Data(contentsOf: fileURL) else { return block(.unreadable) }
        guard data.count <= maxFileByteCount else { return block(.fileTooLarge(byteCount: data.count)) }

        // Default `Date` coding round-trips exactly, so an unchanged authority never rewrites.
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
        guard let document = try? decoder.decode(DelegationScopeDocument.self, from: data) else {
            return quarantineAndStartEmpty()
        }
        guard document.scopes.count <= maxDecodedRowCount else {
            return block(.tooManyRows(rowCount: document.scopes.count))
        }
        // Duplicate IDs collapse onto the first row; a load never writes.
        var seen: Set<UUID> = []
        grants = document.scopes.filter { seen.insert($0.id).inserted }
        return settle(.loaded)
    }

    private func settle(_ source: DelegationScopeLoadResult.Source) -> DelegationScopeLoadResult {
        settledSource = source
        return .ready(source: source, grants: grants)
    }

    private func block(_ reason: AgentSessionOversightPersistenceBlockReason) -> DelegationScopeLoadResult {
        blockReason = reason
        return .blocked(reason)
    }

    /// Moves the intact source aside with no-replace semantics, then starts empty and writable. If
    /// the file cannot be moved it stays where it is and mutation stays blocked.
    private func quarantineAndStartEmpty() -> DelegationScopeLoadResult {
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
                return settle(.quarantined)
            } catch {
                guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
                break
            }
        }
        return block(.unreadable)
    }

    // MARK: - Mutation

    /// Replaces the durable set with exactly `newGrants` (the authority's active grants).
    func replace(with newGrants: [DomainDelegationScopeGrant]) -> DelegationScopeWriteOutcome {
        guard mode.performsProductionFileIO, didLoad, blockReason == nil else { return .blocked }
        let ordered = newGrants.sorted { $0.id.uuidString < $1.id.uuidString }
        guard ordered != grants.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { return .unchanged }
        guard ordered.count <= maxDecodedRowCount else { return .blocked }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(DelegationScopeDocument(scopes: ordered))
            guard data.count <= maxFileByteCount else { return .blocked }
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer(data, fileURL)
        } catch {
            return .writeFailed
        }
        grants = ordered
        return .applied
    }

    var currentGrants: [DomainDelegationScopeGrant] {
        grants
    }
}
