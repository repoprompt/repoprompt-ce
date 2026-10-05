import Foundation

package struct WorkspaceRootByteExactPathKey: Hashable, Comparable {
    package let value: String
    private let bytes: [UInt8]

    package init(_ value: String) {
        self.value = value
        bytes = Array(value.utf8)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.count)
        for byte in bytes {
            hasher.combine(byte)
        }
    }

    package var parent: Self? {
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")), slash > bytes.startIndex else {
            return nil
        }
        return Self(String(decoding: bytes[..<slash], as: UTF8.self))
    }

    package func isSameOrDescendant(of ancestor: Self) -> Bool {
        if ancestor.bytes.isEmpty {
            return true
        }
        if bytes == ancestor.bytes {
            return true
        }
        return bytes.starts(with: ancestor.bytes + [UInt8(ascii: "/")])
    }
}

package struct WorkspaceRootByteExactPathSet: Equatable {
    private let valuesByKey: [WorkspaceRootByteExactPathKey: String]

    package init?(
        _ paths: some Sequence<String>,
        rejectExactDuplicates: Bool = false
    ) {
        var valuesByKey: [WorkspaceRootByteExactPathKey: String] = [:]
        var canonicalRepresentatives: [String: WorkspaceRootByteExactPathKey] = [:]
        for path in paths {
            let key = WorkspaceRootByteExactPathKey(path)
            if valuesByKey[key] != nil {
                if rejectExactDuplicates {
                    return nil
                }
                continue
            }
            if let existing = canonicalRepresentatives[path], existing != key {
                return nil
            }
            valuesByKey[key] = path
            canonicalRepresentatives[path] = key
        }
        self.valuesByKey = valuesByKey
    }

    private init(valuesByKey: [WorkspaceRootByteExactPathKey: String]) {
        self.valuesByKey = valuesByKey
    }

    package var count: Int {
        valuesByKey.count
    }

    package var isEmpty: Bool {
        valuesByKey.isEmpty
    }

    package var keys: Set<WorkspaceRootByteExactPathKey> {
        Set(valuesByKey.keys)
    }

    package var sortedKeys: [WorkspaceRootByteExactPathKey] {
        valuesByKey.keys.sorted()
    }

    package var stringValues: [String] {
        sortedKeys.map(\.value)
    }

    package func contains(_ key: WorkspaceRootByteExactPathKey) -> Bool {
        valuesByKey[key] != nil
    }

    package func subtracting(_ other: Self) -> Self {
        Self(valuesByKey: valuesByKey.filter { !other.contains($0.key) })
    }
}

package struct WorkspaceRootCatalogPolicyIdentity: Hashable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let mandatoryIgnorePolicyIdentity: String
    package let globalIgnoreDefaultsDigest: String
    package let respectRepoIgnore: Bool
    package let respectCursorignore: Bool
    package let enableHierarchicalIgnores: Bool
    package let skipSymlinks: Bool

    package init(schemaVersion: Int, mandatoryIgnorePolicyIdentity: String, globalIgnoreDefaultsDigest: String, respectRepoIgnore: Bool, respectCursorignore: Bool, enableHierarchicalIgnores: Bool, skipSymlinks: Bool) {
        self.schemaVersion = schemaVersion
        self.mandatoryIgnorePolicyIdentity = mandatoryIgnorePolicyIdentity
        self.globalIgnoreDefaultsDigest = globalIgnoreDefaultsDigest
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.enableHierarchicalIgnores = enableHierarchicalIgnores
        self.skipSymlinks = skipSymlinks
    }
}

package enum WorkspaceRootCommittedRegularProjectionDisposition: Equatable {
    case searchableRegularFile
    case policyIgnoredRegularFile
    case ineligible(CatalogRegularFileIneligibilityReason)
}

package struct WorkspaceRootCatalogProjectionEvidence: Equatable {
    package let policyIdentity: WorkspaceRootCatalogPolicyIdentity
    package let dispositionsByRelativePath: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition]
    package let ignoreRulesRevision: UInt64
    package init(policyIdentity: WorkspaceRootCatalogPolicyIdentity, dispositionsByRelativePath: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition], ignoreRulesRevision: UInt64) {
        self.policyIdentity = policyIdentity
        self.dispositionsByRelativePath = dispositionsByRelativePath
        self.ignoreRulesRevision = ignoreRulesRevision
    }
}

package struct WorkspaceRootValidatedCatalogProjection {
    package let discoverableRelativeFilePaths: WorkspaceRootByteExactPathSet
    package let policyIgnoredCommittedRegularRelativePaths: WorkspaceRootByteExactPathSet
    package let policyIdentity: WorkspaceRootCatalogPolicyIdentity
    package init(discoverableRelativeFilePaths: WorkspaceRootByteExactPathSet, policyIgnoredCommittedRegularRelativePaths: WorkspaceRootByteExactPathSet, policyIdentity: WorkspaceRootCatalogPolicyIdentity) {
        self.discoverableRelativeFilePaths = discoverableRelativeFilePaths
        self.policyIgnoredCommittedRegularRelativePaths = policyIgnoredCommittedRegularRelativePaths
        self.policyIdentity = policyIdentity
    }
}

package enum WorkspaceGitignorePolicyIdentity: String, Hashable {
    case gitIgnoreFloorV3 = "mandatory-gitignore-floor-reachable-controls-v3"

    package static let current = WorkspaceGitignorePolicyIdentity.gitIgnoreFloorV3
}
