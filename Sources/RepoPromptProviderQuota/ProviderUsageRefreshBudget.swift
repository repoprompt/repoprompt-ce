import Foundation

/// Durable, non-secret admission metadata. Conservative rolling-day caps survive relaunches.
/// A corrupt/unwritable record denies background work; manual refresh remains independent.
package actor ProviderUsageRefreshBudget {
    private let url: URL
    private let now: @Sendable () -> Date
    private var records: [String: [Date]]?
    private var unavailable = false

    package init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    package func reserve(profile: String, minimumGap: TimeInterval, dailyLimit: Int) -> Bool {
        guard !profile.isEmpty, minimumGap > 0, dailyLimit > 0, !unavailable else { return false }
        do {
            if records == nil {
                if FileManager.default.fileExists(atPath: url.path) {
                    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                    guard let size, size.intValue <= 65536 else { unavailable = true
                        return false
                    }
                    let loaded = try JSONDecoder().decode([String: [Date]].self, from: Data(contentsOf: url))
                    guard loaded.count <= 32, loaded.values.allSatisfy({ $0.count <= 12 }) else { unavailable = true
                        return false
                    }
                    records = loaded
                } else { records = [:] }
            }
            let time = now()
            var next = records ?? [:]
            for key in Array(next.keys) {
                let retained = (next[key] ?? []).filter { time.timeIntervalSince($0) < 86400 }
                next[key] = retained.isEmpty ? nil : retained
            }
            let history = next[profile] ?? []
            guard history.count < dailyLimit, history.allSatisfy({ time.timeIntervalSince($0) >= minimumGap }) else { return false }
            guard next[profile] != nil || next.count < 32 else { return false }
            next[profile] = history + [time]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(next)
            // The temporary inode already has private permissions; atomic rename cannot expose metadata.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            defer { try? FileManager.default.removeItem(at: temporary) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: url) }
            records = next
            return true
        } catch {
            unavailable = true
            return false
        }
    }
}
