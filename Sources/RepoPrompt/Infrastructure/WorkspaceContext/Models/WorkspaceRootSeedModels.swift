import CryptoKit
import Foundation

struct WorkspaceRootByteExactPathKey: Hashable, Comparable {
    let value: String
    private let bytes: [UInt8]

    init(_ value: String) {
        self.value = value
        bytes = Array(value.utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.count)
        for byte in bytes {
            hasher.combine(byte)
        }
    }

    static func rootRelativePath(
        repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        let pathBytes = Array(repositoryRelativePath.utf8)
        let prefixBytes = Array(prefix.value.utf8)
        guard !prefixBytes.isEmpty else { return repositoryRelativePath }
        let requiredPrefix = prefixBytes + [UInt8(ascii: "/")]
        guard pathBytes.starts(with: requiredPrefix), pathBytes.count > requiredPrefix.count else {
            return nil
        }
        return String(decoding: pathBytes.dropFirst(requiredPrefix.count), as: UTF8.self)
    }

    var parent: Self? {
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")), slash > bytes.startIndex else {
            return nil
        }
        return Self(String(decoding: bytes[..<slash], as: UTF8.self))
    }

    func isSameOrDescendant(of ancestor: Self) -> Bool {
        if ancestor.bytes.isEmpty { return true }
        if bytes == ancestor.bytes { return true }
        return bytes.starts(with: ancestor.bytes + [UInt8(ascii: "/")])
    }
}

struct WorkspaceRootByteExactPathSet: Equatable {
    private let valuesByKey: [WorkspaceRootByteExactPathKey: String]

