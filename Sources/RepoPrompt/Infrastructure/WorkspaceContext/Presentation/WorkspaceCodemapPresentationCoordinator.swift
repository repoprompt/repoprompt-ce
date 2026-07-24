import Foundation

let workspaceCodemapProductionDemandWaitMilliseconds = 10000

struct WorkspaceCodemapPresentationRequestPolicy: Equatable {
    static let `default` = Self()

    let maximumReadinessRounds: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let maximumTotalWait: Duration
    let maximumCandidateDemandCount: Int

    init(
        maximumReadinessRounds: Int = 4096,
        initialBackoffMilliseconds: Int = 25,
        maximumBackoffMilliseconds: Int = 250,
        maximumTotalWait: Duration = .milliseconds(workspaceCodemapProductionDemandWaitMilliseconds),
        maximumCandidateDemandCount: Int = 1024
    ) {
        precondition(maximumReadinessRounds > 0)
        precondition(initialBackoffMilliseconds > 0)
        precondition(maximumBackoffMilliseconds >= initialBackoffMilliseconds)
        precondition(maximumTotalWait >= .zero)
        precondition(maximumCandidateDemandCount > 0)
        self.maximumReadinessRounds = maximumReadinessRounds
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.maximumTotalWait = maximumTotalWait
        self.maximumCandidateDemandCount = maximumCandidateDemandCount
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
        let bundles: [WorkspaceCodemapFrozenPresentationBundle]
    }

    private var ticketsByRetainID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
    private var bundlesByID: [
        WorkspaceCodemapFrozenPresentationBundleID: WorkspaceCodemapFrozenPresentationBundle
    ] = [:]
    private var bundleIDsInAcquisitionOrder: [WorkspaceCodemapFrozenPresentationBundleID] = []

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
            bundles: bundleIDsInAcquisitionOrder.compactMap { bundlesByID[$0] }
        )
        ticketsByRetainID.removeAll()
        bundlesByID.removeAll()
        bundleIDsInAcquisitionOrder.removeAll()
        return resources
    }
}

enum WorkspaceCodemapStructureExecutionPhase: Equatable {
    case seedResolution
    case graphSnapshot
    case graphTraversal
    case graphRevalidation
    case renderDemand
    case freeze
    case render
    case assembly
}

struct WorkspaceCodemapPresentationAttempt<Context> {
    let context: Context
    let intent: WorkspaceCodemapOperationPresentationIntent
    let rootScope: WorkspaceLookupRootScope
    let logicalRootDisplayNamesByRootID: [UUID: String]
    let requestedCodemapCount: Int?
}

struct WorkspaceCodemapPresentationCoordinator {
    private struct AutomaticPreparation {
        let candidates: [WorkspaceCodemapOperationPresentationCandidate]
        let issues: [WorkspaceCodemapOperationIssue]
        let coverage: WorkspaceCodemapOperationPresentationCoverage?
        let receipt: WorkspaceCodemapAutomaticSelectionReceipt?
    }

    private struct DemandBatch {
        let resultsByFileID: [UUID: WorkspaceCodemapArtifactDemandResult]
        let deadlineReached: Bool
        let defensiveRoundLimitReached: Bool
    }

    let store: WorkspaceFileContextStore
    let policy: WorkspaceCodemapPresentationRequestPolicy
    let waiter: WorkspaceCodemapPresentationWaiter
    let beforePublicationRevalidation: @Sendable (
        WorkspaceCodemapOperationPresentationPublicationReceipt
    ) async -> Void
    let afterAutomaticCandidateReconstruction: @Sendable (
        WorkspaceCodemapAutomaticSelectionReceipt
    ) async throws -> Void
    let structureAttemptDidBegin: @Sendable (Int) -> Void
    let structurePhaseDidChange: @Sendable (WorkspaceCodemapStructureExecutionPhase) async -> Void

