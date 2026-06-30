import Foundation

final class WorkspaceCodemapAutomaticSelectionPublicationPermit: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var current = true

    static func == (
        lhs: WorkspaceCodemapAutomaticSelectionPublicationPermit,
        rhs: WorkspaceCodemapAutomaticSelectionPublicationPermit
    ) -> Bool {
        lhs === rhs
    }

    func withCurrent<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard current else { return nil }
        return body()
    }

    func revoke() {
        lock.lock()
        current = false
        lock.unlock()
    }
}

final class WorkspaceCodemapAutomaticSelectionPublicationLease: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () async -> Void)?

    init(release: @escaping @Sendable () async -> Void) {
        releaseAction = release
    }

    static func == (
        lhs: WorkspaceCodemapAutomaticSelectionPublicationLease,
        rhs: WorkspaceCodemapAutomaticSelectionPublicationLease
    ) -> Bool {
        lhs === rhs
    }

    func release() async {
        let action = lock.withLock {
            let action = releaseAction
            releaseAction = nil
            return action
        }
        await action?()
    }

    deinit {
        let action = lock.withLock {
            let action = releaseAction
            releaseAction = nil
            return action
        }
        if let action {
            Task { await action() }
        }
    }
}

struct WorkspaceCodemapAutomaticSelectionSourceIdentity: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let catalogGeneration: UInt64
}

struct WorkspaceCodemapAutomaticSelectionTarget: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let catalogGeneration: UInt64
    let requestGeneration: UInt64
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
}

