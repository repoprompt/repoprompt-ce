import Darwin
import Foundation

struct TipHistoryStagingRecord: Codable, Equatable {
    let id: UUID
    let path: String
    let createdAt: Date
    let device: Int32
    let inode: UInt64
    var cleanupDisabled = false
}

/// Only directories recorded here, carrying the same ownership marker/inode,
/// older than 24 hours and exclusively lockable are eligible for deferred cleanup.
/// This is a private cache registry, never UserDefaults or a destination sweep.
actor TipHistoryStagingRegistry {
    private var uncertainStages: [UUID: TipHistoryOwnedStaging] = [:]
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    func preserveUncertain(_ stage: TipHistoryOwnedStaging) {
        uncertainStages[stage.record.id] = stage
        try? transaction { records in
            if let index = records.firstIndex(where: { $0.id == stage.record.id }) { records[index].cleanupDisabled = true }
        }
    }

    private func directory() throws -> URL {
        let root: URL
        if let directoryOverride { root = directoryOverride }
        else {
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let bundle = Bundle.main.bundleIdentifier ?? "com.repoprompt.ce.unidentified"
            root = cache.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("TipHistoryAcquisition", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw TipHistoryDownloadError.fileSystem }
        return root
    }

    private func transaction<T>(_ body: (inout [TipHistoryStagingRecord]) throws -> T) throws -> T {
        let root = try directory()
        let fd = open(root.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TipHistoryDownloadError.fileSystem }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TipHistoryDownloadError.fileSystem }
        defer { flock(fd, LOCK_UN) }
        let url = root.appendingPathComponent("attempts.json")
        var records: [TipHistoryStagingRecord] = []
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if input >= 0 {
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                close(input)
                throw TipHistoryDownloadError.fileSystem
            }
            let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144 else { throw TipHistoryDownloadError.fileSystem }
            records = try JSONDecoder().decode([TipHistoryStagingRecord].self, from: data)
        } else if errno != ENOENT { throw TipHistoryDownloadError.fileSystem }
        guard records.count <= 128 else { throw TipHistoryDownloadError.fileSystem }
        let result = try body(&records)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }

    func register(_ record: TipHistoryStagingRecord) throws {
        try transaction { records in
            guard records.count < 128, !records.contains(where: { $0.id == record.id }) else { throw TipHistoryDownloadError.fileSystem }
            records.append(record)
        }
    }

    func remove(_ id: UUID) {
        try? transaction { $0.removeAll { $0.id == id } }
    }

    func removeStaleStaging(now: Date = Date()) {
        guard let records = try? transaction({ Array($0.filter { !$0.cleanupDisabled && now.timeIntervalSince($0.createdAt) >= 86400 }.prefix(10)) }) else { return }
        for record in records {
            let url = URL(fileURLWithPath: record.path, isDirectory: true)
            guard TipHistoryOwnedStaging.matches(record, at: url) else { continue }
            let fd = open(url.appendingPathComponent("attempt.lock").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(fd, LOCK_UN) }
            guard TipHistoryOwnedStaging.matches(record, at: url) else { continue }
            do {
                try TipHistoryOwnedStaging.removeVerified(record, at: url)
                remove(record.id)
            } catch {
                // Unavailable external volumes and denied paths are left alone.
            }
        }
    }
}

final class TipHistoryOwnedStaging: Sendable {
    let url: URL
    let payloadURL: URL
    let archiveURL: URL
    let record: TipHistoryStagingRecord
    private let lockDescriptor: Int32