    init?(
        _ paths: some Sequence<String>,
        rejectExactDuplicates: Bool = false
    ) {
        var valuesByKey: [WorkspaceRootByteExactPathKey: String] = [:]
        var canonicalRepresentatives: [String: WorkspaceRootByteExactPathKey] = [:]
        for path in paths {
            let key = WorkspaceRootByteExactPathKey(path)
            if valuesByKey[key] != nil {
                if rejectExactDuplicates { return nil }
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

    var count: Int {
        valuesByKey.count
    }

    var isEmpty: Bool {
        valuesByKey.isEmpty
    }

    var keys: Set<WorkspaceRootByteExactPathKey> {
        Set(valuesByKey.keys)
    }

    var sortedKeys: [WorkspaceRootByteExactPathKey] {
        valuesByKey.keys.sorted()
    }

    var stringValues: [String] {
        sortedKeys.map(\.value)
    }

    func contains(_ key: WorkspaceRootByteExactPathKey) -> Bool {
        valuesByKey[key] != nil
    }

    func subtracting(_ other: Self) -> Self {
        Self(valuesByKey: valuesByKey.filter { !other.contains($0.key) })
    }
}

struct WorkspaceRootCatalogPolicyIdentity: Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mandatoryIgnorePolicyIdentity: String
    let globalIgnoreDefaultsDigest: String
    let respectRepoIgnore: Bool
    let respectCursorignore: Bool
    let enableHierarchicalIgnores: Bool
    let skipSymlinks: Bool

    static let canonicalDefaults = WorkspaceRootCatalogPolicyIdentity(
        schemaVersion: currentSchemaVersion,
        mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
        globalIgnoreDefaultsDigest: IgnoreRulesManager.globalIgnoreDefaultsDigest(
            for: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        ),
        respectRepoIgnore: true,
        respectCursorignore: true,
        enableHierarchicalIgnores: true,
        skipSymlinks: true
    )
}

enum WorkspaceRootCommittedRegularProjectionDisposition: Equatable {
    case searchableRegularFile
    case policyIgnoredRegularFile
    case ineligible(CatalogRegularFileIneligibilityReason)
}

struct WorkspaceRootCatalogProjectionEvidence: Equatable {
    let policyIdentity: WorkspaceRootCatalogPolicyIdentity
    let dispositionsByRelativePath: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition]
    let ignoreRulesRevision: UInt64
}

struct WorkspaceRootValidatedCatalogProjection {
    let discoverableRelativeFilePaths: WorkspaceRootByteExactPathSet
    let policyIgnoredCommittedRegularRelativePaths: WorkspaceRootByteExactPathSet
    let policyIdentity: WorkspaceRootCatalogPolicyIdentity
}

enum WorkspaceRootSeedDeltaCompatibilitySource: String, CaseIterable, Hashable {
    case hintEvaluator
    case planner
}

enum WorkspaceRootSeedDeltaCompatibilityDecision: String, Hashable {
    case compatible
    case incompatible
}

enum WorkspaceRootSeedDeltaCompatibilityCorrectionRule: String, Hashable {
    case none
    case canonicalMissingResolvedExcludesFileIdentity
    case canonicalMissingResolvedAttributesFileIdentity
    case canonicalMissingResolvedExternalAuthorityIdentities
}

enum WorkspaceRootSeedDeltaCompatibilityField: String, CaseIterable, Hashable {
    case repositoryNamespace
    case objectFormat
    case repositoryRelativeRootPrefix
    case inventorySchemaVersion
    case mandatoryIgnorePolicyIdentity
    case committedIgnoreControlDigest
    case configuredIgnoreAuthorityDigest
    case attributePolicyDigest
    case sparsePolicyDigest
    case searchABIMatcherSchemaVersion
    case searchABIProjectedKeySchemaVersion
    case searchABIComparatorSchemaVersion
    case searchABIPathNormalizationSchemaVersion
    case resolvedExcludesFileIdentity
    case resolvedAttributesFileIdentity
}

enum WorkspaceRootSeedDeltaCompatibilityFieldDecision: String, Hashable {
    case match
    case mismatch
}

enum WorkspaceRootSeedDeltaCompatibilityTreeRelation: String, Hashable {
    case sameExcludedFromDeltaCompatibility
    case differentExcludedFromDeltaCompatibility
}

struct WorkspaceRootSeedDeltaCompatibilityFieldEvaluation: Hashable {
    let field: WorkspaceRootSeedDeltaCompatibilityField
    let decision: WorkspaceRootSeedDeltaCompatibilityFieldDecision
    let baseDigest: String
    let targetDigest: String
}

struct WorkspaceRootSeedDeltaCompatibilityEvaluation: Hashable {
    let source: WorkspaceRootSeedDeltaCompatibilitySource
    let decision: WorkspaceRootSeedDeltaCompatibilityDecision
    let fieldEvaluations: [WorkspaceRootSeedDeltaCompatibilityFieldEvaluation]
    let mismatchedFields: [WorkspaceRootSeedDeltaCompatibilityField]
    let correctionRuleApplied: WorkspaceRootSeedDeltaCompatibilityCorrectionRule
    let treeRelation: WorkspaceRootSeedDeltaCompatibilityTreeRelation
}

struct WorkspaceRootSeedCompatibilityKey: Hashable {
    static let currentInventorySchemaVersion = 5

    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let inventorySchemaVersion: Int
    let policyIdentity: GitWorkspacePolicyIdentity

    init(
        authority: GitWorkspaceAuthoritySnapshot,
        inventorySchemaVersion: Int = Self.currentInventorySchemaVersion
    ) {
        repositoryNamespace = authority.repositoryNamespace
        objectFormat = authority.objectFormat
        treeOID = authority.treeOID
        repositoryRelativeRootPrefix = authority.repositoryRelativeRootPrefix
        self.inventorySchemaVersion = inventorySchemaVersion
        policyIdentity = authority.policyIdentity
    }

