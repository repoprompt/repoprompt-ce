import Darwin
import Foundation
import RepoPromptC
import RepoPromptShared

/// Bounded, read-only source capture followed by a same-volume atomic publish.
/// No live app store may be opened until this startup operation succeeds.
struct DebugStateSnapshot {
    struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    struct Entry {
        let source: URL
        let relativePath: String
        /// Bytes captured under the source's observed stamp; nil only for SQLite
        /// entries, which are copied by an online backup during publication.
        var replacement: Data?
        var database = false
    }

    /// Bytes and derived records captured by earlier attempts of one bootstrap. Reuse
    /// requires the source to still carry the exact stamp it was read under, so a retry
    /// re-reads and re-derives only what production changed since the prior attempt.
    final class CaptureCache {
        /// Facts parsed from one workspace document, plus whether this binary decoded it.
        struct WorkspaceRecord {
            let name: String
            let isSystemWorkspace: Bool
            let isHiddenInMenus: Bool
            let activeAgentSessionIDs: [String]
            var decoded = false
        }

        private var capturedBytes: [String: (stamp: Stamp, data: Data)] = [:]
        private var derivedRecords: [String: (stamp: Stamp, context: Int, data: Data)] = [:]
        private var workspaceRecords: [String: (stamp: Stamp, record: WorkspaceRecord)] = [:]
        private var contexts: [[String]: Int] = [:]
        /// Derived records actually computed rather than reused.
        private(set) var derivations = 0

        func workspaceRecord(_ key: String, stamp: Stamp) -> WorkspaceRecord? {
            workspaceRecords[key].flatMap { $0.stamp == stamp ? $0.record : nil }
        }

        func storeWorkspaceRecord(_ record: WorkspaceRecord, _ key: String, stamp: Stamp) {
            workspaceRecords[key] = (stamp, record)
        }

        func bytes(_ url: URL, stamp: Stamp) -> Data? {
            capturedBytes[url.path].flatMap { $0.stamp == stamp ? $0.data : nil }
        }

        func store(_ data: Data, _ url: URL, stamp: Stamp) {
            capturedBytes[url.path] = (stamp, data)
        }

        func derived(kind: String, url: URL, stamp: Stamp, context: Int) -> Data? {
            derivedRecords[kind + "\u{0}" + url.path].flatMap { $0.stamp == stamp && $0.context == context ? $0.data : nil }
        }

        func storeDerived(_ data: Data, kind: String, url: URL, stamp: Stamp, context: Int) {
            derivations += 1
            derivedRecords[kind + "\u{0}" + url.path] = (stamp, context, data)
        }

        /// A stable identifier for one transform input table (for example path mappings).
        func context(_ signature: [String]) -> Int {
            if let id = contexts[signature] { return id }
            let id = contexts.count
            contexts[signature] = id
            return id
        }
    }

    /// Cooperative stop request checked only at safe points: before staging, between
    /// staged entries and between SQLite backup page batches, never after the swap.
    struct Cancellation {
        private let isRequested: () -> Bool

        init(_ isRequested: @escaping () -> Bool) {
            self.isRequested = isRequested
        }

        func check() throws {
            if isRequested() { throw Failure.cancelled }
        }
    }

    /// The names one enumeration consumes. Verification re-applies the identical rule, so
    /// skipped names (caller exclusions, rebuildable/owned control entries, transient
    /// artifacts) can neither be published nor invalidate a capture by churning.
    struct Selection: Hashable {
        var excluding: Set<String> = []
        var ignoresTransientArtifacts = true
        static let verbatim = Selection(ignoresTransientArtifacts: false)

        func select(_ names: [String]) -> [String] {
            names.filter { !excluding.contains($0) && !(ignoresTransientArtifacts && DebugStateSnapshot.isTransientArtifact($0)) }
        }
    }

    struct Plan {
        struct Listing: Equatable {
            let names: [String]
            let selection: Selection
        }

        var entries: [Entry] = []
        var generated: [String: Data] = [:]
        var observed: [URL: Stamp] = [:]
        /// Every distinct selection taken from one directory during this plan.
        var directories: [URL: [Listing]] = [:]
        var cache = CaptureCache()
        var cancellation: Cancellation?
        /// Ancestor chains proven during this capture pass.
        var validatedDirectories = Set<String>()