enum WorkspaceCodemapAutomaticSelectionSourceIssue: Equatable {
    case outsideRootScope(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case notCataloged(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case notDemanded(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case pending(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        WorkspaceCodemapArtifactDemandTicket
    )
    case unavailable(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        WorkspaceCodemapArtifactDemandUnavailableReason
    )
    case staleCatalogGeneration(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        currentCatalogGeneration: UInt64?
    )
}

enum WorkspaceCodemapAutomaticSelectionTargetIssue: Equatable {
    case notCataloged(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
    case staleGeneration(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        requestGeneration: UInt64
    )
    case logicalPathUnavailable(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
}

enum WorkspaceCodemapAutomaticSelectionPartialReason: Equatable {
    case graph(WorkspaceCodemapStoreSelectionGraphPartialReason)
    case source(WorkspaceCodemapAutomaticSelectionSourceIssue)
    case sourceDemandTimedOut(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case candidateUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        reason: WorkspaceCodemapArtifactDemandUnavailableReason
    )
}

enum WorkspaceCodemapAutomaticSelectionIncompleteReason: Equatable {
    case graph(WorkspaceCodemapStoreSelectionGraphQueryIncompleteReason)
}

enum WorkspaceCodemapAutomaticSelectionPendingReason: Equatable {
    case sourceDemand(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        WorkspaceCodemapArtifactDemandTicket
    )
    case sourceBusy(WorkspaceCodemapAutomaticSelectionSourceIdentity, attempts: Int)
    case candidateDemand(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        ticket: WorkspaceCodemapArtifactDemandTicket
    )
    case candidateBusy(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID, attempts: Int)
    case manifestAdmission(rootEpoch: WorkspaceCodemapRootEpoch)
    case graphRebuild(rootEpoch: WorkspaceCodemapRootEpoch)
}

enum WorkspaceCodemapAutomaticSelectionUnavailableReason: Equatable {
    case noReadySources
    case candidate(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        reason: WorkspaceCodemapArtifactDemandUnavailableReason
    )
    case graph(WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason)
}

enum WorkspaceCodemapAutomaticSelectionStaleReason: Equatable {
    case rootEpochNotCurrent(WorkspaceCodemapRootEpoch)
    case rootScopeChanged(WorkspaceCodemapRootEpoch)
    case sourceStateChanged(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceCatalogGeneration(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        currentCatalogGeneration: UInt64?
    )
    case targetStateChanged(WorkspaceCodemapAutomaticSelectionTargetIssue)
    case coverageProof(WorkspaceCodemapRootEpoch)
    case graph(WorkspaceCodemapStoreSelectionGraphQueryStaleReason)
    case publicationReceipt
}

enum WorkspaceCodemapAutomaticSelectionBudgetReason: Equatable {
    case sourceLimit(attempted: Int, limit: Int)
    case uniqueSourceLimit(attempted: Int, limit: Int)
    case sourceIssueLimit(attempted: Int, limit: Int)
    case rootLimit(attempted: Int, limit: Int)
    case candidateDemandLimit(attempted: Int, limit: Int)
    case targetLimit(attempted: Int, limit: Int)
    case resolutionLimit(attempted: Int, limit: Int)
    case referenceFailureLimit(attempted: Int, limit: Int)
    case byteLimit(attempted: Int, limit: Int)
    case accountingOverflow
    case graph(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapStoreSelectionGraphQueryBudgetReason
    )
}

enum WorkspaceCodemapAutomaticSelectionCoverage: Equatable {
    case complete(WorkspaceCodemapProjectionCoverageProof)
    case partial(
        proof: WorkspaceCodemapProjectionCoverageProof,
        reasons: [WorkspaceCodemapAutomaticSelectionPartialReason]
    )
    case provisional(
        incomplete: [WorkspaceCodemapAutomaticSelectionIncompleteReason],
        pending: [WorkspaceCodemapAutomaticSelectionPendingReason],
        partial: [WorkspaceCodemapAutomaticSelectionPartialReason]
    )
    case incomplete([WorkspaceCodemapAutomaticSelectionIncompleteReason])
    case pending([WorkspaceCodemapAutomaticSelectionPendingReason])
    case unavailable(WorkspaceCodemapAutomaticSelectionUnavailableReason)
    case stale(WorkspaceCodemapAutomaticSelectionStaleReason)
    case busy(WorkspaceCodemapStoreSelectionGraphQueryBusyReason)
    case budget(WorkspaceCodemapStoreSelectionGraphQueryBudgetReason)
}

enum WorkspaceCodemapAutomaticSelectionAggregateCoverage: Equatable {
    case complete([WorkspaceCodemapProjectionCoverageProof])
    case partial(
        proofs: [WorkspaceCodemapProjectionCoverageProof],
        reasons: [WorkspaceCodemapAutomaticSelectionPartialReason]
    )
    case provisional(
        incomplete: [WorkspaceCodemapAutomaticSelectionIncompleteReason],
        pending: [WorkspaceCodemapAutomaticSelectionPendingReason],
        partial: [WorkspaceCodemapAutomaticSelectionPartialReason]
    )
    case incomplete([WorkspaceCodemapAutomaticSelectionIncompleteReason])
    case pending([WorkspaceCodemapAutomaticSelectionPendingReason])
    case unavailable(WorkspaceCodemapAutomaticSelectionUnavailableReason)
    case stale(WorkspaceCodemapAutomaticSelectionStaleReason)
    case busy(WorkspaceCodemapStoreSelectionGraphQueryBusyReason)
    case budget(WorkspaceCodemapAutomaticSelectionBudgetReason)
}

struct WorkspaceCodemapAutomaticSelectionRootResult: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let targets: [WorkspaceCodemapAutomaticSelectionTarget]
    let sourceIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue]
    let targetIssues: [WorkspaceCodemapAutomaticSelectionTargetIssue]
    let coverage: WorkspaceCodemapAutomaticSelectionCoverage
    let graphTargetCount: Int
    let graphResolutionCount: Int
    let graphReferenceFailureCount: Int
    let graphByteCount: Int
    let graphKey: WorkspaceCodemapSelectionGraphRuntimeKey?

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        targets: [WorkspaceCodemapAutomaticSelectionTarget],
        sourceIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue],
        targetIssues: [WorkspaceCodemapAutomaticSelectionTargetIssue],
        coverage: WorkspaceCodemapAutomaticSelectionCoverage,
        graphTargetCount: Int = 0,
        graphResolutionCount: Int = 0,
        graphReferenceFailureCount: Int = 0,
        graphByteCount: Int = 0,
        graphKey: WorkspaceCodemapSelectionGraphRuntimeKey? = nil
    ) {
        self.rootEpoch = rootEpoch
        self.targets = targets
        self.sourceIssues = sourceIssues
        self.targetIssues = targetIssues
        self.coverage = coverage
        self.graphTargetCount = graphTargetCount
        self.graphResolutionCount = graphResolutionCount
        self.graphReferenceFailureCount = graphReferenceFailureCount
        self.graphByteCount = graphByteCount
        self.graphKey = graphKey
    }
}

enum WorkspaceCodemapAutomaticSelectionPublicationBasis: Equatable {
    case projectionCoverage
    case provisionalCandidates([WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate])
}

struct WorkspaceCodemapRootScopedFileSlot: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID

    init(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID) {
        self.rootEpoch = rootEpoch
        self.fileID = fileID
    }

    init(candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate) {
        self.init(rootEpoch: candidate.rootEpoch, fileID: candidate.identity.fileID)
    }

    init(target: WorkspaceCodemapAutomaticSelectionTarget) {
        self.init(rootEpoch: target.rootEpoch, fileID: target.fileID)
    }

    init(ticket: WorkspaceCodemapArtifactDemandTicket) {
        self.init(rootEpoch: ticket.rootEpoch, fileID: ticket.fileID)
    }

    init(source: WorkspaceCodemapAutomaticSelectionSourceIdentity) {
        self.init(rootEpoch: source.rootEpoch, fileID: source.fileID)
    }
}

func workspaceCodemapRootEpochPrecedes(
    _ lhs: WorkspaceCodemapRootEpoch,
    _ rhs: WorkspaceCodemapRootEpoch
) -> Bool {
    if lhs.rootID != rhs.rootID { return lhs.rootID.uuidString < rhs.rootID.uuidString }
    return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
}

func automaticSelectionCandidatePrecedes(
    _ lhs: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate,
    _ rhs: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate
) -> Bool {
    if lhs.rootEpoch != rhs.rootEpoch {
        return workspaceCodemapRootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch)
    }
    if lhs.identity.standardizedRelativePath != rhs.identity.standardizedRelativePath {
        return lhs.identity.standardizedRelativePath.utf8.lexicographicallyPrecedes(
            rhs.identity.standardizedRelativePath.utf8
        )
    }
    return lhs.identity.fileID.uuidString < rhs.identity.fileID.uuidString
}