    init(
        store: WorkspaceFileContextStore,
        policy: WorkspaceCodemapPresentationRequestPolicy = .default,
        waiter: WorkspaceCodemapPresentationWaiter = .production,
        beforePublicationRevalidation: @escaping @Sendable (
            WorkspaceCodemapOperationPresentationPublicationReceipt
        ) async -> Void = { _ in },
        afterAutomaticCandidateReconstruction: @escaping @Sendable (
            WorkspaceCodemapAutomaticSelectionReceipt
        ) async throws -> Void = { _ in },
        structureAttemptDidBegin: @escaping @Sendable (Int) -> Void = { _ in },
        structurePhaseDidChange: @escaping @Sendable (
            WorkspaceCodemapStructureExecutionPhase
        ) async -> Void = { _ in }
    ) {
        self.store = store
        self.policy = policy
        self.waiter = waiter
        self.beforePublicationRevalidation = beforePublicationRevalidation
        self.afterAutomaticCandidateReconstruction = afterAutomaticCandidateReconstruction
        self.structureAttemptDidBegin = structureAttemptDidBegin
        self.structurePhaseDidChange = structurePhaseDidChange
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

    func structureSignaturePresentation(
        fileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> WorkspaceCodemapOperationPresentation {
        try await presentation(
            for: .exact(fileIDs: fileIDs, completeRootSet: false),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
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
        return try await withPresentation(
            prepareAttempt: {
                WorkspaceCodemapPresentationAttempt(
                    context: (),
                    intent: intent,
                    rootScope: rootScope,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                    requestedCodemapCount: nil
                )
            }
        ) { _, presentation in
            try await operation(presentation)
        }
    }

    func withPresentation<Context, Value>(
        prepareAttempt: () async throws -> WorkspaceCodemapPresentationAttempt<Context>,
        operation: (Context, WorkspaceCodemapOperationPresentation) async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.maximumTotalWait)
        var lastStaleReason: WorkspaceCodemapOperationPublicationStaleReason?
        var initialRequestedCodemapCount: Int?
        var lastAttempt: WorkspaceCodemapPresentationAttempt<Context>?

        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            let prepared = try await prepareAttempt()
            lastAttempt = prepared
            if initialRequestedCodemapCount == nil {
                initialRequestedCodemapCount = prepared.requestedCodemapCount
            }
            let ownership = WorkspaceCodemapOperationPresentationOwnership()
            do {
                var result = try await makePresentation(
                    intent: prepared.intent,
                    rootScope: prepared.rootScope,
                    logicalRootDisplayNamesByRootID: prepared.logicalRootDisplayNamesByRootID,
                    ownership: ownership,
                    clock: clock,
                    deadline: deadline
                )
                if let reason = lastStaleReason,
                   let requestedCount = initialRequestedCodemapCount
                {
                    result = preservingPriorStaleCoverage(
                        result,
                        reason: reason,
                        requestedCodemapCount: requestedCount
                    )
                }
                if let reason = retryableStaleReason(in: result.issues) {
                    lastStaleReason = reason
                    if attempt == 0, clock.now < deadline {
                        await release(ownership)
                        continue
                    }
                    guard initialRequestedCodemapCount != nil,
                          !result.orderedEntries.isEmpty
                    else {
                        await release(ownership)
                        let value = try await operation(
                            prepared.context,
                            incompletePublication(reason: reason)
                        )
                        try Task.checkCancellation()
                        return value
                    }
                }
                if let reason = lastStaleReason,
                   result.publicationReceipt == nil,
                   result.orderedEntries.isEmpty
                {
                    await release(ownership)
                    let value = try await operation(
                        prepared.context,
                        incompletePublication(reason: reason)
                    )
                    try Task.checkCancellation()
                    return value
                }
                let value = try await operation(prepared.context, result)
                try Task.checkCancellation()
                if let receipt = result.publicationReceipt {
                    await beforePublicationRevalidation(receipt)
                    try Task.checkCancellation()
                    let disposition = await store.revalidateCodemapOperationPresentationForPublication(
                        receipt,
                        rootScope: prepared.rootScope
                    )
                    switch disposition {
                    case .current:
                        await release(ownership)
                        return value
                    case let .stale(reason):
                        lastStaleReason = reason
                        await release(ownership)
                        if attempt == 0, clock.now < deadline { continue }
                        let fallbackValue = try await operation(
                            prepared.context,
                            incompletePublication(reason: reason)
                        )
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
        let prepared: WorkspaceCodemapPresentationAttempt<Context> = if let lastAttempt {
            lastAttempt
        } else {
            try await prepareAttempt()
        }
        let value = try await operation(
            prepared.context,
            incompletePublication(reason: lastStaleReason ?? .rootScope)
        )
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
        let automaticReceipt: WorkspaceCodemapAutomaticSelectionReceipt?

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

        await structurePhaseDidChange(.renderDemand)
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
            await structurePhaseDidChange(.freeze)
            switch await store.freezeCodemapPresentation(requests) {
            case let .unavailable(reason):
                issues.append(.freezeUnavailable(rootEpoch: rootEpoch, reason: reason))
            case let .ready(bundle):
                await ownership.record(bundle)
                await structurePhaseDidChange(.render)
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
        clock _: ContinuousClock,
        deadline _: ContinuousClock.Instant
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
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable([.emptySources])
            issues.append(.automatic(coverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }
        let sourceLimit = await store.automaticCodemapSelectionSourceLimit()
        guard identities.count <= sourceLimit else {
            let coverage = WorkspaceCodemapAutomaticSelectionAggregateCoverage.unavailable([
                .budget(.sourceLimit(attempted: identities.count, limit: sourceLimit))
            ])
            issues.append(.automatic(coverage))
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .unavailable(issues),
                receipt: nil
            )
        }

        let selection = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: rootScope
        )
        if case .ok = selection.aggregateCoverage {
            // No issue entry is needed for a complete graph result.
        } else {
            issues.append(.automatic(selection.aggregateCoverage))
        }
        guard let receipt = selection.receipt, !selection.targets.isEmpty else {
            let coverage: WorkspaceCodemapOperationPresentationCoverage = switch selection.status {
            case .ok, .partial, .pending: .pending(issues)
            case .unavailable: .unavailable(issues)
            }
            return AutomaticPreparation(candidates: [], issues: issues, coverage: coverage, receipt: nil)
        }

        let initialRevalidation = await store.revalidateAutomaticCodemapSelection(
            receipt,
            rootScope: rootScope
        )
        let validTargets = Set(initialRevalidation.validTargets)
        let rootReceipts = Dictionary(uniqueKeysWithValues: receipt.roots.map { ($0.rootEpoch, $0) })
        for target in selection.targets where validTargets.contains(target) {
            guard let rootReceipt = rootReceipts[target.rootEpoch],
                  let owned = await store.requestAutomaticCodemapTargetWithOwnership(
                      target: target,
                      rootReceipt: rootReceipt,
                      rootScope: rootScope,
                      priority: .background
                  )
            else { continue }
            await ownership.record(owned)
        }

        let collection = await store.codemapOperationPresentationCandidates(
            forFileIDs: selection.targets.filter { validTargets.contains($0) }.map(\.fileID),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        try await afterAutomaticCandidateReconstruction(receipt)
        let finalRevalidation = await store.revalidateAutomaticCodemapSelection(
            receipt,
            rootScope: rootScope
        )
        let finalIDs = Set(finalRevalidation.validTargets.map(\.fileID))
        let candidates = collection.candidates.filter { finalIDs.contains($0.fileID) }
        issues.append(contentsOf: collection.issues.map(WorkspaceCodemapOperationIssue.candidate))
        guard !candidates.isEmpty else {
            return AutomaticPreparation(
                candidates: [],
                issues: issues,
                coverage: .pending(issues),
                receipt: nil
            )
        }
        return AutomaticPreparation(
            candidates: candidates,
            issues: issues,
            coverage: nil,
            receipt: receipt
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
            var hasBusy = false
            var pendingTickets: [(fileID: UUID, ticket: WorkspaceCodemapArtifactDemandTicket)] = []
            var retryAfter: [Int] = []
            for fileID in orderedFileIDs {
                guard let current = results[fileID] else { continue }
                switch current {
                case let .pending(ticket):
                    let refreshed = await store.codemapArtifactDemandStatus(ticket)
                    results[fileID] = refreshed
                    if case let .pending(refreshedTicket) = refreshed {
                        hasPending = true
                        pendingTickets.append((fileID, refreshedTicket))
                    }
                    if case let .unavailable(.busy(milliseconds)) = refreshed {
                        hasPending = true
                        hasBusy = true
                        if let milliseconds { retryAfter.append(milliseconds) }
                    }
                case let .unavailable(.busy(milliseconds)):
                    hasPending = true
                    hasBusy = true
                    if let milliseconds { retryAfter.append(milliseconds) }
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < policy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }

            if !pendingTickets.isEmpty, !hasBusy {
                let firstCompletion: (fileID: UUID, result: WorkspaceCodemapArtifactDemandResult)? = try await withThrowingTaskGroup(
                    of: (fileID: UUID, result: WorkspaceCodemapArtifactDemandResult).self
                ) { group in
                    for pending in pendingTickets {
                        group.addTask {
                            try Task.checkCancellation()
                            let result = await store.waitForCodemapArtifactDemandChange(
                                pending.ticket,
                                deadline: deadline
                            )
                            try Task.checkCancellation()
                            return (pending.fileID, result)
                        }
                    }
                    guard let first = try await group.next() else { return nil }
                    group.cancelAll()
                    return first
                }
                if let firstCompletion {
                    results[firstCompletion.fileID] = firstCompletion.result
                }
                continue
            }

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

    private func release(_ ownership: WorkspaceCodemapOperationPresentationOwnership) async {
        let resources = await ownership.drain()
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
                case .pending:
                    return true
                case .ok, .partial, .unavailable:
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

    private func preservingPriorStaleCoverage(
        _ presentation: WorkspaceCodemapOperationPresentation,
        reason: WorkspaceCodemapOperationPublicationStaleReason,
        requestedCodemapCount: Int
    ) -> WorkspaceCodemapOperationPresentation {
        guard presentation.orderedEntries.count < requestedCodemapCount else {
            return presentation
        }
        let issue = WorkspaceCodemapOperationIssue.publicationStale(reason)
        let issues = presentation.issues.contains(issue)
            ? presentation.issues
            : presentation.issues + [issue]
        let coverage: WorkspaceCodemapOperationPresentationCoverage = presentation.orderedEntries.isEmpty
            ? .unavailable(issues)
            : .partial(issues)
        return WorkspaceCodemapOperationPresentation(
            id: presentation.id,
            orderedEntries: presentation.orderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: presentation.publicationReceipt
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
