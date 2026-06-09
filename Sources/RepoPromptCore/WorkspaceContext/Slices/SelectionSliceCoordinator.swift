import Foundation

/// Dormant value-based façade around `PartitionStore` for selection slice persistence.
///
/// This service intentionally does not read or write compose-tab `StoredSelection` values.
/// `WorkspaceManagerViewModel` remains the only writer of compose-tab selections; this
/// coordinator only loads and mutates partition-backed slice state.
package actor SelectionSliceCoordinator {
    package struct RootScopeRequest {
        let rootPath: String
        let scope: PartitionScope

        init(rootPath: String, scope: PartitionScope) {
            self.rootPath = (rootPath as NSString).standardizingPath
            self.scope = scope
        }

        init(root: WorkspaceRootRecord, scope: PartitionScope) {
            self.init(rootPath: root.standardizedFullPath, scope: scope)
        }
    }

    package struct SliceUpdate {
        let relativePath: String
        let ranges: [LineRange]
        let fileModificationTime: Double?
        let anchors: [SliceAnchor]?

        init(
            relativePath: String,
            ranges: [LineRange],
            fileModificationTime: Double?,
            anchors: [SliceAnchor]? = nil
        ) {
            self.relativePath = StandardizedPath.relative(relativePath)
            self.ranges = ranges
            self.fileModificationTime = fileModificationTime
            self.anchors = anchors
        }

        init(file: WorkspaceFileRecord, ranges: [LineRange], anchors: [SliceAnchor]? = nil) {
            self.init(
                relativePath: file.standardizedRelativePath,
                ranges: ranges,
                fileModificationTime: file.modificationDate?.timeIntervalSince1970,
                anchors: anchors
            )
        }
    }

    private let store: PartitionStore
    package nonisolated let notificationSourceID: UUID

    package init(store: PartitionStore) {
        self.store = store
        notificationSourceID = store.notificationSourceID
    }

    // MARK: - Loading

    package func loadSlices(
        forRootPath rootPath: String,
        scope: PartitionScope
    ) async -> [String: PartitionStore.StoredSlices] {
        let standardizedRoot = (rootPath as NSString).standardizingPath
        let data = await store.load(forRoot: standardizedRoot, scope: scope)
        return data.files
    }

    package func loadSlices(
        forRoot root: WorkspaceRootRecord,
        scope: PartitionScope
    ) async -> [String: PartitionStore.StoredSlices] {
        await loadSlices(forRootPath: root.standardizedFullPath, scope: scope)
    }

    package func loadSlices(
        forRoots roots: [WorkspaceRootRecord],
        scope: PartitionScope
    ) async -> [String: [String: PartitionStore.StoredSlices]] {
        await loadSlices(
            for: roots.map { RootScopeRequest(root: $0, scope: scope) }
        )
    }

    package func loadSlices(
        for requests: [RootScopeRequest]
    ) async -> [String: [String: PartitionStore.StoredSlices]] {
        var result: [String: [String: PartitionStore.StoredSlices]] = [:]
        for request in requests {
            let data = await store.load(forRoot: request.rootPath, scope: request.scope)
            result[request.rootPath] = data.files
        }
        return result
    }

    // MARK: - Applying updates

    @discardableResult
    package func applyPartitionUpdates(
        forRootPath rootPath: String,
        scope: PartitionScope,
        updates: [String: PartitionStore.SliceUpdate],
        mode: SliceMutationMode
    ) async throws -> [String: PartitionStore.StoredSlices] {
        try await store.apply(
            forRoot: (rootPath as NSString).standardizingPath,
            scope: scope,
            updates: updates,
            mode: mode
        )
    }

    @discardableResult
    package func applySliceUpdates(
        groupedByRootPath updatesByRootPath: [String: [SliceUpdate]],
        scope: PartitionScope,
        mode: SliceMutationMode
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        var result: [String: [String: PartitionStore.StoredSlices]] = [:]
        for (rootPath, updates) in updatesByRootPath {
            let standardizedRoot = (rootPath as NSString).standardizingPath
            let partitionUpdates = Self.partitionUpdates(from: updates)
            let post = try await store.apply(
                forRoot: standardizedRoot,
                scope: scope,
                updates: partitionUpdates,
                mode: mode
            )
            result[standardizedRoot] = post
        }
        return result
    }

    @discardableResult
    package func applySliceUpdates(
        groupedByRootPath updatesByRootPath: [String: [String: SliceUpdate]],
        scope: PartitionScope,
        mode: SliceMutationMode
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        let flattened = updatesByRootPath.mapValues { Array($0.values) }
        return try await applySliceUpdates(groupedByRootPath: flattened, scope: scope, mode: mode)
    }

    // MARK: - Moves and clears

    @discardableResult
    package func moveSliceState(
        rootPath: String,
        oldRelativePath: String,
        newRelativePath: String,
        scope: PartitionScope
    ) async throws -> [String: PartitionStore.StoredSlices] {
        let standardizedRoot = (rootPath as NSString).standardizingPath
        let oldKey = StandardizedPath.relative(oldRelativePath)
        let newKey = StandardizedPath.relative(newRelativePath)
        guard oldKey != newKey else {
            return await loadSlices(forRootPath: standardizedRoot, scope: scope)
        }

        let data = await store.load(forRoot: standardizedRoot, scope: scope)
        guard let existing = data.files[oldKey] else { return data.files }

        _ = try await store.apply(
            forRoot: standardizedRoot,
            scope: scope,
            updates: [
                oldKey: PartitionStore.SliceUpdate(
                    ranges: [],
                    fileModificationTime: existing.fileModificationTime,
                    anchors: []
                )
            ],
            mode: .remove
        )

        return try await store.apply(
            forRoot: standardizedRoot,
            scope: scope,
            updates: [
                newKey: PartitionStore.SliceUpdate(
                    ranges: existing.ranges,
                    fileModificationTime: existing.fileModificationTime,
                    anchors: existing.anchors
                )
            ],
            mode: .add
        )
    }

    @discardableResult
    package func clearSlices(
        forRootPaths rootPaths: [String],
        scope: PartitionScope
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        var result: [String: [String: PartitionStore.StoredSlices]] = [:]
        for rootPath in rootPaths {
            let standardizedRoot = (rootPath as NSString).standardizingPath
            let post = try await store.apply(
                forRoot: standardizedRoot,
                scope: scope,
                updates: [:],
                mode: .set
            )
            result[standardizedRoot] = post
        }
        return result
    }

    @discardableResult
    package func clearSlices(
        forRoots roots: [WorkspaceRootRecord],
        scope: PartitionScope
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        try await clearSlices(forRootPaths: roots.map(\.standardizedFullPath), scope: scope)
    }

    @discardableResult
    package func removeSlices(
        forPaths pathsByRootPath: [String: [String]],
        scope: PartitionScope
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        var updatesByRoot: [String: [SliceUpdate]] = [:]
        for (rootPath, relativePaths) in pathsByRootPath {
            updatesByRoot[rootPath] = relativePaths.map {
                SliceUpdate(relativePath: $0, ranges: [], fileModificationTime: nil, anchors: [])
            }
        }
        return try await applySliceUpdates(groupedByRootPath: updatesByRoot, scope: scope, mode: .remove)
    }

    @discardableResult
    package func removeSlices(
        forRootPaths rootPaths: [String],
        scope: PartitionScope
    ) async throws -> [String: [String: PartitionStore.StoredSlices]] {
        var pathsByRoot: [String: [String]] = [:]
        for rootPath in rootPaths {
            let standardizedRoot = (rootPath as NSString).standardizingPath
            let loaded = await loadSlices(forRootPath: standardizedRoot, scope: scope)
            pathsByRoot[standardizedRoot] = Array(loaded.keys)
        }
        return try await removeSlices(forPaths: pathsByRoot, scope: scope)
    }

    // MARK: - Projection

    package nonisolated static func buildFileIDProjection(
        from sliceMapsByRootPath: [String: [String: PartitionStore.StoredSlices]],
        files: [WorkspaceFileRecord]
    ) -> [UUID: [LineRange]] {
        var normalizedMaps: [String: [String: PartitionStore.StoredSlices]] = [:]
        for (rootPath, map) in sliceMapsByRootPath {
            normalizedMaps[(rootPath as NSString).standardizingPath] = map
        }

        var projection: [UUID: [LineRange]] = [:]
        for file in files {
            guard let rootMap = normalizedMaps[fileRootPath(for: file, in: normalizedMaps.keys)],
                  let stored = rootMap[file.standardizedRelativePath],
                  !stored.ranges.isEmpty
            else { continue }
            projection[file.id] = stored.ranges
        }
        return projection
    }

    private nonisolated static func partitionUpdates(
        from updates: [SliceUpdate]
    ) -> [String: PartitionStore.SliceUpdate] {
        var result: [String: PartitionStore.SliceUpdate] = [:]
        for update in updates {
            var existing = result[update.relativePath] ?? PartitionStore.SliceUpdate(
                ranges: [],
                fileModificationTime: update.fileModificationTime,
                anchors: update.anchors
            )
            existing.ranges.append(contentsOf: update.ranges)
            existing.fileModificationTime = update.fileModificationTime ?? existing.fileModificationTime
            existing.anchors = update.anchors ?? existing.anchors
            result[update.relativePath] = existing
        }
        return result
    }

    private nonisolated static func fileRootPath(
        for file: WorkspaceFileRecord,
        in rootPaths: Dictionary<String, [String: PartitionStore.StoredSlices]>.Keys
    ) -> String {
        let standardizedFull = file.standardizedFullPath
        let relative = file.standardizedRelativePath
        for rootPath in rootPaths {
            let expectedFull = URL(fileURLWithPath: rootPath)
                .appendingPathComponent(relative)
                .path
            if (expectedFull as NSString).standardizingPath == standardizedFull {
                return rootPath
            }
        }
        return (standardizedFull as NSString).deletingLastPathComponent
    }
}