func automaticSelectionPendingReasonPrecedes(
    _ lhs: WorkspaceCodemapAutomaticSelectionPendingReason,
    _ rhs: WorkspaceCodemapAutomaticSelectionPendingReason
) -> Bool {
    automaticSelectionIssueSortKey(lhs) < automaticSelectionIssueSortKey(rhs)
}

func automaticSelectionPartialReasonPrecedes(
    _ lhs: WorkspaceCodemapAutomaticSelectionPartialReason,
    _ rhs: WorkspaceCodemapAutomaticSelectionPartialReason
) -> Bool {
    automaticSelectionIssueSortKey(lhs) < automaticSelectionIssueSortKey(rhs)
}

private struct WorkspaceCodemapAutomaticSelectionIssueSortKey: Comparable {
    let components: [String]

    static func < (
        lhs: WorkspaceCodemapAutomaticSelectionIssueSortKey,
        rhs: WorkspaceCodemapAutomaticSelectionIssueSortKey
    ) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

private func automaticSelectionIssueSortKey(
    _ reason: WorkspaceCodemapAutomaticSelectionPendingReason
) -> WorkspaceCodemapAutomaticSelectionIssueSortKey {
    switch reason {
    case let .sourceDemand(source, ticket):
        automaticSelectionIssueSortKey(
            tag: "sourceDemand",
            source: source,
            details: automaticSelectionTicketSortComponents(ticket)
        )
    case let .sourceBusy(source, attempts):
        automaticSelectionIssueSortKey(
            tag: "sourceBusy",
            source: source,
            details: [String(attempts)]
        )
    case let .candidateDemand(rootEpoch, fileID, ticket):
        automaticSelectionIssueSortKey(
            tag: "candidateDemand",
            rootEpoch: rootEpoch,
            fileID: fileID,
            details: automaticSelectionTicketSortComponents(ticket)
        )
    case let .candidateBusy(rootEpoch, fileID, attempts):
        automaticSelectionIssueSortKey(
            tag: "candidateBusy",
            rootEpoch: rootEpoch,
            fileID: fileID,
            details: [String(attempts)]
        )
    case let .manifestAdmission(rootEpoch):
        automaticSelectionIssueSortKey(tag: "manifestAdmission", rootEpoch: rootEpoch)
    case let .graphRebuild(rootEpoch):
        automaticSelectionIssueSortKey(tag: "graphRebuild", rootEpoch: rootEpoch)
    }
}

private func automaticSelectionIssueSortKey(
    _ reason: WorkspaceCodemapAutomaticSelectionPartialReason
) -> WorkspaceCodemapAutomaticSelectionIssueSortKey {
    switch reason {
    case let .graph(reason):
        WorkspaceCodemapAutomaticSelectionIssueSortKey(
            components: ["graph"] + automaticSelectionGraphPartialReasonSortComponents(reason)
        )
    case let .source(issue):
        WorkspaceCodemapAutomaticSelectionIssueSortKey(
            components: ["source"] + automaticSelectionSourceIssueSortKey(issue).components
        )
    case let .sourceDemandTimedOut(source):
        automaticSelectionIssueSortKey(tag: "sourceDemandTimedOut", source: source)
    case let .candidateUnavailable(rootEpoch, fileID, reason):
        automaticSelectionIssueSortKey(
            tag: "candidateUnavailable",
            rootEpoch: rootEpoch,
            fileID: fileID,
            details: automaticSelectionUnavailableReasonSortComponents(reason)
        )
    }
}

private func automaticSelectionSourceIssueSortKey(
    _ issue: WorkspaceCodemapAutomaticSelectionSourceIssue
) -> WorkspaceCodemapAutomaticSelectionIssueSortKey {
    switch issue {
    case let .outsideRootScope(source):
        automaticSelectionIssueSortKey(tag: "outsideRootScope", source: source)
    case let .notCataloged(source):
        automaticSelectionIssueSortKey(tag: "notCataloged", source: source)
    case let .notDemanded(source):
        automaticSelectionIssueSortKey(tag: "notDemanded", source: source)
    case let .pending(source, ticket):
        automaticSelectionIssueSortKey(
            tag: "pending",
            source: source,
            details: automaticSelectionTicketSortComponents(ticket)
        )
    case let .unavailable(source, reason):
        automaticSelectionIssueSortKey(
            tag: "unavailable",
            source: source,
            details: automaticSelectionUnavailableReasonSortComponents(reason)
        )
    case let .staleCatalogGeneration(source, currentCatalogGeneration):
        automaticSelectionIssueSortKey(
            tag: "staleCatalogGeneration",
            source: source,
            details: [automaticSelectionOptionalUInt64SortComponent(currentCatalogGeneration)]
        )
    }
}

private func automaticSelectionIssueSortKey(
    tag: String,
    source: WorkspaceCodemapAutomaticSelectionSourceIdentity,
    details: [String] = []
) -> WorkspaceCodemapAutomaticSelectionIssueSortKey {
    automaticSelectionIssueSortKey(
        tag: tag,
        rootEpoch: source.rootEpoch,
        fileID: source.fileID,
        details: [String(source.catalogGeneration)] + details
    )
}

private func automaticSelectionIssueSortKey(
    tag: String,
    rootEpoch: WorkspaceCodemapRootEpoch? = nil,
    fileID: UUID? = nil,
    details: [String] = []
) -> WorkspaceCodemapAutomaticSelectionIssueSortKey {
    var components = [tag]
    if let rootEpoch {
        components.append(contentsOf: automaticSelectionRootEpochSortComponents(rootEpoch))
    } else {
        components.append(contentsOf: ["", ""])
    }
    components.append(fileID?.uuidString ?? "")
    components.append(contentsOf: details)
    return WorkspaceCodemapAutomaticSelectionIssueSortKey(components: components)
}

private func automaticSelectionRootEpochSortComponents(
    _ rootEpoch: WorkspaceCodemapRootEpoch
) -> [String] {
    [rootEpoch.rootID.uuidString, rootEpoch.rootLifetimeID.uuidString]
}

private func automaticSelectionTicketSortComponents(
    _ ticket: WorkspaceCodemapArtifactDemandTicket
) -> [String] {
    [
        ticket.retainID.uuidString,
        ticket.requestID.uuidString
    ] + automaticSelectionRootEpochSortComponents(ticket.rootEpoch) + [
        ticket.fileID.uuidString,
        String(ticket.requestGeneration),
        String(ticket.catalogGeneration),
        String(ticket.pathGeneration),
        String(ticket.ingressGeneration)
    ]
}

private func automaticSelectionGraphPartialReasonSortComponents(
    _ reason: WorkspaceCodemapStoreSelectionGraphPartialReason
) -> [String] {
    switch reason {
    case .referenceFailuresPresent: ["referenceFailuresPresent"]
    case .sourceCoverageIncomplete: ["sourceCoverageIncomplete"]
    }
}

private func automaticSelectionUnavailableReasonSortComponents(
    _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
) -> [String] {
    switch reason {
    case .rootNotLoaded: ["rootNotLoaded"]
    case .fileNotCataloged: ["fileNotCataloged"]
    case .unsupportedFileType: ["unsupportedFileType"]
    case let .gitTerminal(reason): ["gitTerminal", reason.rawValue]
    case let .gitTransient(reason): ["gitTransient", reason.rawValue]
    case let .demandUnavailable(reason):
        ["demandUnavailable"] + automaticSelectionDemandUnavailableReasonSortComponents(reason)
    case let .busy(retryAfterMilliseconds):
        ["busy", automaticSelectionOptionalIntSortComponent(retryAfterMilliseconds)]
    case let .rejected(reason):
        ["rejected"] + automaticSelectionDemandRejectionSortComponents(reason)
    case .routeConflict: ["routeConflict"]
    case .registrationFailed: ["registrationFailed"]
    case .runtimeFailure: ["runtimeFailure"]
    case .staleCurrentness: ["staleCurrentness"]
    case .cancelled: ["cancelled"]
    }
}

private func automaticSelectionDemandUnavailableReasonSortComponents(
    _ reason: WorkspaceCodemapBindingDemandUnavailableReason
) -> [String] {
    switch reason {
    case .unsupportedFileType: ["unsupportedFileType"]
    case .missing: ["missing"]
    case .securityExcluded: ["securityExcluded"]
    case .nonRegular: ["nonRegular"]
    case .oversized: ["oversized"]
    case .transient: ["transient"]
    case let .terminalArtifact(outcome):
        ["terminalArtifact"] + automaticSelectionLiveArtifactOutcomeSortComponents(outcome)
    }
}

private func automaticSelectionDemandRejectionSortComponents(
    _ reason: WorkspaceCodemapBindingDemandRejection
) -> [String] {
    switch reason {
    case .rootNotRegistered: ["rootNotRegistered"]
    case .capabilityUnavailable: ["capabilityUnavailable"]
    case .rootEpochMismatch: ["rootEpochMismatch"]
    case .rootPathMismatch: ["rootPathMismatch"]
    case .invalidIdentity: ["invalidIdentity"]
    case .catalogGenerationMismatch: ["catalogGenerationMismatch"]
    case .requestGenerationInvalid: ["requestGenerationInvalid"]
    case .stalePathGeneration: ["stalePathGeneration"]
    case .staleIngressGeneration: ["staleIngressGeneration"]
    case .languageMismatch: ["languageMismatch"]
    case .classificationMismatch: ["classificationMismatch"]
    case .sourceAuthorityUnavailable: ["sourceAuthorityUnavailable"]
    case .overlayRejected: ["overlayRejected"]
    case .staleCompletion: ["staleCompletion"]
    }
}

private func automaticSelectionLiveArtifactOutcomeSortComponents(
    _ outcome: WorkspaceCodemapLiveArtifactOutcome
) -> [String] {
    switch outcome {
    case .ready: ["ready"]
    case .readyNoSymbols: ["readyNoSymbols"]
    case .oversize: ["oversize"]
    case .decodeFailed: ["decodeFailed"]
    case .parseFailed: ["parseFailed"]
    }
}

private func automaticSelectionOptionalIntSortComponent(_ value: Int?) -> String {
    value.map { String($0) } ?? "nil"
}

private func automaticSelectionOptionalUInt64SortComponent(_ value: UInt64?) -> String {
    value.map { String($0) } ?? "nil"
}

struct WorkspaceCodemapAutomaticSelectionPublicationReceipt: Equatable {
    let requestID: UUID
    let rootScope: WorkspaceLookupRootScope
    let rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    let sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
    let graphKeys: [WorkspaceCodemapSelectionGraphRuntimeKey]
    let coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
    let targets: [WorkspaceCodemapAutomaticSelectionTarget]
    let publicationBasis: WorkspaceCodemapAutomaticSelectionPublicationBasis
    let publicationPermit: WorkspaceCodemapAutomaticSelectionPublicationPermit
    let publicationLease: WorkspaceCodemapAutomaticSelectionPublicationLease?

