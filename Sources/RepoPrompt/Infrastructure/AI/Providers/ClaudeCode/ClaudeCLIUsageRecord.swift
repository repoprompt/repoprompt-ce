import CoreFoundation
import Darwin
import Foundation
import RepoPromptProviderQuota

/// Statistics-only wire/cache shape. Never carries a token, transcript, or account identity.
struct ClaudeCLIUsageRecord: Codable, Equatable {
    struct Window: Codable, Equatable {
        let used: Double
        let resetsAt: Double?
    }

    let version: Int
    let receivedAt: Date
    let windows: [String: Window]

    static func extract(_ data: Data, now: Date = Date()) -> Self? {
        guard data.count <= 65536,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let limits = payload["rate_limits"] as? [String: Any] ?? [:]
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        var windows: [String: Window] = [:]
        for role in ["five_hour", "seven_day"] {
            guard let row = limits[role] as? [String: Any], let used = number(row["used_percentage"]), (0 ... 100).contains(used) else { continue }
            let reset = number(row["resets_at"]).flatMap { $0 > 0 && $0 < 253_402_300_800 ? $0 : nil }
            windows[role] = Window(used: used, resetsAt: reset)
        }
        return Self(version: 1, receivedAt: now, windows: windows)
    }

    var isValid: Bool {
        version == 1 && receivedAt.timeIntervalSince1970.isFinite && windows.count <= 2
            && windows.allSatisfy { role, value in
                ["five_hour", "seven_day"].contains(role) && value.used.isFinite && (0 ... 100).contains(value.used)
                    && (value.resetsAt.map { $0.isFinite && $0 > 0 && $0 < 253_402_300_800 } ?? true)
            }
    }

    func snapshot(profileID: String) -> ProviderQuotaSnapshot {
        let id = ProviderQuotaBucketID.synthesizedDefault
        let rows = ["five_hour", "seven_day"].compactMap { role -> ProviderQuotaWindow? in
            guard let value = windows[role] else { return nil }
            return ProviderQuotaWindow(
                key: .init(bucketID: id, nativeRole: role),
                percent: ProviderQuotaPercent(rawValue: value.used, sense: .used, declaredUpperBound: 100),
                windowDuration: role == "five_hour" ? 5 * 60 * 60 : 7 * 24 * 60 * 60,
                resetsAt: value.resetsAt.map { Date(timeIntervalSince1970: $0) },
                observedAt: receivedAt
            )
        }
        let bucket = ProviderQuotaBucket(
            bucketID: id,
            displayLabel: nil,
            nativeModelAlias: nil,
            scope: .accountWide,
            reachedType: nil,
            isReached: nil,
            planType: nil,
            credits: nil,
            spendControl: nil,
            windows: rows
        )
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profileID),
            buckets: [bucket],
            facets: .empty,
            source: .claudeCLIUsage,
            coverage: .accountWideAggregateOnly,
            observedAt: receivedAt
        )
    }
}

/// Private bounded files shared by the collector and acquisition source. No credential IO.
enum ClaudeCLIUsageFiles {
    static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isPrivateDirectory(url) else { throw ProviderQuotaReadError.invalidResponse }
    }

    static func read(_ url: URL, limit: Int = 4096) -> Data? {
        guard isPrivateDirectory(url.deletingLastPathComponent()) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size >= 0, info.st_size <= limit else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1)
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= 65536, isPrivateDirectory(url.deletingLastPathComponent()) else { throw ProviderQuotaReadError.invalidResponse }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProviderQuotaReadError.transport }
        defer { close(fd)
            unlink(temporary.path)
        }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard rename(temporary.path, url.path) == 0 else { throw ProviderQuotaReadError.transport }
    }
}

/// Invoked as a child, before app bootstrap. Outputs nothing and has a hard input timeout.
enum ClaudeCLIUsageCollector {
    static let flag = "--rpce-claude-usage-collector"
    static func runIfInvoked(arguments: [String]) -> Int32? {
        guard arguments.contains(flag) else { return nil }
        guard arguments.count == 3, arguments[1] == flag, arguments[2].hasPrefix("/") else { return 1 }
        alarm(3)
        defer { alarm(0) }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard ClaudeCLIUsageFiles.isPrivateDirectory(root) else { return 1 }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 65536 {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }
                return 1
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let record = ClaudeCLIUsageRecord.extract(data), let output = try? JSONEncoder().encode(record) else { return 1 }
        do { try ClaudeCLIUsageFiles.write(output, to: root.appendingPathComponent("latest.json"))
            return 0
        } catch { return 1 }
    }
}

struct ClaudeCLIUsageCache {
    private struct Envelope: Codable { let profileID: String
        let record: ClaudeCLIUsageRecord
    }

    let root: URL
    func load(profileID: String) -> ClaudeCLIUsageRecord? {
        guard let data = ClaudeCLIUsageFiles.read(root.appendingPathComponent("cache.json")),
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.profileID == profileID,
              value.record.isValid, !value.record.windows.isEmpty, value.record.receivedAt <= Date().addingTimeInterval(60)
        else { return nil }
        return value.record
    }

    func save(_ record: ClaudeCLIUsageRecord, profileID: String) throws {
        guard record.isValid, !record.windows.isEmpty else { throw ProviderQuotaReadError.invalidResponse }
        try ClaudeCLIUsageFiles.createDirectory(root)
        try ClaudeCLIUsageFiles.write(JSONEncoder().encode(Envelope(profileID: profileID, record: record)), to: root.appendingPathComponent("cache.json"))
    }

    func clear() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("cache.json"))
    }
}
