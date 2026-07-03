import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

class WorkspaceFileContextStoreCodemapSeamTestSupport: XCTestCase {
    func automaticSelectionCandidate(
        file: WorkspaceFileRecord,
        root: WorkspaceRootRecord,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) throws -> WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate {
        let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: ticket.rootEpoch.rootID,
            rootLifetimeID: ticket.rootEpoch.rootLifetimeID,
            fileID: file.id,
            standardizedRootPath: root.standardizedFullPath,
            standardizedRelativePath: file.standardizedRelativePath,
            standardizedFullPath: file.standardizedFullPath
        ))
        return WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
            identity: identity,
            language: .swift,
            requestGeneration: ticket.requestGeneration,
            catalogGeneration: ticket.catalogGeneration,
            pathGeneration: ticket.pathGeneration,
            ingressGeneration: ticket.ingressGeneration
        )
    }

    func publishCompleteAutomaticSelectionProjection(
        fixture: CodemapStoreFixture,
        graphProbe: CodemapSelectionGraphProbe,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        contributionsByFileID: [UUID: CodeMapSelectionGraphContribution]
    ) async throws -> WorkspaceCodemapProjectionCoverageProof {
        guard fixture.projectionAuthority == .manual else {
            throw CodemapStoreTestError.manualProjectionAuthorityRequired
        }
        let catalog = fixture.registry.makeBindingCatalogClient()
        var token: WorkspaceCodemapProjectionCatalogToken?
        var cursor: WorkspaceCodemapProjectionCatalogCursor?
        var candidates: [WorkspaceCodemapProjectionCatalogCandidate] = []
        var pageCount: UInt64 = 0
        var catalogPathByteCount: UInt64 = 0
        while token == nil || cursor != nil {
            let page = try await projectionPage(catalog.readProjectionCatalogPage(
                WorkspaceCodemapProjectionCatalogPageRequest(
                    rootEpoch: ticket.rootEpoch,
                    token: token,
                    cursor: cursor,
                    maximumEntryCount: 256,
                    maximumPathByteCount: 256 * 1024
                )
            ))
            token = page.token
            candidates.append(contentsOf: page.entries)
            pageCount += 1
            catalogPathByteCount += page.pathByteCount
            cursor = page.nextCursor
            if page.isEnd { break }
        }
        let catalogToken = try XCTUnwrap(token)
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))
        let graphAccounting = await graph.accounting()
        let summary = try XCTUnwrap(graphAccounting.publishedSummary)
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: catalogToken,
            repositoryAuthority: summary.key.repositoryAuthority,
            contributionGeneration: summary.key.contributionGeneration
        )
        var pipelinesByLanguage: [LanguageType: CodeMapPipelineIdentity] = [:]
        var entries: [WorkspaceCodemapProjectionEntry] = []
        entries.reserveCapacity(candidates.count)
        for candidate in candidates {
            let pipeline: CodeMapPipelineIdentity
            if let existing = pipelinesByLanguage[candidate.language] {
                pipeline = existing
            } else {
                let created = try SyntaxManager().pipelineIdentity(
                    for: candidate.language,
                    decoderPolicy: .workspaceAutomaticV1
                )
                pipelinesByLanguage[candidate.language] = created
                pipeline = created
            }
            let outcome: WorkspaceCodemapProjectionEntryOutcome = if let contribution =
                contributionsByFileID[candidate.identity.fileID]
            {
                .contributed(contribution)
            } else {
                .terminalExcluded(.securityExcluded)
            }
            entries.append(WorkspaceCodemapProjectionEntry(
                identity: candidate.identity,
                requestGeneration: candidate.requestGeneration,
                pathGeneration: candidate.pathGeneration,
                pipelineIdentity: pipeline,
                outcome: outcome
            ))
        }
        guard let supportedCount = UInt64(exactly: candidates.count), !entries.isEmpty else {
            throw CodemapStoreTestError.expectedProjectionPublication
        }
        let completion = WorkspaceCodemapProjectionCatalogCompletion(
            token: catalogToken,
            finalCursor: candidates.last.map {
                WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: $0.identity.standardizedRelativePath,
                    fileID: $0.identity.fileID
                )
            },
            supportedCandidateCount: supportedCount
        )
        var contributedCount: UInt64 = 0
        var terminalExcludedCount: UInt64 = 0
        var publishedSegmentByteCount: UInt64 = 0
        var finalCounts = WorkspaceCodemapProjectionCounts.zero
        var lastSegmentSequence: UInt64?
        let maximumSegmentEntryCount = 256
        for (segmentIndex, lowerBound) in stride(
            from: 0,
            to: entries.count,
            by: maximumSegmentEntryCount
        ).enumerated() {
            let upperBound = min(entries.count, lowerBound + maximumSegmentEntryCount)
            let segmentEntries = Array(entries[lowerBound ..< upperBound])
            let segmentByteCount: UInt64
            switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
                entries: segmentEntries
            ) {
            case let .success(value):
                segmentByteCount = value
            case .failure:
                throw CodemapStoreTestError.expectedProjectionPublication
            }
            for entry in segmentEntries {
                switch entry.outcome {
                case .contributed:
                    contributedCount += 1
                case .terminalExcluded:
                    terminalExcludedCount += 1
                case .empty, .terminalArtifact:
                    throw CodemapStoreTestError.expectedProjectionPublication
                }
            }
            let (nextPublishedByteCount, byteOverflow) = publishedSegmentByteCount
                .addingReportingOverflow(segmentByteCount)
            guard !byteOverflow,
                  let processedCount = UInt64(exactly: upperBound),
                  let sequence = UInt64(exactly: segmentIndex)
            else { throw CodemapStoreTestError.expectedProjectionPublication }
            publishedSegmentByteCount = nextPublishedByteCount
            finalCounts = WorkspaceCodemapProjectionCounts(
                supportedCandidateCount: supportedCount,
                processedCandidateCount: processedCount,
                contributedCount: contributedCount,
                emptyCount: 0,
                terminalArtifactCount: 0,
                terminalExcludedCount: terminalExcludedCount,
                transientCount: 0
            )
            let progress = WorkspaceCodemapProjectionProgress(
                phase: .publishingProjectionSegment,
                counts: finalCounts,
                catalogPageCount: pageCount,
                catalogPathByteCount: catalogPathByteCount,
                publishedSegmentCount: sequence + 1,
                publishedSegmentByteCount: publishedSegmentByteCount,
                catalogCompletion: completion
            )
            let segment: WorkspaceCodemapProjectionSegment
            switch WorkspaceCodemapProjectionSegment.validated(
                generation: generation,
                sequence: sequence,
                entries: segmentEntries,
                progress: progress,
                byteCount: segmentByteCount
            ) {
            case let .success(value):
                segment = value
            case .failure:
                throw CodemapStoreTestError.expectedProjectionPublication
            }
            let publication = await catalog.publishProjection(.segment(segment))
            let publishedProgress: WorkspaceCodemapProjectionProgress
            switch publication {
            case let .accepted(progress):
                publishedProgress = progress
            case .exactDuplicate, .stale, .superseded, .busy, .budget, .unavailable:
                throw CodemapStoreTestError.expectedProjectionPublication
            }
            guard publishedProgress == progress else {
                throw CodemapStoreTestError.expectedProjectionPublication
            }
            lastSegmentSequence = sequence
        }
        let finalSegmentSequence = try XCTUnwrap(lastSegmentSequence)
        let proof: WorkspaceCodemapProjectionCoverageProof
        switch WorkspaceCodemapProjectionCoverageProof.validated(
            generation: generation,
            catalogCompletion: completion,
            counts: finalCounts,
            lastSegmentSequence: finalSegmentSequence
        ) {
        case let .success(value):
            proof = value
        case .failure:
            throw CodemapStoreTestError.expectedProjectionPublication
        }
        let expectedCompletedProgress = WorkspaceCodemapProjectionProgress(
            phase: .complete,
            counts: finalCounts,
            catalogPageCount: pageCount,
            catalogPathByteCount: catalogPathByteCount,
            publishedSegmentCount: finalSegmentSequence + 1,
            publishedSegmentByteCount: publishedSegmentByteCount,
            catalogCompletion: completion
        )
        let sealPublication = await catalog.publishProjection(.seal(proof))
        let completedProgress: WorkspaceCodemapProjectionProgress
        switch sealPublication {
        case let .accepted(progress):
            completedProgress = progress
        case .exactDuplicate, .stale, .superseded, .busy, .budget, .unavailable:
            throw CodemapStoreTestError.expectedProjectionPublication
        }
        guard completedProgress == expectedCompletedProgress else {
            throw CodemapStoreTestError.expectedProjectionPublication
        }
        return proof
    }

    func smallManifestAdoptionPolicy(recordLimit: Int) -> WorkspaceCodemapBindingEnginePolicy {
        precondition(recordLimit > 0)
        return WorkspaceCodemapBindingEnginePolicy(maximumManifestAdoptionRecordCount: recordLimit)
    }

    func waitForCompletionBeforeExternalDeadline(
        _ completion: CodemapBoundedCompletionState,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        while clock.now < deadline {
            if completion.completedBeforeDeadline {
                return true
            }
            if completion.isFinished {
                return completion.expireDeadline()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completion.expireDeadline()
    }

    func waitForBoundedCompletionDrain(
        _ completion: CodemapBoundedCompletionState,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "bounded codemap completion drain",
                timeout: Self.timeInterval(timeout)
            ) {
                completion.isFinished
            }
            return true
        } catch {
            return completion.isFinished
        }
    }

    func waitForCodemapGraphPublicationDrain(
        store: WorkspaceFileContextStore,
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap graph publication drain",
                timeout: Self.timeInterval(timeout)
            ) {
                let state = await store.codemapGraphPublicationRecoveryStateForTesting(
                    rootEpoch: rootEpoch
                )
                return !state.flightActive && !state.observerActive
            }
            return true
        } catch {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(
                rootEpoch: rootEpoch
            )
            return !state.flightActive && !state.observerActive
        }
    }

    func pendingTicket(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandTicket {
        guard case let .pending(ticket) = result else {
            throw CodemapStoreTestError.expectedPending
        }
        return ticket
    }

    func projectionPage(
        _ disposition: WorkspaceCodemapProjectionCatalogPageDisposition
    ) throws -> WorkspaceCodemapProjectionCatalogPage {
        guard case let .page(page) = disposition else {
            throw CodemapStoreTestError.expectedProjectionPage
        }
        return page
    }

    func readyResult(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandReady {
        guard case let .ready(ready) = result else {
            throw CodemapStoreTestError.expectedReady
        }
        return ready
    }

    /// Requests a codemap artifact demand and retries through transient unavailability
    /// (git transient failures, busy backoff, runtime setup hiccups) until the demand
    /// settles ready or a stable unavailability/timeout is reached. Hosted CI runners
    /// can transiently fail git authority capture under load; re-requesting detaches
    /// the failed session and re-triggers setup so the test reaches the ready state
    /// it needs without masking genuine terminal failures.
    func readyArtifactDemand(
        store: WorkspaceFileContextStore,
        forFileID fileID: UUID,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (ticket: WorkspaceCodemapArtifactDemandTicket, ready: WorkspaceCodemapArtifactDemandReady) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastNonReadyResult: WorkspaceCodemapArtifactDemandResult?
        while clock.now < deadline {
            let initial = await store.requestCodemapArtifact(forFileID: fileID)
            switch initial {
            case let .pending(ticket):
                let result = try await settledResult(store: store, ticket: ticket)
                switch result {
                case let .ready(ready):
                    return (ticket, ready)
                case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                    lastNonReadyResult = result
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                default:
                    lastNonReadyResult = result
                    throw CodemapStoreTestError.expectedReady
                }
            case let .ready(ready):
                return (ready.ticket, ready)
            case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                lastNonReadyResult = initial
                try await Task.sleep(for: .milliseconds(50))
                continue
            default:
                lastNonReadyResult = initial
                throw CodemapStoreTestError.expectedReady
            }
        }
        XCTFail(
            "Timed out waiting for ready codemap artifact demand; last result = \(String(describing: lastNonReadyResult)).",
            file: file,
            line: line
        )
        throw CodemapStoreTestError.timedOut
    }

    private static func demandUnavailableIsStable(
        _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
    ) -> Bool {
        switch reason {
        case .rootNotLoaded, .fileNotCataloged, .unsupportedFileType:
            true
        case let .gitTerminal(reason):
            reason != .releasedRootEpoch
        case let .demandUnavailable(reason):
            reason != .transient
        case .gitTransient, .busy, .rejected, .routeConflict, .registrationFailed,
             .runtimeFailure, .staleCurrentness, .cancelled:
            false
        }
    }

    func frozenPresentationBundle(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition
    ) throws -> WorkspaceCodemapFrozenPresentationBundle {
        guard case let .ready(bundle) = disposition else {
            throw CodemapStoreTestError.expectedFrozenPresentationBundle
        }
        return bundle
    }

    func renderedPresentationEntries(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [WorkspaceCodemapRenderedPresentationEntry] {
        guard case let .ready(entries) = disposition else {
            if case let .unavailable(reason) = disposition {
                XCTFail(
                    "Expected rendered presentation entries, got \(reason).",
                    file: file,
                    line: line
                )
            }
            throw CodemapStoreTestError.expectedRenderedPresentationEntries
        }
        return entries
    }

    func assertPresentationFreezeUnavailable(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition,
        equals expected: WorkspaceCodemapPresentationFreezeUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation freeze unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func assertPresentationRenderUnavailable(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        equals expected: WorkspaceCodemapPresentationRenderUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation render unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func readyGraphQuery(
        store: WorkspaceFileContextStore,
        query: WorkspaceCodemapStoreSelectionGraphQuery,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapStoreSelectionGraphQueryResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latest: WorkspaceCodemapStoreSelectionGraphQueryDisposition?
        while clock.now < deadline {
            let disposition = await store.queryCodemapSelectionGraph(query)
            latest = disposition
            if case let .readyPartial(result) = disposition {
                return result
            }
            switch disposition {
            case .incomplete, .busy, .stale(.runtime), .unavailable(.runtime), .unavailable(.notActivated(_)):
                try await Task.sleep(for: .milliseconds(10))
            case .readyPartial, .unavailable, .stale, .budget:
                throw CodemapStoreTestError.expectedReadyGraph(disposition)
            }
        }
        if let latest {
            throw CodemapStoreTestError.expectedReadyGraph(latest)
        }
        throw CodemapStoreTestError.timedOut
    }

    func projectionDemandDeadlineUptimeNanoseconds(
        retentionDuration: Duration
    ) -> UInt64 {
        let components = retentionDuration.components
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
        let (deadline, overflow) = now.addingReportingOverflow(remainingNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    func boundedProjectionRetryMilliseconds(_ retry: UInt64) -> Int {
        min(1000, max(25, Int(exactly: retry) ?? 1000))
    }

    func projectionDemandSourceTicketDiagnostics(
        _ sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
    ) -> String {
        sourceTickets.map { ticket in
            "fileID=\(ticket.fileID) rootEpoch=\(ticket.rootEpoch) " +
                "catalogGeneration=\(ticket.catalogGeneration) " +
                "ingressGeneration=\(ticket.ingressGeneration)"
        }.joined(separator: "; ")
    }

    func requireReadyProjectionDemand(
        store: WorkspaceFileContextStore,
        sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
        phase: String,
        readinessTimeout: Duration = .seconds(15),
        retentionDuration: Duration = .seconds(45),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> WorkspaceCodemapProjectionDemandTicket {
        guard !sourceTickets.isEmpty else {
            XCTFail(
                "Expected \(phase) source tickets for projection demand.",
                file: file,
                line: line
            )
            throw CodemapStoreTestError.expectedReadyProjectionDemand(phase)
        }
        let sourceDiagnostics = projectionDemandSourceTicketDiagnostics(sourceTickets)
        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: sourceTickets,
            deadlineUptimeNanoseconds: projectionDemandDeadlineUptimeNanoseconds(
                retentionDuration: retentionDuration
            )
        )
        let projectionTicket: WorkspaceCodemapProjectionDemandTicket
        var latestStatus: WorkspaceCodemapProjectionDemandStatus
        switch acquisition {
        case let .acquired(ticket, status):
            projectionTicket = ticket
            latestStatus = status
        case let .busy(reason, retryAfterMilliseconds):
            XCTFail(
                "Expected \(phase) projection demand acquired, got busy \(reason) " +
                    "retry=\(retryAfterMilliseconds); sourceTickets=\(sourceDiagnostics).",
                file: file,
                line: line
            )
            throw CodemapStoreTestError.expectedReadyProjectionDemand(phase)
        case let .unavailable(reason, retryAfterMilliseconds):
            XCTFail(
                "Expected \(phase) projection demand acquired, got unavailable \(reason) " +
                    "retry=\(String(describing: retryAfterMilliseconds)); " +
                    "sourceTickets=\(sourceDiagnostics).",
                file: file,
                line: line
            )
            throw CodemapStoreTestError.expectedReadyProjectionDemand(phase)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while clock.now < deadline {
            switch latestStatus {
            case .ready:
                return projectionTicket
            case let .waitingForSetup(retryAfterMilliseconds),
                 let .queued(_, retryAfterMilliseconds),
                 let .joined(_, retryAfterMilliseconds),
                 let .waitingForBatchBoundary(_, retryAfterMilliseconds),
                 let .activeBatch(_, retryAfterMilliseconds),
                 let .suspendedBusy(_, retryAfterMilliseconds):
                try await Task.sleep(for: .milliseconds(
                    boundedProjectionRetryMilliseconds(retryAfterMilliseconds)
                ))
                latestStatus = await store.codemapProjectionDemandStatus(projectionTicket)
            case .stale, .cancelled, .expired:
                _ = await store.releaseCodemapProjectionDemand(projectionTicket)
                XCTFail(
                    "Expected \(phase) projection demand ready, got \(latestStatus); " +
                        "sourceTickets=\(sourceDiagnostics).",
                    file: file,
                    line: line
                )
                throw CodemapStoreTestError.expectedReadyProjectionDemand(phase)
            case let .unavailable(reason, retryAfterMilliseconds):
                _ = await store.releaseCodemapProjectionDemand(projectionTicket)
                XCTFail(
                    "Expected \(phase) projection demand ready, got unavailable \(reason) " +
                        "retry=\(String(describing: retryAfterMilliseconds)); " +
                        "sourceTickets=\(sourceDiagnostics).",
                    file: file,
                    line: line
                )
                throw CodemapStoreTestError.expectedReadyProjectionDemand(phase)
            }
        }
        _ = await store.releaseCodemapProjectionDemand(projectionTicket)
        XCTFail(
            "Expected \(phase) projection demand ready, latest \(latestStatus); " +
                "sourceTickets=\(sourceDiagnostics).",
            file: file,
            line: line
        )
        throw CodemapStoreTestError.timedOut
    }

    func assertProjectionDemandReleased(
        store: WorkspaceFileContextStore,
        _ ticket: WorkspaceCodemapProjectionDemandTicket,
        phase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let released = await store.releaseCodemapProjectionDemand(ticket)
        XCTAssertTrue(
            released,
            "Expected \(phase) projection demand release to succeed.",
            file: file,
            line: line
        )
    }

    func generationMatchedCompleteSeal(
        catalogClient: WorkspaceCodemapBindingCatalogClient,
        graphProbe: CodemapSelectionGraphProbe,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapProjectionCoverageProof {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latestAccounting: WorkspaceCodemapSelectionGraphRuntimeAccounting?
        while clock.now < deadline {
            guard let graph = graphProbe.graph(rootEpoch: ticket.rootEpoch) else {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            let accounting = await graph.accounting()
            latestAccounting = accounting
            if let observedKey = accounting.currentObservedKey,
               observedKey.catalogGeneration > ticket.catalogGeneration
            {
                throw CodemapStoreTestError.newerProjectionAuthority
            }
            if accounting.budgetRejectedCount > 0 {
                throw CodemapStoreTestError.terminalProjectionCoverage
            }
            if let unavailable = accounting.currentUnavailableReason {
                switch unavailable {
                case .budgetExceeded, .invalidSnapshot, .explicitRootUnavailable, .invalidQuery:
                    throw CodemapStoreTestError.terminalProjectionCoverage
                case .notBuilt, .rebuilding, .staleCurrentness, .actorAdmissionRejected,
                     .processAdmissionRejected, .cancelled, .outputBudgetExceeded:
                    break
                }
            }
            guard let summary = accounting.publishedSummary else {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            switch summary.definitionUniverseCoverage {
            case let .complete(proof, _, _, _):
                let generation = proof.generation
                let token = generation.catalogToken
                if generation.catalogGeneration < ticket.catalogGeneration ||
                    token.ingressGeneration < ticket.ingressGeneration
                {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard generation.catalogGeneration == ticket.catalogGeneration,
                      token.ingressGeneration == ticket.ingressGeneration
                else { throw CodemapStoreTestError.newerProjectionAuthority }
                guard generation.rootEpoch == ticket.rootEpoch,
                      summary.key == WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation),
                      summary.key == accounting.currentObservedKey
                else {
                    if let observedKey = accounting.currentObservedKey,
                       observedKey.rootEpoch == ticket.rootEpoch,
                       observedKey.catalogGeneration == ticket.catalogGeneration,
                       observedKey.contributionGeneration > summary.key.contributionGeneration
                    {
                        try await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    throw CodemapStoreTestError.expectedGenerationMatchedSeal(
                        "proof=\(generation), observed=\(String(describing: accounting.currentObservedKey))"
                    )
                }
                switch await catalogClient.revalidateProjectionCatalogToken(
                    ticket.rootEpoch,
                    token
                ) {
                case .current:
                    return proof
                case .stale:
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                case .unavailable:
                    throw CodemapStoreTestError.terminalProjectionCoverage
                }
            case .budget, .unavailable:
                throw CodemapStoreTestError.terminalProjectionCoverage
            case .incomplete, .busy:
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CodemapStoreTestError.expectedGenerationMatchedSeal(
            "ticket=\(ticket), accounting=\(String(describing: latestAccounting))"
        )
    }

    func settledResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if case .pending = result {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return result
        }
        throw CodemapStoreTestError.timedOut
    }

    func routeBecomesUnavailable(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        relativePath: String
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil("codemap route unavailable", timeout: 5) {
                let candidate = await registry.makeBindingCatalogClient()
                    .resolveManifestBinding(ticket.rootEpoch, relativePath)
                return candidate == nil
            }
            return true
        } catch {
            return false
        }
    }

    func assertEngineRootCount(
        _ expected: Int,
        fixture: CodemapStoreFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try fixture.runtime().bindingEngine()
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.rootCount, expected, file: file, line: line)
    }

    func engineRootCountBecomesZero(
        fixture: CodemapStoreFixture
    ) async throws -> Bool {
        let engine = try fixture.runtime().bindingEngine()
        do {
            try await AsyncTestWait.waitUntil("codemap engine root count zero", timeout: 5) {
                await engine.accounting().rootCount == 0
            }
            return true
        } catch {
            return await engine.accounting().rootCount == 0
        }
    }

    func waitForCodemapPreloadEvent(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        kind: WorkspaceFileContextStore.CodemapProjectionPreloadStoreEventKind,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        await waitForCodemapPreloadEventCount(
            store: store,
            rootID: rootID,
            kind: kind,
            count: 1,
            timeout: timeout
        )
    }

    func waitForCodemapPreloadEventCount(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        kind: WorkspaceFileContextStore.CodemapProjectionPreloadStoreEventKind,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap preload event count",
                timeout: Self.timeInterval(timeout)
            ) {
                let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: rootID)
                return events.count(where: { $0.kind == kind }) >= count
            }
            return true
        } catch {
            let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: rootID)
            return events.count(where: { $0.kind == kind }) >= count
        }
    }

    func assertNonGitTerminal(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git unavailability.", file: file, line: line)
        }
    }

    func assertCancelled(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.cancelled) = result else {
            return XCTFail("Expected cancelled unavailability.", file: file, line: line)
        }
    }

    func assertStale(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.staleCurrentness) = result else {
            return XCTFail("Expected stale currentness.", file: file, line: line)
        }
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum CodemapStoreTestError: Error {
    case expectedGenerationMatchedSeal(String)
    case expectedReadyProjectionDemand(String)
    case expectedFrozenPresentationBundle
    case manualProjectionAuthorityRequired
    case expectedPending
    case expectedProjectionPage
    case expectedProjectionPublication
    case expectedReady
    case expectedRenderedPresentationEntries
    case expectedReadyGraph(WorkspaceCodemapStoreSelectionGraphQueryDisposition)
    case newerProjectionAuthority
    case terminalProjectionCoverage
    case timedOut
}

final class CodemapStoreFixture: @unchecked Sendable {
    enum ProjectionAuthority: Equatable {
        case engine
        case manual
        case none
    }

    let registry = WorkspaceCodemapBindingIntegrationRegistry()
    let providerAccessCount = CodemapLockedCounter()
    let runtimeFactoryCount = CodemapLockedCounter()
    let engineFactoryCount = CodemapLockedCounter()
    let manifestReadCount = CodemapLockedCounter()
    let buildCount = CodemapLockedCounter()
    let buildPriorities = CodemapLockedValues<CodeMapArtifactBuildPriority>()
    let projectionAuthority: ProjectionAuthority

    private let sandbox: URL
    private let artifactRoot: URL
    private let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(
        name: String,
        projectionAuthority: ProjectionAuthority = .engine,
        resolutionGate: CodemapResolutionGate? = nil,
        syntheticGraphArtifacts: Bool = false,
        bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy = .default,
        manifestStoreFaultAction: @escaping @Sendable (
            CodeMapRootManifestStoreFaultPoint
        ) -> CodeMapRootManifestStoreFaultAction = { _ in .proceed }
    ) throws {
        let sandbox = try Self.makeSandbox(name: name)
        let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
        let registry = registry
        let runtimeFactoryCount = runtimeFactoryCount
        let engineFactoryCount = engineFactoryCount
        let manifestReadCount = manifestReadCount
        let buildCount = buildCount
        let buildPriorities = buildPriorities
        let defaultBuilder = CodeMapArtifactBuilderClient()
        let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime = {
            runtimeFactoryCount.increment()
            return try CodeMapArtifactRuntime(
                rootURL: artifactRoot,
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterReadAdmission: {
                        manifestReadCount.increment()
                    },
                    faultAction: manifestStoreFaultAction
                ),
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    buildCount.increment()
                    buildPriorities.append(priority)
                    if syntheticGraphArtifacts,
                       case let .decoded(source) = input.source.decodeResult
                    {
                        return CodeMapArtifactBuilderExecution(
                            outcome: .ready(Self.syntheticGraphArtifact(source.text)),
                            permitWaitNanoseconds: 0,
                            buildNanoseconds: 0
                        )
                    }
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    engineFactoryCount.increment()
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            ),
                            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                                beforeResolution: {
                                    await resolutionGate?.enterAndWait()
                                }
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient(),
                        policy: bindingEnginePolicy
                    )
                }
            )
        }
        runtimeProvider = CodeMapArtifactRuntimeProvider(factory: freshRuntimeFactory)
        self.projectionAuthority = projectionAuthority
        self.sandbox = sandbox
        self.artifactRoot = artifactRoot
        self.freshRuntimeFactory = freshRuntimeFactory
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore(
        codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .init { _ in
            .requiresGitPreflight
        },
        codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = WorkspaceCodemapGitEligibilityProbe { _ in
            .eligible
        },
        codemapProjectionPreloadRetryPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy = .production,
        codemapProjectionPreloadLaunchPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting? = nil,
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy = .initial,
        automaticSelectionAccountingMaximum: Int = .max,
        cancellationCleanupHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        readyPublicationHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        graphPublicationWaiter: @escaping @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void = { _ in },
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
        automaticSelectionQueryHook: @escaping @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void = { _ in },
        selectionGraphRuntimeQueryOverride: (@Sendable (
            WorkspaceCodemapRootEpoch,
            WorkspaceCodemapSelectionGraphRuntimeQuery
        ) async -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition?)? = nil
    ) -> WorkspaceFileContextStore {
        let providerAccessCount = providerAccessCount
        let runtimeProvider = runtimeProvider
        let policies = projectionAuthorityPolicies(
            preloadOverride: codemapProjectionPreloadLaunchPolicy
        )
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return try runtimeProvider.runtime()
            },
            codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
            codemapGitEligibilityProbe: codemapGitEligibilityProbe,
            codemapProjectionPreloadRetryPolicy: codemapProjectionPreloadRetryPolicy,
            codemapProjectionPreloadLaunchPolicyForTesting: policies.preload,
            codemapAutomaticRetainedProjectionDemandPolicyForTesting: policies.retainedDemand,
            selectionGraphFactory: selectionGraphFactory,
            codemapSelectionGraphRuntimeQueryOverrideForTesting: selectionGraphRuntimeQueryOverride,
            selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
            automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
            codemapCancellationCleanupHook: cancellationCleanupHook,
            codemapReadyPublicationHook: readyPublicationHook,
            codemapGraphPublicationWaiter: graphPublicationWaiter,
            codemapDemandResultHook: demandResultHook,
            codemapAutomaticSelectionQueryHook: automaticSelectionQueryHook
        )
    }

    func makeFreshStore(
        codemapProjectionPreloadLaunchPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting? = nil,
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production
    ) throws -> WorkspaceFileContextStore {
        let runtime = try freshRuntimeFactory()
        let providerAccessCount = providerAccessCount
        let policies = projectionAuthorityPolicies(
            preloadOverride: codemapProjectionPreloadLaunchPolicy
        )
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return runtime
            },
            codemapProjectionPreloadLaunchPolicyForTesting: policies.preload,
            codemapAutomaticRetainedProjectionDemandPolicyForTesting: policies.retainedDemand,
            selectionGraphFactory: selectionGraphFactory
        )
    }

    private func projectionAuthorityPolicies(
        preloadOverride: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting?
    ) -> (
        preload: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting,
        retainedDemand: WorkspaceFileContextStore.CodemapAutomaticRetainedProjectionDemandPolicyForTesting
    ) {
        switch projectionAuthority {
        case .engine:
            return (preloadOverride ?? .enabled, .enabled)
        case .manual, .none:
            precondition(preloadOverride == nil || preloadOverride == .disabled)
            return (.disabled, .suppressed)
        }
    }

    func artifactURL(for key: CodeMapArtifactKey) -> URL {
        artifactRoot
            .appendingPathComponent("CodeMapArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(key.shard, isDirectory: true)
            .appendingPathComponent(key.storageDigestHex)
    }

    func makePlainRoot(files: [String: String]) throws -> URL {
        let root = sandbox.appendingPathComponent(
            "plain-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            try Self.write(
                contents,
                to: root.appendingPathComponent(relativePath)
            )
        }
        return root
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        try runtimeProvider.runtime()
    }

    func shutdown() async {
        if let runtime = try? runtimeProvider.runtime(),
           let engine = try? runtime.bindingEngine()
        {
            await engine.shutdown()
        }
    }

    static func makeSandbox(name: String) throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceFileContextStoreCodemapSeamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func syntheticGraphArtifact(_ source: String) -> CodeMapSyntaxArtifact {
        let definitions: [String]
        let references: [String]
        if source.contains("let target: Target") {
            definitions = ["Source"]
            references = ["Target"]
        } else if source.contains("protocol FirstSource") {
            definitions = ["FirstSource"]
            references = ["FirstTarget"]
        } else if source.contains("protocol SecondSource") {
            definitions = ["SecondSource"]
            references = ["SecondTarget"]
        } else if source.contains("protocol SourceProtocol") {
            definitions = ["SourceProtocol"]
            if source.contains("ForeignDefinition") {
                references = ["ForeignDefinition"]
            } else if source.contains("FirstTarget"), source.contains("SecondTarget") {
                references = ["FirstTarget", "SecondTarget"]
            } else {
                references = ["Target"]
            }
        } else if source.contains("ForeignDefinition") {
            definitions = ["ForeignDefinition"]
            references = []
        } else if source.contains("FirstTarget") {
            definitions = ["FirstTarget"]
            references = []
        } else if source.contains("SecondTarget") {
            definitions = ["SecondTarget"]
            references = []
        } else if source.contains("Target") {
            definitions = ["Target"]
            references = []
        } else {
            definitions = []
            references = []
        }
        return CodeMapSyntaxArtifact(
            imports: [],
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }
}

