import CoreFoundation
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

/// Invoked as a child, before app bootstrap. Outputs nothing and has a hard input timeout.
enum ClaudeCLIUsageCollector {
    static let flag = "--rpce-claude-usage-collector"
    static func runIfInvoked(arguments: [String]) -> Int32? {
        guard arguments.contains(flag) else { return nil }
        guard arguments.count == 3, arguments[1] == flag, arguments[2].hasPrefix("/") else { return 1 }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard CLIUsagePrivateFiles.isPrivateDirectory(root), let data = CLIUsagePrivateFiles.readStatusLineInput(),
              let record = ClaudeCLIUsageRecord.extract(data), let output = try? JSONEncoder().encode(record) else { return 1 }
        do { try CLIUsagePrivateFiles.write(output, to: root.appendingPathComponent("latest.json"))
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
        guard let data = CLIUsagePrivateFiles.read(root.appendingPathComponent("cache.json")),
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.profileID == profileID,
              value.record.isValid, !value.record.windows.isEmpty, value.record.receivedAt <= Date().addingTimeInterval(60)
        else { return nil }
        return value.record
    }

    func save(_ record: ClaudeCLIUsageRecord, profileID: String) throws {
        guard record.isValid, !record.windows.isEmpty else { throw ProviderQuotaReadError.invalidResponse }
        try CLIUsagePrivateFiles.createDirectory(root)
        try CLIUsagePrivateFiles.write(JSONEncoder().encode(Envelope(profileID: profileID, record: record)), to: root.appendingPathComponent("cache.json"))
    }

    func clear() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("cache.json"))
    }
}
