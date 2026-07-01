import Foundation

let workspaceCodemapProductionDemandWaitMilliseconds = 10000

struct WorkspaceCodemapPresentationRequestPolicy: Equatable {
    static let `default` = Self()

    let maximumReadinessRounds: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let maximumTotalWait: Duration
    let maximumStructureSeedCountPerRoot: Int
    let maximumCandidateDemandCount: Int
    let maximumStructurePublicationAttempts: Int

    init(
        maximumReadinessRounds: Int = 4096,
        initialBackoffMilliseconds: Int = 25,
        maximumBackoffMilliseconds: Int = 250,
        maximumTotalWait: Duration = .milliseconds(workspaceCodemapProductionDemandWaitMilliseconds),
        maximumStructureSeedCountPerRoot: Int = 8192,
        maximumCandidateDemandCount: Int = 1024,
        maximumStructurePublicationAttempts: Int = 4
    ) {
        precondition(maximumReadinessRounds > 0)
        precondition(initialBackoffMilliseconds > 0)
        precondition(maximumBackoffMilliseconds >= initialBackoffMilliseconds)
        precondition(maximumTotalWait >= .zero)
        precondition(maximumStructureSeedCountPerRoot > 0)
        precondition(maximumCandidateDemandCount > 0)
        precondition(maximumStructurePublicationAttempts > 0)
        self.maximumReadinessRounds = maximumReadinessRounds
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.maximumTotalWait = maximumTotalWait
        self.maximumStructureSeedCountPerRoot = maximumStructureSeedCountPerRoot
        self.maximumCandidateDemandCount = maximumCandidateDemandCount
        self.maximumStructurePublicationAttempts = maximumStructurePublicationAttempts
    }
}

struct WorkspaceCodemapPresentationWaiter {
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = Self { duration in
        try await Task.sleep(for: duration)
    }
}

private actor WorkspaceCodemapOperationPresentationOwnership {
    struct Resources {
        let tickets: [WorkspaceCodemapArtifactDemandTicket]
        let projectionTickets: [WorkspaceCodemapProjectionDemandTicket]
        let bundles: [WorkspaceCodemapFrozenPresentationBundle]
    }

    private var ticketsByRetainID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
    private var bundlesByID: [
        WorkspaceCodemapFrozenPresentationBundleID: WorkspaceCodemapFrozenPresentationBundle
    ] = [:]
    private var bundleIDsInAcquisitionOrder: [WorkspaceCodemapFrozenPresentationBundleID] = []
    private var projectionTicketsByID: [UUID: WorkspaceCodemapProjectionDemandTicket] = [:]

    func record(_ ownedResult: WorkspaceCodemapArtifactDemandOwnedResult) {
        switch ownedResult.ownership {
        case let .created(ticket), let .joined(ticket):
            ticketsByRetainID[ticket.retainID] = ticket
        case .notAcquired:
            break
        }
    }

    func record(_ bundle: WorkspaceCodemapFrozenPresentationBundle) {
        if bundlesByID[bundle.id] == nil {
            bundleIDsInAcquisitionOrder.append(bundle.id)
        }
        bundlesByID[bundle.id] = bundle
    }

    func record(_ ticket: WorkspaceCodemapProjectionDemandTicket) {
        projectionTicketsByID[ticket.id] = ticket
    }

    func tickets() -> [WorkspaceCodemapArtifactDemandTicket] {
        ticketsByRetainID.values.sorted { $0.retainID.uuidString < $1.retainID.uuidString }
    }

    func owns(_ ticket: WorkspaceCodemapArtifactDemandTicket) -> Bool {
        ticketsByRetainID[ticket.retainID] == ticket
    }

    func replaceConsumed(
        _ oldTicket: WorkspaceCodemapArtifactDemandTicket,
        with result: WorkspaceCodemapArtifactDemandResult
    ) {
        ticketsByRetainID.removeValue(forKey: oldTicket.retainID)
        let replacement: WorkspaceCodemapArtifactDemandTicket? = switch result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
        if let replacement {
            ticketsByRetainID[replacement.retainID] = replacement
        }
    }

    func drain() -> Resources {
        let resources = Resources(
            tickets: ticketsByRetainID.values.sorted { $0.retainID.uuidString < $1.retainID.uuidString },
            projectionTickets: projectionTicketsByID.values.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            bundles: bundleIDsInAcquisitionOrder.compactMap { bundlesByID[$0] }
        )
        ticketsByRetainID.removeAll()
        projectionTicketsByID.removeAll()
        bundlesByID.removeAll()
        bundleIDsInAcquisitionOrder.removeAll()
        return resources
    }
}

struct WorkspaceCodemapPresentationCoordinator {
    private struct AutomaticPreparation {
        let candidates: [WorkspaceCodemapOperationPresentationCandidate]
        let issues: [WorkspaceCodemapOperationIssue]
        let coverage: WorkspaceCodemapOperationPresentationCoverage?
        let receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?
    }

    private struct DemandBatch {
        let resultsByFileID: [UUID: WorkspaceCodemapArtifactDemandResult]
        let deadlineReached: Bool
        let defensiveRoundLimitReached: Bool
    }