final class CodemapSelectionGraphProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let admission: CodeMapSelectionGraphAdmission
    private let buildGate: CodemapSelectionGraphBuildGate?
    private let runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private let processAdmissionWaitHook: @Sendable () async -> Void
    private var graphsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraph] = [:]
    private var factoryInvocationCount = 0

    init(
        buildGate: CodemapSelectionGraphBuildGate? = nil,
        admissionPolicy: CodeMapSelectionGraphAdmissionPolicy = .init(
            maximumActiveReservationCount: 8,
            maximumReservedBindingCount: 100_000
        ),
        runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial,
        processAdmissionWaitHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.buildGate = buildGate
        admission = CodeMapSelectionGraphAdmission(policy: admissionPolicy)
        self.runtimePolicy = runtimePolicy
        self.processAdmissionWaitHook = processAdmissionWaitHook
    }

    var factory: WorkspaceCodemapSelectionGraphFactory {
        WorkspaceCodemapSelectionGraphFactory { [self] rootEpoch in
            lock.withLock {
                factoryInvocationCount += 1
                let graph = WorkspaceCodemapSelectionGraph(
                    rootEpoch: rootEpoch,
                    policy: runtimePolicy,
                    admission: admission,
                    diagnostics: buildGate?.diagnostics ?? .none,
                    processAdmissionWaitHook: processAdmissionWaitHook
                )
                graphsByRootEpoch[rootEpoch] = graph
                return graph
            }
        }
    }

    var factoryCount: Int {
        lock.withLock { factoryInvocationCount }
    }

    func graph(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph? {
        lock.withLock { graphsByRootEpoch[rootEpoch] }
    }

    func waitUntilPublished(
        rootEpoch: WorkspaceCodemapRootEpoch,
        minimumNodeCount: Int = 0,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap selection graph published",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                guard let graph = self.graph(rootEpoch: rootEpoch),
                      let summary = await (graph.accounting()).publishedSummary
                else { return false }
                return summary.nodeCount >= minimumNodeCount
            }
            return true
        } catch {
            return false
        }
    }

    func waitUntilProcessBusy(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap selection graph process busy",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                guard let graph = self.graph(rootEpoch: rootEpoch) else { return false }
                return await (graph.accounting()).processBusyCount > 0
            }
            return true
        } catch {
            return false
        }
    }

    func waitUntilCompleteCoverage(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap selection graph complete coverage",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                guard let graph = self.graph(rootEpoch: rootEpoch) else { return false }
                let accounting = await graph.accounting()
                guard let summary = accounting.publishedSummary,
                      accounting.currentObservedKey == summary.key,
                      case .complete = summary.definitionUniverseCoverage
                else { return false }
                return true
            }
            return true
        } catch {
            return false
        }
    }

    func waitUntilCompleteCoverage(
        rootEpoch: WorkspaceCodemapRootEpoch,
        after contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        timeout: Duration = .seconds(5)
    ) async -> WorkspaceCodemapSelectionGraphRuntimeKey? {
        var matchedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
        do {
            try await AsyncTestWait.waitUntil(
                "codemap selection graph complete coverage after generation",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                guard let graph = self.graph(rootEpoch: rootEpoch) else { return false }
                let accounting = await graph.accounting()
                guard let summary = accounting.publishedSummary,
                      summary.key.contributionGeneration > contributionGeneration,
                      accounting.currentObservedKey == summary.key,
                      case .complete = summary.definitionUniverseCoverage
                else { return false }
                matchedKey = summary.key
                return true
            }
            return matchedKey
        } catch {
            return nil
        }
    }

    func waitUntilObservedKey(
        rootEpoch: WorkspaceCodemapRootEpoch,
        after contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        timeout: Duration = .seconds(5)
    ) async -> WorkspaceCodemapSelectionGraphRuntimeKey? {
        var matchedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
        do {
            try await AsyncTestWait.waitUntil(
                "codemap selection graph observed key",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                guard let graph = self.graph(rootEpoch: rootEpoch),
                      let key = await (graph.accounting()).currentObservedKey,
                      key.contributionGeneration > contributionGeneration
                else { return false }
                matchedKey = key
                return true
            }
            return matchedKey
        } catch {
            return nil
        }
    }

    func materializedQueryResultCount() async -> UInt64 {
        let graphs = lock.withLock { Array(graphsByRootEpoch.values) }
        var count: UInt64 = 0
        for graph in graphs {
            await count += (graph.accounting()).materializedQueryResultCount
        }
        return count
    }
}

