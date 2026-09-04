import Foundation

/// Current discovery controls eligibility. Remembered metadata only resolves saved
/// selections after a provider omits a model; it must not repopulate the picker.
final class ProviderModelDiscoveryCache<Record: Codable> {
    let key: String
    let identity: (Record) -> String
    private let lock = NSLock()
    private var decoded: Snapshot?

    private struct Snapshot {
        let defaults: UserDefaults
        let currentData: Data?
        let historyData: Data?
        let current: [Record]
        let remembered: [Record]
    }

    init(key: String, identity: @escaping (Record) -> String) {
        self.key = key
        self.identity = identity
    }

    func current(defaults: UserDefaults = .standard) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot(defaults: defaults).current
    }

    func remembered(defaults: UserDefaults = .standard) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot(defaults: defaults).remembered
    }

    @discardableResult
    func save(_ records: [Record], defaults: UserDefaults = .standard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = snapshot(defaults: defaults)
        let current = merged([], records)
        let remembered = merged(previous.remembered, current)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(current),
              let history = try? encoder.encode(remembered) else { return false }
        let changed = previous.currentData != data
        defaults.set(history, forKey: key + ".savedSelectionMetadata")
        defaults.set(data, forKey: key)
        decoded = Snapshot(defaults: defaults, currentData: data, historyData: history, current: current, remembered: remembered)
        return changed
    }

    /// Picker sorting resolves many model IDs; decode once per persisted snapshot.
    /// Data comparison also observes writes from another window/process or test suite.
    private func snapshot(defaults: UserDefaults) -> Snapshot {
        let currentData = defaults.data(forKey: key)
        let historyData = defaults.data(forKey: key + ".savedSelectionMetadata")
        if let decoded, decoded.defaults === defaults,
           decoded.currentData == currentData, decoded.historyData == historyData
        {
            return decoded
        }
        let current = decode(currentData)
        let snapshot = Snapshot(
            defaults: defaults,
            currentData: currentData,
            historyData: historyData,
            current: current,
            remembered: merged(decode(historyData), current)
        )
        decoded = snapshot
        return snapshot
    }

    private func decode(_ data: Data?) -> [Record] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func merged(_ old: [Record], _ new: [Record]) -> [Record] {
        var byID = Dictionary(old.map { (identity($0), $0) }, uniquingKeysWith: { _, latest in latest })
        for record in new {
            byID[identity(record)] = record
        }
        return byID.sorted { $0.key < $1.key }.map(\.value)
    }
}
