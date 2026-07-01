import Foundation

struct WorkspaceCodemapSelectionGraphBindingGeneration: RawRepresentable, Hashable, Comparable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WorkspaceCodemapSelectionGraphContributionGeneration: RawRepresentable, Hashable, Comparable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WorkspaceCodemapSelectionGraphKey: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogGeneration: UInt64,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32
    ) {
        self.rootEpoch = rootEpoch
        self.catalogGeneration = catalogGeneration
        self.repositoryAuthority = repositoryAuthority
        self.contributionGeneration = contributionGeneration
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }

    fileprivate static func authorized(
        binding: WorkspaceCodemapResolvedGraphBinding,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32
    ) -> Self? {
        guard schemaVersion > 0, policyVersion > 0 else { return nil }
        return Self(
            rootEpoch: binding.rootEpoch,
            catalogGeneration: binding.catalogGeneration,
            repositoryAuthority: binding.repositoryAuthority,
            contributionGeneration: contributionGeneration,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion
        )
    }
}

enum WorkspaceCodemapSelectionGraphContributionRejection: Hashable {
    case bindingNotResolved
    case artifactUnavailable
    case rootIDMismatch
    case rootLifetimeIDMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case schemaVersionMismatch
    case policyVersionMismatch
    case staleRequestGeneration(received: UInt64, current: UInt64)
    case requestGenerationConflict(UInt64)
    case ordinalExhausted
    case bindingGenerationExhausted
    case sizeLimitExceeded(WorkspaceCodemapSelectionGraphSizeRejection)
}

struct WorkspaceCodemapSelectionGraphNodeIdentity: Hashable, Comparable {
    fileprivate let graphKey: WorkspaceCodemapSelectionGraphKey
    fileprivate let storeID: UUID
    fileprivate let ordinal: UInt64
    fileprivate let fileIDStorage: UUID
    fileprivate let requestGenerationStorage: UInt64
    fileprivate let bindingGenerationStorage: WorkspaceCodemapSelectionGraphBindingGeneration

    var rootEpoch: WorkspaceCodemapRootEpoch {
        graphKey.rootEpoch
    }

    var fileID: UUID {
        fileIDStorage
    }

    var contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration {
        graphKey.contributionGeneration
    }

    var requestGeneration: UInt64 {
        requestGenerationStorage
    }

    var bindingGeneration: WorkspaceCodemapSelectionGraphBindingGeneration {
        bindingGenerationStorage
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.graphKey != rhs.graphKey {
            return graphKeyPrecedes(lhs.graphKey, rhs.graphKey)
        }
        if lhs.storeID != rhs.storeID {
            return uuidPrecedes(lhs.storeID, rhs.storeID)
        }
        if lhs.fileID != rhs.fileID {
            return uuidPrecedes(lhs.fileID, rhs.fileID)
        }
        if lhs.requestGeneration != rhs.requestGeneration {
            return lhs.requestGeneration < rhs.requestGeneration
        }
        if lhs.bindingGeneration != rhs.bindingGeneration {
            return lhs.bindingGeneration < rhs.bindingGeneration
        }
        return lhs.ordinal < rhs.ordinal
    }
}

struct WorkspaceCodemapSelectionGraphDuplicateOrderKey: Hashable, Comparable {
    let standardizedRelativePath: String
    let fileID: UUID
    let bindingGeneration: WorkspaceCodemapSelectionGraphBindingGeneration
    let ordinal: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return utf8Precedes(lhs.standardizedRelativePath, rhs.standardizedRelativePath)
        }
        if lhs.fileID != rhs.fileID {
            return uuidPrecedes(lhs.fileID, rhs.fileID)
        }
        if lhs.bindingGeneration != rhs.bindingGeneration {
            return lhs.bindingGeneration < rhs.bindingGeneration
        }
        return lhs.ordinal < rhs.ordinal
    }
}

struct WorkspaceCodemapSelectionGraphNode: Hashable {
    let identity: WorkspaceCodemapSelectionGraphNodeIdentity
    let artifactKey: CodeMapArtifactKey
    let contributionDigest: CodeMapSHA256Digest
    let definitions: [String]
    let references: [String]
    fileprivate let standardizedRelativePath: String

    fileprivate var duplicateOrderKey: WorkspaceCodemapSelectionGraphDuplicateOrderKey {
        WorkspaceCodemapSelectionGraphDuplicateOrderKey(
            standardizedRelativePath: standardizedRelativePath,
            fileID: identity.fileID,
            bindingGeneration: identity.bindingGeneration,
            ordinal: identity.ordinal
        )
    }
}