final class CodemapSelectionGraphBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let autoReleaseTimeout: TimeInterval?
    private var blockedGenerations: [UInt64] = []
    private var releasedGenerations = Set<UInt64>()
    private var isOpen = false

    init(autoReleaseTimeout: TimeInterval? = 10) {
        self.autoReleaseTimeout = autoReleaseTimeout
    }

    var diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
        WorkspaceCodemapSelectionGraphRuntimeDiagnostics { [self] event in
            guard event.kind == .beforePublication else { return }
            block(generation: event.key.contributionGeneration.rawValue)
        }
    }

    func waitUntilFirstBlocked() -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while blockedGenerations.isEmpty {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations[0]
    }

    func waitUntilBlocked(after generation: UInt64) -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !blockedGenerations.contains(where: { $0 > generation }) {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations.first(where: { $0 > generation })
    }

    func release(generation: UInt64) {
        condition.lock()
        releasedGenerations.insert(generation)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func block(generation: UInt64) {
        condition.lock()
        guard !isOpen else {
            condition.unlock()
            return
        }
        blockedGenerations.append(generation)
        condition.broadcast()
        if let autoReleaseTimeout {
            let deadline = Date(timeIntervalSinceNow: autoReleaseTimeout)
            while !isOpen, !releasedGenerations.contains(generation) {
                guard condition.wait(until: deadline) else { break }
            }
        } else {
            while !isOpen, !releasedGenerations.contains(generation) {
                condition.wait()
            }
        }
        condition.unlock()
    }
}