        mutating func read(_ url: URL) throws -> Data {
            try capture(url, retain: true).data
        }

        mutating func observe(_ url: URL) throws -> Stamp {
            try DebugStateSnapshot.observe(url, validated: &validatedDirectories)
        }

        /// One plan holds one version of each source. A source captured again under a
        /// different stamp changed mid-capture; never let the later stamp bless both.
        mutating func record(_ stamp: Stamp, for url: URL) throws {
            if let prior = observed[url], prior != stamp { throw Failure.sourceChanged }
            observed[url] = stamp
        }

        /// Stamp-bracketed read; unchanged bytes from an earlier attempt are reused.
        mutating func capture(_ url: URL, retain: Bool) throws -> (stamp: Stamp, data: Data) {
            try cancellation?.check()
            let before = try observe(url)
            if let data = cache.bytes(url, stamp: before) {
                try record(before, for: url)
                return (before, data)
            }
            let bytes: Data
            do { bytes = try Data(contentsOf: url) } catch where DebugStateSnapshot.isMissing(url) { throw Failure.sourceChanged }
            guard try observe(url) == before else { throw Failure.sourceChanged }
            try record(before, for: url)
            if retain { cache.store(bytes, url, stamp: before) }
            return (before, bytes)
        }

        /// A derived record is reused only for the exact source stamp and transform context.
        mutating func cachedDerivation(_ url: URL, kind: String, context: Int) throws -> Data? {
            try cancellation?.check()
            let stamp = try observe(url)
            guard let data = cache.derived(kind: kind, url: url, stamp: stamp, context: context) else { return nil }
            try record(stamp, for: url)
            return data
        }

        /// Production listings omit transient artifacts by default; debug-owned verbatim
        /// retention passes `.verbatim` to keep every name.
        mutating func children(_ url: URL, selection: Selection = .init()) throws -> [URL] {
            try cancellation?.check()
            let membership = try DebugStateSnapshot.listing(url, validated: &validatedDirectories)
            let listing = Listing(names: selection.select(membership), selection: selection)
            try record(listing, for: url, membership: membership)
            return listing.names.map { url.appendingPathComponent($0) }
        }

        /// Same one-version rule for membership. With the raw membership in hand, every
        /// earlier selection from this directory must still reproduce exactly what it
        /// consumed; without it (merging another plan) equal rules must agree, and
        /// `verify()` checks every rule against one fresh listing.
        mutating func record(_ listing: Listing, for url: URL, membership: [String]? = nil) throws {
            var listings = directories[url] ?? []
            for prior in listings {
                if let membership {
                    guard prior.selection.select(membership) == prior.names else { throw Failure.sourceChanged }
                } else if prior.selection == listing.selection, prior.names != listing.names {
                    throw Failure.sourceChanged
                }
            }
            if !listings.contains(where: { $0.selection == listing.selection }) { listings.append(listing) }
            directories[url] = listings
        }

        mutating func add(_ source: URL, as relativePath: String, replacement: Data? = nil, database: Bool = false) throws {
            // Capture plain bytes now: publication writes only verified captured bytes and
            // never re-reads a production source after the consistency check.
            var bytes = replacement
            if bytes == nil, !database { bytes = try read(source) }
            if observed[source] == nil { try record(observe(source), for: source) }
            entries.append(Entry(source: source, relativePath: relativePath, replacement: bytes, database: database))
            if database {
                for suffix in ["-wal", "-shm", "-journal"] {
                    let companion = URL(fileURLWithPath: source.path + suffix)
                    if FileManager.default.fileExists(atPath: companion.path) {
                        try record(observe(companion), for: companion)
                    }
                }
            }
        }

        /// The snapshot instant: every captured byte and listing still matches its source.
        func verify() throws {
            try cancellation?.check()
            var validated = Set<String>()
            for (url, expected) in observed {
                try cancellation?.check()
                guard try DebugStateSnapshot.observe(url, validated: &validated) == expected else { throw Failure.sourceChanged }
            }
            for (url, listings) in directories {
                try cancellation?.check()
                let membership = try DebugStateSnapshot.listing(url, validated: &validated)
                for expected in listings {
                    guard expected.selection.select(membership) == expected.names else { throw Failure.sourceChanged }
                }
            }
        }