enum WorkspaceCodemapSelectionGraphContributionAcceptanceResult: Hashable {
    case accepted(
        node: WorkspaceCodemapSelectionGraphNode,
        accounting: WorkspaceCodemapSelectionGraphSizeAccounting
    )
    case exactDuplicate(
        node: WorkspaceCodemapSelectionGraphNode,
        accounting: WorkspaceCodemapSelectionGraphSizeAccounting
    )
    case rejected(WorkspaceCodemapSelectionGraphContributionRejection)
}

struct WorkspaceCodemapSelectionGraphEdge: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let target: WorkspaceCodemapSelectionGraphNodeIdentity

    fileprivate init(
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        target: WorkspaceCodemapSelectionGraphNodeIdentity
    ) {
        self.source = source
        self.target = target
    }
}

enum WorkspaceCodemapSelectionGraphEdgeRejection: Hashable {
    case sourceGraphMismatch
    case targetGraphMismatch
    case sourceStoreMismatch
    case targetStoreMismatch
    case sourceNotCurrent
    case targetNotCurrent
    case sizeLimitExceeded(WorkspaceCodemapSelectionGraphSizeRejection)
}

enum WorkspaceCodemapSelectionGraphEndpointSide {
    case source
    case target
}

enum WorkspaceCodemapSelectionGraphEdgeValidator {
    static func graphMismatch(
        expected: WorkspaceCodemapSelectionGraphKey,
        actual: WorkspaceCodemapSelectionGraphKey,
        side: WorkspaceCodemapSelectionGraphEndpointSide
    ) -> WorkspaceCodemapSelectionGraphEdgeRejection? {
        guard expected != actual else { return nil }
        return switch side {
        case .source: .sourceGraphMismatch
        case .target: .targetGraphMismatch
        }
    }
}

enum WorkspaceCodemapSelectionGraphEdgeConstructionResult: Hashable {
    case edge(
        WorkspaceCodemapSelectionGraphEdge,
        accounting: WorkspaceCodemapSelectionGraphSizeAccounting
    )
    case rejected(WorkspaceCodemapSelectionGraphEdgeRejection)
}

struct WorkspaceCodemapSelectionGraphOrderedCandidateSet: Hashable {
    let definitionName: String
    let orderedCandidates: [WorkspaceCodemapSelectionGraphNodeIdentity]

    fileprivate init(
        definitionName: String,
        orderedCandidates: [WorkspaceCodemapSelectionGraphNodeIdentity]
    ) {
        self.definitionName = definitionName
        self.orderedCandidates = orderedCandidates
    }
}

enum WorkspaceCodemapSelectionGraphDefinitionLookupResult: Hashable {
    case candidates(WorkspaceCodemapSelectionGraphOrderedCandidateSet)
    case candidateOverflow(actual: UInt64, limit: UInt64)
    case graphMismatch
}

struct WorkspaceCodemapSelectionGraphQuery: Hashable {
    let key: WorkspaceCodemapSelectionGraphKey
    let selectedSources: [WorkspaceCodemapSelectionGraphNodeIdentity]
    fileprivate let storeID: UUID
}

enum WorkspaceCodemapSelectionGraphTerminalSourceUnavailableReason: Hashable {
    case unsupported
    case oversize
    case decodeFailed
    case parseFailed
}

enum WorkspaceCodemapSelectionGraphSourceCoverageState: Hashable {
    case covered
    case missing
    case stale
    case terminalUnavailable(WorkspaceCodemapSelectionGraphTerminalSourceUnavailableReason)
}

struct WorkspaceCodemapSelectionGraphSourceCoverage: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let state: WorkspaceCodemapSelectionGraphSourceCoverageState

    fileprivate init(
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        state: WorkspaceCodemapSelectionGraphSourceCoverageState
    ) {
        self.source = source
        self.state = state
    }
}

struct WorkspaceCodemapSelectionGraphResolvedTarget: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let target: WorkspaceCodemapSelectionGraphNodeIdentity

    fileprivate init(
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        target: WorkspaceCodemapSelectionGraphNodeIdentity
    ) {
        self.source = source
        self.target = target
    }
}

enum WorkspaceCodemapSelectionGraphUnavailableReason: Hashable {
    case notBuilt
    case gitDisabled
    case rootUnloaded
    case authorityRevoked
    case catalogUnavailable
    case corrupt
    case schemaMismatch
    case policyMismatch
    case invalidCompletenessProof
    case accountingOverflow
}