final class CodemapBoundedCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlineExpired = false
    private var completed = false
    private var finished = false

    var completedBeforeDeadline: Bool {
        lock.withLock { completed }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func recordCompletion(beforeDeadline: Bool) {
        lock.withLock {
            finished = true
            if beforeDeadline, !deadlineExpired {
                completed = true
            }
        }
    }

    func expireDeadline() -> Bool {
        lock.withLock {
            deadlineExpired = true
            return completed
        }
    }
}

final class CodemapManifestWriteAttemptLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    func recordAttempt() -> Int {
        let update = lock.withLock {
            attempts += 1
            return (count: attempts, continuations: Array(continuations.values))
        }
        for continuation in update.continuations {
            continuation.yield(update.count)
        }
        return update.count
    }

    func waitForAttemptCount(_ count: Int, timeout: Duration) async -> Bool {
        if currentAttemptCount >= count { return true }
        let stream = attemptStream()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await attemptCount in stream where attemptCount >= count {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return self.currentAttemptCount >= count
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result || self.currentAttemptCount >= count
        }
    }

    private var currentAttemptCount: Int {
        lock.withLock { attempts }
    }

    private func attemptStream() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
            let current = lock.withLock {
                continuations[id] = continuation
                return attempts
            }
            continuation.yield(current)
        }
    }

    private func removeContinuation(id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}