        /// SQLite backups are the only publication-time source reads; prove each
        /// database and its observed sidecars stayed at the verified snapshot.
        func verifyDatabaseReads() throws {
            var validated = Set<String>()
            for entry in entries where entry.database {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    let url = suffix.isEmpty ? entry.source : URL(fileURLWithPath: entry.source.path + suffix)
                    guard let expected = observed[url] else { continue }
                    guard try DebugStateSnapshot.observe(url, validated: &validated) == expected else { throw Failure.sourceChanged }
                }
            }
        }
    }

    private struct RecoveryRecord: Codable {
        let version: Int
        let profile: String
        let createdAt: Date
        let previousPreferences: Data
    }

    struct Receipt: Codable {
        let version: Int
        let profile: String
        let cleanSlate: Bool
        let copiedFiles: Int
        let copiedBytes: Int
        let seconds: Double
    }

    enum Failure: Error, LocalizedError {
        case sourceChanged, cancelled, unsafeFile, unsafeDestination, duplicateDestination, database(Int32), unsupportedWAL
        var errorDescription: String? {
            switch self {
            case .sourceChanged: "Production state changed during capture. Retry when release is idle; no profile was replaced."
            case .cancelled: "Debug state preparation was cancelled before publication; no profile was replaced."
            case .unsafeFile: "A snapshot source is missing, aliased, or not a regular metadata file. Original state was preserved."
            case .unsafeDestination: "Debug snapshot destination or recovery ownership is unsafe. Original state was preserved."
            case .duplicateDestination: "Snapshot metadata references conflict. Original state was preserved."
            case let .database(code): "A read-only database snapshot could not complete (SQLite \(code)). Original state was preserved."
            case .unsupportedWAL: "A WAL database needs a source-write-free snapshot reader; this build will not modify its shared-memory sidecar. Original state was preserved."
            }
        }
    }

    let locations: AppProfileLocations
    private let fm = FileManager.default

    static func requireDirectory(_ url: URL) throws {
        var validated = Set<String>()
        try requireDirectory(url, validated: &validated)
    }

    /// `validated` lives for one capture or verification pass: the directory itself is
    /// always re-checked, but an ancestor chain already proven free of app-owned
    /// symlink components is not walked again for every sibling file.
    static func requireDirectory(_ url: URL, validated: inout Set<String>) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        // Resolve OS aliases, not app-owned symlink components.
        var parent = url.standardizedFileURL
        var proven: [String] = []
        while parent.path != "/", !validated.contains(parent.path) {
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK
                || ["/tmp", "/var"].contains(parent.path) else { throw Failure.unsafeFile }
            proven.append(parent.path)
            parent.deleteLastPathComponent()
        }
        validated.formUnion(proven)
    }

    static func stamp(_ url: URL) throws -> Stamp {
        var validated = Set<String>()
        return try stamp(url, validated: &validated)
    }

    static func stamp(_ url: URL, validated: inout Set<String>) throws -> Stamp {
        try requireDirectory(url.deletingLastPathComponent(), validated: &validated)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        return Stamp(
            inode: UInt64(info.st_ino),
            size: info.st_size,
            seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    /// A live production app deletes and renames files while it runs. A source that
    /// disappears after enumeration is a concurrent change to retry, not an alias.
    static func observe(_ url: URL, validated: inout Set<String>) throws -> Stamp {
        do { return try stamp(url, validated: &validated) } catch Failure.unsafeFile where isMissing(url) { throw Failure.sourceChanged }
    }

    static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    enum SourceKind { case directory, file }

    static func kind(_ url: URL) throws -> SourceKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw errno == ENOENT ? Failure.sourceChanged : Failure.unsafeFile }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: throw Failure.unsafeFile
        }
    }

    /// Finder view metadata and atomic-write/lock temporaries are never application
    /// state; their churn must not invalidate a capture of a live production profile.
    /// Patterns are exact so names derived from user repositories or workspaces
    /// (for example a `client.sb-tools` partition) are never mistaken for temporaries.
    static func isTransientArtifact(_ name: String) -> Bool {
        if name == ".DS_Store" || name.hasPrefix(".dat.nosync") || name.hasSuffix(".lock") { return true }
        // App atomic writers stage hidden `.<name>.<UUID>.tmp` siblings.
        if name.hasPrefix("."), name.hasSuffix(".tmp") { return true }
        // Sandboxed safe-save temporaries: `<name>.sb-<8 hex>-<6 alphanumerics>`.
        return name.range(of: #"\.sb-[0-9a-f]{8}-[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil
    }

    /// Raw, sorted membership; selection rules are applied by the caller.
    static func listing(_ url: URL, validated: inout Set<String>) throws -> [String] {
        do {
            try requireDirectory(url, validated: &validated)
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        } catch where isMissing(url) {
            throw Failure.sourceChanged
        }
    }

    static func physicalPath(_ url: URL) throws -> String {
        var parent = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = url.deletingLastPathComponent().path.withCString { rpce_catalog_resolve_directory($0, &parent) }
        guard result == 0 else { throw Failure.unsafeFile }
        return String(cString: parent) + "/" + url.lastPathComponent
    }

    /// Pages per backup step: production writers are not held behind one long read, and a
    /// cancellation request is honored between batches.
    static let backupPagesPerStep: Int32 = 128

    /// Online backup of a rollback-journal source. READONLY never recovers or
    /// checkpoints the live source. Refuse WAL rather than write its SHM read marks.
    static func copyDatabase(
        from source: URL,
        to destination: URL,
        expectedStamp: Stamp? = nil,
        cancellation: Cancellation? = nil,
        pagesPerStep: Int32 = backupPagesPerStep
    ) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8) else { throw Failure.unsafeFile }
        guard header[18] != 2 else { throw Failure.unsupportedWAL }
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer {
            if let input { sqlite3_close_v2(input) }
            if let output { sqlite3_close_v2(output) }
        }
        // NOFOLLOW also rejects /var -> /private/var. The component check above
        // has already rejected application-state aliases; resolve OS parents only.
        try requireDirectory(source.deletingLastPathComponent())
        try requireDirectory(destination.deletingLastPathComponent())
        let inputPath = try physicalPath(source)
        let outputPath = try physicalPath(destination)
        var code = sqlite3_open_v2(inputPath, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let input else { throw Failure.database(code) }
        sqlite3_busy_timeout(input, 250)
        code = sqlite3_open_v2(outputPath, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let output else { throw Failure.database(code) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw Failure.database(sqlite3_errcode(output))
        }
        // Finish always runs before the connections close (defers unwind in reverse), so a
        // cancelled partial destination is released and left only inside the doomed stage.
        var finish = SQLITE_OK
        var validated = Set<String>()
        do {
            defer { finish = sqlite3_backup_finish(backup) }
            repeat {
                try cancellation?.check()
                code = sqlite3_backup_step(backup, pagesPerStep)
                // A write between batches makes SQLite restart the backup; against a busy
                // source that need never converge. End this attempt instead and let the
                // bounded capture retry start from a fresh verified plan.
                if let expectedStamp, try observe(source, validated: &validated) != expectedStamp { throw Failure.sourceChanged }
            } while code == SQLITE_OK
        }
        // Lock contention from a production writer is a transient source change, retried
        // within the same bounded attempts rather than failing startup outright.
        if [SQLITE_BUSY, SQLITE_LOCKED].contains(code & 0xFF) { throw Failure.sourceChanged }
        guard code == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.database(code == SQLITE_DONE ? finish : code) }
    }

    func publish(plan: Plan, cleanSlate: Bool, preferences: Data, previousPreferences: Data, startedAt: Date = Date(), profileLease: DebugProfileAccessLease? = nil) throws -> Receipt {
        let lease = try profileLease ?? DebugProfileAccessLease.acquire(locations: locations, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let root = locations.applicationSupportRoot
        try locations.validateWritableRoot(root)
        let parent = root.deletingLastPathComponent()
        try Self.requireDirectory(parent)
        let recovery = parent.appendingPathComponent("RepoPrompt CE Debug Recovery", isDirectory: true)
        try locations.validateWritableRoot(recovery)
        if fm.fileExists(atPath: recovery.path) { try Self.requireDirectory(recovery) }
        else { try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        // Prove consistency before staging anything. Publication below writes only these
        // verified captured bytes, so later production writes cannot tear the snapshot.
        try plan.verify()
        try plan.cancellation?.check()
        // Temporary staging/recovery shares the destination's volume. Never copy
        // or follow an existing debug root while protecting it from replacement.
        let stage = recovery.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let recordURL = recovery.appendingPathComponent(stage.lastPathComponent + ".json")
        let record = RecoveryRecord(version: 1, profile: locations.preferencesDomain, createdAt: Date(), previousPreferences: previousPreferences)
        try JSONEncoder().encode(record).write(to: recordURL, options: .withoutOverwriting)
        var published = false
        defer {
            if !published {
                try? fm.removeItem(at: stage)
                try? fm.removeItem(at: recordURL)
            }
        }
        var seen = Set<String>()
        var bytes = 0
        for entry in plan.entries {
            try plan.cancellation?.check()
            let target = stage.appendingPathComponent(entry.relativePath).standardizedFileURL
            guard target.pathComponents.starts(with: stage.pathComponents), target.path != stage.path,
                  seen.insert(target.path).inserted else { throw Failure.duplicateDestination }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if entry.database {
                try Self.copyDatabase(from: entry.source, to: target, expectedStamp: plan.observed[entry.source], cancellation: plan.cancellation)
            } else {
                guard let data = entry.replacement else { throw Failure.unsafeFile }
                try data.write(to: target, options: .withoutOverwriting)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try bytes += Int(Self.stamp(target).size)
        }
        for (relative, data) in plan.generated {
            try plan.cancellation?.check()
            let target = stage.appendingPathComponent(relative).standardizedFileURL
            guard target.pathComponents.starts(with: stage.pathComponents), target.path != stage.path, seen.insert(target.path).inserted else { throw Failure.duplicateDestination }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: .withoutOverwriting)
            bytes += data.count
        }
        try preferences.write(to: stage.appendingPathComponent("seedPreferences.plist"), options: .withoutOverwriting)
        try plan.verifyDatabaseReads()
        let receipt = Receipt(
            version: 1,
            profile: locations.preferencesDomain,
            cleanSlate: cleanSlate,
            copiedFiles: plan.entries.count + plan.generated.count,
            copiedBytes: bytes,
            seconds: Date().timeIntervalSince(startedAt)
        )
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("debugSeed.json"), options: .withoutOverwriting)
        // Last safe stopping point: after the swap the new profile is published and complete.
        try plan.cancellation?.check()
        if fm.fileExists(atPath: root.path) {
            try Self.requireDirectory(root)
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.unsafeDestination
            }
            // stage now contains the prior debug profile, intact and recoverable.
            published = true
            // The ownership/preferences receipt lives beside, not inside, the
            // displaced profile: every prior debug file keeps its exact bytes.
        } else {
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure.unsafeDestination
            }
            published = true
            try? fm.removeItem(at: recordURL)
        }
        // Delete only archives created by this bootstrap. Unknown directories
        // and partial/crash leftovers are not ours to discard automatically.
        pruneRecovery(recovery)
        return receipt
    }

    private func pruneRecovery(_ directory: URL) {
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        // A displaced pre-bootstrap profile may contain unrelated provider or
        // historical data. Archiving it does not make all its bytes ours to prune.
        // Keep that unclassified original; bound only recognized seed snapshots.
        let owned = children.compactMap { url -> (URL, Date)? in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  (try? Self.requireDirectory(url)) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(url.lastPathComponent + ".json")),
                  let receipt = try? JSONDecoder().decode(RecoveryRecord.self, from: data), receipt.version == 1,
                  receipt.profile == locations.preferencesDomain,
                  let seedData = try? Data(contentsOf: url.appendingPathComponent("debugSeed.json")),
                  let seed = try? JSONDecoder().decode(Receipt.self, from: seedData),
                  seed.version == 1, seed.profile == locations.preferencesDomain else { return nil }
            return (url, receipt.createdAt)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in owned.dropFirst(3) {
            do {
                try fm.removeItem(at: url)
                try fm.removeItem(at: directory.appendingPathComponent(url.lastPathComponent + ".json"))
            } catch { /* Preserve a failed cleanup for the next bounded prune. */ }
        }
    }
}