enum WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage: Hashable {
    case complete(
        proof: WorkspaceCodemapProjectionCoverageProof,
        candidateCount: UInt64,
        contributedCount: UInt64,
        terminalCount: UInt64
    )
    case incomplete(
        progress: WorkspaceCodemapProjectionProgress,
        remainingCount: UInt64?,
        retry: WorkspaceCodemapProjectionRetry?
    )
    case busy(
        progress: WorkspaceCodemapProjectionProgress,
        retryAfterMilliseconds: UInt64?
    )
    case budget(
        dimension: WorkspaceCodemapProjectionBudgetDimension,
        attempted: UInt64,
        limit: UInt64
    )
    case unavailable(WorkspaceCodemapSelectionGraphUnavailableReason)
}

enum WorkspaceCodemapSelectionGraphReferenceFailure: Hashable {
    case provenMissingDefinition
    case unresolvedDefinitionUniverse
    case candidateOverflow
    case staleTarget
}

struct WorkspaceCodemapSelectionGraphReferenceFailureRecord: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure

    fileprivate init(
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        referencedName: String,
        failure: WorkspaceCodemapSelectionGraphReferenceFailure
    ) {
        self.source = source
        self.referencedName = referencedName
        self.failure = failure
    }
}

struct WorkspaceCodemapSelectionGraphQueryResult: Hashable {
    let query: WorkspaceCodemapSelectionGraphQuery
    let targets: [WorkspaceCodemapSelectionGraphNodeIdentity]
    let resolvedTargets: [WorkspaceCodemapSelectionGraphResolvedTarget]
    let sourceCoverage: [WorkspaceCodemapSelectionGraphSourceCoverage]
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    let referenceFailures: [WorkspaceCodemapSelectionGraphReferenceFailureRecord]

    fileprivate init(
        query: WorkspaceCodemapSelectionGraphQuery,
        targets: [WorkspaceCodemapSelectionGraphNodeIdentity],
        resolvedTargets: [WorkspaceCodemapSelectionGraphResolvedTarget],
        sourceCoverage: [WorkspaceCodemapSelectionGraphSourceCoverage],
        definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage,
        referenceFailures: [WorkspaceCodemapSelectionGraphReferenceFailureRecord]
    ) {
        self.query = query
        self.targets = targets
        self.resolvedTargets = resolvedTargets
        self.sourceCoverage = sourceCoverage
        self.definitionUniverseCoverage = definitionUniverseCoverage
        self.referenceFailures = referenceFailures
    }
}

struct WorkspaceCodemapSelectionGraphSizePolicy: Hashable {
    static let initial = WorkspaceCodemapSelectionGraphSizePolicy(
        maxNodes: 100_000,
        maxPostings: 2_000_000,
        maxEdges: 1_000_000,
        maxBytes: 192 * 1024 * 1024,
        maxDefinitionCandidates: 4096
    )

    let maxNodes: UInt64
    let maxPostings: UInt64
    let maxEdges: UInt64
    let maxBytes: UInt64
    let maxDefinitionCandidates: UInt64
}

struct WorkspaceCodemapSelectionGraphSizeAccounting: Hashable {
    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64

    fileprivate static let zero = WorkspaceCodemapSelectionGraphSizeAccounting(
        nodes: 0,
        postings: 0,
        edges: 0,
        bytes: 0
    )

    fileprivate init(nodes: UInt64, postings: UInt64, edges: UInt64, bytes: UInt64) {
        self.nodes = nodes
        self.postings = postings
        self.edges = edges
        self.bytes = bytes
    }

