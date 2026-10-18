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
        var replacement: Data?
        var database = false
    }

    struct Plan {
        var entries: [Entry] = []
        var generated: [String: Data] = [:]
        var observed: [URL: Stamp] = [:]
        var directories: [URL: [String]] = [:]

        mutating func read(_ url: URL) throws -> Data {
            let before = try DebugStateSnapshot.stamp(url)
            let bytes = try Data(contentsOf: url)
            guard try DebugStateSnapshot.stamp(url) == before else { throw Failure.sourceChanged }
            observed[url] = before
            return bytes
        }

        mutating func children(_ url: URL) throws -> [URL] {
            try DebugStateSnapshot.requireDirectory(url)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            directories[url] = names
            return names.map { url.appendingPathComponent($0) }
        }

        mutating func add(_ source: URL, as relativePath: String, replacement: Data? = nil, database: Bool = false) throws {
            if observed[source] == nil { observed[source] = try DebugStateSnapshot.stamp(source) }
            entries.append(Entry(source: source, relativePath: relativePath, replacement: replacement, database: database))
            if database {
                for suffix in ["-wal", "-shm", "-journal"] {
                    let companion = URL(fileURLWithPath: source.path + suffix)
                    if FileManager.default.fileExists(atPath: companion.path) {
                        observed[companion] = try DebugStateSnapshot.stamp(companion)
                    }
                }
            }
        }

        func verify() throws {
            for (url, expected) in observed {
                guard try DebugStateSnapshot.stamp(url) == expected else { throw Failure.sourceChanged }
            }
            for (url, expected) in directories {
                guard try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() == expected else { throw Failure.sourceChanged }
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
        case sourceChanged, unsafeFile, unsafeDestination, duplicateDestination, database(Int32), unsupportedWAL
        var errorDescription: String? {
            switch self {
            case .sourceChanged: "Production state changed during capture. Retry when release is idle; no profile was replaced."
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
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        // Resolve OS aliases, not app-owned symlink components.
        var parent = url.standardizedFileURL
        while parent.path != "/" {
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK
                || ["/tmp", "/var"].contains(parent.path) else { throw Failure.unsafeFile }
            parent.deleteLastPathComponent()
        }
    }

    static func stamp(_ url: URL) throws -> Stamp {
        try requireDirectory(url.deletingLastPathComponent())
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        return Stamp(
            inode: UInt64(info.st_ino),
            size: info.st_size,
            seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    static func physicalPath(_ url: URL) throws -> String {
        var parent = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = url.deletingLastPathComponent().path.withCString { rpce_catalog_resolve_directory($0, &parent) }
        guard result == 0 else { throw Failure.unsafeFile }
        return String(cString: parent) + "/" + url.lastPathComponent
    }

    /// Online backup of a rollback-journal source. READONLY never recovers or
    /// checkpoints the live source. Refuse WAL rather than write its SHM read marks.
    static func copyDatabase(from source: URL, to destination: URL) throws {
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
        code = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
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
            let target = stage.appendingPathComponent(entry.relativePath).standardizedFileURL
            guard target.pathComponents.starts(with: stage.pathComponents), target.path != stage.path,
                  seen.insert(target.path).inserted else { throw Failure.duplicateDestination }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if entry.database { try Self.copyDatabase(from: entry.source, to: target) }
            else {
                let data = try entry.replacement ?? Data(contentsOf: entry.source)
                try data.write(to: target, options: .withoutOverwriting)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try bytes += Int(Self.stamp(target).size)
        }
        for (relative, data) in plan.generated {
            let target = stage.appendingPathComponent(relative).standardizedFileURL
            guard target.pathComponents.starts(with: stage.pathComponents), target.path != stage.path, seen.insert(target.path).inserted else { throw Failure.duplicateDestination }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: .withoutOverwriting)
            bytes += data.count
        }
        try preferences.write(to: stage.appendingPathComponent("seedPreferences.plist"), options: .withoutOverwriting)
        try plan.verify()
        let receipt = Receipt(
            version: 1,
            profile: locations.preferencesDomain,
            cleanSlate: cleanSlate,
            copiedFiles: plan.entries.count + plan.generated.count,
            copiedBytes: bytes,
            seconds: Date().timeIntervalSince(startedAt)
        )
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("debugSeed.json"), options: .withoutOverwriting)
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