final class CodemapLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }

    func incrementAndGet() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

final class CodemapLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

final class CodemapRetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64

    init(nowNanoseconds: UInt64) {
        storage = nowNanoseconds
    }

    var nowNanoseconds: UInt64 {
        lock.withLock { storage }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { storage &+= nanoseconds }
    }
}

actor CodemapAutomaticSelectionSequenceHarness {
    private var demandTickets: [WorkspaceCodemapArtifactDemandTicket] = []
    private var waiterInvocationCount = 0
    private var releasedWaits = Set<Int>()
    private var releaseAllWaits = false
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var demandCountObservers: [UUID: AsyncStream<[WorkspaceCodemapArtifactDemandTicket]>.Continuation] = [:]
    private var waitCountObservers: [UUID: AsyncStream<Int>.Continuation] = [:]

    var recordedTickets: [WorkspaceCodemapArtifactDemandTicket] {
        demandTickets
    }

    var waitCount: Int {
        waiterInvocationCount
    }

    func recordDemand(_ ticket: WorkspaceCodemapArtifactDemandTicket) -> Int {
        demandTickets.append(ticket)
        publishDemandTickets()
        return demandTickets.count
    }

    func wait() async throws {
        try Task.checkCancellation()
        waiterInvocationCount += 1
        let invocation = waiterInvocationCount
        publishWaitCount()
        guard !releaseAllWaits, !releasedWaits.contains(invocation) else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if releaseAllWaits || releasedWaits.contains(invocation) || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[invocation] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWait(invocation) }
        }
    }

    func releaseWait(_ invocation: Int) {
        releasedWaits.insert(invocation)
        continuations.removeValue(forKey: invocation)?.resume(returning: ())
    }

    func releaseAll() {
        releaseAllWaits = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        let demandObservers = Array(demandCountObservers.values)
        demandCountObservers.removeAll()
        let waitObservers = Array(waitCountObservers.values)
        waitCountObservers.removeAll()
        for continuation in pending {
            continuation.resume(returning: ())
        }
        for observer in demandObservers {
            observer.finish()
        }
        for observer in waitObservers {
            observer.finish()
        }
    }

    func waitUntilDemandCount(
        _ expectedCount: Int
    ) async -> [WorkspaceCodemapArtifactDemandTicket]? {
        if demandTickets.count >= expectedCount { return demandTickets }
        let stream = demandTicketStream()
        for await tickets in stream {
            if tickets.count >= expectedCount { return tickets }
            guard !Task.isCancelled else { return nil }
        }
        return demandTickets.count >= expectedCount ? demandTickets : nil
    }

    func waitUntilWaitCount(_ expectedCount: Int) async -> Bool {
        if waiterInvocationCount >= expectedCount { return true }
        let stream = waitCountStream()
        for await count in stream {
            if count >= expectedCount { return true }
            guard !Task.isCancelled else { return false }
        }
        return waiterInvocationCount >= expectedCount
    }

    private func demandTicketStream() -> AsyncStream<[WorkspaceCodemapArtifactDemandTicket]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[WorkspaceCodemapArtifactDemandTicket]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        demandCountObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDemandObserver(id) }
        }
        continuation.yield(demandTickets)
        return stream
    }

    private func waitCountStream() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        waitCountObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWaitObserver(id) }
        }
        continuation.yield(waiterInvocationCount)
        return stream
    }

    private func publishDemandTickets() {
        for continuation in demandCountObservers.values {
            continuation.yield(demandTickets)
        }
    }

    private func publishWaitCount() {
        for continuation in waitCountObservers.values {
            continuation.yield(waiterInvocationCount)
        }
    }

    private func removeDemandObserver(_ id: UUID) {
        demandCountObservers.removeValue(forKey: id)
    }

    private func removeWaitObserver(_ id: UUID) {
        waitCountObservers.removeValue(forKey: id)
    }

    private func cancelWait(_ invocation: Int) {
        continuations.removeValue(forKey: invocation)?.resume(throwing: CancellationError())
    }
}