    func adding(
        _ delta: WorkspaceCodemapSelectionGraphSizeDelta,
        policy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> Result<Self, WorkspaceCodemapSelectionGraphSizeRejection> {
        switch Self.add(nodes, delta.nodes, dimension: .nodes, limit: policy.maxNodes) {
        case let .success(value):
            addingPostings(value, delta: delta, policy: policy)
        case let .failure(rejection):
            .failure(rejection)
        }
    }

    private func addingPostings(
        _ newNodes: UInt64,
        delta: WorkspaceCodemapSelectionGraphSizeDelta,
        policy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> Result<Self, WorkspaceCodemapSelectionGraphSizeRejection> {
        let newPostings: UInt64
        switch Self.add(postings, delta.postings, dimension: .postings, limit: policy.maxPostings) {
        case let .success(value):
            newPostings = value
        case let .failure(rejection):
            return .failure(rejection)
        }
        let newEdges: UInt64
        switch Self.add(edges, delta.edges, dimension: .edges, limit: policy.maxEdges) {
        case let .success(value):
            newEdges = value
        case let .failure(rejection):
            return .failure(rejection)
        }
        switch Self.add(bytes, delta.bytes, dimension: .bytes, limit: policy.maxBytes) {
        case let .success(newBytes):
            return .success(Self(
                nodes: newNodes,
                postings: newPostings,
                edges: newEdges,
                bytes: newBytes
            ))
        case let .failure(rejection):
            return .failure(rejection)
        }
    }

    private static func add(
        _ current: UInt64,
        _ delta: UInt64,
        dimension: WorkspaceCodemapSelectionGraphSizeDimension,
        limit: UInt64
    ) -> Result<UInt64, WorkspaceCodemapSelectionGraphSizeRejection> {
        let (attempted, overflow) = current.addingReportingOverflow(delta)
        guard !overflow else { return .failure(.arithmeticOverflow(dimension)) }
        guard attempted <= limit else {
            return .failure(.limitExceeded(dimension: dimension, attempted: attempted, limit: limit))
        }
        return .success(attempted)
    }
}

struct WorkspaceCodemapSelectionGraphSizeDelta {
    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64
}

enum WorkspaceCodemapSelectionGraphSizeDimension: Hashable {
    case nodes
    case postings
    case edges
    case bytes
}

enum WorkspaceCodemapSelectionGraphSizeRejection: Error, Hashable {
    case arithmeticOverflow(WorkspaceCodemapSelectionGraphSizeDimension)
    case limitExceeded(
        dimension: WorkspaceCodemapSelectionGraphSizeDimension,
        attempted: UInt64,
        limit: UInt64
    )
}

/// A future graph actor owns one of these stores. The store is intentionally not Sendable:
/// endpoint minting, ordinal issuance, current-node state, and cumulative accounting must remain
/// serialized by that owner.
final class WorkspaceCodemapSelectionGraphModelStore {
    let key: WorkspaceCodemapSelectionGraphKey
    let sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy

    private let storeID: UUID
    private var accountingStorage: WorkspaceCodemapSelectionGraphSizeAccounting
    private var nextOrdinal: UInt64?
    private var nextBindingGeneration: UInt64?
    private var currentNodesByFileID: [UUID: WorkspaceCodemapSelectionGraphNode]

    var accounting: WorkspaceCodemapSelectionGraphSizeAccounting {
        accountingStorage
    }

    private init(
        key: WorkspaceCodemapSelectionGraphKey,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) {
        self.key = key
        self.sizePolicy = sizePolicy
        storeID = UUID()
        accountingStorage = .zero
        nextOrdinal = 0
        nextBindingGeneration = 0
        currentNodesByFileID = [:]
    }

    static func authorized(
        by resolvedBinding: WorkspaceCodemapArtifactBinding,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy = .initial
    ) -> WorkspaceCodemapSelectionGraphModelStore? {
        guard let binding = WorkspaceCodemapResolvedGraphBinding(resolvedBinding),
              let key = WorkspaceCodemapSelectionGraphKey.authorized(
                  binding: binding,
                  contributionGeneration: contributionGeneration,
                  schemaVersion: schemaVersion,
                  policyVersion: policyVersion
              )
        else { return nil }
        return WorkspaceCodemapSelectionGraphModelStore(key: key, sizePolicy: sizePolicy)
    }

    func accept(
        _ resolvedBinding: WorkspaceCodemapArtifactBinding
    ) -> WorkspaceCodemapSelectionGraphContributionAcceptanceResult {
        guard let binding = WorkspaceCodemapResolvedGraphBinding(resolvedBinding) else {
            return .rejected(.bindingNotResolved)
        }
        guard let contribution = binding.contribution else {
            return .rejected(.artifactUnavailable)
        }
        guard binding.rootEpoch.rootID == key.rootEpoch.rootID else {
            return .rejected(.rootIDMismatch)
        }
        guard binding.rootEpoch.rootLifetimeID == key.rootEpoch.rootLifetimeID else {
            return .rejected(.rootLifetimeIDMismatch)
        }
        guard binding.catalogGeneration == key.catalogGeneration else {
            return .rejected(.catalogGenerationMismatch)
        }
        guard binding.repositoryAuthority == key.repositoryAuthority else {
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard contribution.schemaVersion == key.schemaVersion else {
            return .rejected(.schemaVersionMismatch)
        }
        guard contribution.policyVersion == key.policyVersion else {
            return .rejected(.policyVersionMismatch)
        }

        // The graph key's contribution generation scopes the whole projection. Within that
        // scope, request generation is the per-file freshness fence: lower is stale, equal must
        // be an exact duplicate, and only higher input receives a new graph binding generation
        // and ordinal.
        if let current = currentNodesByFileID[binding.identity.fileID] {
            let currentRequestGeneration = current.identity.requestGeneration
            guard binding.requestGeneration >= currentRequestGeneration else {
                return .rejected(.staleRequestGeneration(
                    received: binding.requestGeneration,
                    current: currentRequestGeneration
                ))
            }
            if binding.requestGeneration == currentRequestGeneration {
                guard current.standardizedRelativePath == binding.identity.standardizedRelativePath,
                      current.artifactKey == contribution.artifactKey,
                      current.contributionDigest == contribution.contributionDigest,
                      current.definitions == contribution.sortedUniqueDefinitions,
                      current.references == contribution.sortedUniqueReferences
                else {
                    return .rejected(.requestGenerationConflict(binding.requestGeneration))
                }
                return .exactDuplicate(node: current, accounting: accountingStorage)
            }
        }

        guard let ordinal = nextOrdinal else { return .rejected(.ordinalExhausted) }
        guard let rawBindingGeneration = nextBindingGeneration else {
            return .rejected(.bindingGenerationExhausted)
        }
        guard let delta = sizeDelta(
            contribution: contribution,
            relativePath: binding.identity.standardizedRelativePath
        ) else {
            return .rejected(.sizeLimitExceeded(.arithmeticOverflow(.bytes)))
        }

        let nextAccounting: WorkspaceCodemapSelectionGraphSizeAccounting
        switch accountingStorage.adding(delta, policy: sizePolicy) {
        case let .success(value):
            nextAccounting = value
        case let .failure(rejection):
            return .rejected(.sizeLimitExceeded(rejection))
        }

        let node = WorkspaceCodemapSelectionGraphNode(
            identity: WorkspaceCodemapSelectionGraphNodeIdentity(
                graphKey: key,
                storeID: storeID,
                ordinal: ordinal,
                fileIDStorage: binding.identity.fileID,
                requestGenerationStorage: binding.requestGeneration,
                bindingGenerationStorage: .init(rawValue: rawBindingGeneration)
            ),
            artifactKey: contribution.artifactKey,
            contributionDigest: contribution.contributionDigest,
            definitions: contribution.sortedUniqueDefinitions,
            references: contribution.sortedUniqueReferences,
            standardizedRelativePath: binding.identity.standardizedRelativePath
        )

        accountingStorage = nextAccounting
        nextOrdinal = incrementing(ordinal)
        nextBindingGeneration = incrementing(rawBindingGeneration)
        currentNodesByFileID[binding.identity.fileID] = node
        return .accepted(node: node, accounting: nextAccounting)
    }

    func makeEdge(
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        target: WorkspaceCodemapSelectionGraphNodeIdentity
    ) -> WorkspaceCodemapSelectionGraphEdgeConstructionResult {
        if let rejection = WorkspaceCodemapSelectionGraphEdgeValidator.graphMismatch(
            expected: key,
            actual: source.graphKey,
            side: .source
        ) {
            return .rejected(rejection)
        }
        if let rejection = WorkspaceCodemapSelectionGraphEdgeValidator.graphMismatch(
            expected: key,
            actual: target.graphKey,
            side: .target
        ) {
            return .rejected(rejection)
        }
        guard source.storeID == storeID else { return .rejected(.sourceStoreMismatch) }
        guard target.storeID == storeID else { return .rejected(.targetStoreMismatch) }
        guard isCurrent(source) else { return .rejected(.sourceNotCurrent) }
        guard isCurrent(target) else { return .rejected(.targetNotCurrent) }

        let delta = WorkspaceCodemapSelectionGraphSizeDelta(
            nodes: 0,
            postings: 0,
            edges: 1,
            bytes: 64
        )
        switch accountingStorage.adding(delta, policy: sizePolicy) {
        case let .success(nextAccounting):
            let edge = WorkspaceCodemapSelectionGraphEdge(source: source, target: target)
            accountingStorage = nextAccounting
            return .edge(edge, accounting: nextAccounting)
        case let .failure(rejection):
            return .rejected(.sizeLimitExceeded(rejection))
        }
    }

    func definitionCandidates(
        named definitionName: String,
        among nodes: [WorkspaceCodemapSelectionGraphNode]
    ) -> WorkspaceCodemapSelectionGraphDefinitionLookupResult {
        guard nodes.allSatisfy({ isCurrent($0.identity) && currentNode($0.identity) == $0 }) else {
            return .graphMismatch
        }

        var uniqueNodes: [WorkspaceCodemapSelectionGraphNodeIdentity: WorkspaceCodemapSelectionGraphNode] = [:]
        for node in nodes {
            if let existing = uniqueNodes[node.identity], existing != node {
                return .graphMismatch
            }
            uniqueNodes[node.identity] = node
        }
        let canonicalName = definitionName.precomposedStringWithCanonicalMapping
        let candidates = uniqueNodes.values
            .filter { $0.definitions.contains(canonicalName) }
            .sorted(by: Self.candidatePrecedes)
        guard let actual = UInt64(exactly: candidates.count) else {
            return .candidateOverflow(actual: .max, limit: sizePolicy.maxDefinitionCandidates)
        }
        guard actual <= sizePolicy.maxDefinitionCandidates else {
            return .candidateOverflow(actual: actual, limit: sizePolicy.maxDefinitionCandidates)
        }
        return .candidates(WorkspaceCodemapSelectionGraphOrderedCandidateSet(
            definitionName: canonicalName,
            orderedCandidates: candidates.map(\.identity)
        ))
    }

    func makeQuery(
        selectedSources: [WorkspaceCodemapSelectionGraphNodeIdentity]
    ) -> WorkspaceCodemapSelectionGraphQuery? {
        guard Set(selectedSources).count == selectedSources.count,
              selectedSources.allSatisfy(isCurrent)
        else { return nil }
        return WorkspaceCodemapSelectionGraphQuery(
            key: key,
            selectedSources: selectedSources.sorted(),
            storeID: storeID
        )
    }

    func makeSourceCoverage(
        for query: WorkspaceCodemapSelectionGraphQuery,
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        state: WorkspaceCodemapSelectionGraphSourceCoverageState
    ) -> WorkspaceCodemapSelectionGraphSourceCoverage? {
        guard queryIsCurrent(query), query.selectedSources.contains(source), isCurrent(source) else {
            return nil
        }
        return WorkspaceCodemapSelectionGraphSourceCoverage(source: source, state: state)
    }

    func makeResolvedTarget(
        for query: WorkspaceCodemapSelectionGraphQuery,
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        target: WorkspaceCodemapSelectionGraphNodeIdentity
    ) -> WorkspaceCodemapSelectionGraphResolvedTarget? {
        guard queryIsCurrent(query),
              query.selectedSources.contains(source),
              !query.selectedSources.contains(target),
              isCurrent(source),
              isCurrent(target)
        else { return nil }
        return WorkspaceCodemapSelectionGraphResolvedTarget(source: source, target: target)
    }

    func makeReferenceFailure(
        for query: WorkspaceCodemapSelectionGraphQuery,
        source: WorkspaceCodemapSelectionGraphNodeIdentity,
        referencedName: String,
        failure: WorkspaceCodemapSelectionGraphReferenceFailure,
        definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage = .incomplete(
            progress: .notStarted,
            remainingCount: nil,
            retry: nil
        )
    ) -> WorkspaceCodemapSelectionGraphReferenceFailureRecord? {
        guard queryIsCurrent(query), query.selectedSources.contains(source), isCurrent(source) else {
            return nil
        }
        if failure == .provenMissingDefinition {
            guard definitionUniverseIsCurrentComplete(
                definitionUniverseCoverage,
                for: query
            ) else { return nil }
        }
        return WorkspaceCodemapSelectionGraphReferenceFailureRecord(
            source: source,
            referencedName: referencedName.precomposedStringWithCanonicalMapping,
            failure: failure
        )
    }

    func immediateResult(
        for query: WorkspaceCodemapSelectionGraphQuery,
        resolvedTargets: [WorkspaceCodemapSelectionGraphResolvedTarget] = [],
        sourceCoverage: [WorkspaceCodemapSelectionGraphSourceCoverage],
        definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage,
        referenceFailures: [WorkspaceCodemapSelectionGraphReferenceFailureRecord] = []
    ) -> WorkspaceCodemapSelectionGraphQueryResult? {
        guard queryIsCurrent(query) else { return nil }

        let selectedSources = Set(query.selectedSources)
        var coverageBySource: [WorkspaceCodemapSelectionGraphNodeIdentity: WorkspaceCodemapSelectionGraphSourceCoverageState] = [:]
        for coverage in sourceCoverage {
            guard selectedSources.contains(coverage.source),
                  isCurrent(coverage.source),
                  coverageBySource.updateValue(coverage.state, forKey: coverage.source) == nil
            else { return nil }
        }
        guard coverageBySource.count == selectedSources.count else { return nil }

        guard Set(resolvedTargets).count == resolvedTargets.count else { return nil }
        var targetBySourceAndFile: [WorkspaceCodemapSelectionGraphTargetSlot: WorkspaceCodemapSelectionGraphNodeIdentity] = [:]
        for resolution in resolvedTargets {
            guard selectedSources.contains(resolution.source),
                  !selectedSources.contains(resolution.target),
                  isCurrent(resolution.source),
                  isCurrent(resolution.target),
                  coverageBySource[resolution.source] == .covered
            else { return nil }
            let slot = WorkspaceCodemapSelectionGraphTargetSlot(
                source: resolution.source,
                targetFileID: resolution.target.fileID
            )
            if let existing = targetBySourceAndFile.updateValue(resolution.target, forKey: slot),
               existing != resolution.target
            {
                return nil
            }
        }

        switch definitionUniverseCoverage {
        case .complete:
            guard definitionUniverseIsCurrentComplete(
                definitionUniverseCoverage,
                for: query
            ) else { return nil }
        case .incomplete, .busy, .budget, .unavailable:
            guard resolvedTargets.isEmpty else { return nil }
        }

        var failuresByReference: [WorkspaceCodemapSelectionGraphFailureSlot: WorkspaceCodemapSelectionGraphReferenceFailure] = [:]
        for record in referenceFailures {
            guard selectedSources.contains(record.source), isCurrent(record.source) else { return nil }
            if record.failure == .provenMissingDefinition {
                guard definitionUniverseIsCurrentComplete(
                    definitionUniverseCoverage,
                    for: query
                ) else { return nil }
            }
            let slot = WorkspaceCodemapSelectionGraphFailureSlot(
                source: record.source,
                referencedName: record.referencedName
            )
            guard failuresByReference.updateValue(record.failure, forKey: slot) == nil else {
                return nil
            }
        }

        let orderedTargets = resolvedTargets.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.target < $1.target
        }
        let targets = Array(Set(orderedTargets.map(\.target))).sorted()
        let orderedCoverage = sourceCoverage.sorted { $0.source < $1.source }
        let orderedFailures = referenceFailures.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            return utf8Precedes($0.referencedName, $1.referencedName)
        }
        return WorkspaceCodemapSelectionGraphQueryResult(
            query: query,
            targets: targets,
            resolvedTargets: orderedTargets,
            sourceCoverage: orderedCoverage,
            definitionUniverseCoverage: definitionUniverseCoverage,
            referenceFailures: orderedFailures
        )
    }

    private func definitionUniverseIsCurrentComplete(
        _ coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage,
        for query: WorkspaceCodemapSelectionGraphQuery
    ) -> Bool {
        guard case let .complete(
            proof,
            candidateCount,
            contributedCount,
            terminalCount
        ) = coverage else {
            return false
        }
        let generation = proof.generation
        return queryIsCurrent(query) &&
            generation.rootEpoch == key.rootEpoch &&
            generation.catalogGeneration == key.catalogGeneration &&
            generation.repositoryAuthority == key.repositoryAuthority &&
            generation.contributionGeneration == key.contributionGeneration &&
            generation.schemaVersion == key.schemaVersion &&
            generation.policyVersion == key.policyVersion &&
            candidateCount == proof.candidateCount &&
            contributedCount == proof.contributedCount &&
            terminalCount == proof.terminalCount
    }

    private func queryIsCurrent(_ query: WorkspaceCodemapSelectionGraphQuery) -> Bool {
        query.key == key &&
            query.storeID == storeID &&
            Set(query.selectedSources).count == query.selectedSources.count &&
            query.selectedSources.allSatisfy(isCurrent)
    }

    private func currentNode(
        _ identity: WorkspaceCodemapSelectionGraphNodeIdentity
    ) -> WorkspaceCodemapSelectionGraphNode? {
        currentNodesByFileID[identity.fileID]
    }

    private func isCurrent(_ identity: WorkspaceCodemapSelectionGraphNodeIdentity) -> Bool {
        identity.graphKey == key &&
            identity.storeID == storeID &&
            currentNodesByFileID[identity.fileID]?.identity == identity
    }

    private func sizeDelta(
        contribution: CodeMapSelectionGraphContribution,
        relativePath: String
    ) -> WorkspaceCodemapSelectionGraphSizeDelta? {
        let names = contribution.sortedUniqueDefinitions + contribution.sortedUniqueReferences
        guard let postings = UInt64(exactly: names.count),
              let keyBytes = UInt64(exactly: contribution.artifactKey.canonicalBytes.count),
              let pathBytes = UInt64(exactly: relativePath.utf8.count)
        else { return nil }

        var bytes: UInt64 = 16 + 8 + 8 + 8
        for value in [keyBytes, UInt64(CodeMapSHA256Digest.byteCount), pathBytes] +
            names.compactMap({ UInt64(exactly: $0.utf8.count) })
        {
            let (next, overflow) = bytes.addingReportingOverflow(value)
            guard !overflow else { return nil }
            bytes = next
        }
        guard names.allSatisfy({ UInt64(exactly: $0.utf8.count) != nil }) else { return nil }
        return WorkspaceCodemapSelectionGraphSizeDelta(
            nodes: 1,
            postings: postings,
            edges: 0,
            bytes: bytes
        )
    }

    private static func candidatePrecedes(
        _ lhs: WorkspaceCodemapSelectionGraphNode,
        _ rhs: WorkspaceCodemapSelectionGraphNode
    ) -> Bool {
        lhs.duplicateOrderKey < rhs.duplicateOrderKey
    }

    private func incrementing(_ value: UInt64) -> UInt64? {
        value == .max ? nil : value + 1
    }
}

private struct WorkspaceCodemapResolvedGraphBinding {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let requestGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contribution: CodeMapSelectionGraphContribution?