    init(
        requestID: UUID,
        rootScope: WorkspaceLookupRootScope,
        rootScopeEpochs: [WorkspaceCodemapRootEpoch],
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        graphKeys: [WorkspaceCodemapSelectionGraphRuntimeKey],
        coverageProofs: [WorkspaceCodemapProjectionCoverageProof],
        targets: [WorkspaceCodemapAutomaticSelectionTarget],
        publicationBasis: WorkspaceCodemapAutomaticSelectionPublicationBasis = .projectionCoverage,
        publicationPermit: WorkspaceCodemapAutomaticSelectionPublicationPermit,
        publicationLease: WorkspaceCodemapAutomaticSelectionPublicationLease? = nil
    ) {
        self.requestID = requestID
        self.rootScope = rootScope
        self.rootScopeEpochs = rootScopeEpochs
        self.sourceTickets = sourceTickets
        self.graphKeys = graphKeys
        self.coverageProofs = coverageProofs
        self.targets = targets
        self.publicationBasis = publicationBasis
        self.publicationPermit = publicationPermit
        self.publicationLease = publicationLease
    }
}

enum WorkspaceCodemapAutomaticSelectionPublicationDisposition: Equatable {
    case current([WorkspaceCodemapAutomaticSelectionTarget])
    case stale(WorkspaceCodemapAutomaticSelectionStaleReason)
}

struct WorkspaceCodemapAutomaticSelectionCandidatePlan: Equatable {
    let candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
    let rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    let coverageProofs: [WorkspaceCodemapProjectionCoverageProof]
}

struct WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan: Equatable {
    let candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
    let rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    let incompleteReasons: [WorkspaceCodemapAutomaticSelectionIncompleteReason]
}

enum WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition: Equatable {
    case ready(WorkspaceCodemapAutomaticSelectionCandidatePlan)
    case provisional(WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan)
    case incomplete([WorkspaceCodemapAutomaticSelectionIncompleteReason])
    case pending([WorkspaceCodemapAutomaticSelectionPendingReason])
    case busy(WorkspaceCodemapStoreSelectionGraphQueryBusyReason)
    case unavailable(WorkspaceCodemapAutomaticSelectionUnavailableReason)
    case stale(WorkspaceCodemapAutomaticSelectionStaleReason)
    case budget(WorkspaceCodemapAutomaticSelectionBudgetReason)
}

func automaticSelectionCandidatePlanDispositionShouldRetryForReadiness(
    _ disposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition
) -> Bool {
    switch disposition {
    case .provisional, .incomplete, .pending, .busy:
        true
    case let .unavailable(reason):
        automaticSelectionUnavailableReasonIsTransientGraphReadiness(reason)
    case let .stale(reason):
        automaticSelectionStaleReasonIsTransientGraphReadiness(reason)
    case .ready, .budget:
        false
    }
}

func automaticSelectionCandidatePlanDispositionIsTransientGraphReadiness(
    _ disposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition
) -> Bool {
    switch disposition {
    case let .unavailable(reason):
        automaticSelectionUnavailableReasonIsTransientGraphReadiness(reason)
    case let .stale(reason):
        automaticSelectionStaleReasonIsTransientGraphReadiness(reason)
    case .ready, .provisional, .incomplete, .pending, .busy, .budget:
        false
    }
}

func automaticSelectionAggregateCoverageShouldRetryForReadiness(
    _ coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
) -> Bool {
    switch coverage {
    case .incomplete, .pending, .busy:
        true
    case let .unavailable(reason):
        automaticSelectionUnavailableReasonIsTransientGraphReadiness(reason)
    case let .stale(reason):
        automaticSelectionStaleReasonIsTransientGraphReadiness(reason)
    case .complete, .partial, .provisional, .budget:
        false
    }
}

func automaticSelectionAggregateCoverageIsTransientGraphReadiness(
    _ coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
) -> Bool {
    switch coverage {
    case let .unavailable(reason):
        automaticSelectionUnavailableReasonIsTransientGraphReadiness(reason)
    case let .stale(reason):
        automaticSelectionStaleReasonIsTransientGraphReadiness(reason)
    case .complete, .partial, .provisional, .incomplete, .pending, .busy, .budget:
        false
    }
}

private func automaticSelectionUnavailableReasonIsTransientGraphReadiness(
    _ reason: WorkspaceCodemapAutomaticSelectionUnavailableReason
) -> Bool {
    switch reason {
    case let .graph(graphReason):
        automaticSelectionGraphUnavailableReasonIsTransientReadiness(graphReason)
    case .noReadySources, .candidate:
        false
    }
}

private func automaticSelectionStaleReasonIsTransientGraphReadiness(
    _ reason: WorkspaceCodemapAutomaticSelectionStaleReason
) -> Bool {
    switch reason {
    case let .graph(graphReason):
        automaticSelectionGraphStaleReasonIsTransientReadiness(graphReason)
    case .rootEpochNotCurrent, .rootScopeChanged, .sourceStateChanged, .sourceCatalogGeneration,
         .targetStateChanged, .coverageProof, .publicationReceipt:
        false
    }
}

private func automaticSelectionGraphUnavailableReasonIsTransientReadiness(
    _ reason: WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason
) -> Bool {
    switch reason {
    case .notActivated, .sourceNotReady:
        true
    case .runtime(_, .notBuilt):
        true
    case .emptySources, .foreignRootEpoch, .duplicateSourceConflict, .invalidGraphResult,
         .definitionUniverse, .runtime:
        false
    }
}

private func automaticSelectionGraphStaleReasonIsTransientReadiness(
    _ reason: WorkspaceCodemapStoreSelectionGraphQueryStaleReason
) -> Bool {
    switch reason {
    case .currentness:
        true
    case .runtime(_, .staleCurrentness):
        true
    case .runtime:
        false
    }
}

struct WorkspaceCodemapAutomaticSelectionResult: Equatable {
    let roots: [WorkspaceCodemapAutomaticSelectionRootResult]
    let aggregateCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
    let publicationReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?