    init(
        repositoryNamespace: GitBlobRepositoryNamespace,
        objectFormat: GitObjectFormat,
        treeOID: GitObjectID,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        inventorySchemaVersion: Int = Self.currentInventorySchemaVersion,
        policyIdentity: GitWorkspacePolicyIdentity
    ) {
        self.repositoryNamespace = repositoryNamespace
        self.objectFormat = objectFormat
        self.treeOID = treeOID
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.inventorySchemaVersion = inventorySchemaVersion
        self.policyIdentity = policyIdentity
    }

    var searchABI: GitWorkspaceSearchABIIdentity {
        policyIdentity.searchABI
    }

    func deltaCompatibilityEvaluation(
        with base: Self,
        source: WorkspaceRootSeedDeltaCompatibilitySource,
        correctionRuleApplied: WorkspaceRootSeedDeltaCompatibilityCorrectionRule = .none
    ) -> WorkspaceRootSeedDeltaCompatibilityEvaluation {
        let fieldEvaluations = Self.deltaCompatibilityFieldEvaluations(base: base, target: self)
        let mismatchedFields = fieldEvaluations.compactMap {
            $0.decision == .mismatch ? $0.field : nil
        }
        return WorkspaceRootSeedDeltaCompatibilityEvaluation(
            source: source,
            decision: mismatchedFields.isEmpty ? .compatible : .incompatible,
            fieldEvaluations: fieldEvaluations,
            mismatchedFields: mismatchedFields,
            correctionRuleApplied: correctionRuleApplied,
            treeRelation: treeOID == base.treeOID
                ? .sameExcludedFromDeltaCompatibility
                : .differentExcludedFromDeltaCompatibility
        )
    }

    /// Delta reuse deliberately excludes the committed tree object from compatibility.
    /// The planner proves that difference with a bounded tree-to-tree delta; every policy,
    /// prefix, repository, and matcher field must still match exactly.
    func isDeltaCompatible(with other: Self) -> Bool {
        Self.deltaCompatibilityFieldEvaluations(base: other, target: self).allSatisfy {
            $0.decision == .match
        }
    }

    private static func deltaCompatibilityFieldEvaluations(
        base: Self,
        target: Self
    ) -> [WorkspaceRootSeedDeltaCompatibilityFieldEvaluation] {
        let basePolicy = base.policyIdentity
        let targetPolicy = target.policyIdentity
        let baseABI = basePolicy.searchABI
        let targetABI = targetPolicy.searchABI
        return [
            field(.repositoryNamespace, base.repositoryNamespace.rawValue, target.repositoryNamespace.rawValue),
            field(.objectFormat, base.objectFormat.rawValue, target.objectFormat.rawValue),
            field(
                .repositoryRelativeRootPrefix,
                base.repositoryRelativeRootPrefix.value,
                target.repositoryRelativeRootPrefix.value
            ),
            field(.inventorySchemaVersion, base.inventorySchemaVersion, target.inventorySchemaVersion),
            field(
                .mandatoryIgnorePolicyIdentity,
                basePolicy.mandatoryIgnorePolicyIdentity,
                targetPolicy.mandatoryIgnorePolicyIdentity
            ),
            field(
                .committedIgnoreControlDigest,
                basePolicy.committedIgnoreControlDigest,
                targetPolicy.committedIgnoreControlDigest
            ),
            field(
                .configuredIgnoreAuthorityDigest,
                basePolicy.configuredIgnoreAuthorityDigest,
                targetPolicy.configuredIgnoreAuthorityDigest
            ),
            field(.attributePolicyDigest, basePolicy.attributePolicyDigest, targetPolicy.attributePolicyDigest),
            field(.sparsePolicyDigest, basePolicy.sparsePolicyDigest, targetPolicy.sparsePolicyDigest),
            field(
                .searchABIMatcherSchemaVersion,
                baseABI.matcherSchemaVersion,
                targetABI.matcherSchemaVersion
            ),
            field(
                .searchABIProjectedKeySchemaVersion,
                baseABI.projectedKeySchemaVersion,
                targetABI.projectedKeySchemaVersion
            ),
            field(
                .searchABIComparatorSchemaVersion,
                baseABI.comparatorSchemaVersion,
                targetABI.comparatorSchemaVersion
            ),
            field(
                .searchABIPathNormalizationSchemaVersion,
                baseABI.pathNormalizationSchemaVersion,
                targetABI.pathNormalizationSchemaVersion
            ),
            field(
                .resolvedExcludesFileIdentity,
                contentIdentityMaterial(basePolicy.resolvedExcludesFileIdentity),
                contentIdentityMaterial(targetPolicy.resolvedExcludesFileIdentity)
            ),
            field(
                .resolvedAttributesFileIdentity,
                contentIdentityMaterial(basePolicy.resolvedAttributesFileIdentity),
                contentIdentityMaterial(targetPolicy.resolvedAttributesFileIdentity)
            )
        ]
    }

