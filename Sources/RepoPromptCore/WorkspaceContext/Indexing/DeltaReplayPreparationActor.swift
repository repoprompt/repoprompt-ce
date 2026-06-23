import Foundation

package struct PreparedFileSystemDelta {
    package let delta: FileSystemDelta
    package let relativePath: String
    package let absolutePath: String

    var isFolderAdded: Bool {
        if case .folderAdded = delta { return true }
        return false
    }

    var isFolderRemoved: Bool {
        if case .folderRemoved = delta { return true }
        return false
    }
}

package struct PreparedFolderRenameTransfer: Equatable {
    package let oldAbsolutePath: String
    package let newAbsolutePath: String
}

package struct PreparedFileSystemReplayChunkSummary: Equatable {
    package var fileAddedCount: Int = 0
    package var fileRemovedCount: Int = 0
    package var folderAddedCount: Int = 0
    package var folderRemovedCount: Int = 0
    var fileModifiedCount: Int = 0
    var folderModifiedCount: Int = 0

    package var modifiedCount: Int {
        fileModifiedCount + folderModifiedCount
    }
}

package struct PreparedFileSystemReplayChunk: Equatable {
    package let range: Range<Int>
    package let deltaCount: Int
    package let summary: PreparedFileSystemReplayChunkSummary
    package let renameTransfers: [PreparedFolderRenameTransfer]
}

package struct PreparedFileSystemReplayBatch {
    package let rootKey: String
    package let queuedDeltaCount: Int
    package let coalescedDeltaCount: Int
    package let preparedDeltas: [PreparedFileSystemDelta]
    package let chunks: [PreparedFileSystemReplayChunk]
    package let coalesceDurationMS: Double
    package let preparationDurationMS: Double

    package var discardedDeltaCount: Int {
        max(queuedDeltaCount - coalescedDeltaCount, 0)
    }
}

package enum FileSystemDeltaPreparation {
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

    package static func standardizedRelativePath(for delta: FileSystemDelta) -> String {
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

    package static func prepare(
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

    package static func coalesce(
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
            if case .folderRemoved = pair.delta { return pair.rel }
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

package actor DeltaReplayPreparationActor: DeltaReplayPreparing {
    package init() {}

    package func prepare(
        rootKey: String,
        deltas: [FileSystemDelta],
        chunkSize: Int
    ) async -> PreparedFileSystemReplayBatch {
        let signpost = WorkspaceRuntimePerf.begin("prepareReplayBatch")
        defer { WorkspaceRuntimePerf.end("prepareReplayBatch", signpost) }
        return FileSystemDeltaPreparation.prepareBatch(
            rootKey: rootKey,
            deltas: deltas,
            chunkSize: chunkSize
        )
    }
}