    init(
        roots: [WorkspaceCodemapAutomaticSelectionRootResult],
        aggregateCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage? = nil,
        publicationReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt? = nil
    ) {
        self.roots = roots
        self.aggregateCoverage = if roots.isEmpty, let aggregateCoverage {
            aggregateCoverage
        } else {
            Self.aggregateCoverage(for: roots)
        }
        self.publicationReceipt = Self.validatedPublicationReceipt(
            publicationReceipt,
            coverage: self.aggregateCoverage
        )
    }

    var targets: [WorkspaceCodemapAutomaticSelectionTarget] {
        switch aggregateCoverage {
        case .complete, .partial, .provisional:
            roots.flatMap(\.targets)
        case .incomplete, .pending, .unavailable, .stale, .busy, .budget:
            []
        }
    }

    private static func aggregateCoverage(
        for roots: [WorkspaceCodemapAutomaticSelectionRootResult]
    ) -> WorkspaceCodemapAutomaticSelectionAggregateCoverage {
        var proofs: [WorkspaceCodemapProjectionCoverageProof] = []
        var partial: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        var provisionalIncomplete: [WorkspaceCodemapAutomaticSelectionIncompleteReason] = []
        var provisionalPending: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        var provisionalPartial: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        var sawProvisional = false
        for root in roots {
            switch root.coverage {
            case let .complete(proof):
                proofs.append(proof)
            case let .partial(proof, reasons):
                proofs.append(proof)
                partial.append(contentsOf: reasons)
            case let .provisional(incomplete, pending, provisionalReasons):
                sawProvisional = true
                provisionalIncomplete.append(contentsOf: incomplete)
                provisionalPending.append(contentsOf: pending)
                provisionalPartial.append(contentsOf: provisionalReasons)
            case let .incomplete(reasons):
                return .incomplete(reasons)
            case let .pending(reasons):
                return .pending(reasons)
            case let .unavailable(reason):
                return .unavailable(reason)
            case let .stale(reason):
                return .stale(reason)
            case let .busy(reason):
                return .busy(reason)
            case let .budget(reason):
                return .budget(.graph(rootEpoch: root.rootEpoch, reason: reason))
            }
        }
        if sawProvisional {
            return .provisional(
                incomplete: provisionalIncomplete,
                pending: provisionalPending,
                partial: partial + provisionalPartial
            )
        }
        return partial.isEmpty ? .complete(proofs) : .partial(proofs: proofs, reasons: partial)
    }