    private static func field(
        _ field: WorkspaceRootSeedDeltaCompatibilityField,
        _ base: some CustomStringConvertible,
        _ target: some CustomStringConvertible
    ) -> WorkspaceRootSeedDeltaCompatibilityFieldEvaluation {
        let baseValue = String(describing: base)
        let targetValue = String(describing: target)
        return WorkspaceRootSeedDeltaCompatibilityFieldEvaluation(
            field: field,
            decision: baseValue == targetValue ? .match : .mismatch,
            baseDigest: fieldDigest(baseValue, field: field),
            targetDigest: fieldDigest(targetValue, field: field)
        )
    }

    private static func contentIdentityMaterial(_ identity: GitWorkspaceAuthorityContentIdentity?) -> String {
        guard let identity else { return "present=0" }
        return "present=1;exists=\(identity.exists ? 1 : 0);sha256=\(identity.sha256);bytes=\(identity.byteCount)"
    }

    private static func fieldDigest(
        _ value: String,
        field: WorkspaceRootSeedDeltaCompatibilityField
    ) -> String {
        let domain = "worktree-startup-delta-compatibility-v1/\(field.rawValue)"
        return SHA256.hash(data: Data("\(domain)\0\(value)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct WorkspaceRootReusableSnapshotIdentity: Hashable {
    let sha256: String
    let searchABI: GitWorkspaceSearchABIIdentity
}

struct RootNeutralTreeInventoryEntry: Hashable {
    enum Provenance: String, Hashable {
        case committedTree
    }

    enum CatalogProjection: String, Hashable {
        case searchableRegularFile
        case policyIgnoredRegularFile
        case nonRegularTopology
    }

    let ordinal: Int
    let parentOrdinal: Int?
    let relativePath: String
    let mode: String
    let kind: GitTreeEntryKind
    let objectID: GitObjectID
    let provenance: Provenance
    let catalogProjection: CatalogProjection

    init(
        ordinal: Int,
        parentOrdinal: Int?,
        relativePath: String,
        mode: String,
        kind: GitTreeEntryKind,
        objectID: GitObjectID,
        provenance: Provenance,
        catalogProjection: CatalogProjection? = nil
    ) {
        self.ordinal = ordinal
        self.parentOrdinal = parentOrdinal
        self.relativePath = relativePath
        self.mode = mode
        self.kind = kind
        self.objectID = objectID
        self.provenance = provenance
        self.catalogProjection = catalogProjection
            ?? (
                kind == .blob && (mode == "100644" || mode == "100755")
                    ? .searchableRegularFile
                    : .nonRegularTopology
            )
    }

    var isCommittedRegularFile: Bool {
        kind == .blob && (mode == "100644" || mode == "100755")
    }

    var isSearchableFile: Bool {
        isCommittedRegularFile && catalogProjection == .searchableRegularFile
    }
}

struct RootNeutralTreeInventory: Hashable {
    let entries: [RootNeutralTreeInventoryEntry]
}

final class WorkspaceSearchRelativePathBase: @unchecked Sendable {
    let relativePaths: [String]
    let filenames: [String]
    let stableOrdinals: [Int]
    let index: PathSearchIndex

    init(relativePaths: [String], stableOrdinals: [Int]) {
        precondition(relativePaths.count == stableOrdinals.count)
        self.relativePaths = relativePaths.map(StandardizedPath.relative)
        filenames = self.relativePaths.map { ($0 as NSString).lastPathComponent }
        self.stableOrdinals = stableOrdinals
        index = PathSearchIndex(paths: self.relativePaths)
    }
}

final class WorkspaceRootReusableSnapshot: @unchecked Sendable {
    static let contentAddressDomain = "workspace-root-reusable-snapshot-v5"
    static let manifestCompatibilityDomain = "workspace-root-reusable-inventory-v1"

    let identity: WorkspaceRootReusableSnapshotIdentity
    let compatibilityKey: WorkspaceRootSeedCompatibilityKey
    let inventoryManifest: WorkspaceRootReusableInventoryManifestLease
    let searchBase: WorkspaceSearchRelativePathBase
    let catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    let estimatedByteCount: Int
    let artifactByteCount: UInt64

    #if DEBUG
        /// Small-fixture inspection only. Production consumers must stream the
        /// leased manifest rather than materializing the inventory.
        var inventory: RootNeutralTreeInventory {
            RootNeutralTreeInventory(
                entries: (try? inventoryManifest.materializeForTesting()) ?? []
            )
        }
    #endif

    init(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventoryManifest: WorkspaceRootReusableInventoryManifestLease,
        searchBase: WorkspaceSearchRelativePathBase,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults,
        estimatedByteCount: Int
    ) {
        self.compatibilityKey = compatibilityKey
        self.inventoryManifest = inventoryManifest
        self.searchBase = searchBase
        self.catalogPolicyIdentity = catalogPolicyIdentity
        identity = WorkspaceRootReusableSnapshotIdentity(
            sha256: Self.contentDigest(
                compatibilityKey: compatibilityKey,
                inventoryManifest: inventoryManifest,
                catalogPolicyIdentity: catalogPolicyIdentity
            ),
            searchABI: compatibilityKey.searchABI
        )
        self.estimatedByteCount = estimatedByteCount
        artifactByteCount = inventoryManifest.artifactByteCount
    }

    func hasValidContentAddress() -> Bool {
        guard (try? inventoryManifest.makeReader()) != nil else { return false }
        return identity.searchABI == compatibilityKey.searchABI
            && inventoryManifest.header.compatibilityDomain == Self.manifestCompatibilityDomain
            && inventoryManifest.header.compatibilityDigest == Self.compatibilityDigest(compatibilityKey)
            && inventoryManifest.header.catalogPolicyDigest == Self.catalogPolicyDigest(catalogPolicyIdentity)
            && identity.sha256 == Self.contentDigest(
                compatibilityKey: compatibilityKey,
                inventoryManifest: inventoryManifest,
                catalogPolicyIdentity: catalogPolicyIdentity
            )
    }

    static func make(
        authority: GitWorkspaceAuthoritySnapshot,
        inventoryManifest: WorkspaceRootReusableInventoryManifestLease,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity,
        maximumResidentBytes: Int = WorkspaceRootReusableSnapshotCacheLimits.production.maximumEstimatedBytes
    ) -> WorkspaceRootReusableSnapshot? {
        let compatibilityKey = WorkspaceRootSeedCompatibilityKey(authority: authority)
        let header = inventoryManifest.header
        let footer = inventoryManifest.footer
        guard authority.policyIdentity.searchABI == .current,
              header.schemaVersion == WorkspaceRootReusableInventoryManifestHeader.currentSchemaVersion,
              header.compatibilityDomain == manifestCompatibilityDomain,
              header.compatibilityDigest == compatibilityDigest(compatibilityKey),
              header.treeOID == authority.treeOID,
              header.objectFormat == authority.objectFormat,
              header.repositoryRelativeRootPrefix == authority.repositoryRelativeRootPrefix,
              header.catalogPolicyDigest == catalogPolicyDigest(catalogPolicyIdentity),
              footer.totalRecordCount == inventoryManifest.statistics.recordCount,
              footer.searchableRegularFileCount
              + footer.policyIgnoredRegularFileCount
              + footer.nonRegularTopologyCount == footer.totalRecordCount,
              maximumResidentBytes > 0
        else { return nil }
        do {
            let reader = try inventoryManifest.makeReader()
            var relativePaths: [String] = []
            var stableOrdinals: [Int] = []
            var residentBytes = 0
            while let entry = try reader.next() {
                guard entry.isSearchableFile else { continue }
                let (pathBytes, pathOverflow) = entry.relativePath.utf8.count.addingReportingOverflow(96)
                let (proposed, totalOverflow) = residentBytes.addingReportingOverflow(pathBytes)
                guard !pathOverflow, !totalOverflow, proposed <= maximumResidentBytes else {
                    return nil
                }
                relativePaths.append(entry.relativePath)
                stableOrdinals.append(entry.ordinal)
                residentBytes = proposed
            }
            guard reader.validationState == .verified,
                  UInt64(relativePaths.count) == footer.searchableRegularFileCount
            else { return nil }
            return WorkspaceRootReusableSnapshot(
                compatibilityKey: compatibilityKey,
                inventoryManifest: inventoryManifest,
                searchBase: WorkspaceSearchRelativePathBase(
                    relativePaths: relativePaths,
                    stableOrdinals: stableOrdinals
                ),
                catalogPolicyIdentity: catalogPolicyIdentity,
                estimatedByteCount: residentBytes
            )
        } catch {
            return nil
        }
    }

    private static func contentDigest(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventoryManifest: WorkspaceRootReusableInventoryManifestLease,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    ) -> String {
        var writer = CanonicalWriter()
        writer.append(contentAddressDomain)
        writer.append(compatibilityKey.repositoryNamespace.rawValue)
        writer.append(compatibilityKey.objectFormat.rawValue)
        writer.append(compatibilityKey.treeOID.lowercaseHex)
        writer.append(compatibilityKey.repositoryRelativeRootPrefix.value)
        writer.append(compatibilityKey.inventorySchemaVersion)
        writer.append(compatibilityKey.policyIdentity.mandatoryIgnorePolicyIdentity)
        writer.append(compatibilityKey.policyIdentity.committedIgnoreControlDigest)
        writer.append(compatibilityKey.policyIdentity.configuredIgnoreAuthorityDigest)
        writer.append(compatibilityKey.policyIdentity.attributePolicyDigest)
        writer.append(compatibilityKey.policyIdentity.sparsePolicyDigest)
        writer.append(compatibilityKey.searchABI.matcherSchemaVersion)
        writer.append(compatibilityKey.searchABI.projectedKeySchemaVersion)
        writer.append(compatibilityKey.searchABI.comparatorSchemaVersion)
        writer.append(compatibilityKey.searchABI.pathNormalizationSchemaVersion)
        writer.append(catalogPolicyIdentity.schemaVersion)
        writer.append(catalogPolicyIdentity.mandatoryIgnorePolicyIdentity)
        writer.append(catalogPolicyIdentity.globalIgnoreDefaultsDigest)
        writer.append(catalogPolicyIdentity.respectRepoIgnore ? "1" : "0")
        writer.append(catalogPolicyIdentity.respectCursorignore ? "1" : "0")
        writer.append(catalogPolicyIdentity.enableHierarchicalIgnores ? "1" : "0")
        writer.append(catalogPolicyIdentity.skipSymlinks ? "1" : "0")
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedExcludesFileIdentity)
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedAttributesFileIdentity)
        writer.append(inventoryManifest.header.commandFormat)
        writer.append(inventoryManifest.header.rawStandardOutputDigest.hexString)
        writer.append(inventoryManifest.manifestDigest.hexString)
        writer.append(String(inventoryManifest.footer.totalRecordCount))
        writer.append(String(inventoryManifest.footer.searchableRegularFileCount))
        writer.append(String(inventoryManifest.footer.policyIgnoredRegularFileCount))
        writer.append(String(inventoryManifest.footer.nonRegularTopologyCount))
        return Data(SHA256.hash(data: writer.data)).map { String(format: "%02x", $0) }.joined()
    }

    static func compatibilityDigest(_ key: WorkspaceRootSeedCompatibilityKey) -> Data {
        var writer = CanonicalWriter()
        writer.append(manifestCompatibilityDomain)
        writer.append(key.repositoryNamespace.rawValue)
        writer.append(key.objectFormat.rawValue)
        writer.append(key.treeOID.lowercaseHex)
        writer.append(key.repositoryRelativeRootPrefix.value)
        writer.append(key.inventorySchemaVersion)
        writer.append(key.policyIdentity.mandatoryIgnorePolicyIdentity)
        writer.append(key.policyIdentity.committedIgnoreControlDigest)
        writer.append(key.policyIdentity.configuredIgnoreAuthorityDigest)
        writer.append(key.policyIdentity.attributePolicyDigest)
        writer.append(key.policyIdentity.sparsePolicyDigest)
        writer.append(contentIdentity: key.policyIdentity.resolvedExcludesFileIdentity)
        writer.append(contentIdentity: key.policyIdentity.resolvedAttributesFileIdentity)
        return Data(SHA256.hash(data: writer.data))
    }

    static func catalogPolicyDigest(_ identity: WorkspaceRootCatalogPolicyIdentity) -> Data {
        var writer = CanonicalWriter()
        writer.append(identity.schemaVersion)
        writer.append(identity.mandatoryIgnorePolicyIdentity)
        writer.append(identity.globalIgnoreDefaultsDigest)
        writer.append(identity.respectRepoIgnore ? "1" : "0")
        writer.append(identity.respectCursorignore ? "1" : "0")
        writer.append(identity.enableHierarchicalIgnores ? "1" : "0")
        writer.append(identity.skipSymlinks ? "1" : "0")
        return Data(SHA256.hash(data: writer.data))
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkspaceRootReusableSnapshotCacheLimits: Equatable {
    let maximumSnapshotCount: Int
    let maximumSnapshotsPerRepository: Int
    let maximumEstimatedBytes: Int
    let maximumArtifactBytes: UInt64

    init(
        maximumSnapshotCount: Int,
        maximumSnapshotsPerRepository: Int,
        maximumEstimatedBytes: Int,
        maximumArtifactBytes: UInt64 = 4 * 1024 * 1024 * 1024
    ) {
        self.maximumSnapshotCount = maximumSnapshotCount
        self.maximumSnapshotsPerRepository = maximumSnapshotsPerRepository
        self.maximumEstimatedBytes = maximumEstimatedBytes
        self.maximumArtifactBytes = maximumArtifactBytes
    }

    static let production = WorkspaceRootReusableSnapshotCacheLimits(
        maximumSnapshotCount: 32,
        maximumSnapshotsPerRepository: 8,
        maximumEstimatedBytes: 512 * 1024 * 1024,
        maximumArtifactBytes: 4 * 1024 * 1024 * 1024
    )
}

struct WorkspaceRootMaterializationHint: Equatable, @unchecked Sendable {
    let bindingID: String
    let standardizedTargetPath: String
    let creationReceipt: GitWorktreeCreationReceipt
    let orderedCompatibleBaseCandidates: [WorkspaceRootReusableSnapshotIdentity]
    let agentSessionID: UUID
    let correlationID: UUID
    let standardizedLogicalRootPath: String
    let expectedOwnerBindingGeneration: UInt64
    let validationFallbackReason: WorkspaceRootSeedFallbackReason?

    init(
        bindingID: String,
        standardizedTargetPath: String,
        creationReceipt: GitWorktreeCreationReceipt,
        orderedCompatibleBaseCandidates: [WorkspaceRootReusableSnapshotIdentity]? = nil,
        correlationID: UUID,
        validationFallbackReason: WorkspaceRootSeedFallbackReason? = nil
    ) {
        self.bindingID = bindingID
        self.standardizedTargetPath = StandardizedPath.absolute(standardizedTargetPath)
        self.creationReceipt = creationReceipt
        self.orderedCompatibleBaseCandidates = orderedCompatibleBaseCandidates
            ?? [creationReceipt.parentSnapshotIdentity]
        agentSessionID = creationReceipt.agentSessionID
        self.correlationID = correlationID
        standardizedLogicalRootPath = creationReceipt.standardizedLogicalRootPath
        expectedOwnerBindingGeneration = creationReceipt.expectedOwnerBindingGeneration
        self.validationFallbackReason = validationFallbackReason
    }

    func validated(
        matching binding: AgentSessionWorktreeBinding,
        sessionID: UUID,
        startupContext: WorktreeStartupContext?
    ) -> Self {
        Self(
            bindingID: bindingID,
            standardizedTargetPath: standardizedTargetPath,
            creationReceipt: creationReceipt,
            orderedCompatibleBaseCandidates: orderedCompatibleBaseCandidates,
            correlationID: correlationID,
            validationFallbackReason: fallbackReason(
                matching: binding,
                sessionID: sessionID,
                startupContext: startupContext
            )
        )
    }

    func fallbackReason(
        matching binding: AgentSessionWorktreeBinding,
        sessionID: UUID,
        startupContext: WorktreeStartupContext?
    ) -> WorkspaceRootSeedFallbackReason? {
        let expectedPhysicalRootPath = creationReceipt.repositoryRelativeRootPrefix.value.isEmpty
            ? creationReceipt.actualTargetPath
            : URL(fileURLWithPath: creationReceipt.actualTargetPath, isDirectory: true)
            .appendingPathComponent(
                creationReceipt.repositoryRelativeRootPrefix.value,
                isDirectory: true
            )
            .standardizedFileURL.path
        guard let startupContext,
              startupContext.agentSessionID == sessionID,
              agentSessionID == sessionID,
              creationReceipt.agentSessionID == sessionID,
              startupContext.correlationID == correlationID,
              binding.id == bindingID,
              correlationID == creationReceipt.correlationID,
              standardizedLogicalRootPath == creationReceipt.standardizedLogicalRootPath,
              StandardizedPath.absolute(binding.logicalRootPath) == standardizedLogicalRootPath,
              StandardizedPath.absolute(binding.worktreeRootPath) == standardizedTargetPath,
              expectedPhysicalRootPath == standardizedTargetPath,
              binding.repositoryID == creationReceipt.worktree.repository.repositoryID,
              binding.repoKey == creationReceipt.worktree.repository.repoKey,
              binding.worktreeID == creationReceipt.worktree.worktreeID
        else { return .compatibilityMismatch }
        return creationReceipt.fallbackReason()
    }
}

enum WorkspaceRootMaterializationHintObservation: Equatable {
    case observationDisabled
    case eligible(WorkspaceRootReusableSnapshotIdentity)
    case fallback(WorkspaceRootSeedFallbackReason)
}

enum WorkspaceRootSeedPlannerOutcome {
    case planned(WorkspaceRootTargetSeedPlanHandle)
    case fallback(WorkspaceRootSeedFallbackReason)
}

private struct CanonicalWriter {
    private(set) var data = Data()

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: String) {
        var count = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }

    mutating func append(contentIdentity value: GitWorkspaceAuthorityContentIdentity?) {
        guard let value else {
            append("nil")
            return
        }
        append(value.exists ? "1" : "0")
        append(value.sha256)
        append(value.byteCount)
    }
}