    init(destination: URL, id: UUID) throws {
        let destination = try Self.validatedDestination(destination)
        let manager = FileManager.default
        let root = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true).resolvingSymlinksInPath()
        var ownsRoot = false
        do {
            guard try manager.contentsOfDirectory(atPath: root.path).isEmpty else { throw TipHistoryDownloadError.fileSystem }
            ownsRoot = true
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var info = stat()
            var destinationInfo = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  stat(destination.path, &destinationInfo) == 0, info.st_dev == destinationInfo.st_dev,
                  info.st_uid == geteuid()
            else { throw TipHistoryDownloadError.fileSystem }
            let record = TipHistoryStagingRecord(id: id, path: root.path, createdAt: Date(), device: info.st_dev, inode: info.st_ino)
            try JSONEncoder().encode(record).write(to: root.appendingPathComponent("ownership.json"), options: .atomic)
            let descriptor = open(root.appendingPathComponent("attempt.lock").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw TipHistoryDownloadError.fileSystem }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw TipHistoryDownloadError.fileSystem
            }
            url = root
            payloadURL = root.appendingPathComponent("payload", isDirectory: true)
            archiveURL = root.appendingPathComponent("verified.zip")
            self.record = record
            lockDescriptor = descriptor
        } catch {
            if ownsRoot { try? manager.removeItem(at: root) }
            throw error
        }
    }

    deinit { close(lockDescriptor) }

    func remove() throws {
        try Self.removeVerified(record, at: url)
    }

    static func removeVerified(_ record: TipHistoryStagingRecord, at url: URL) throws {
        guard matches(record, at: url) else { throw TipHistoryDownloadError.fileSystem }
        // Keep the marker until large recursive removals have succeeded, so a
        // crash or unavailable volume leaves ownership proof for a later retry.
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            guard matches(record, at: url) else { throw TipHistoryDownloadError.fileSystem }
            if child.lastPathComponent == "ownership.json" || child.lastPathComponent == "attempt.lock" { continue }
            try FileManager.default.removeItem(at: child)
        }
        guard matches(record, at: url) else { throw TipHistoryDownloadError.fileSystem }
        guard unlink(url.appendingPathComponent("ownership.json").path) == 0,
              unlink(url.appendingPathComponent("attempt.lock").path) == 0,
              rmdir(url.path) == 0
        else { throw TipHistoryDownloadError.fileSystem }
    }

    static func matches(_ record: TipHistoryStagingRecord, at url: URL) -> Bool {
        var info = stat()
        guard url.isFileURL, url.path == record.path, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0, info.st_uid == geteuid(), info.st_dev == record.device, info.st_ino == record.inode
        else { return false }
        let fd = open(url.appendingPathComponent("ownership.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var markerInfo = stat()
        guard fstat(fd, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG, markerInfo.st_uid == geteuid() else {
            close(fd)
            return false
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let bytes = try? handle.read(upToCount: 4097), bytes.count <= 4096,
              let marker = try? JSONDecoder().decode(TipHistoryStagingRecord.self, from: bytes)
        else { return false }
        return marker == record
    }

    /// A chosen download folder is not permission to install into Applications
    /// or mutate a running/other app bundle. Compare inode identity as well as
    /// resolved paths so macOS's /System/Volumes/Data firmlink cannot bypass it.
    static func validatedDestination(_ destination: URL) throws -> URL {
        guard destination.isFileURL else { throw TipHistoryDownloadError.accessDenied }
        let destination = destination.resolvingSymlinksInPath()
        var info = stat()
        guard stat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw TipHistoryDownloadError.accessDenied }
        let applications = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let blocked = applications.compactMap { url -> (Int32, UInt64)? in
            var value = stat()
            guard stat(url.path, &value) == 0 else { return nil }
            return (value.st_dev, value.st_ino)
        }
        var ancestor = destination
        // Foundation may represent deleting the volume root as a distinct URL
        // spelling. Stop before deleting root; require strict path shortening.
        while ancestor.path.count > 1 {
            guard !["app", "framework", "bundle", "xctest"].contains(ancestor.pathExtension.lowercased()) else { throw TipHistoryDownloadError.accessDenied }
            var value = stat()
            if stat(ancestor.path, &value) == 0, blocked.contains(where: { $0.0 == value.st_dev && $0.1 == value.st_ino }) { throw TipHistoryDownloadError.accessDenied }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path.count < ancestor.path.count else { throw TipHistoryDownloadError.accessDenied }
            ancestor = parent
        }
        return destination
    }

    static func requireCapacity(at destination: URL, download: TipHistoryDownload, allocationHeadroom: Int64 = 0) throws {
        guard download.size > 0, download.size <= 2_147_483_648, download.expandedSize > 0, download.expandedSize <= 8_589_934_592, allocationHeadroom >= 0, allocationHeadroom <= 1_638_400_000 else { throw TipHistoryDownloadError.archiveLimitExceeded }
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let required = download.size + download.expandedSize * 2 + allocationHeadroom + 64 * 1024 * 1024
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= required else {
            throw TipHistoryDownloadError.insufficientDiskSpace
        }
    }

    /// Main-actor caller owns the generation/context/cancel commit fence. This
    /// synchronous, exclusive rename must run inside that fence without awaits.
    static func commit(payload: URL, destination: URL, build: String, shortSHA: String) throws -> URL {
        let destination = try validatedDestination(destination)
        guard TipHistoryRepository.matches(build, #"^[0-9]+(\.[0-9]+){0,2}$"#), TipHistoryRepository.matches(shortSHA, #"^[0-9a-f]{12}$"#) else { throw TipHistoryDownloadError.fileSystem }
        var sourceInfo = stat()
        var destinationInfo = stat()
        guard lstat(payload.path, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFDIR,
              stat(destination.path, &destinationInfo) == 0, sourceInfo.st_dev == destinationInfo.st_dev
        else { throw TipHistoryDownloadError.fileSystem }
        for suffix in 1 ... 1000 {
            let name = "RepoPrompt CE Tip \(build) (\(shortSHA))" + (suffix == 1 ? "" : " \(suffix)")
            let final = destination.appendingPathComponent(name, isDirectory: true)
            if renamex_np(payload.path, final.path, UInt32(RENAME_EXCL)) == 0 { return final }
            guard errno == EEXIST else { throw TipHistoryDownloadError.fileSystem }
        }
        throw TipHistoryDownloadError.fileSystem
    }
}