actor CodemapRetrySleepGate {
    private(set) var delays: [UInt64] = []
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sleep(_ nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
        try Task.checkCancellation()
        guard !released else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if released || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitForFirstDelay(timeout: Duration = .seconds(10)) async -> UInt64? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while delays.isEmpty, clock.now < deadline {
            await Task.yield()
        }
        return delays.first
    }

    func releaseAll() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: ())
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }
}

actor CodemapSuspensionGate {
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func enterAndWait() async {
        entered = true
        guard !released, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled {
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap suspension gate entered",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                self.entered
            }
            return true
        } catch {
            return entered
        }
    }

    func release() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume()
    }
}

actor CodemapArmableSuspensionGate {
    private var armed = false
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func arm() {
        armed = true
    }

    func enterIfArmedAndWait() async {
        guard armed else { return }
        entered = true
        guard !released, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled {
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap suspension gate entered",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                self.entered
            }
            return true
        } catch {
            return entered
        }
    }

    func release() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume()
    }
}

actor CodemapGraphPublicationGate {
    private var invocationRoots: [WorkspaceCodemapRootEpoch] = []
    private var isOpen = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    var invocationCount: Int {
        invocationRoots.count
    }

    func enterAndWait(_ rootEpoch: WorkspaceCodemapRootEpoch) async {
        invocationRoots.append(rootEpoch)
        guard !isOpen, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitUntilInvocationCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap graph publication gate invocation count",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                self.invocationRoots.count >= expectedCount
            }
            return true
        } catch {
            return invocationRoots.count >= expectedCount
        }
    }

    func release() {
        isOpen = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume()
    }
}

actor CodemapRootSuspensionGate {
    private var enteredRootEpoch: WorkspaceCodemapRootEpoch?
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func enterAndWait(_ rootEpoch: WorkspaceCodemapRootEpoch) async {
        guard enteredRootEpoch == nil else { return }
        enteredRootEpoch = rootEpoch
        guard !released, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled {
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> WorkspaceCodemapRootEpoch? {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap root suspension gate entered",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                self.enteredRootEpoch != nil
            }
            return enteredRootEpoch
        } catch {
            return enteredRootEpoch
        }
    }

    func release() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume()
    }
}

actor CodemapResolutionGate {
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var resolutionCount = 0

    func enterAndWait() async {
        resolutionCount += 1
        entered = true
        guard !released, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled {
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap suspension gate entered",
                timeout: WorkspaceFileContextStoreCodemapSeamTestSupport.timeInterval(timeout)
            ) {
                self.entered
            }
            return true
        } catch {
            return entered
        }
    }

    func release() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: UUID) {
        continuations.removeValue(forKey: waiterID)?.resume()
    }
}