    private struct ProvisionalDemandBatch {
        let readyCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
        let pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason]
        let partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason]
    }

    private enum ProjectionDemandWaitOutcome {
        case ready(WorkspaceCodemapProjectionCoverageProof)
        case busy(retryAfterMilliseconds: Int)
        case timeout(retryAfterMilliseconds: Int)
        case unavailable(WorkspaceCodemapProjectionDemandUnavailableReason, retryAfterMilliseconds: Int?)
        case stale
        case cancelled
    }

    let store: WorkspaceFileContextStore
    let policy: WorkspaceCodemapPresentationRequestPolicy
    let waiter: WorkspaceCodemapPresentationWaiter
    let beforePublicationRevalidation: @Sendable (
        WorkspaceCodemapOperationPresentationPublicationReceipt
    ) async -> Void
    let afterAutomaticCandidateReconstruction: @Sendable (
        WorkspaceCodemapAutomaticSelectionPublicationReceipt
    ) async throws -> Void
    let structureAttemptDidBegin: @Sendable (Int) -> Void

    init(
        store: WorkspaceFileContextStore,
        policy: WorkspaceCodemapPresentationRequestPolicy = .default,
        waiter: WorkspaceCodemapPresentationWaiter = .production,
        beforePublicationRevalidation: @escaping @Sendable (
            WorkspaceCodemapOperationPresentationPublicationReceipt
        ) async -> Void = { _ in },
        afterAutomaticCandidateReconstruction: @escaping @Sendable (
            WorkspaceCodemapAutomaticSelectionPublicationReceipt
        ) async throws -> Void = { _ in },
        structureAttemptDidBegin: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.store = store
        self.policy = policy
        self.waiter = waiter
        self.beforePublicationRevalidation = beforePublicationRevalidation
        self.afterAutomaticCandidateReconstruction = afterAutomaticCandidateReconstruction
        self.structureAttemptDidBegin = structureAttemptDidBegin
    }

    func presentation(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapOperationPresentation {
        try await withPresentation(
            for: intent,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        ) { $0 }
    }

    func withPresentation<Value>(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:],
        operation: (WorkspaceCodemapOperationPresentation) async throws -> Value
    ) async throws -> Value {
        guard intent != .none else {
            try Task.checkCancellation()
            let value = try await operation(.empty)
            try Task.checkCancellation()
            return value
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        var lastStaleReason: WorkspaceCodemapOperationPublicationStaleReason?

        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            let ownership = WorkspaceCodemapOperationPresentationOwnership()
            do {
                let result = try await makePresentation(
                    intent: intent,
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                if let reason = retryableStaleReason(in: result.issues) {
                    lastStaleReason = reason
                    await release(ownership)
                    if attempt == 0, clock.now < deadline { continue }
                    let value = try await operation(incompletePublication(reason: reason))
                    try Task.checkCancellation()
                    return value
                }
                if let reason = lastStaleReason,
                   result.publicationReceipt == nil,
                   result.orderedEntries.isEmpty
                {
                    await release(ownership)
                    let value = try await operation(incompletePublication(reason: reason))
                    try Task.checkCancellation()
                    return value
                }
                let value = try await operation(result)
                try Task.checkCancellation()
                if let receipt = result.publicationReceipt {
                    await beforePublicationRevalidation(receipt)
                    try Task.checkCancellation()
                    let disposition = await store.revalidateCodemapOperationPresentationForPublication(
                        receipt,
                        rootScope: rootScope
                    )
                    switch disposition {
                    case .current:
                        await release(ownership)
                        return value
                    case let .stale(reason):
                        lastStaleReason = reason
                        await release(ownership)
                        if attempt == 0, clock.now < deadline { continue }
                        let fallbackValue = try await operation(incompletePublication(reason: reason))
                        try Task.checkCancellation()
                        return fallbackValue
                    }
                }
                await release(ownership)
                return value
            } catch {
                await release(ownership)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        }
        let value = try await operation(incompletePublication(reason: lastStaleReason ?? .rootScope))
        try Task.checkCancellation()
        return value
    }

    private func makePresentation(
        intent: WorkspaceCodemapOperationPresentationIntent,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapOperationPresentation {
        let candidates: [WorkspaceCodemapOperationPresentationCandidate]
        var issues: [WorkspaceCodemapOperationIssue]
        let completeRootSet: Bool
        let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
        let automaticReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?

        switch intent {
        case .none:
            return .empty
        case let .exact(fileIDs, isCompleteRootSet):
            let collection = await store.codemapOperationPresentationCandidates(
                forFileIDs: fileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                includeCompleteRootCatalogs: isCompleteRootSet
            )
            candidates = collection.candidates
            issues = collection.issues.map(WorkspaceCodemapOperationIssue.candidate)
            completeRootSet = isCompleteRootSet
            completeRootCatalogs = collection.completeRootCatalogs
            automaticReceipt = nil
        case let .automatic(sourceFileIDs):
            let preparation = try await prepareAutomaticCandidates(
                sourceFileIDs: sourceFileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
            if let coverage = preparation.coverage {
                return WorkspaceCodemapOperationPresentation(
                    orderedEntries: [],
                    coverage: coverage,
                    issues: preparation.issues,
                    publicationReceipt: nil
                )
            }
            candidates = preparation.candidates
            issues = preparation.issues
            completeRootSet = false
            completeRootCatalogs = []
            automaticReceipt = preparation.receipt
        }

        guard !candidates.isEmpty else {
            let coverage: WorkspaceCodemapOperationPresentationCoverage = issues.isEmpty
                ? .complete
                : .unavailable(issues)
            let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt? = if let automaticReceipt {
                WorkspaceCodemapOperationPresentationPublicationReceipt(
                    requestID: UUID(),
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: [:],
                    completeRootSet: completeRootSet,
                    completeRootCatalogs: completeRootCatalogs,
                    candidates: [],
                    demandTickets: [],
                    bundles: [],
                    automaticReceipt: automaticReceipt
                )
            } else {
                nil
            }
            return WorkspaceCodemapOperationPresentation(
                orderedEntries: [],
                coverage: coverage,
                issues: issues,
                publicationReceipt: receipt
            )
        }

        let demandBatch = try await demand(
            fileIDs: candidates.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var requestsByRoot: [WorkspaceCodemapRootEpoch: [WorkspaceCodemapPresentationRequest]] = [:]
        for candidate in candidates {
            guard let result = demandBatch.resultsByFileID[candidate.fileID] else {
                issues.append(.unavailable(fileID: candidate.fileID, reason: .registrationFailed))
                continue
            }
            switch result {
            case let .ready(ready):
                guard ready.ticket.rootEpoch == candidate.rootEpoch else {
                    issues.append(.unavailable(fileID: candidate.fileID, reason: .staleCurrentness))
                    continue
                }
                requestsByRoot[candidate.rootEpoch, default: []].append(
                    WorkspaceCodemapPresentationRequest(
                        ticket: ready.ticket,
                        logicalPath: candidate.logicalPath
                    )
                )
            case let .pending(ticket):
                issues.append(.pending(fileID: candidate.fileID, ticket: ticket))
            case let .unavailable(reason):
                issues.append(.unavailable(fileID: candidate.fileID, reason: reason))
            }
        }

        var renderedEntries: [WorkspaceCodemapOperationRenderedEntry] = []
        var bundleReceipts: [WorkspaceCodemapOperationPresentationBundleReceipt] = []
        for rootEpoch in requestsByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes) {
            try Task.checkCancellation()
            let requests = requestsByRoot[rootEpoch] ?? []
            switch await store.freezeCodemapPresentation(requests) {
            case let .unavailable(reason):
                issues.append(.freezeUnavailable(rootEpoch: rootEpoch, reason: reason))
            case let .ready(bundle):
                await ownership.record(bundle)
                switch await store.renderCodemapPresentation(bundle) {
                case let .unavailable(reason):
                    issues.append(.renderUnavailable(rootEpoch: rootEpoch, reason: reason))
                case let .ready(rendered):
                    bundleReceipts.append(WorkspaceCodemapOperationPresentationBundleReceipt(
                        bundleID: bundle.id,
                        rootEpoch: bundle.rootEpoch,
                        entries: bundle.entries
                    ))
                    renderedEntries.append(contentsOf: rendered.map { entry in
                        WorkspaceCodemapOperationRenderedEntry(
                            bundleID: bundle.id,
                            fileID: entry.ticket.fileID,
                            rootEpoch: entry.ticket.rootEpoch,
                            artifactKey: entry.artifactKey,
                            logicalPath: entry.logicalPath,
                            text: entry.text,
                            tokenCount: entry.tokenCount
                        )
                    })
                }
            }
        }
        renderedEntries.sort(by: renderedEntryPrecedes)
        issues.sort { debugReflectionIssueSortKey($0) < debugReflectionIssueSortKey($1) }
        let coverage = coverage(for: renderedEntries, issues: issues)
        let receipt: WorkspaceCodemapOperationPresentationPublicationReceipt?
        if renderedEntries.isEmpty, automaticReceipt == nil {
            receipt = nil
        } else {
            let candidatesByFileID = Dictionary(
                uniqueKeysWithValues: candidates.map { ($0.fileID, $0) }
            )
            let publishedCandidates = renderedEntries.compactMap { candidatesByFileID[$0.fileID] }
            let validatedLogicalRootDisplayNames = Dictionary(
                publishedCandidates.map { ($0.rootEpoch.rootID, $0.logicalPath.rootDisplayName) },
                uniquingKeysWith: { current, _ in current }
            )
            let demandTickets = publicationTickets(
                from: bundleReceipts,
                publishedFileIDs: Set(renderedEntries.map(\.fileID))
            )
            receipt = WorkspaceCodemapOperationPresentationPublicationReceipt(
                requestID: UUID(),
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: validatedLogicalRootDisplayNames,
                completeRootSet: completeRootSet,
                completeRootCatalogs: completeRootCatalogs,
                candidates: publishedCandidates,
                demandTickets: demandTickets,
                bundles: bundleReceipts,
                automaticReceipt: automaticReceipt
            )
        }
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: renderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: receipt
        )
    }

    private func prepareAutomaticCandidates(
        sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> AutomaticPreparation {
        let sourceCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: sourceFileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        var issues = sourceCollection.issues.map(WorkspaceCodemapOperationIssue.candidate)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceCollection.candidates.map(\.fileID),
            rootScope: rootScope
        )
        guard !identities.isEmpty else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage
                .unavailable(.noReadySources)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }
        let sourceLimit = await store.automaticCodemapSelectionSourceDemandLimit()
        guard identities.count <= sourceLimit else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(
                .sourceLimit(attempted: identities.count, limit: sourceLimit)
            )
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }

        let sourceDemand = try await demand(
            fileIDs: identities.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var readySources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
        var pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        var partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        for source in identities {
            guard let result = sourceDemand.resultsByFileID[source.fileID] else { continue }
            switch result {
            case .ready:
                readySources.append(source)
            case let .pending(ticket):
                pendingReasons.append(.sourceDemand(source, ticket))
                partialReasons.append(.sourceDemandTimedOut(source))
            case .unavailable(.busy):
                pendingReasons.append(.sourceBusy(source, attempts: policy.maximumReadinessRounds))
                partialReasons.append(.sourceDemandTimedOut(source))
            case let .unavailable(reason):
                partialReasons.append(.source(.unavailable(source, reason)))
            }
        }
        guard !readySources.isEmpty else {
            pendingReasons.sort(by: automaticSelectionPendingReasonPrecedes)
            partialReasons.sort(by: automaticSelectionPartialReasonPrecedes)
            let automaticCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage = pendingReasons.isEmpty
                ? .unavailable(.noReadySources)
                : .pending(pendingReasons)
            issues.append(.automatic(automaticCoverage))
            let coverage: WorkspaceCodemapOperationPresentationCoverage = pendingReasons.isEmpty
                ? .unavailable(issues)
                : .pending(issues)
            return AutomaticPreparation(candidates: [], issues: issues, coverage: coverage, receipt: nil)
        }
        let allSourceRootEpochs = Set(identities.map(\.rootEpoch))
        let readySourceRootEpochs = Set(readySources.map(\.rootEpoch))
        guard readySourceRootEpochs == allSourceRootEpochs else {
            pendingReasons.sort(by: automaticSelectionPendingReasonPrecedes)
            let automaticCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage =
                pendingReasons.isEmpty ? .unavailable(.noReadySources) : .pending(pendingReasons)
            issues.append(.automatic(automaticCoverage))
            let coverage: WorkspaceCodemapOperationPresentationCoverage = pendingReasons.isEmpty
                ? .unavailable(issues)
                : .pending(issues)
            return AutomaticPreparation(candidates: [], issues: issues, coverage: coverage, receipt: nil)
        }

        let retainedSourceTickets = await ownership.tickets()
        let readySourceIDs = Set(readySources.map(\.fileID))
        let sourceTicketsByRoot = Dictionary(
            grouping: retainedSourceTickets.filter { readySourceIDs.contains($0.fileID) },
            by: \.rootEpoch
        )
        let projectionDeadline = projectionDeadlineUptimeNanoseconds(clock: clock, deadline: deadline)
        for rootEpoch in sourceTicketsByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes) {
            let acquisition = await store.acquireCodemapProjectionDemand(
                sourceTickets: sourceTicketsByRoot[rootEpoch] ?? [],
                deadlineUptimeNanoseconds: projectionDeadline
            )
            if case let .acquired(ticket, _) = acquisition {
                await ownership.record(ticket)
            }
        }
        var planDisposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition = .pending([])
        var provisionallyDemandedFileIDs = Set<UUID>()
        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            planDisposition = await store.planAutomaticCodemapSelectionCandidates(
                sources: readySources,
                rootScope: rootScope,
                maximumCandidateDemandCount: policy.maximumCandidateDemandCount
            )
            if case let .provisional(provisional) = planDisposition {
                for candidate in provisional.candidates
                    where !provisionallyDemandedFileIDs.contains(candidate.identity.fileID)
                {
                    guard let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                        candidate: candidate,
                        rootScope: rootScope,
                        rootScopeEpochs: provisional.rootScopeEpochs
                    ) else { continue }
                    await ownership.record(owned)
                    switch owned.result {
                    case .ready, .pending:
                        provisionallyDemandedFileIDs.insert(candidate.identity.fileID)
                    case .unavailable(.busy):
                        break
                    case .unavailable:
                        provisionallyDemandedFileIDs.insert(candidate.identity.fileID)
                    }
                }
            }
            guard automaticSelectionCandidatePlanDispositionShouldRetryForReadiness(planDisposition),
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
        }
        if automaticSelectionCandidatePlanDispositionIsTransientGraphReadiness(planDisposition) {
            let rootEpochs = Set(readySources.map(\.rootEpoch))
            if try await drainAutomaticSelectionGraphPublications(
                rootEpochs: rootEpochs,
                clock: clock,
                deadline: deadline
            ) {
                planDisposition = await store.planAutomaticCodemapSelectionCandidates(
                    sources: readySources,
                    rootScope: rootScope,
                    maximumCandidateDemandCount: policy.maximumCandidateDemandCount
                )
            }
        }
        let plan: WorkspaceCodemapAutomaticSelectionCandidatePlan
        switch planDisposition {
        case let .ready(value):
            plan = value
        case let .provisional(value):
            let provisionalDemand = try await settleProvisionalAutomaticCandidates(
                plan: value,
                rootScope: rootScope,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
            let selection = await store.provisionalAutomaticCodemapSelectionResult(
                sources: readySources,
                plan: value,
                readyCandidates: provisionalDemand.readyCandidates,
                pendingReasons: pendingReasons + provisionalDemand.pendingReasons,
                partialReasons: partialReasons + provisionalDemand.partialReasons,
                rootScope: rootScope
            )
            issues.append(.automatic(selection.aggregateCoverage))
            guard case .provisional = selection.aggregateCoverage else {
                let coverage: WorkspaceCodemapOperationPresentationCoverage = switch selection.aggregateCoverage {
                case .unavailable, .stale, .budget:
                    .unavailable(issues)
                default:
                    .pending(issues)
                }
                return AutomaticPreparation(candidates: [], issues: issues, coverage: coverage, receipt: nil)
            }
            let targets = selection.targets
            guard let automaticReceipt = selection.publicationReceipt,
                  automaticReceipt.targets == targets,
                  automaticReceipt.publicationPermit.withCurrent({ true }) == true,
                  !targets.isEmpty
            else {
                return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
            }
            let collection = await store.codemapOperationPresentationCandidates(
                forFileIDs: targets.map(\.fileID),
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            )
            try await afterAutomaticCandidateReconstruction(automaticReceipt)
            let publicationDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
                automaticReceipt,
                rootScope: rootScope
            )
            guard case let .current(currentTargets) = publicationDisposition,
                  currentTargets == targets
            else {
                return staleAutomaticPreparation(issues: issues)
            }
            issues.append(contentsOf: collection.issues.map(WorkspaceCodemapOperationIssue.candidate))
            guard let preparation = automaticReceipt.publicationPermit.withCurrent({
                AutomaticPreparation(
                    candidates: collection.candidates,
                    issues: issues,
                    coverage: nil,
                    receipt: automaticReceipt
                )
            }) else {
                return staleAutomaticPreparation(issues: issues)
            }
            return preparation
        case let .incomplete(reasons):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.incomplete(reasons)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case let .pending(reasons):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending(reasons)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case let .busy(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.busy(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case let .unavailable(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        case let .stale(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.stale(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        case let .budget(reason):
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.budget(reason)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        }

        guard let candidateDemand = try await demandAutomaticCandidates(
            plan: plan,
            rootScope: rootScope,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        ) else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage
                .stale(.publicationReceipt)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        }
        var candidatePending: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in plan.candidates {
            let fileID = candidate.identity.fileID
            guard let result = candidateDemand.resultsByFileID[fileID] else { continue }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: candidate.identity.rootID,
                rootLifetimeID: candidate.identity.rootLifetimeID
            )
            switch result {
            case .ready:
                break
            case let .pending(ticket):
                candidatePending.append(.candidateDemand(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    ticket: ticket
                ))
            case .unavailable(.busy):
                candidatePending.append(.candidateBusy(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    attempts: policy.maximumReadinessRounds
                ))
            case let .unavailable(reason):
                let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage
                    .unavailable(.candidate(rootEpoch: rootEpoch, fileID: fileID, reason: reason))
                issues.append(.automatic(automaticCoverage))
                return AutomaticPreparation(
                    candidates: [],
                    issues: issues,
                    coverage: .unavailable(issues),
                    receipt: nil
                )
            }
        }
        guard candidatePending.isEmpty else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.pending(candidatePending)
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        }

        let finalGraphDrainRootEpochs = Set(readySources.map(\.rootEpoch)).union(plan.candidates.map(\.rootEpoch))
        guard try await drainAutomaticSelectionGraphPublications(
            rootEpochs: finalGraphDrainRootEpochs,
            clock: clock,
            deadline: deadline
        ) else {
            let automaticCoverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage
                .pending(
                    finalGraphDrainRootEpochs
                        .sorted(by: workspaceCodemapRootEpochPrecedes)
                        .map { .graphRebuild(rootEpoch: $0) }
                )
            issues.append(.automatic(automaticCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        }

        var selection = try await store.resolveAutomaticCodemapSelection(
            sources: readySources,
            rootScope: rootScope
        )
        for round in 1 ..< policy.maximumReadinessRounds {
            guard automaticSelectionAggregateCoverageShouldRetryForReadiness(selection.aggregateCoverage),
                  clock.now < deadline
            else { break }
            try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
            if automaticSelectionAggregateCoverageIsTransientGraphReadiness(selection.aggregateCoverage) {
                let rootEpochs = Set(readySources.map(\.rootEpoch)).union(plan.candidates.map(\.rootEpoch))
                guard try await drainAutomaticSelectionGraphPublications(
                    rootEpochs: rootEpochs,
                    clock: clock,
                    deadline: deadline
                ) else { break }
            }
            selection = try await store.resolveAutomaticCodemapSelection(
                sources: readySources,
                rootScope: rootScope
            )
        }
        if !partialReasons.isEmpty {
            partialReasons.sort(by: automaticSelectionPartialReasonPrecedes)
            selection = automaticSelectionAppendingSourcePartialReasons(
                partialReasons,
                to: selection
            )
        }
        switch selection.aggregateCoverage {
        case .complete:
            break
        case .provisional:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case .partial:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case .incomplete, .pending:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .pending(issues), receipt: nil)
        case .unavailable, .stale, .busy, .budget:
            issues.append(.automatic(selection.aggregateCoverage))
            return AutomaticPreparation(candidates: [], issues: issues, coverage: .unavailable(issues), receipt: nil)
        }
        let targets = selection.targets
        guard let automaticReceipt = selection.publicationReceipt,
              automaticReceipt.targets == targets,
              automaticReceipt.publicationPermit.withCurrent({ true }) == true
        else {
            return staleAutomaticPreparation(issues: issues)
        }
        let collection = await store.codemapOperationPresentationCandidates(
            forFileIDs: targets.map(\.fileID),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        try await afterAutomaticCandidateReconstruction(automaticReceipt)
        let publicationDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
            automaticReceipt,
            rootScope: rootScope
        )
        let currentTargets: [WorkspaceCodemapAutomaticSelectionTarget]
        switch publicationDisposition {
        case let .current(targets):
            currentTargets = targets
        case let .stale(reason):
            return staleAutomaticPreparation(reason: reason, issues: issues)
        }
        guard currentTargets == targets else {
            return staleAutomaticPreparation(issues: issues)
        }
        issues.append(contentsOf: collection.issues.map(WorkspaceCodemapOperationIssue.candidate))
        guard let preparation = automaticReceipt.publicationPermit.withCurrent({
            AutomaticPreparation(
                candidates: collection.candidates,
                issues: issues,
                coverage: nil,
                receipt: automaticReceipt
            )
        }) else {
            return staleAutomaticPreparation(issues: issues)
        }
        return preparation
    }

    private func staleAutomaticPreparation(
        reason: WorkspaceCodemapAutomaticSelectionStaleReason = .publicationReceipt,
        issues existingIssues: [WorkspaceCodemapOperationIssue]
    ) -> AutomaticPreparation {
        var issues = existingIssues
        issues.append(.automatic(.stale(reason)))
        return AutomaticPreparation(
            candidates: [],
            issues: issues,
            coverage: .pending(issues),
            receipt: nil
        )
    }

    private func settleProvisionalAutomaticCandidates(
        plan: WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan,
        rootScope: WorkspaceLookupRootScope,
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> ProvisionalDemandBatch {
        var candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var seen = Set<UUID>()
        for candidate in plan.candidates.sorted(by: automaticSelectionCandidatePrecedes)
            where seen.insert(candidate.identity.fileID).inserted
        {
            candidates.append(candidate)
        }

        var results: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var ticketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        var attemptsByFileID: [UUID: Int] = [:]
        var partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                candidate: candidate,
                rootScope: rootScope,
                rootScopeEpochs: plan.rootScopeEpochs
            ) else {
                // Ownership acquisition only reports nil here; staleCurrentness is the conservative provisional catch-all.
                partialReasons.append(.candidateUnavailable(
                    rootEpoch: candidate.rootEpoch,
                    fileID: candidate.identity.fileID,
                    reason: .staleCurrentness
                ))
                continue
            }
            await ownership.record(owned)
            results[candidate.identity.fileID] = owned.result
            ticketsByFileID[candidate.identity.fileID] = ticket(from: owned.result)
        }

        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            var hasPending = false
            var retryAfter: [Int] = []
            var busyCandidates: [(WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate, WorkspaceCodemapArtifactDemandTicket?)] = []
            for candidate in candidates {
                let fileID = candidate.identity.fileID
                guard let current = results[fileID] else { continue }
                let refreshed: WorkspaceCodemapArtifactDemandResult = switch current {
                case let .pending(ticket): await store.codemapArtifactDemandStatus(ticket)
                case .ready, .unavailable: current
                }
                results[fileID] = refreshed
                switch refreshed {
                case .pending:
                    hasPending = true
                case let .unavailable(.busy(milliseconds)):
                    hasPending = true
                    if let milliseconds { retryAfter.append(milliseconds) }
                    busyCandidates.append((candidate, ticketsByFileID[fileID]))
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(
                round: round,
                suggestedMilliseconds: retryAfter,
                clock: clock,
                deadline: deadline
            )
            for (candidate, existingTicket) in busyCandidates {
                let fileID = candidate.identity.fileID
                attemptsByFileID[fileID, default: 0] += 1
                let result: WorkspaceCodemapArtifactDemandResult
                if let existingTicket, await ownership.owns(existingTicket) {
                    result = await store.retryBusyCodemapArtifactDemand(
                        existingTicket,
                        priority: .background
                    )
                    await ownership.replaceConsumed(existingTicket, with: result)
                } else if let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                    candidate: candidate,
                    rootScope: rootScope,
                    rootScopeEpochs: plan.rootScopeEpochs
                ) {
                    await ownership.record(owned)
                    result = owned.result
                } else {
                    // Ownership reacquisition only reports nil here; staleCurrentness is the conservative catch-all.
                    result = .unavailable(.staleCurrentness)
                }
                results[fileID] = result
                ticketsByFileID[fileID] = ticket(from: result)
            }
        }

        var readyCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in candidates {
            let fileID = candidate.identity.fileID
            guard let result = results[fileID] else { continue }
            let rootEpoch = candidate.rootEpoch
            switch result {
            case .ready:
                readyCandidates.append(candidate)
            case let .pending(ticket):
                pendingReasons.append(.candidateDemand(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    ticket: ticket
                ))
            case .unavailable(.busy):
                pendingReasons.append(.candidateBusy(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    attempts: attemptsByFileID[fileID, default: 0]
                ))
            case let .unavailable(reason):
                partialReasons.append(.candidateUnavailable(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    reason: reason
                ))
            }
        }
        pendingReasons.sort(by: automaticSelectionPendingReasonPrecedes)
        partialReasons.sort(by: automaticSelectionPartialReasonPrecedes)
        return ProvisionalDemandBatch(
            readyCandidates: readyCandidates,
            pendingReasons: pendingReasons,
            partialReasons: partialReasons
        )
    }

    private func demandAutomaticCandidates(
        plan: WorkspaceCodemapAutomaticSelectionCandidatePlan,
        rootScope: WorkspaceLookupRootScope,
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> DemandBatch? {
        var candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var seen = Set<UUID>()
        for candidate in plan.candidates where seen.insert(candidate.identity.fileID).inserted {
            candidates.append(candidate)
        }
        var results: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var ticketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        for candidate in candidates {
            try Task.checkCancellation()
            guard let ownedResult = await store.requestAutomaticCodemapArtifactWithOwnership(
                candidate: candidate,
                rootScope: rootScope,
                rootScopeEpochs: plan.rootScopeEpochs,
                coverageProofs: plan.coverageProofs
            ) else { return nil }
            await ownership.record(ownedResult)
            let fileID = candidate.identity.fileID
            results[fileID] = ownedResult.result
            ticketsByFileID[fileID] = ticket(from: ownedResult.result)
        }

        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            var hasPending = false
            var retryAfter: [Int] = []
            for candidate in candidates {
                let fileID = candidate.identity.fileID
                guard let current = results[fileID] else { continue }
                switch current {
                case let .pending(ticket):
                    let refreshed = await store.codemapArtifactDemandStatus(ticket)
                    results[fileID] = refreshed
                    if case .pending = refreshed { hasPending = true }
                    if case let .unavailable(.busy(milliseconds)) = refreshed {
                        hasPending = true
                        if let milliseconds { retryAfter.append(milliseconds) }
                    }
                case let .unavailable(.busy(milliseconds)):
                    hasPending = true
                    if let milliseconds { retryAfter.append(milliseconds) }
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(
                round: round,
                suggestedMilliseconds: retryAfter,
                clock: clock,
                deadline: deadline
            )
            for candidate in candidates {
                let fileID = candidate.identity.fileID
                guard case .unavailable(.busy) = results[fileID] else { continue }
                let ownedResult: WorkspaceCodemapArtifactDemandOwnedResult
                if let existingTicket = ticketsByFileID[fileID],
                   await ownership.owns(existingTicket)
                {
                    guard let retried = await store.retryBusyAutomaticCodemapArtifactDemand(
                        existingTicket,
                        candidate: candidate,
                        rootScope: rootScope,
                        rootScopeEpochs: plan.rootScopeEpochs,
                        coverageProofs: plan.coverageProofs
                    ) else { return nil }
                    await ownership.replaceConsumed(existingTicket, with: retried.result)
                    ownedResult = retried
                } else {
                    guard let requested = await store.requestAutomaticCodemapArtifactWithOwnership(
                        candidate: candidate,
                        rootScope: rootScope,
                        rootScopeEpochs: plan.rootScopeEpochs,
                        coverageProofs: plan.coverageProofs
                    ) else { return nil }
                    await ownership.record(requested)
                    ownedResult = requested
                }
                results[fileID] = ownedResult.result
                ticketsByFileID[fileID] = ticket(from: ownedResult.result)
            }
        }
        let stillWaiting = results.values.contains { result in
            switch result {
            case .pending, .unavailable(.busy): true
            case .ready, .unavailable: false
            }
        }
        let deadlineReached = clock.now >= deadline
        return DemandBatch(
            resultsByFileID: results,
            deadlineReached: deadlineReached,
            defensiveRoundLimitReached: stillWaiting && !deadlineReached
        )
    }

    private func automaticSelectionAppendingSourcePartialReasons(
        _ reasons: [WorkspaceCodemapAutomaticSelectionPartialReason],
        to result: WorkspaceCodemapAutomaticSelectionResult
    ) -> WorkspaceCodemapAutomaticSelectionResult {
        let reasonsByRoot = Dictionary(grouping: reasons) { reason in
            switch reason {
            case let .source(issue):
                switch issue {
                case let .outsideRootScope(source), let .notCataloged(source),
                     let .notDemanded(source), let .pending(source, _),
                     let .unavailable(source, _), let .staleCatalogGeneration(source, _):
                    source.rootEpoch
                }
            case let .sourceDemandTimedOut(source):
                source.rootEpoch
            case let .candidateUnavailable(rootEpoch, _, _):
                rootEpoch
            case .graph:
                preconditionFailure("Graph partial reasons are produced by the store query")
            }
        }
        let roots = result.roots.map { root -> WorkspaceCodemapAutomaticSelectionRootResult in
            let additional = reasonsByRoot[root.rootEpoch] ?? []
            guard !additional.isEmpty else { return root }
            let coverage: WorkspaceCodemapAutomaticSelectionCoverage = switch root.coverage {
            case let .complete(proof):
                .partial(proof: proof, reasons: additional)
            case let .partial(proof, existing):
                .partial(proof: proof, reasons: existing + additional)
            case let .provisional(incomplete, pending, existing):
                .provisional(incomplete: incomplete, pending: pending, partial: existing + additional)
            case .incomplete, .pending, .unavailable, .stale, .busy, .budget:
                root.coverage
            }
            return WorkspaceCodemapAutomaticSelectionRootResult(
                rootEpoch: root.rootEpoch,
                targets: root.targets,
                sourceIssues: root.sourceIssues,
                targetIssues: root.targetIssues,
                coverage: coverage,
                graphTargetCount: root.graphTargetCount,
                graphResolutionCount: root.graphResolutionCount,
                graphReferenceFailureCount: root.graphReferenceFailureCount,
                graphByteCount: root.graphByteCount,
                graphKey: root.graphKey
            )
        }
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: roots,
            publicationReceipt: result.publicationReceipt
        )
    }

    private func demand(
        fileIDs: [UUID],
        priority: CodeMapArtifactBuildPriority,
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> DemandBatch {
        var orderedFileIDs: [UUID] = []
        var seen = Set<UUID>()
        for fileID in fileIDs where seen.insert(fileID).inserted {
            orderedFileIDs.append(fileID)
        }
        var results: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var ticketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        for fileID in orderedFileIDs {
            try Task.checkCancellation()
            let ownedResult = await store.requestCodemapArtifactWithOwnership(
                forFileID: fileID,
                priority: priority
            )
            await ownership.record(ownedResult)
            results[fileID] = ownedResult.result
            ticketsByFileID[fileID] = ticket(from: ownedResult.result)
        }

        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            var hasPending = false
            var retryAfter: [Int] = []
            for fileID in orderedFileIDs {
                guard let current = results[fileID] else { continue }
                switch current {
                case let .pending(ticket):
                    let refreshed = await store.codemapArtifactDemandStatus(ticket)
                    results[fileID] = refreshed
                    if case .pending = refreshed { hasPending = true }
                    if case let .unavailable(.busy(milliseconds)) = refreshed {
                        hasPending = true
                        if let milliseconds { retryAfter.append(milliseconds) }
                    }
                case let .unavailable(.busy(milliseconds)):
                    hasPending = true
                    if let milliseconds { retryAfter.append(milliseconds) }
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            try await wait(
                round: round,
                suggestedMilliseconds: retryAfter,
                clock: clock,
                deadline: deadline
            )
            for fileID in orderedFileIDs {
                guard case .unavailable(.busy) = results[fileID] else { continue }
                if let existingTicket = ticketsByFileID[fileID],
                   await ownership.owns(existingTicket)
                {
                    let retried = await store.retryBusyCodemapArtifactDemand(
                        existingTicket,
                        priority: priority
                    )
                    let oldStatus = await store.codemapArtifactDemandStatus(existingTicket)
                    if case .unavailable(.staleCurrentness) = oldStatus {
                        await ownership.replaceConsumed(existingTicket, with: retried)
                        ticketsByFileID[fileID] = ticket(from: retried)
                    }
                    results[fileID] = retried
                } else {
                    let ownedResult = await store.requestCodemapArtifactWithOwnership(
                        forFileID: fileID,
                        priority: priority
                    )
                    await ownership.record(ownedResult)
                    results[fileID] = ownedResult.result
                    ticketsByFileID[fileID] = ticket(from: ownedResult.result)
                }
            }
        }
        let stillWaiting = results.values.contains { result in
            switch result {
            case .pending, .unavailable(.busy): true
            case .ready, .unavailable: false
            }
        }
        let deadlineReached = clock.now >= deadline
        return DemandBatch(
            resultsByFileID: results,
            deadlineReached: deadlineReached,
            defensiveRoundLimitReached: stillWaiting && !deadlineReached
        )
    }

    private func ticket(
        from result: WorkspaceCodemapArtifactDemandResult
    ) -> WorkspaceCodemapArtifactDemandTicket? {
        switch result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
    }

    private func publicationTickets(
        from bundles: [WorkspaceCodemapOperationPresentationBundleReceipt],
        publishedFileIDs: Set<UUID>
    ) -> [WorkspaceCodemapArtifactDemandTicket] {
        var seenRetainIDs = Set<UUID>()
        return bundles
            .flatMap(\.entries)
            .filter { publishedFileIDs.contains($0.ticket.fileID) }
            .sorted { lhs, rhs in
                if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
                    return lhs.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                        rhs.logicalPath.displayPath.utf8
                    )
                }
                if lhs.ticket.fileID != rhs.ticket.fileID {
                    return lhs.ticket.fileID.uuidString < rhs.ticket.fileID.uuidString
                }
                return lhs.ticket.retainID.uuidString < rhs.ticket.retainID.uuidString
            }
            .compactMap { entry in
                seenRetainIDs.insert(entry.ticket.retainID).inserted ? entry.ticket : nil
            }
    }

    private func projectionDeadlineUptimeNanoseconds(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) -> UInt64 {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return DispatchTime.now().uptimeNanoseconds }
        let components = remaining.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }
        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        let (secondNanoseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (combinedNanoseconds, combinedOverflow) = secondNanoseconds.addingReportingOverflow(
            attoseconds / 1_000_000_000
        )
        let remainingNanoseconds = secondsOverflow || combinedOverflow
            ? UInt64.max
            : combinedNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        let (value, overflow) = now.addingReportingOverflow(remainingNanoseconds)
        return overflow ? UInt64.max : value
    }

    private func awaitProjectionDemand(
        _ ticket: WorkspaceCodemapProjectionDemandTicket,
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> ProjectionDemandWaitOutcome {
        await ownership.record(ticket)
        for round in 0 ..< policy.maximumReadinessRounds {
            try Task.checkCancellation()
            let status = await store.codemapProjectionDemandStatus(ticket)
            switch status {
            case let .ready(proof):
                return .ready(proof)
            case .stale:
                return .stale
            case .cancelled:
                return .cancelled
            case .expired:
                return .timeout(retryAfterMilliseconds: 100)
            case let .unavailable(reason, retryAfterMilliseconds):
                return .unavailable(
                    reason,
                    retryAfterMilliseconds: retryAfterMilliseconds.flatMap { Int(exactly: $0) }
                )
            case let .waitingForSetup(retry),
                 let .queued(_, retry),
                 let .joined(_, retry),
                 let .waitingForBatchBoundary(_, retry),
                 let .activeBatch(_, retry),
                 let .suspendedBusy(_, retry):
                let boundedRetry = min(1000, max(25, Int(exactly: retry) ?? 1000))
                if clock.now >= deadline {
                    return .timeout(retryAfterMilliseconds: boundedRetry)
                }
                guard round + 1 < policy.maximumReadinessRounds else {
                    return .busy(retryAfterMilliseconds: boundedRetry)
                }
                try await wait(
                    round: round,
                    suggestedMilliseconds: [boundedRetry],
                    clock: clock,
                    deadline: deadline
                )
            }
        }
        return .busy(retryAfterMilliseconds: 100)
    }

    private func readinessTimeoutIssue(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        retryAfterMilliseconds: Int
    ) -> WorkspaceCodemapStructureIssue {
        let limit = durationMilliseconds(policy.maximumTotalWait)
        let remaining = max(0, durationMilliseconds(clock.now.duration(to: deadline)))
        return .readinessTimeout(
            elapsedMilliseconds: max(0, limit - remaining),
            limitMilliseconds: limit,
            retryAfterMilliseconds: min(1000, max(25, retryAfterMilliseconds))
        )
    }

    private func durationMilliseconds(_ duration: Duration) -> Int {
        guard duration > .zero else { return 0 }
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = Int(exactly: components.seconds) ?? Int.max
        let attosecondMilliseconds = Int(exactly: components.attoseconds / 1_000_000_000_000_000)
            ?? Int.max
        let (secondMilliseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1000)
        guard !secondsOverflow else { return Int.max }
        let (milliseconds, overflow) = secondMilliseconds.addingReportingOverflow(attosecondMilliseconds)
        return overflow ? Int.max : milliseconds
    }

    private func wait(
        round: Int,
        suggestedMilliseconds: [Int],
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        let exponential = policy.initialBackoffMilliseconds << min(round, 3)
        let suggested = suggestedMilliseconds.max() ?? exponential
        let milliseconds = min(
            policy.maximumBackoffMilliseconds,
            max(policy.initialBackoffMilliseconds, suggested)
        )
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        try await waiter.sleep(min(.milliseconds(milliseconds), remaining))
        try Task.checkCancellation()
    }

    private func drainAutomaticSelectionGraphPublications(
        rootEpochs: Set<WorkspaceCodemapRootEpoch>,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        guard !rootEpochs.isEmpty else { return true }
        for rootEpoch in rootEpochs.sorted(by: workspaceCodemapRootEpochPrecedes) {
            try Task.checkCancellation()
            guard clock.now < deadline else { return false }
            let publicationCurrent = await store.waitForCodemapGraphPublication(
                rootEpoch: rootEpoch,
                deadline: deadline
            )
            try Task.checkCancellation()
            guard publicationCurrent, clock.now < deadline else { return false }
        }
        try Task.checkCancellation()
        return clock.now < deadline
    }

    private func release(_ ownership: WorkspaceCodemapOperationPresentationOwnership) async {
        let resources = await ownership.drain()
        for ticket in resources.projectionTickets {
            _ = await store.releaseCodemapProjectionDemand(ticket)
        }
        for bundle in resources.bundles {
            _ = await store.releaseCodemapPresentation(bundle)
        }
        for ticket in resources.tickets {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
    }

    private func coverage(
        for renderedEntries: [WorkspaceCodemapOperationRenderedEntry],
        issues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentationCoverage {
        guard !issues.isEmpty else { return .complete }
        if !renderedEntries.isEmpty { return .partial(issues) }
        if issues.contains(where: { issue in
            if case .pending = issue { return true }
            if case let .automatic(coverage) = issue {
                switch coverage {
                case .pending, .provisional:
                    return true
                case .complete, .partial, .incomplete, .unavailable, .stale, .busy, .budget:
                    return false
                }
            }
            return false
        }) {
            return .pending(issues)
        }
        return .unavailable(issues)
    }

    private func incompletePublication(
        reason: WorkspaceCodemapOperationPublicationStaleReason
    ) -> WorkspaceCodemapOperationPresentation {
        let issue = WorkspaceCodemapOperationIssue.publicationStale(reason)
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .unavailable([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
    }

    private func retryableStaleReason(
        in issues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPublicationStaleReason? {
        for issue in issues {
            switch issue {
            case let .unavailable(fileID, .staleCurrentness):
                return .catalog(fileID: fileID)
            case let .freezeUnavailable(rootEpoch, reason):
                switch reason {
                case .staleCurrentness, .handleRevoked, .logicalPathMismatch:
                    return .rootEpoch(rootEpoch)
                case .emptyRequest, .entryLimitExceeded, .retainedBundleLimitExceeded,
                     .duplicateFileID, .mixedRootEpoch, .pending, .demandUnavailable:
                    break
                }
            case let .renderUnavailable(rootEpoch, reason):
                switch reason {
                case .bundleNotRetained, .bundleMetadataMismatch, .staleCurrentness, .handleRevoked:
                    return .rootEpoch(rootEpoch)
                case .noRenderableCodemap:
                    break
                }
            case let .automatic(.stale(reason)):
                return .automatic(reason)
            case let .publicationStale(reason):
                return reason
            case .coordinationUnavailable, .cancelled, .candidate, .pending, .unavailable, .automatic:
                break
            }
        }
        return nil
    }

    private func renderedEntryPrecedes(
        _ lhs: WorkspaceCodemapOperationRenderedEntry,
        _ rhs: WorkspaceCodemapOperationRenderedEntry
    ) -> Bool {
        if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
            return lhs.logicalPath.displayPath < rhs.logicalPath.displayPath
        }
        return lhs.fileID.uuidString < rhs.fileID.uuidString
    }

    private func debugReflectionIssueSortKey(_ value: some Any) -> String {
        // Broad presentation/structure diagnostics still use a debug fallback; automatic-selection
        // pending/partial reasons use explicit typed comparators in WorkspaceCodemapAutomaticSelectionModels.
        String(reflecting: value)
    }
}

private struct WorkspaceCodemapStructureAttempt {
    let presentation: WorkspaceCodemapStructurePresentation
    let receipt: WorkspaceCodemapStructurePublicationReceipt?
    let staleReason: WorkspaceCodemapStructurePublicationStaleReason?
}

extension WorkspaceCodemapPresentationCoordinator {
    func structurePresentation(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        traversalLimits: WorkspaceCodemapStructureTraversalLimits,
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapStructurePresentation {
        if direction == nil,
           let published = await store.publishedCodemapStructurePresentation(
               seedFileIDs: seedFileIDs,
               outputLimits: outputLimits,
               rootScope: rootScope,
               logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
           )
        {
            try Task.checkCancellation()
            return published
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        var lastStaleReason: WorkspaceCodemapStructurePublicationStaleReason?

        for attemptIndex in 0 ..< policy.maximumStructurePublicationAttempts {
            try Task.checkCancellation()
            structureAttemptDidBegin(attemptIndex)
            let ownership = WorkspaceCodemapOperationPresentationOwnership()
            do {
                let attempt = try await makeStructureAttempt(
                    seedFileIDs: seedFileIDs,
                    direction: direction,
                    traversalLimits: traversalLimits,
                    outputLimits: outputLimits,
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                if let staleReason = attempt.staleReason {
                    lastStaleReason = staleReason
                    await release(ownership)
                    if attemptIndex + 1 < policy.maximumStructurePublicationAttempts,
                       clock.now < deadline
                    {
                        continue
                    }
                    return .stale(staleReason, requestedSeedCount: seedFileIDs.count)
                }
                guard let receipt = attempt.receipt else {
                    await release(ownership)
                    if attemptIndex > 0, let lastStaleReason {
                        return .stale(lastStaleReason, requestedSeedCount: seedFileIDs.count)
                    }
                    return attempt.presentation
                }
                await beforePublicationRevalidation(receipt.presentation)
                switch await store.revalidateCodemapStructureForPublication(
                    receipt,
                    rootScope: rootScope
                ) {
                case .current:
                    await release(ownership)
                    return attempt.presentation
                case let .stale(reason):
                    lastStaleReason = reason
                    await release(ownership)
                    if attemptIndex + 1 < policy.maximumStructurePublicationAttempts,
                       clock.now < deadline
                    {
                        continue
                    }
                    return .stale(reason, requestedSeedCount: seedFileIDs.count)
                }
            } catch {
                await release(ownership)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        }
        return .stale(lastStaleReason ?? .output, requestedSeedCount: seedFileIDs.count)
    }

    private func makeStructureAttempt(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        traversalLimits: WorkspaceCodemapStructureTraversalLimits,
        outputLimits: WorkspaceCodemapStructureOutputLimits,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String],
        ownership: WorkspaceCodemapOperationPresentationOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapStructureAttempt {
        let seedDemandLimit = min(
            policy.maximumCandidateDemandCount,
            outputLimits.maximumFileCount
        )
        let seedAdmission = await store.codemapStructureSeedAdmission(
            forFileIDs: seedFileIDs,
            rootScope: rootScope,
            maximumUniqueFileCount: seedDemandLimit
        )
        var issues = seedAdmission.issues.map(WorkspaceCodemapStructureIssue.candidate)
        guard !seedAdmission.didExceedLimit else {
            issues.append(.seedDemandLimit(
                attempted: seedAdmission.fileIDs.count,
                limit: seedDemandLimit
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }

        let seedCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: seedAdmission.fileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        issues.append(contentsOf: seedCollection.issues.map(WorkspaceCodemapStructureIssue.candidate))
        let seedCountsByRoot = Dictionary(
            grouping: seedCollection.candidates,
            by: \.rootEpoch
        ).mapValues(\.count)
        if let overRootLimit = seedCountsByRoot.values.max(),
           overRootLimit > policy.maximumStructureSeedCountPerRoot
        {
            issues.append(.seedDemandLimit(
                attempted: overRootLimit,
                limit: policy.maximumStructureSeedCountPerRoot
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        guard seedCollection.candidates.count <= seedDemandLimit else {
            issues.append(.seedDemandLimit(
                attempted: seedCollection.candidates.count,
                limit: seedDemandLimit
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        if let firstCandidate = seedCollection.candidates.first,
           outputLimits.maximumCodemapTokenCount == 0
        {
            issues.append(.tokenLimit(
                path: firstCandidate.logicalPath.displayPath,
                attempted: 1,
                limit: 0
            ))
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .budget,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        let seedDemand = try await demand(
            fileIDs: seedCollection.candidates.map(\.fileID),
            priority: .demand,
            ownership: ownership,
            clock: clock,
            deadline: deadline
        )
        var readyTicketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        var graphSeeds: [WorkspaceCodemapStoreSelectionGraphSourceIdentity] = []
        for candidate in seedCollection.candidates {
            guard let result = seedDemand.resultsByFileID[candidate.fileID] else {
                issues.append(.artifactUnavailable(
                    fileID: candidate.fileID,
                    reason: .registrationFailed
                ))
                continue
            }
            switch result {
            case let .ready(ready):
                readyTicketsByFileID[candidate.fileID] = ready.ticket
                graphSeeds.append(.init(ticket: ready.ticket))
            case let .pending(ticket):
                issues.append(.artifactPending(fileID: candidate.fileID, ticket: ticket))
            case .unavailable(.cancelled):
                throw CancellationError()
            case .unavailable(.staleCurrentness):
                let ticket = await ownership.tickets().first {
                    $0.fileID == candidate.fileID
                }
                let reason: WorkspaceCodemapStructurePublicationStaleReason = if let ticket {
                    .presentation(.demand(ticket))
                } else {
                    .presentation(.catalog(fileID: candidate.fileID))
                }
                return WorkspaceCodemapStructureAttempt(
                    presentation: emptyStructurePresentation(
                        outcome: .stale,
                        issues: [],
                        requestedSeedCount: seedFileIDs.count,
                        resolvedSeedCount: graphSeeds.count
                    ),
                    receipt: nil,
                    staleReason: reason
                )
            case let .unavailable(reason):
                issues.append(.artifactUnavailable(fileID: candidate.fileID, reason: reason))
            }
        }

        let seedHasPending = seedDemand.resultsByFileID.values.contains { result in
            if case .pending = result { return true }
            return false
        }
        let seedBusyDelays = seedDemand.resultsByFileID.values.compactMap { result -> Int? in
            guard case let .unavailable(.busy(retryAfterMilliseconds)) = result else { return nil }
            return retryAfterMilliseconds
        }
        if seedHasPending {
            let retryAfter = min(1000, max(25, seedBusyDelays.max() ?? 100))
            let outcome: WorkspaceCodemapStructureOutcome
            if seedDemand.deadlineReached {
                outcome = .timeout
                issues.append(readinessTimeoutIssue(
                    clock: clock,
                    deadline: deadline,
                    retryAfterMilliseconds: retryAfter
                ))
            } else {
                outcome = .busy
                issues.append(.busy(retryAfterMilliseconds: retryAfter))
            }
            return WorkspaceCodemapStructureAttempt(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: outcome,
                    entries: [],
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        if !seedBusyDelays.isEmpty || seedDemand.defensiveRoundLimitReached {
            issues.append(.busy(retryAfterMilliseconds: min(1000, max(25, seedBusyDelays.max() ?? 100))))
            return WorkspaceCodemapStructureAttempt(
                presentation: emptyStructurePresentation(
                    outcome: .busy,
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: graphSeeds.count
                ),
                receipt: nil,
                staleReason: nil
            )
        }
        guard graphSeeds.count == seedCollection.candidates.count else {
            return WorkspaceCodemapStructureAttempt(
                presentation: emptyStructurePresentation(
                    outcome: .unavailable,
                    issues: issues,
                    requestedSeedCount: seedFileIDs.count,
                    resolvedSeedCount: graphSeeds.count
                ),
                receipt: nil,
                staleReason: nil
            )
        }

        if direction != nil {
            let sourceTicketsByRoot = Dictionary(grouping: graphSeeds.map(\.ticket), by: \.rootEpoch)
            let deadlineUptimeNanoseconds = projectionDeadlineUptimeNanoseconds(
                clock: clock,
                deadline: deadline
            )
            var acquiredProjectionDemands: [(
                ticket: WorkspaceCodemapProjectionDemandTicket,
                sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
            )] = []
            var projectionOutcomes: [(
                outcome: ProjectionDemandWaitOutcome,
                sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
            )] = []
            for rootEpoch in sourceTicketsByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes) {
                let sourceTickets = sourceTicketsByRoot[rootEpoch] ?? []
                let acquisition = await store.acquireCodemapProjectionDemand(
                    sourceTickets: sourceTickets,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                switch acquisition {
                case let .acquired(ticket, _):
                    await ownership.record(ticket)
                    acquiredProjectionDemands.append((ticket, sourceTickets))
                case let .busy(_, retryAfterMilliseconds):
                    projectionOutcomes.append((.busy(
                        retryAfterMilliseconds: min(
                            1000,
                            max(25, Int(exactly: retryAfterMilliseconds) ?? 1000)
                        )
                    ), sourceTickets))
                case let .unavailable(reason, retryAfterMilliseconds):
                    projectionOutcomes.append((.unavailable(
                        reason,
                        retryAfterMilliseconds: retryAfterMilliseconds.flatMap { Int(exactly: $0) }
                    ), sourceTickets))
                }
            }
            for acquired in acquiredProjectionDemands {
                let outcome = try await awaitProjectionDemand(
                    acquired.ticket,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                projectionOutcomes.append((outcome, acquired.sourceTickets))
            }

            for (waitOutcome, sourceTickets) in projectionOutcomes {
                switch waitOutcome {
                case .ready:
                    continue
                case let .busy(retryAfterMilliseconds):
                    issues.append(.busy(retryAfterMilliseconds: retryAfterMilliseconds))
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .busy,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                case let .timeout(retryAfterMilliseconds):
                    issues.append(readinessTimeoutIssue(
                        clock: clock,
                        deadline: deadline,
                        retryAfterMilliseconds: retryAfterMilliseconds
                    ))
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .timeout,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                case let .unavailable(.projectionBudget(budget), _):
                    issues.append(.projectionBudget(budget))
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .budget,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                case let .unavailable(reason, retryAfterMilliseconds):
                    issues.append(.projectionUnavailable(
                        reason: reason,
                        retryAfterMilliseconds: retryAfterMilliseconds
                    ))
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .unavailable,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                case .stale:
                    let staleReason = sourceTickets.first.map {
                        WorkspaceCodemapStructurePublicationStaleReason.presentation(.demand($0))
                    } ?? .output
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .stale,
                            issues: [],
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: staleReason
                    )
                case .cancelled:
                    throw CancellationError()
                }
            }
        }

        var provenanceByFileID: [UUID: (depth: Int, reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>)] =
            Dictionary(uniqueKeysWithValues: graphSeeds.map { ($0.ticket.fileID, (0, [])) })
        var traversalReceipt: WorkspaceCodemapStructureTraversalPublicationReceipt?
        var examinedEdgeCount = 0
        var traversalBudgetHit = false

        if let direction {
            var disposition = await store.queryCodemapStructureGraph(
                WorkspaceCodemapStructureTraversalQuery(
                    seeds: graphSeeds,
                    direction: direction,
                    limits: traversalLimits
                )
            )
            for round in 0 ..< policy.maximumReadinessRounds {
                let awaitsExactReadiness = switch disposition {
                case .pending, .unavailable(.graphNotBuilt), .unavailable(.definitionUniverse): true
                case .readyPartial, .unavailable, .stale, .budget, .cancelled: false
                }
                guard awaitsExactReadiness,
                      round + 1 < policy.maximumReadinessRounds,
                      clock.now < deadline else { break }
                try await wait(round: round, suggestedMilliseconds: [], clock: clock, deadline: deadline)
                disposition = await store.queryCodemapStructureGraph(
                    WorkspaceCodemapStructureTraversalQuery(
                        seeds: graphSeeds,
                        direction: direction,
                        limits: traversalLimits
                    )
                )
            }

            var traversalResult: WorkspaceCodemapStructureTraversalResult?
            switch disposition {
            case let .readyPartial(result):
                traversalResult = result
            case let .budget(result, reason):
                traversalResult = result
                traversalBudgetHit = true
                issues.append(.traversalBudget(reason))
            case let .pending(reason):
                issues.append(.traversalPending(reason))
                let deadlineReached = clock.now >= deadline
                issues.append(
                    deadlineReached
                        ? readinessTimeoutIssue(clock: clock, deadline: deadline, retryAfterMilliseconds: 100)
                        : .busy(retryAfterMilliseconds: 100)
                )
                return WorkspaceCodemapStructureAttempt(
                    presentation: emptyStructurePresentation(
                        outcome: deadlineReached ? .timeout : .busy,
                        issues: issues,
                        requestedSeedCount: seedFileIDs.count,
                        resolvedSeedCount: graphSeeds.count
                    ),
                    receipt: nil,
                    staleReason: nil
                )
            case let .unavailable(reason):
                issues.append(.traversalUnavailable(reason))
                let readinessUnavailable = switch reason {
                case .graphNotBuilt, .definitionUniverse: true
                case .emptySeeds, .foreignRootEpoch, .duplicateSeedConflict, .seedNotReady,
                     .invalidGraphResult, .runtime: false
                }
                if readinessUnavailable {
                    let deadlineReached = clock.now >= deadline
                    issues.append(
                        deadlineReached
                            ? readinessTimeoutIssue(clock: clock, deadline: deadline, retryAfterMilliseconds: 100)
                            : .busy(retryAfterMilliseconds: 100)
                    )
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: deadlineReached ? .timeout : .busy,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                }
            case let .stale(reason):
                return WorkspaceCodemapStructureAttempt(
                    presentation: emptyStructurePresentation(
                        outcome: .stale,
                        issues: [.traversalStale(reason)],
                        requestedSeedCount: seedFileIDs.count,
                        resolvedSeedCount: graphSeeds.count
                    ),
                    receipt: nil,
                    staleReason: .traversal(reason)
                )
            case .cancelled:
                throw CancellationError()
            }

            if let traversalResult {
                traversalReceipt = traversalResult.publicationReceipt
                examinedEdgeCount = traversalResult.examinedEdgeCount
                issues.append(
                    contentsOf: traversalResult.partialReasons
                        .sorted { debugReflectionIssueSortKey($0) < debugReflectionIssueSortKey($1) }
                        .map(WorkspaceCodemapStructureIssue.traversalPartial)
                )
                guard traversalResult.partialReasons.isEmpty else {
                    return WorkspaceCodemapStructureAttempt(
                        presentation: emptyStructurePresentation(
                            outcome: .unavailable,
                            issues: issues,
                            requestedSeedCount: seedFileIDs.count,
                            resolvedSeedCount: graphSeeds.count
                        ),
                        receipt: nil,
                        staleReason: nil
                    )
                }
                provenanceByFileID = Dictionary(uniqueKeysWithValues: traversalResult.nodes.map {
                    ($0.fileID, ($0.depth, $0.reachedBy))
                })

                let targetIDs = traversalResult.nodes.filter { $0.depth > 0 }.map(\.fileID)
                if !targetIDs.isEmpty {
                    let targetDemand = try await demand(
                        fileIDs: targetIDs,
                        priority: .explicit,
                        ownership: ownership,
                        clock: clock,
                        deadline: deadline
                    )
                    for fileID in targetIDs {
                        guard let result = targetDemand.resultsByFileID[fileID] else { continue }
                        switch result {
                        case let .ready(ready):
                            readyTicketsByFileID[fileID] = ready.ticket
                        case let .pending(ticket):
                            issues.append(.artifactPending(fileID: fileID, ticket: ticket))
                        case .unavailable(.cancelled):
                            throw CancellationError()
                        case .unavailable(.staleCurrentness):
                            let ticket = await ownership.tickets().first { $0.fileID == fileID }
                            let reason: WorkspaceCodemapStructurePublicationStaleReason = if let ticket {
                                .presentation(.demand(ticket))
                            } else {
                                .presentation(.catalog(fileID: fileID))
                            }
                            return WorkspaceCodemapStructureAttempt(
                                presentation: emptyStructurePresentation(
                                    outcome: .stale,
                                    issues: [],
                                    requestedSeedCount: seedFileIDs.count,
                                    resolvedSeedCount: graphSeeds.count
                                ),
                                receipt: nil,
                                staleReason: reason
                            )
                        case let .unavailable(reason):
                            issues.append(.artifactUnavailable(fileID: fileID, reason: reason))
                        }
                    }

                    let targetHasPending = targetDemand.resultsByFileID.values.contains { result in
                        if case .pending = result { return true }
                        return false
                    }
                    let targetBusyDelays = targetDemand.resultsByFileID.values.compactMap { result -> Int? in
                        guard case let .unavailable(.busy(retryAfterMilliseconds)) = result else { return nil }
                        return retryAfterMilliseconds
                    }
                    if targetHasPending {
                        let retryAfter = min(1000, max(25, targetBusyDelays.max() ?? 100))
                        let deadlineReached = targetDemand.deadlineReached
                        issues.append(
                            deadlineReached
                                ? readinessTimeoutIssue(
                                    clock: clock,
                                    deadline: deadline,
                                    retryAfterMilliseconds: retryAfter
                                )
                                : .busy(retryAfterMilliseconds: retryAfter)
                        )
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: deadlineReached ? .timeout : .busy,
                                issues: issues,
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: nil
                        )
                    }
                    if !targetBusyDelays.isEmpty || targetDemand.defensiveRoundLimitReached {
                        issues.append(.busy(
                            retryAfterMilliseconds: min(
                                1000,
                                max(25, targetBusyDelays.max() ?? 100)
                            )
                        ))
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: .busy,
                                issues: issues,
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: nil
                        )
                    }
                    guard targetIDs.allSatisfy({ readyTicketsByFileID[$0] != nil }) else {
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: .unavailable,
                                issues: issues,
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: nil
                        )
                    }

                    var revalidated = await store.queryCodemapStructureGraph(
                        WorkspaceCodemapStructureTraversalQuery(
                            seeds: graphSeeds,
                            direction: direction,
                            limits: traversalLimits
                        )
                    )
                    for round in 0 ..< policy.maximumReadinessRounds {
                        let awaitsExactReadiness = switch revalidated {
                        case .pending, .unavailable(.graphNotBuilt), .unavailable(.definitionUniverse): true
                        case .readyPartial, .unavailable, .stale, .budget, .cancelled: false
                        }
                        guard awaitsExactReadiness,
                              round + 1 < policy.maximumReadinessRounds,
                              clock.now < deadline else { break }
                        try await wait(
                            round: round,
                            suggestedMilliseconds: [],
                            clock: clock,
                            deadline: deadline
                        )
                        revalidated = await store.queryCodemapStructureGraph(
                            WorkspaceCodemapStructureTraversalQuery(
                                seeds: graphSeeds,
                                direction: direction,
                                limits: traversalLimits
                            )
                        )
                    }
                    switch revalidated {
                    case let .readyPartial(result):
                        if !result.partialReasons.isEmpty {
                            issues.append(
                                contentsOf: result.partialReasons
                                    .sorted { debugReflectionIssueSortKey($0) < debugReflectionIssueSortKey($1) }
                                    .map(WorkspaceCodemapStructureIssue.traversalPartial)
                            )
                            return WorkspaceCodemapStructureAttempt(
                                presentation: emptyStructurePresentation(
                                    outcome: .unavailable,
                                    issues: issues,
                                    requestedSeedCount: seedFileIDs.count,
                                    resolvedSeedCount: graphSeeds.count
                                ),
                                receipt: nil,
                                staleReason: nil
                            )
                        }
                        traversalReceipt = result.publicationReceipt
                        examinedEdgeCount = result.examinedEdgeCount
                        provenanceByFileID = Dictionary(uniqueKeysWithValues: result.nodes.map {
                            ($0.fileID, ($0.depth, $0.reachedBy))
                        })
                    case let .budget(result?, reason):
                        traversalBudgetHit = true
                        issues.append(.traversalBudget(reason))
                        traversalReceipt = result.publicationReceipt
                        examinedEdgeCount = result.examinedEdgeCount
                        provenanceByFileID = Dictionary(uniqueKeysWithValues: result.nodes.map {
                            ($0.fileID, ($0.depth, $0.reachedBy))
                        })
                    case let .stale(reason):
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: .stale,
                                issues: [.traversalStale(reason)],
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: .traversal(reason)
                        )
                    case .cancelled:
                        throw CancellationError()
                    case let .pending(reason):
                        issues.append(.traversalPending(reason))
                        let deadlineReached = clock.now >= deadline
                        issues.append(
                            deadlineReached
                                ? readinessTimeoutIssue(
                                    clock: clock,
                                    deadline: deadline,
                                    retryAfterMilliseconds: 100
                                )
                                : .busy(retryAfterMilliseconds: 100)
                        )
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: deadlineReached ? .timeout : .busy,
                                issues: issues,
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: nil
                        )
                    case let .unavailable(reason):
                        issues.append(.traversalUnavailable(reason))
                        return WorkspaceCodemapStructureAttempt(
                            presentation: emptyStructurePresentation(
                                outcome: .unavailable,
                                issues: issues,
                                requestedSeedCount: seedFileIDs.count,
                                resolvedSeedCount: graphSeeds.count
                            ),
                            receipt: nil,
                            staleReason: nil
                        )
                    case let .budget(nil, reason):
                        traversalBudgetHit = true
                        issues.append(.traversalBudget(reason))
                    }
                }
            }
        }

        let seedSet = Set(graphSeeds.map(\.ticket.fileID))
        let candidateCollection = await store.codemapOperationPresentationCandidates(
            forFileIDs: Array(provenanceByFileID.keys),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        issues.append(contentsOf: candidateCollection.issues.map(WorkspaceCodemapStructureIssue.candidate))
        var orderedCandidates = candidateCollection.candidates.filter {
            readyTicketsByFileID[$0.fileID] != nil
        }
        orderedCandidates.sort { lhs, rhs in
            let lhsSeed = seedSet.contains(lhs.fileID)
            let rhsSeed = seedSet.contains(rhs.fileID)
            if lhsSeed != rhsSeed { return lhsSeed }
            let lhsDepth = provenanceByFileID[lhs.fileID]?.depth ?? .max
            let rhsDepth = provenanceByFileID[rhs.fileID]?.depth ?? .max
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
                return lhs.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                    rhs.logicalPath.displayPath.utf8
                )
            }
            return lhs.fileID.uuidString < rhs.fileID.uuidString
        }
        if orderedCandidates.count > outputLimits.maximumFileCount {
            issues.append(.fileLimit(
                attempted: orderedCandidates.count,
                limit: outputLimits.maximumFileCount
            ))
            orderedCandidates = Array(orderedCandidates.prefix(outputLimits.maximumFileCount))
        }

        var requestsByRoot: [WorkspaceCodemapRootEpoch: [WorkspaceCodemapPresentationRequest]] = [:]
        for candidate in orderedCandidates {
            guard let ticket = readyTicketsByFileID[candidate.fileID] else { continue }
            requestsByRoot[candidate.rootEpoch, default: []].append(
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: candidate.logicalPath)
            )
        }
        var renderedByFileID: [UUID: WorkspaceCodemapOperationRenderedEntry] = [:]
        var bundleReceipts: [WorkspaceCodemapOperationPresentationBundleReceipt] = []
        for rootEpoch in requestsByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes) {
            try Task.checkCancellation()
            switch await store.freezeCodemapPresentation(requestsByRoot[rootEpoch] ?? []) {
            case let .unavailable(reason):
                issues.append(.freezeUnavailable(rootEpoch: rootEpoch, reason: reason))
            case let .ready(bundle):
                await ownership.record(bundle)
                switch await store.renderCodemapPresentation(bundle) {
                case let .unavailable(reason):
                    issues.append(.renderUnavailable(rootEpoch: rootEpoch, reason: reason))
                case let .ready(rendered):
                    bundleReceipts.append(.init(
                        bundleID: bundle.id,
                        rootEpoch: bundle.rootEpoch,
                        entries: bundle.entries
                    ))
                    for entry in rendered {
                        renderedByFileID[entry.ticket.fileID] = WorkspaceCodemapOperationRenderedEntry(
                            bundleID: bundle.id,
                            fileID: entry.ticket.fileID,
                            rootEpoch: entry.ticket.rootEpoch,
                            artifactKey: entry.artifactKey,
                            logicalPath: entry.logicalPath,
                            text: entry.text,
                            tokenCount: entry.tokenCount
                        )
                    }
                }
            }
        }

        let separatorTokens = TokenCalculationService.estimateTokens(for: "\n\n")
        var structureEntries: [WorkspaceCodemapStructureRenderedEntry] = []
        var usedTokens = 0
        for candidate in orderedCandidates {
            guard let entry = renderedByFileID[candidate.fileID] else { continue }
            let cost = entry.tokenCount + (structureEntries.isEmpty ? 0 : separatorTokens)
            let (attempted, overflow) = usedTokens.addingReportingOverflow(cost)
            guard !overflow, attempted <= outputLimits.maximumCodemapTokenCount else {
                issues.append(.tokenLimit(
                    path: candidate.logicalPath.displayPath,
                    attempted: overflow ? .max : attempted,
                    limit: outputLimits.maximumCodemapTokenCount
                ))
                break
            }
            usedTokens = attempted
            let provenance = provenanceByFileID[candidate.fileID] ?? (0, [])
            structureEntries.append(.init(
                entry: entry,
                isSeed: seedSet.contains(candidate.fileID),
                depth: provenance.depth,
                reachedBy: provenance.reachedBy
            ))
        }

        let outputFileIDs = structureEntries.map(\.entry.fileID)
        let outputSet = Set(outputFileIDs)
        let receiptCandidates = orderedCandidates.filter { outputSet.contains($0.fileID) }
        let validatedLogicalRootDisplayNames = Dictionary(
            receiptCandidates.map { ($0.rootEpoch.rootID, $0.logicalPath.rootDisplayName) },
            uniquingKeysWith: { current, _ in current }
        )
        let publishedBundleReceipts = bundleReceipts.compactMap { bundle -> WorkspaceCodemapOperationPresentationBundleReceipt? in
            let publishedEntries = bundle.entries.filter { outputSet.contains($0.ticket.fileID) }
            guard !publishedEntries.isEmpty else { return nil }
            return WorkspaceCodemapOperationPresentationBundleReceipt(
                bundleID: bundle.bundleID,
                rootEpoch: bundle.rootEpoch,
                entries: publishedEntries
            )
        }
        let presentationReceipt = WorkspaceCodemapOperationPresentationPublicationReceipt(
            requestID: UUID(),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: validatedLogicalRootDisplayNames,
            completeRootSet: false,
            completeRootCatalogs: [],
            candidates: receiptCandidates,
            demandTickets: publicationTickets(
                from: publishedBundleReceipts,
                publishedFileIDs: outputSet
            ),
            bundles: publishedBundleReceipts,
            automaticReceipt: nil
        )
        let receipt = WorkspaceCodemapStructurePublicationReceipt(
            presentation: presentationReceipt,
            traversal: traversalReceipt,
            outputFileIDs: outputFileIDs
        )
        issues.sort { debugReflectionIssueSortKey($0) < debugReflectionIssueSortKey($1) }
        let budgetHit = traversalBudgetHit || issues.contains(where: {
            switch $0 {
            case .fileLimit, .seedDemandLimit, .tokenLimit, .traversalBudget: true
            default: false
            }
        })
        let outcome: WorkspaceCodemapStructureOutcome = if budgetHit {
            .budget
        } else if issues.isEmpty, structureEntries.count == orderedCandidates.count {
            .ready
        } else {
            .unavailable
        }
        let publishesEntries = outcome == .ready || outcome == .budget
        return WorkspaceCodemapStructureAttempt(
            presentation: WorkspaceCodemapStructurePresentation(
                outcome: outcome,
                entries: publishesEntries ? structureEntries : [],
                issues: issues,
                requestedSeedCount: seedFileIDs.count,
                resolvedSeedCount: graphSeeds.count,
                examinedEdgeCount: examinedEdgeCount,
                codemapTokenCount: publishesEntries ? usedTokens : 0
            ),
            receipt: publishesEntries ? receipt : nil,
            staleReason: nil
        )
    }

    private func emptyStructurePresentation(
        outcome: WorkspaceCodemapStructureOutcome,
        issues: [WorkspaceCodemapStructureIssue],
        requestedSeedCount: Int,
        resolvedSeedCount: Int
    ) -> WorkspaceCodemapStructurePresentation {
        WorkspaceCodemapStructurePresentation(
            outcome: outcome,
            entries: [],
            issues: issues,
            requestedSeedCount: requestedSeedCount,
            resolvedSeedCount: resolvedSeedCount,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )
    }
}