    init?(_ binding: WorkspaceCodemapArtifactBinding) {
        guard case let .resolved(completion) = binding.availability,
              completion.token.isFactoryValidated,
              completion.sourceProof.isFactoryValidated,
              completion.token.identity == binding.identity,
              completion.sourceProof == completion.token.sourceExpectation,
              completion.sourceProof.sourceAuthority.rootEpoch.rootID == binding.identity.rootID,
              completion.sourceProof.sourceAuthority.rootEpoch.rootLifetimeID == binding.identity.rootLifetimeID
        else { return nil }

        identity = binding.identity
        rootEpoch = completion.sourceProof.sourceAuthority.rootEpoch
        catalogGeneration = completion.token.catalogGeneration
        requestGeneration = completion.token.requestGeneration
        repositoryAuthority = completion.sourceProof.sourceAuthority.repositoryAuthority
        contribution = switch completion.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(artifactKey: completion.artifactKey, artifact: artifact)
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: completion.artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
    }
}

private struct WorkspaceCodemapSelectionGraphTargetSlot: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let targetFileID: UUID
}

private struct WorkspaceCodemapSelectionGraphFailureSlot: Hashable {
    let source: WorkspaceCodemapSelectionGraphNodeIdentity
    let referencedName: String
}

private func graphKeyPrecedes(
    _ lhs: WorkspaceCodemapSelectionGraphKey,
    _ rhs: WorkspaceCodemapSelectionGraphKey
) -> Bool {
    if lhs.rootEpoch.rootID != rhs.rootEpoch.rootID {
        return uuidPrecedes(lhs.rootEpoch.rootID, rhs.rootEpoch.rootID)
    }
    if lhs.rootEpoch.rootLifetimeID != rhs.rootEpoch.rootLifetimeID {
        return uuidPrecedes(lhs.rootEpoch.rootLifetimeID, rhs.rootEpoch.rootLifetimeID)
    }
    if lhs.catalogGeneration != rhs.catalogGeneration {
        return lhs.catalogGeneration < rhs.catalogGeneration
    }
    if lhs.repositoryAuthority != rhs.repositoryAuthority {
        return repositoryAuthorityPrecedes(lhs.repositoryAuthority, rhs.repositoryAuthority)
    }
    if lhs.contributionGeneration != rhs.contributionGeneration {
        return lhs.contributionGeneration < rhs.contributionGeneration
    }
    if lhs.schemaVersion != rhs.schemaVersion {
        return lhs.schemaVersion < rhs.schemaVersion
    }
    return lhs.policyVersion < rhs.policyVersion
}

