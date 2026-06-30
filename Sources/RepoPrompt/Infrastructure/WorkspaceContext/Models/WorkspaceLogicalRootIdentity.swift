import Foundation

enum WorkspaceLogicalRootIdentity {
    struct RootDescriptor {
        let physicalRootID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let preferredName: String
    }

    static func label(for rootEpoch: WorkspaceCodemapRootEpoch) -> String {
        "root@\(rootEpoch.rootID.uuidString.lowercased())+\(rootEpoch.rootLifetimeID.uuidString.lowercased())"
    }

    static func labels(for descriptors: [RootDescriptor]) -> [UUID: String] {
        let nameCounts = Dictionary(grouping: descriptors) {
            $0.preferredName.lowercased()
        }.mapValues(\.count)
        let ordered = descriptors.sorted { lhs, rhs in
            let lhsLabel = label(for: lhs.rootEpoch)
            let rhsLabel = label(for: rhs.rootEpoch)
            if lhsLabel != rhsLabel {
                return lhsLabel.utf8.lexicographicallyPrecedes(rhsLabel.utf8)
            }
            return lhs.physicalRootID.uuidString < rhs.physicalRootID.uuidString
        }
        let preferredLabels = Dictionary(
            uniqueKeysWithValues: ordered.map { descriptor in
                let preferredName = descriptor.preferredName
                let usePreferredName = !preferredName.isEmpty
                    && nameCounts[preferredName.lowercased()] == 1
                return (
                    descriptor.physicalRootID,
                    usePreferredName ? preferredName : label(for: descriptor.rootEpoch)
                )
            }
        )
        let labelCounts = Dictionary(grouping: preferredLabels.values) {
            $0.lowercased()
        }.mapValues(\.count)
        return Dictionary(
            uniqueKeysWithValues: ordered.map { descriptor in
                let preferredLabel = preferredLabels[descriptor.physicalRootID]
                    ?? label(for: descriptor.rootEpoch)
                let resolvedLabel = labelCounts[preferredLabel.lowercased()] == 1
                    ? preferredLabel
                    : label(for: descriptor.rootEpoch)
                return (descriptor.physicalRootID, resolvedLabel)
            }
        )
    }
}

extension WorkspaceLookupContext {
    func logicalRootDisplayNamesByRootID(
        store: WorkspaceFileContextStore
    ) async -> [UUID: String] {
        let physicalRoots = await store.rootRefs(scope: rootScope)
        let rootEpochs = await store.codemapRootEpochs(scope: rootScope)
        let boundLogicalNames = Dictionary(
            (bindingProjection?.boundRootsForMetadata ?? []).map {
                ($0.physicalRoot.id, $0.logicalRoot.name)
            },
            uniquingKeysWith: { current, _ in current }
        )
        return WorkspaceLogicalRootIdentity.labels(for: physicalRoots.compactMap { physicalRoot in
            guard let rootEpoch = rootEpochs[physicalRoot.id] else { return nil }
            return WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: physicalRoot.id,
                rootEpoch: rootEpoch,
                preferredName: boundLogicalNames[physicalRoot.id] ?? physicalRoot.name
            )
        })
    }

    func logicalDisplayPath(
        for file: WorkspaceFileRecord,
        roots: [WorkspaceRootRef],
        rootDisplayNamesByRootID: [UUID: String],
        display: FilePathDisplay
    ) -> String? {
        guard roots.contains(where: { $0.id == file.rootID }) else { return nil }
        if display == .full {
            return bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: file.standardizedFullPath,
                display: .full
            ) ?? file.standardizedFullPath
        }
        guard
            let rootLabel = rootDisplayNamesByRootID[file.rootID]
        else { return nil }
        let relativePath = file.standardizedRelativePath
        if roots.count == 1 {
            return relativePath
        }
        return relativePath.isEmpty ? rootLabel : "\(rootLabel)/\(relativePath)"
    }
}
