import CryptoKit
import Foundation

public enum SliceMutationMode: Sendable {
    case add
    case set
    case remove
    case setPaths // file-scoped replacement: replace slices only for specified files
}

package struct SliceAnchor: Codable, Equatable {
    var range: LineRange
    var startSignature: [String]
    var endSignature: [String]

    init(
        range: LineRange,
        startSignature: [String] = [],
        endSignature: [String] = []
    ) {
        self.range = range
        self.startSignature = startSignature
        self.endSignature = endSignature
    }
}

public struct PartitionScope: Sendable, Equatable {
    public let workspaceID: UUID
    public let tabID: UUID?

    public init(workspaceID: UUID, tabID: UUID? = nil) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

package struct PartitionStoreSaveEvent: Equatable {
    package let rootPath: String
    package let workspaceID: UUID
    package let tabID: UUID?
    package let sourceID: UUID
}

package actor PartitionStore {
    /// Posted **after** a successful save so other windows/tabs reload in-memory slices.
    package static let didSaveNotification = Notification.Name("RepoPrompt.PartitionStoreDidSave")
    package static let notifRootPathKey = "rootPath"
    package static let notifWorkspaceIDKey = "workspaceID"
    package static let notifTabIDKey = "tabID"
    package static let notifSourceIDKey = "sourceID"
    package nonisolated let notificationSourceID = UUID()
    private static let partitionFileLock = NSLock()

    private static func withPartitionFileLock<T>(_ body: () throws -> T) rethrows -> T {
        partitionFileLock.lock()
        defer { partitionFileLock.unlock() }
        return try body()
    }

    /// repoKey = "<leafName>-<sha256(stdPath)[0..12]>"
    private func repoKey(forRoot rootPath: String) -> String {
        let std = (rootPath as NSString).standardizingPath
        let leaf = (std as NSString).lastPathComponent
        let digest = SHA256.hash(data: Data(std.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let short = String(hex.prefix(12))
        return "\(leaf)-\(short)"
    }

    package struct StoredSlices: Codable, Equatable {
        package var ranges: [LineRange]
        package var fileModificationTime: Double?
        package var anchors: [SliceAnchor]?

        package init(
            ranges: [LineRange],
            fileModificationTime: Double?,
            anchors: [SliceAnchor]? = nil
        ) {
            self.ranges = ranges
            self.fileModificationTime = fileModificationTime
            self.anchors = anchors
        }
    }

    package struct SliceUpdate {
        package var ranges: [LineRange]
        package var fileModificationTime: Double?
        package var anchors: [SliceAnchor]?

        package init(
            ranges: [LineRange],
            fileModificationTime: Double?,
            anchors: [SliceAnchor]? = nil
        ) {
            self.ranges = ranges
            self.fileModificationTime = fileModificationTime
            self.anchors = anchors
        }
    }

    package struct PartitionData: Codable {
        var version: Int
        package var files: [String: StoredSlices]
        var updatedAt: String?

        static func empty() -> PartitionData {
            PartitionData(version: 1, files: [:], updatedAt: nil)
        }

        init(version: Int, files: [String: StoredSlices], updatedAt: String?) {
            self.version = version
            self.files = files
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case files
            case updatedAt
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            if let decoded = try? container.decode([String: StoredSlices].self, forKey: .files) {
                files = decoded
            } else {
                let legacy = try container.decode([String: [LineRange]].self, forKey: .files)
                files = legacy.mapValues { StoredSlices(ranges: $0, fileModificationTime: nil) }
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(files, forKey: .files)
            try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        }
    }

    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dateFormatter = ISO8601DateFormatter()
    private let saveObserver: @Sendable (PartitionStoreSaveEvent) -> Void

    #if DEBUG
        private var didPersistHandlerForTesting: (@Sendable () -> Void)?
        private var didValidateCurrentHandlerForTesting: (@Sendable () -> Void)?

        package func setDidPersistHandlerForTesting(_ handler: (@Sendable () -> Void)?) {
            didPersistHandlerForTesting = handler
        }

        package func setDidValidateCurrentHandlerForTesting(_ handler: (@Sendable () -> Void)?) {
            didValidateCurrentHandlerForTesting = handler
        }
    #endif

    package init(
        baseURL: URL,
        saveObserver: @escaping @Sendable (PartitionStoreSaveEvent) -> Void = { _ in }
    ) {
        self.baseURL = baseURL.standardizedFileURL
        self.saveObserver = saveObserver
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    package func load(forRoot rootPath: String, scope: PartitionScope) async -> PartitionData {
        Self.withPartitionFileLock {
            loadData(forRoot: rootPath, scope: scope)
        }
    }

    private func loadData(forRoot rootPath: String, scope: PartitionScope) -> PartitionData {
        let primaryURL = partitionURL(forRoot: rootPath, scope: scope)
        return loadPartition(at: primaryURL) ?? PartitionData.empty()
    }

    func save(
        forRoot rootPath: String,
        scope: PartitionScope,
        data: PartitionData
    ) async throws {
        try Self.withPartitionFileLock {
            try saveData(forRoot: rootPath, scope: scope, data: data)
        }
    }

    private func saveData(
        forRoot rootPath: String,
        scope: PartitionScope,
        data: PartitionData
    ) throws {
        try Task.checkCancellation()
        let url = partitionURL(forRoot: rootPath, scope: scope)

        // Ensure directories exist: .../Application Support/RepoPrompt CE/Partitions/<repoKey>/
        let dirURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        var dataToPersist = data
        dataToPersist.updatedAt = dateFormatter.string(from: Date())

        let encoded = try encoder.encode(dataToPersist)
        try Task.checkCancellation()
        try encoded.write(to: url, options: [.atomic])
        #if DEBUG
            didPersistHandlerForTesting?()
        #endif

        // The atomic replacement is the commit point. Once it succeeds, always publish
        // the matching notification even if the caller is cancelled concurrently.
        // Inform other windows/tabs within the process to reload slices for this scope.
        postSaveNotification(rootPath: rootPath, scope: scope)
    }

    /// High-level mutation helper that loads, mutates, persists, and returns the merged range map.
    /// Paths are expected to be standardized by the caller; ranges are normalized before persistence.
    @discardableResult
    package func apply(
        forRoot rootPath: String,
        scope: PartitionScope,
        updates: [String: SliceUpdate],
        mode: SliceMutationMode
    ) async throws -> [String: StoredSlices] {
        try applyBody(
            forRoot: rootPath,
            scope: scope,
            updates: updates,
            mode: mode,
            expectedCurrent: nil
        ) ?? [:]
    }

    /// Atomically applies file-scoped updates only when the persisted inputs still match.
    @discardableResult
    package func applyIfCurrent(
        forRoot rootPath: String,
        scope: PartitionScope,
        updates: [String: SliceUpdate],
        mode: SliceMutationMode,
        expectedCurrent: [String: StoredSlices]
    ) async throws -> [String: StoredSlices]? {
        try applyBody(
            forRoot: rootPath,
            scope: scope,
            updates: updates,
            mode: mode,
            expectedCurrent: expectedCurrent
        )
    }

    private func applyBody(
        forRoot rootPath: String,
        scope: PartitionScope,
        updates: [String: SliceUpdate],
        mode: SliceMutationMode,
        expectedCurrent: [String: StoredSlices]?
    ) throws -> [String: StoredSlices]? {
        Self.partitionFileLock.lock()
        defer { Self.partitionFileLock.unlock() }

        try Task.checkCancellation()
        var data = loadData(forRoot: rootPath, scope: scope)
        try Task.checkCancellation()
        if let expectedCurrent,
           !expectedCurrent.allSatisfy({ data.files[$0.key] == $0.value })
        {
            return nil
        }
        #if DEBUG
            if expectedCurrent != nil {
                didValidateCurrentHandlerForTesting?()
            }
        #endif
        switch mode {
        case .set:
            var next: [String: StoredSlices] = [:]
            for (path, update) in updates {
                let ranges = update.ranges
                let normalized = SliceRangeMath.normalize(ranges)
                if !normalized.isEmpty {
                    let normalizedAnchors = Self.sanitizedAnchors(update.anchors, for: normalized)
                    next[path] = StoredSlices(
                        ranges: normalized,
                        fileModificationTime: update.fileModificationTime,
                        anchors: normalizedAnchors
                    )
                }
            }
            data.files = next

        case .setPaths:
            for (path, update) in updates {
                let normalized = SliceRangeMath.normalize(update.ranges)
                if normalized.isEmpty {
                    data.files.removeValue(forKey: path)
                    continue
                }
                let existing = data.files[path]
                let modTime = update.fileModificationTime ?? existing?.fileModificationTime
                let anchors = Self.resolvedAnchors(
                    updateAnchors: update.anchors,
                    existingAnchors: existing?.anchors,
                    finalRanges: normalized
                )
                data.files[path] = StoredSlices(
                    ranges: normalized,
                    fileModificationTime: modTime,
                    anchors: anchors
                )
            }

        case .add:
            for (path, update) in updates {
                let ranges = update.ranges
                let normalized = SliceRangeMath.normalize(ranges)
                guard !normalized.isEmpty else { continue }
                let existing = data.files[path] ?? StoredSlices(ranges: [], fileModificationTime: nil)
                let combined = SliceRangeMath.coalesce(existing.ranges, normalized)
                if combined.isEmpty {
                    data.files.removeValue(forKey: path)
                } else {
                    let modTime = update.fileModificationTime ?? existing.fileModificationTime
                    let anchors = Self.mergedAnchors(
                        updateAnchors: update.anchors,
                        existingAnchors: existing.anchors,
                        finalRanges: combined
                    )
                    data.files[path] = StoredSlices(
                        ranges: combined,
                        fileModificationTime: modTime,
                        anchors: anchors
                    )
                }
            }

        case .remove:
            for (path, update) in updates {
                guard let current = data.files[path] else { continue }
                let ranges = update.ranges
                let normalized = SliceRangeMath.normalize(ranges)
                if normalized.isEmpty {
                    // Empty removal payload signals a full removal for this path.
                    data.files.removeValue(forKey: path)
                    continue
                }
                let remaining = SliceRangeMath.subtract(current.ranges, removing: normalized)
                if remaining.isEmpty {
                    data.files.removeValue(forKey: path)
                } else {
                    let anchors = Self.sanitizedAnchors(current.anchors, for: remaining)
                    data.files[path] = StoredSlices(
                        ranges: remaining,
                        fileModificationTime: current.fileModificationTime,
                        anchors: anchors
                    )
                }
            }
        }

        try Task.checkCancellation()
        try saveData(forRoot: rootPath, scope: scope, data: data)
        return data.files
    }

    private static func sanitizedAnchors(
        _ anchors: [SliceAnchor]?,
        for ranges: [LineRange]
    ) -> [SliceAnchor]? {
        guard let anchors, !anchors.isEmpty else { return nil }
        let normalizedRanges = SliceRangeMath.normalize(ranges)
        guard !normalizedRanges.isEmpty else { return nil }

        let allowed = Set(normalizedRanges.map { RangeKey(start: $0.start, end: $0.end) })
        let filtered = anchors.filter { anchor in
            allowed.contains(RangeKey(start: anchor.range.start, end: anchor.range.end))
        }
        return filtered.isEmpty ? nil : filtered
    }

    private static func mergedAnchors(
        updateAnchors: [SliceAnchor]?,
        existingAnchors: [SliceAnchor]?,
        finalRanges: [LineRange]
    ) -> [SliceAnchor]? {
        var byRange: [RangeKey: SliceAnchor] = [:]

        if let sanitizedExisting = sanitizedAnchors(existingAnchors, for: finalRanges) {
            for anchor in sanitizedExisting {
                let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
                byRange[key] = anchor
            }
        }

        if let sanitizedUpdate = sanitizedAnchors(updateAnchors, for: finalRanges) {
            for anchor in sanitizedUpdate {
                let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
                byRange[key] = anchor
            }
        }

        guard !byRange.isEmpty else { return nil }
        return byRange
            .values
            .sorted {
                if $0.range.start == $1.range.start {
                    return $0.range.end < $1.range.end
                }
                return $0.range.start < $1.range.start
            }
    }

    private static func resolvedAnchors(
        updateAnchors: [SliceAnchor]?,
        existingAnchors: [SliceAnchor]?,
        finalRanges: [LineRange]
    ) -> [SliceAnchor]? {
        if let updateAnchors {
            return sanitizedAnchors(updateAnchors, for: finalRanges)
        }
        return sanitizedAnchors(existingAnchors, for: finalRanges)
    }

    private struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    package func load(forRoot rootPath: String, workspaceID: UUID) async -> PartitionData {
        await load(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID))
    }

    func save(forRoot rootPath: String, workspaceID: UUID, data: PartitionData) async throws {
        try await save(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID), data: data)
    }

    @discardableResult
    package func apply(
        forRoot rootPath: String,
        workspaceID: UUID,
        updates: [String: SliceUpdate],
        mode: SliceMutationMode
    ) async throws -> [String: StoredSlices] {
        try await apply(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID), updates: updates, mode: mode)
    }

    // MARK: - Helpers

    private func partitionURL(forRoot rootPath: String, scope: PartitionScope) -> URL {
        let folder = baseURL.appendingPathComponent(repoKey(forRoot: rootPath), isDirectory: true)

        let suffix = if let tabID = scope.tabID {
            "-\(tabID.uuidString.lowercased())"
        } else {
            ""
        }
        let fileName = "filepartitions-\(scope.workspaceID.uuidString.lowercased())\(suffix).json"
        return folder.appendingPathComponent(fileName, isDirectory: false)
    }

    private func postSaveNotification(rootPath: String, scope: PartitionScope) {
        let stdRoot = (rootPath as NSString).standardizingPath
        saveObserver(PartitionStoreSaveEvent(
            rootPath: stdRoot,
            workspaceID: scope.workspaceID,
            tabID: scope.tabID,
            sourceID: notificationSourceID
        ))
    }

    private func loadPartition(at url: URL) -> PartitionData? {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(PartitionData.self, from: data)
        } catch {
            return nil
        }
    }
}