private func repositoryAuthorityPrecedes(
    _ lhs: WorkspaceCodemapRepositoryAuthorityToken,
    _ rhs: WorkspaceCodemapRepositoryAuthorityToken
) -> Bool {
    if lhs.authorityGeneration != rhs.authorityGeneration {
        return lhs.authorityGeneration < rhs.authorityGeneration
    }
    let left = [
        lhs.repositoryNamespace.rawValue,
        lhs.objectFormat.rawValue,
        lhs.repositoryBindingEpoch,
        lhs.worktreeBindingEpoch,
        lhs.layoutGeneration,
        lhs.indexGeneration,
        lhs.checkoutConfigurationGeneration,
        lhs.attributeGeneration,
        lhs.sparseGeneration,
        lhs.metadataGeneration
    ]
    let right = [
        rhs.repositoryNamespace.rawValue,
        rhs.objectFormat.rawValue,
        rhs.repositoryBindingEpoch,
        rhs.worktreeBindingEpoch,
        rhs.layoutGeneration,
        rhs.indexGeneration,
        rhs.checkoutConfigurationGeneration,
        rhs.attributeGeneration,
        rhs.sparseGeneration,
        rhs.metadataGeneration
    ]
    for (leftValue, rightValue) in zip(left, right) where leftValue != rightValue {
        return utf8Precedes(leftValue, rightValue)
    }
    return false
}

private func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
