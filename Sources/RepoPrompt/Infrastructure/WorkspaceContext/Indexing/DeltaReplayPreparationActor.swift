import Foundation
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

enum RepoFileReplayPerf {
    #if DEBUG || EDIT_FLOW_PERF
        typealias State = OSSignpostIntervalState
        static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "file-replay")
        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: "enableRepoFileReplaySignposts")
        }

        static func begin(_ name: StaticString) -> State? {
            guard isEnabled else { return nil }
            return signposter.beginInterval(name)
        }

        static func end(_ name: StaticString, _ state: State?) {
            guard isEnabled, let state else { return }
            signposter.endInterval(name, state)
        }
    #else
        struct State {}
        static var isEnabled: Bool {
            false
        }

        static func begin(_ name: StaticString) -> State? {
            nil
        }

        static func end(_ name: StaticString, _ state: State?) {}
    #endif
}

struct PreparedFileSystemDelta {
    let delta: FileSystemDelta
    let relativePath: String
    let absolutePath: String

    var isFolderAdded: Bool {
        if case .folderAdded = delta {
            return true
        }
        return false
    }

    var isFolderRemoved: Bool {
        if case .folderRemoved = delta {
            return true
        }
        return false
    }
}

struct PreparedFolderRenameTransfer: Equatable {
    let oldAbsolutePath: String
    let newAbsolutePath: String
}

struct PreparedFileSystemReplayChunkSummary: Equatable {
    var fileAddedCount: Int = 0
    var fileRemovedCount: Int = 0
    var folderAddedCount: Int = 0
    var folderRemovedCount: Int = 0
    var fileModifiedCount: Int = 0
    var folderModifiedCount: Int = 0

    var modifiedCount: Int {
        fileModifiedCount + folderModifiedCount
    }
}

struct PreparedFileSystemReplayChunk: Equatable {
    let range: Range<Int>
    let deltaCount: Int
    let summary: PreparedFileSystemReplayChunkSummary
    let renameTransfers: [PreparedFolderRenameTransfer]
}

struct PreparedFileSystemReplayBatch {
    let rootKey: String
    let queuedDeltaCount: Int
    let coalescedDeltaCount: Int
    let preparedDeltas: [PreparedFileSystemDelta]
    let chunks: [PreparedFileSystemReplayChunk]
    let coalesceDurationMS: Double
    let preparationDurationMS: Double

    var discardedDeltaCount: Int {
        max(queuedDeltaCount - coalescedDeltaCount, 0)
    }
}

enum FileSystemDeltaPreparation {
    private static func timestampMS() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    static func rawRelativePath(for delta: FileSystemDelta) -> String {
        switch delta {
        case let .fileAdded(rel), let .fileRemoved(rel),
             let .folderAdded(rel), let .folderRemoved(rel),
             let .fileModified(rel, _), let .folderModified(rel, _):
            rel
        }
    }

    static func standardizedRelativePath(for delta: FileSystemDelta) -> String {
        StandardizedPath.relative(rawRelativePath(for: delta))
    }

    static func containedPaths(
        for delta: FileSystemDelta,
        inRoot standardizedRoot: String
    ) -> (relativePath: String, absolutePath: String)? {
        let rawRelativePath = rawRelativePath(for: delta)
        guard !rawRelativePath.hasPrefix("/") else { return nil }
        let relativePath = standardizedRelativePath(for: delta)
        let joined = StandardizedPath.join(
            standardizedRoot: standardizedRoot,
            standardizedRelativePath: relativePath
        )
        let absolutePath = relativePath == ".." || relativePath.hasPrefix("../")
            ? StandardizedPath.absolute(joined)
            : joined
        guard StandardizedPath.isDescendant(absolutePath, of: standardizedRoot) else { return nil }
        return (relativePath, absolutePath)
    }

    static func prepare(
        _ delta: FileSystemDelta,
        inRoot standardizedRoot: String
    ) -> PreparedFileSystemDelta? {
        guard let contained = containedPaths(for: delta, inRoot: standardizedRoot) else { return nil }
        return PreparedFileSystemDelta(
            delta: delta,
            relativePath: contained.relativePath,
            absolutePath: contained.absolutePath
        )
    }