    private static func validatedPublicationReceipt(
        _ receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?,
        coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
    ) -> WorkspaceCodemapAutomaticSelectionPublicationReceipt? {
        guard let receipt,
              receipt.publicationPermit.withCurrent({ true }) == true
        else { return nil }
        switch coverage {
        case let .complete(coverageProofs), let .partial(coverageProofs, _):
            guard receipt.publicationBasis == .projectionCoverage,
                  receipt.coverageProofs == coverageProofs
            else { return nil }
            return receipt
        case .provisional:
            guard case let .provisionalCandidates(candidates) = receipt.publicationBasis,
                  receipt.coverageProofs.isEmpty,
                  receipt.graphKeys.isEmpty,
                  !receipt.targets.isEmpty,
                  candidates.count == receipt.targets.count
            else { return nil }
            let candidateSlots = candidates.map { WorkspaceCodemapRootScopedFileSlot(candidate: $0) }
            let targetSlots = receipt.targets.map { WorkspaceCodemapRootScopedFileSlot(target: $0) }
            guard Set(candidateSlots).count == candidates.count,
                  Set(targetSlots).count == receipt.targets.count,
                  Set(candidateSlots) == Set(targetSlots)
            else { return nil }
            return receipt
        case .incomplete, .pending, .unavailable, .stale, .busy, .budget:
            return nil
        }
    }
}