    static func coalesce(
        _ deltas: [FileSystemDelta],
        inRoot standardizedRoot: String? = nil
    ) -> [FileSystemDelta] {
        enum ItemKind {
            case file
            case folder
        }
        struct Key: Hashable {
            let rel: String
            let kind: ItemKind
        }
        struct State {
            var add: (idx: Int, delta: FileSystemDelta, rel: String)?
            var remove: (idx: Int, delta: FileSystemDelta, rel: String)?
            var modify: (idx: Int, delta: FileSystemDelta, rel: String)?
        }

        var table: [Key: State] = [:]
        for (idx, delta) in deltas.enumerated() {
            let rel: String
            if let standardizedRoot {
                guard let contained = containedPaths(for: delta, inRoot: standardizedRoot) else { continue }
                rel = contained.relativePath
            } else {
                rel = standardizedRelativePath(for: delta)
            }
            let kind: ItemKind = switch delta {
            case .fileAdded, .fileRemoved, .fileModified:
                .file
            case .folderAdded, .folderRemoved, .folderModified:
                .folder
            }
            let key = Key(rel: rel, kind: kind)
            switch delta {
            case .fileAdded, .folderAdded:
                table[key, default: State()].add = (idx, delta, rel)
            case .fileRemoved, .folderRemoved:
                table[key, default: State()].remove = (idx, delta, rel)
            case .fileModified, .folderModified:
                table[key, default: State()].modify = (idx, delta, rel)
            }
        }

        var chosen: [(idx: Int, delta: FileSystemDelta, rel: String)] = []
        for state in table.values {
            if let add = state.add, let remove = state.remove {
                chosen.append(add.idx > remove.idx ? add : remove)
            } else if let add = state.add {
                chosen.append(add)
            } else if let remove = state.remove {
                chosen.append(remove)
            }
            if let modify = state.modify,
               state.add == nil,
               state.remove == nil
            {
                chosen.append(modify)
            }
        }

        let removedFolders = chosen.compactMap { pair -> String? in
            if case .folderRemoved = pair.delta {
                return pair.rel
            }
            return nil
        }

        if !removedFolders.isEmpty {
            chosen.removeAll { pair in
                for folder in removedFolders where pair.rel != folder {
                    if StandardizedPath.isDescendant(pair.rel, of: folder) {
                        return true
                    }
                }
                return false
            }
        }

        return chosen.sorted { $0.idx < $1.idx }.map(\.delta)
    }

    static func makeChunkRanges(totalCount: Int, chunkSize: Int) -> [Range<Int>] {
        guard totalCount > 0 else { return [] }
        let safeChunkSize = max(chunkSize, 1)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity((totalCount + safeChunkSize - 1) / safeChunkSize)
        var chunkStart = 0
        while chunkStart < totalCount {
            let chunkEnd = min(chunkStart + safeChunkSize, totalCount)
            ranges.append(chunkStart ..< chunkEnd)
            chunkStart = chunkEnd
        }
        return ranges
    }

    private static func makeReplayChunk(
        from preparedDeltas: [PreparedFileSystemDelta],
        range: Range<Int>
    ) -> PreparedFileSystemReplayChunk {
        var summary = PreparedFileSystemReplayChunkSummary()
        var addedFoldersByParent: [String: [String]] = [:]
        var removedFolders: [(parent: String, absolutePath: String)] = []

        for prepared in preparedDeltas[range] {
            switch prepared.delta {
            case .fileAdded:
                summary.fileAddedCount += 1
            case .fileRemoved:
                summary.fileRemovedCount += 1
            case .folderAdded:
                summary.folderAddedCount += 1
                let parent = (prepared.relativePath as NSString).deletingLastPathComponent
                addedFoldersByParent[parent, default: []].append(prepared.absolutePath)
            case .folderRemoved:
                summary.folderRemovedCount += 1
                removedFolders.append(
                    (parent: (prepared.relativePath as NSString).deletingLastPathComponent, absolutePath: prepared.absolutePath)
                )
            case .fileModified:
                summary.fileModifiedCount += 1
            case .folderModified:
                summary.folderModifiedCount += 1
            }
        }

        var parentCursor: [String: Int] = [:]
        var renameTransfers: [PreparedFolderRenameTransfer] = []
        for removed in removedFolders {
            guard let addedFolders = addedFoldersByParent[removed.parent] else { continue }
            let nextIndex = parentCursor[removed.parent, default: 0]
            guard nextIndex < addedFolders.count else { continue }
            renameTransfers.append(
                PreparedFolderRenameTransfer(
                    oldAbsolutePath: removed.absolutePath,
                    newAbsolutePath: addedFolders[nextIndex]
                )
            )
            parentCursor[removed.parent] = nextIndex + 1
        }

        return PreparedFileSystemReplayChunk(
            range: range,
            deltaCount: range.count,
            summary: summary,
            renameTransfers: renameTransfers
        )
    }

    static func prepareBatch(
        rootKey: String,
        deltas: [FileSystemDelta],
        chunkSize: Int
    ) -> PreparedFileSystemReplayBatch {
        let coalesceStartMS = timestampMS()
        let coalesced = coalesce(deltas, inRoot: rootKey)
        let coalesceDurationMS = timestampMS() - coalesceStartMS
        let prepareStartMS = timestampMS()
        let preparedDeltas = coalesced.compactMap { prepare($0, inRoot: rootKey) }
        let chunkRanges = makeChunkRanges(totalCount: preparedDeltas.count, chunkSize: chunkSize)
        let chunks = chunkRanges.map { makeReplayChunk(from: preparedDeltas, range: $0) }
        return PreparedFileSystemReplayBatch(
            rootKey: rootKey,
            queuedDeltaCount: deltas.count,
            coalescedDeltaCount: coalesced.count,
            preparedDeltas: preparedDeltas,
            chunks: chunks,
            coalesceDurationMS: coalesceDurationMS,
            preparationDurationMS: timestampMS() - prepareStartMS
        )
    }
}

actor DeltaReplayPreparationActor: DeltaReplayPreparing {
    func prepare(
        rootKey: String,
        deltas: [FileSystemDelta],
        chunkSize: Int
    ) async -> PreparedFileSystemReplayBatch {
        let signpost = RepoFileReplayPerf.begin("prepareReplayBatch")
        defer { RepoFileReplayPerf.end("prepareReplayBatch", signpost) }
        return FileSystemDeltaPreparation.prepareBatch(
            rootKey: rootKey,
            deltas: deltas,
            chunkSize: chunkSize
        )
    }
}
