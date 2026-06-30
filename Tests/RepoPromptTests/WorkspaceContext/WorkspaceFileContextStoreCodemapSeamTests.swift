import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

class WorkspaceFileContextStoreCodemapSeamTestSupport: XCTestCase {
    fileprivate func automaticSelectionCandidate(
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

    fileprivate func publishCompleteAutomaticSelectionProjection(
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

    fileprivate func smallManifestAdoptionPolicy(recordLimit: Int) -> WorkspaceCodemapBindingEnginePolicy {
        precondition(recordLimit > 0)
        return WorkspaceCodemapBindingEnginePolicy(maximumManifestAdoptionRecordCount: recordLimit)
    }

    fileprivate func waitForCompletionBeforeExternalDeadline(
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

    fileprivate func waitForBoundedCompletionDrain(
        _ completion: CodemapBoundedCompletionState,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if completion.isFinished {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completion.isFinished
    }

    fileprivate func pendingTicket(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandTicket {
        guard case let .pending(ticket) = result else {
            throw CodemapStoreTestError.expectedPending
        }
        return ticket
    }

    fileprivate func projectionPage(
        _ disposition: WorkspaceCodemapProjectionCatalogPageDisposition
    ) throws -> WorkspaceCodemapProjectionCatalogPage {
        guard case let .page(page) = disposition else {
            throw CodemapStoreTestError.expectedProjectionPage
        }
        return page
    }

    fileprivate func readyResult(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandReady {
        guard case let .ready(ready) = result else {
            throw CodemapStoreTestError.expectedReady
        }
        return ready
    }

    fileprivate func frozenPresentationBundle(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition
    ) throws -> WorkspaceCodemapFrozenPresentationBundle {
        guard case let .ready(bundle) = disposition else {
            throw CodemapStoreTestError.expectedFrozenPresentationBundle
        }
        return bundle
    }

    fileprivate func renderedPresentationEntries(
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

    fileprivate func assertPresentationFreezeUnavailable(
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

    fileprivate func assertPresentationRenderUnavailable(
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

    fileprivate func readyGraphQuery(
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

    fileprivate func projectionDemandDeadlineUptimeNanoseconds(
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

    fileprivate func boundedProjectionRetryMilliseconds(_ retry: UInt64) -> Int {
        min(1000, max(25, Int(exactly: retry) ?? 1000))
    }

    fileprivate func projectionDemandSourceTicketDiagnostics(
        _ sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
    ) -> String {
        sourceTickets.map { ticket in
            "fileID=\(ticket.fileID) rootEpoch=\(ticket.rootEpoch) " +
                "catalogGeneration=\(ticket.catalogGeneration) " +
                "ingressGeneration=\(ticket.ingressGeneration)"
        }.joined(separator: "; ")
    }

    fileprivate func requireReadyProjectionDemand(
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

    fileprivate func assertProjectionDemandReleased(
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

    fileprivate func generationMatchedCompleteSeal(
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

    fileprivate func settledResult(
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

    fileprivate func routeBecomesUnavailable(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        relativePath: String
    ) async -> Bool {
        for _ in 0 ..< 500 {
            let candidate = await registry.makeBindingCatalogClient()
                .resolveManifestBinding(ticket.rootEpoch, relativePath)
            if candidate == nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    fileprivate func assertEngineRootCount(
        _ expected: Int,
        fixture: CodemapStoreFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try fixture.runtime().bindingEngine()
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.rootCount, expected, file: file, line: line)
    }

    fileprivate func engineRootCountBecomesZero(
        fixture: CodemapStoreFixture
    ) async throws -> Bool {
        let engine = try fixture.runtime().bindingEngine()
        for _ in 0 ..< 500 {
            if await engine.accounting().rootCount == 0 { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await engine.accounting().rootCount == 0
    }

    fileprivate func waitForCodemapPreloadEvent(
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

    fileprivate func waitForCodemapPreloadEventCount(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        kind: WorkspaceFileContextStore.CodemapProjectionPreloadStoreEventKind,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: rootID)
            if events.count(where: { $0.kind == kind }) >= count {
                return true
            }
            await Task.yield()
        }
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: rootID)
        return events.count(where: { $0.kind == kind }) >= count
    }

    fileprivate func assertNonGitTerminal(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git unavailability.", file: file, line: line)
        }
    }

    fileprivate func assertCancelled(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.cancelled) = result else {
            return XCTFail("Expected cancelled unavailability.", file: file, line: line)
        }
    }

    fileprivate func assertStale(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.staleCurrentness) = result else {
            return XCTFail("Expected stale currentness.", file: file, line: line)
        }
    }

    fileprivate static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class WorkspaceFileContextStoreCodemapSeamTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testRootLoadSearchAndReadDoNotInvokeCodemapRuntimeProvider() async throws {
        let sandbox = try CodemapStoreFixture.makeSandbox(name: #function)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.write("struct Feature {}\n", to: root.appendingPathComponent("Sources/Feature.swift"))

        let providerInvocations = CodemapLockedCounter()
        let graphProbe = CodemapSelectionGraphProbe()
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerInvocations.increment()
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .enabled,
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let search = WorkspaceSearchService()
        _ = await search.rebuildIndex(from: snapshot)
        let searchResult = await search.search("Feature", limit: 10)
        let content = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(content, "struct Feature {}\n")
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testProjectionPreloadStartIsAfterOrdinaryRootInventorySearchAndReadVisibility() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let startGate = CodemapRootSuspensionGate()
        addTeardownBlock {
            await startGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        await store.setCodemapProjectionPreloadStartHandlerForTesting { rootEpoch in
            await startGate.enterAndWait(rootEpoch)
        }

        let loaded = try await store.loadRoot(path: root.path)
        let enteredEpoch = await startGate.waitUntilEntered()
        let blockedEpoch = try XCTUnwrap(enteredEpoch)
        let files = await store.files(inRoot: loaded.id)
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
        let contents = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(blockedEpoch.rootID, loaded.id)
        XCTAssertEqual(files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchSnapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(contents, "struct Feature {}\n")
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        let beforeStart = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        XCTAssertEqual(beforeStart.map(\.kind), [
            .rootInventoryAndSearchReady,
            .scheduled
        ])

        await startGate.release()
        let didStart = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .started
        )
        XCTAssertTrue(didStart)
        let afterStart = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let readyOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .rootInventoryAndSearchReady }?.ordinal)
        let scheduledOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .scheduled }?.ordinal)
        let startedOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .started }?.ordinal)
        XCTAssertLessThan(readyOrdinal, scheduledOrdinal)
        XCTAssertLessThan(scheduledOrdinal, startedOrdinal)
        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionPreloadNonGitEligibilityPerformsZeroRuntimeWorkWithoutDemand() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let preflightCount = CodemapLockedCounter()
        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let didReachTerminalEligibility = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachTerminalEligibility)
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        let phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: loaded.id, rootLifetimeID: lifetimeID)
        )
        XCTAssertEqual(phase, .terminalNonGit)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionPreloadAndDemandJoinEligibilityAndSetupSingleflights() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let eligibilityGate = CodemapSuspensionGate()
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await eligibilityGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                await eligibilityGate.enterAndWait()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let eligibilityEntered = await eligibilityGate.waitUntilEntered()
        XCTAssertTrue(eligibilityEntered)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let demandTask = Task {
            await store.requestCodemapArtifact(forFileID: file.id)
        }
        await eligibilityGate.release()
        let demand = await demandTask.value
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)

        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let operationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(operationCounts.setupTasksCreated, 1)
        if case let .pending(ticket) = demand {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherPathInvalidationSupersedesAndReschedulesProjectionPreload() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let preflightCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didReachInitialTerminalEligibility = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachInitialTerminalEligibility)

        try Self.write(
            "struct Feature { let changed = true }\n",
            to: root.appendingPathComponent("Sources/Feature.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Feature.swift", nil)]
        )
        let didReschedule = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 2
        )
        XCTAssertTrue(didReschedule)
        let didReachRescheduledTerminalEligibility = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal,
            count: 2
        )
        XCTAssertTrue(didReachRescheduledTerminalEligibility)
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let superseded = try XCTUnwrap(events.first { $0.kind == .superseded }?.ordinal)
        let schedules = events.filter { $0.kind == .scheduled }
        XCTAssertEqual(schedules.count, 2)
        XCTAssertLessThan(superseded, schedules[1].ordinal)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)

        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: lifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        let didRescheduleAfterGap = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 3
        )
        XCTAssertTrue(didRescheduleAfterGap)
        let didReachTerminalAfterGap = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal,
            count: 3
        )
        XCTAssertTrue(didReachTerminalAfterGap)
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsAndDrainsBlockedProjectionPreloadLaunch() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let startGate = CodemapRootSuspensionGate()
        addTeardownBlock {
            await startGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .enabled)
        await store.setCodemapProjectionPreloadStartHandlerForTesting { rootEpoch in
            await startGate.enterAndWait(rootEpoch)
        }
        let loaded = try await store.loadRoot(path: root.path)
        let enteredRootEpoch = await startGate.waitUntilEntered()
        let rootEpoch = try XCTUnwrap(enteredRootEpoch)

        let unloadTask = Task { await store.unloadRoot(id: loaded.id) }
        let didCancel = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .cancelled
        )
        XCTAssertTrue(didCancel)
        let phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        let flightCount = await store.codemapEligibilityFlightCountForTesting()
        XCTAssertNil(phase)
        XCTAssertEqual(flightCount, 0)
        await startGate.release()
        await unloadTask.value
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
    }

    func testFirstProjectionPageLazilyPublishesRecordsOnlyShardAfterRootReady() async throws {
        let registrationGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: registrationGate)
        addTeardownBlock {
            await registrationGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let before = await store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(before.rootCatalogShards.publishedShardCount, 0)

        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let registrationEntered = await registrationGate.waitUntilEntered()
        XCTAssertTrue(registrationEntered)
        XCTAssertEqual(ticket.rootEpoch, rootEpoch)

        let page = try await projectionPage(
            fixture.registry.makeBindingCatalogClient()
                .readProjectionCatalogPage(WorkspaceCodemapProjectionCatalogPageRequest(
                    rootEpoch: ticket.rootEpoch,
                    token: nil,
                    cursor: nil,
                    maximumEntryCount: 16,
                    maximumPathByteCount: 4096
                ))
        )
        XCTAssertEqual(page.entries.map(\.identity.fileID), [file.id])
        let after = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(after.rootCatalogShards.roots.first { $0.rootID == loaded.id })
        XCTAssertEqual(after.rootCatalogShards.publishedShardCount, 1)
        XCTAssertEqual(shard.pathIndexBuildCount, 0)

        await registrationGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testLargeRootFirstProjectionShardBuildRunsOffActor() async throws {
        let registrationGate = CodemapResolutionGate()
        let catalogBuildGate = CodemapRootSuspensionGate()
        let responsivenessGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: registrationGate)
        addTeardownBlock {
            await responsivenessGate.release()
            await catalogBuildGate.release()
            await registrationGate.release()
            await fixture.shutdown()
        }
        var sourceFiles: [String: String] = [:]
        for index in 0 ..< 2048 {
            sourceFiles[String(format: "Sources/File%04d.swift", index)] =
                "struct File\(index) {}\n"
        }
        let root = try fixture.makePlainRoot(files: sourceFiles)
        let store = fixture.makeStore()
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await catalogBuildGate.enterAndWait(rootEpoch)
        }
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let diagnosticsBeforePage = await store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(diagnosticsBeforePage.rootCatalogShards.publishedShardCount, 0)
        let firstFile = await store.file(rootID: loaded.id, relativePath: "Sources/File0000.swift")
        let file = try XCTUnwrap(firstFile)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let registrationEntered = await registrationGate.waitUntilEntered()
        XCTAssertTrue(registrationEntered)
        XCTAssertEqual(ticket.rootEpoch, rootEpoch)

        let catalog = fixture.registry.makeBindingCatalogClient()
        let pageTask = Task {
            await catalog.readProjectionCatalogPage(WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 4,
                maximumPathByteCount: 4096
            ))
        }
        addTeardownBlock {
            pageTask.cancel()
            await responsivenessGate.release()
            await catalogBuildGate.release()
            await registrationGate.release()
        }
        let enteredCatalogBuildEpoch = await catalogBuildGate.waitUntilEntered(timeout: .seconds(10))
        guard enteredCatalogBuildEpoch == rootEpoch else {
            pageTask.cancel()
            await catalogBuildGate.release()
            XCTFail("Expected catalog shard build gate to enter \(rootEpoch), got \(String(describing: enteredCatalogBuildEpoch))")
            return
        }

        let responsivenessTask = Task {
            let roots = await store.roots()
            let availability = await store.rootScopeAvailability(.allLoaded)
            let content = try await store.readContent(
                rootID: loaded.id,
                relativePath: file.standardizedRelativePath
            )
            await responsivenessGate.enterAndWait()
            return (roots, availability, content)
        }
        let actorRemainedResponsive = await responsivenessGate.waitUntilEntered()
        await responsivenessGate.release()
        await catalogBuildGate.release()
        XCTAssertTrue(actorRemainedResponsive)
        let responsiveness = try await responsivenessTask.value
        XCTAssertEqual(responsiveness.0.map(\.id), [loaded.id])
        XCTAssertEqual(responsiveness.1, .available)
        XCTAssertEqual(responsiveness.2, sourceFiles[file.standardizedRelativePath])

        let page = try await projectionPage(pageTask.value)
        XCTAssertEqual(page.entries.count, 4)
        XCTAssertEqual(page.entries.first?.identity.standardizedRelativePath, "Sources/File0000.swift")
        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(diagnostics.rootCatalogShards.roots.first { $0.rootID == loaded.id })
        XCTAssertEqual(shard.pathIndexBuildCount, 0)

        await registrationGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testTransientEligibilityUsesOneAuthorityCheckedBackoffRetry() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 1000)
        let sleepGate = CodemapRetrySleepGate()
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 2,
            initialBackoffNanoseconds: 100,
            maximumBackoffNanoseconds: 400,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return preflightCount.value == 1
                    ? .transientUnavailable(.repositoryChanging)
                    : .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        let delay = try XCTUnwrap(observedDelay)
        XCTAssertEqual(delay, 100)
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: loaded.id, rootLifetimeID: lifetimeID)
        let retry = await store.codemapProjectionPreloadRetrySnapshotForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(retry?.attempt, 1)
        XCTAssertEqual(retry?.deadlineNanoseconds, 1100)
        XCTAssertEqual(preflightCount.value, 1)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let demandDuringBackoff = await store.requestCodemapArtifact(forFileID: file.id)
        guard case .unavailable(.busy) = demandDuringBackoff else {
            return XCTFail("Expected demand to respect the root retry backoff")
        }
        XCTAssertEqual(preflightCount.value, 1)

        clock.advance(by: 100)
        await sleepGate.releaseAll()
        let didRetry = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .retryStarted
        )
        let didTerminate = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didRetry)
        XCTAssertTrue(didTerminate)
        XCTAssertEqual(preflightCount.value, 2)
        let delays = await sleepGate.delays
        XCTAssertEqual(delays, [100])
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsBlockedPreloadRetrySleepWithoutManualRelease() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 10000)
        let sleepGate = CodemapRetrySleepGate()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 1,
            initialBackoffNanoseconds: 1000,
            maximumBackoffNanoseconds: 1000,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                .transientUnavailable(.repositoryChanging)
            },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        XCTAssertEqual(observedDelay, 1000)

        await store.unloadRoot(id: loaded.id)

        let roots = await store.roots()
        let delays = await sleepGate.delays
        XCTAssertTrue(roots.isEmpty)
        XCTAssertEqual(delays, [1000])
    }

    func testTransientSetupUsesOneBackoffThenFreshSetupRegistration() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 5000)
        let sleepGate = CodemapRetrySleepGate()
        let runtimeCalls = CodemapLockedCounter()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 2,
            initialBackoffNanoseconds: 250,
            maximumBackoffNanoseconds: 500,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                if runtimeCalls.incrementAndGet() == 1 {
                    throw WorkspaceCodemapBindingEngineProviderError.unconfigured
                }
                return try fixture.runtime()
            },
            codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
            codemapGitEligibilityProbe: .init { _ in .eligible },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicyForTesting: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        let delay = try XCTUnwrap(observedDelay)
        XCTAssertEqual(delay, 250)
        XCTAssertEqual(runtimeCalls.value, 1)

        clock.advance(by: 250)
        await sleepGate.releaseAll()
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)
        XCTAssertEqual(runtimeCalls.value, 2)
        let delays = await sleepGate.delays
        XCTAssertEqual(delays, [250])
        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.setupTasksCreated, 2)
        await store.unloadRoot(id: loaded.id)
    }

    func testExplicitMaterializationAndRepositoryAuthorityChangeRescheduleCurrentPreload() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didReachInitialTerminal = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachInitialTerminal)

        do {
            try await store.moveFile(
                rootID: loaded.id,
                from: "Sources/Missing.swift",
                to: "Sources/StillMissing.swift"
            )
            XCTFail("Expected missing move to fail")
        } catch {
            // The authority fence cancelled old work, so failure restores exactly one preload.
        }
        let restoredAfterFailedMove = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 2
        )
        XCTAssertTrue(restoredAfterFailedMove)

        let external = root.appendingPathComponent("Sources/External.swift")
        try Self.write("struct External {}\n", to: external)
        let materialized = try await store.materializeExplicitlyRequestedFile(
            external.path,
            rootScope: .allLoaded
        )
        guard case .materialized = materialized else {
            return XCTFail("Expected explicit materialization")
        }
        let materializationRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 3
        )
        XCTAssertTrue(materializationRescheduled)

        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/Created.swift",
            content: "struct Created {}\n"
        )
        let createRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 4
        )
        XCTAssertTrue(createRescheduled)

        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.folderModified(".git")]
        )
        let repositoryDetached = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .repositoryAuthorityDetached
        )
        let repositoryRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 5
        )
        XCTAssertTrue(repositoryDetached)
        XCTAssertTrue(repositoryRescheduled)
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let detachedOrdinal = try XCTUnwrap(events.last { $0.kind == .repositoryAuthorityDetached }?.ordinal)
        let lastScheduledOrdinal = try XCTUnwrap(events.last { $0.kind == .scheduled }?.ordinal)
        XCTAssertLessThan(detachedOrdinal, lastScheduledOrdinal)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testRepositoryLayoutChangeDetachesEngineSessionThenRegistersCurrentAuthority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let initialHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(initialHandOff)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Feature.swift" })
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: lifetimeID,
            deltas: [.folderModified(".git")]
        )
        let didDetach = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .repositoryAuthorityDetached
        )
        let didRegisterCurrentAuthority = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .handedOff,
            count: 2
        )
        XCTAssertTrue(didDetach)
        XCTAssertTrue(didRegisterCurrentAuthority)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.setupTasksCreated, 2)
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 2)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testStaleLifetimeRepositoryDeltaDoesNotAcquireFenceOrDetachCurrentAuthority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)
        let eventsBefore = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let countsBefore = await store.codemapPresentationOperationCountsForTesting()

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: UUID(),
            deltas: [.folderModified(".git")]
        )

        let eventsAfter = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let countsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(eventsAfter, eventsBefore)
        XCTAssertEqual(countsAfter.setupTasksCreated, countsBefore.setupTasksCreated)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testFirstExplicitDemandReturnsStableExactRootPendingTicketAndRegistersOnce() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let duplicateTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertNotEqual(firstTicket.retainID, duplicateTicket.retainID)
        XCTAssertEqual(firstTicket.requestID, duplicateTicket.requestID)
        XCTAssertEqual(firstTicket.rootEpoch, duplicateTicket.rootEpoch)
        XCTAssertEqual(firstTicket.fileID, duplicateTicket.fileID)
        XCTAssertEqual(firstTicket.requestGeneration, duplicateTicket.requestGeneration)
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let candidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(firstTicket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(candidate?.identity.fileID, file.id)
        XCTAssertEqual(candidate?.identity.rootID, loaded.id)
        XCTAssertEqual(candidate?.identity.rootLifetimeID, firstTicket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let resolutionCount = await gate.resolutionCount
        XCTAssertEqual(resolutionCount, 1)

        await gate.release()
        let settled = try await settledResult(store: store, ticket: firstTicket)
        assertNonGitTerminal(settled)
        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionCatalogPagesAndCallbacksRequireExactCurrentShard() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Zeta.swift": "struct Zeta {}\n",
            "Sources/Alpha.swift": "struct Alpha {}\n",
            "Sources/Unsupported.txt": "unsupported\n",
            "Sources/Beta.py": "class Beta:\n    pass\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let catalog = fixture.registry.makeBindingCatalogClient()
        let alphaPathByteCount = UInt64("Sources/Alpha.swift".utf8.count)
        let firstPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 2,
                maximumPathByteCount: alphaPathByteCount
            )
        ))
        XCTAssertEqual(firstPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Alpha.swift"])
        XCTAssertEqual(firstPage.pathByteCount, alphaPathByteCount)
        XCTAssertEqual(firstPage.supportedCandidateCountThroughPage, 1)
        XCTAssertFalse(firstPage.isEnd)
        XCTAssertEqual(firstPage.entries.first?.identity.rootID, loaded.id)
        XCTAssertEqual(firstPage.entries.first?.identity.rootLifetimeID, ticket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(firstPage.entries.first?.identity.standardizedRootPath, loaded.standardizedFullPath)

        let secondPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: XCTUnwrap(firstPage.nextCursor),
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertEqual(secondPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Beta.py"])
        XCTAssertEqual(secondPage.supportedCandidateCountThroughPage, 2)
        XCTAssertFalse(secondPage.isEnd)

        let thirdPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: XCTUnwrap(secondPage.nextCursor),
                maximumEntryCount: 8,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertEqual(thirdPage.entries.map(\.identity.standardizedRelativePath), ["Sources/Zeta.swift"])
        XCTAssertEqual(thirdPage.supportedCandidateCountThroughPage, 3)
        XCTAssertTrue(thirdPage.isEnd)
        XCTAssertNil(thirdPage.nextCursor)

        let currentToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            firstPage.token
        )
        XCTAssertEqual(currentToken, .current)
        let invalidCursorPage = await catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: firstPage.token,
                cursor: WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: "Sources/Alpha.swift",
                    fileID: UUID()
                ),
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        )
        XCTAssertEqual(invalidCursorPage, .stale)

        let namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32))
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: firstPage.token,
            repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken(
                authorityGeneration: 1,
                repositoryNamespace: namespace,
                objectFormat: .sha1,
                repositoryBindingEpoch: "repository",
                worktreeBindingEpoch: "worktree",
                layoutGeneration: "layout",
                indexGeneration: "index",
                checkoutConfigurationGeneration: "checkout",
                attributeGeneration: "attributes",
                sparseGeneration: "sparse",
                metadataGeneration: "metadata"
            ),
            contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 1)
        )
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: firstPage.entries[0].language,
            decoderPolicy: .workspaceAutomaticV1
        )
        let projectionEntry = WorkspaceCodemapProjectionEntry(
            identity: firstPage.entries[0].identity,
            requestGeneration: firstPage.entries[0].requestGeneration,
            pathGeneration: firstPage.entries[0].pathGeneration,
            pipelineIdentity: pipeline,
            outcome: .terminalExcluded(.securityExcluded)
        )
        let segmentByteCount: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: [projectionEntry]
        ) {
        case let .success(value):
            segmentByteCount = value
        case let .failure(error):
            return XCTFail("Unexpected segment byte accounting failure: \(error)")
        }
        let segmentProgress = WorkspaceCodemapProjectionProgress(
            phase: .publishingProjectionSegment,
            counts: WorkspaceCodemapProjectionCounts(
                supportedCandidateCount: 3,
                processedCandidateCount: 1,
                contributedCount: 0,
                emptyCount: 0,
                terminalArtifactCount: 0,
                terminalExcludedCount: 1,
                transientCount: 0
            ),
            catalogPageCount: 3,
            catalogPathByteCount: 0,
            publishedSegmentCount: 1,
            publishedSegmentByteCount: segmentByteCount,
            catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion(
                token: firstPage.token,
                finalCursor: WorkspaceCodemapProjectionCatalogCursor(
                    standardizedRelativePath: "Sources/Zeta.swift",
                    fileID: thirdPage.entries[0].identity.fileID
                ),
                supportedCandidateCount: 3
            )
        )
        let segment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 0,
            entries: [projectionEntry],
            progress: segmentProgress,
            byteCount: segmentByteCount
        ) {
        case let .success(value):
            segment = value
        case let .failure(error):
            return XCTFail("Unexpected segment validation failure: \(error)")
        }
        let accepted = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(accepted, .accepted(segmentProgress))

        let wrongPipeline = try SyntaxManager().pipelineIdentity(
            for: .python,
            decoderPolicy: .workspaceAutomaticV1
        )
        let wrongPipelineSegment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 1,
            entries: [WorkspaceCodemapProjectionEntry(
                identity: firstPage.entries[0].identity,
                requestGeneration: firstPage.entries[0].requestGeneration,
                pathGeneration: firstPage.entries[0].pathGeneration,
                pipelineIdentity: wrongPipeline,
                outcome: .terminalExcluded(.securityExcluded)
            )],
            progress: .notStarted,
            byteCount: 1
        ) {
        case let .success(value):
            wrongPipelineSegment = value
        case let .failure(error):
            return XCTFail("Unexpected wrong-pipeline segment validation failure: \(error)")
        }
        let wrongPipelineDisposition = await catalog.publishProjection(.segment(wrongPipelineSegment))
        XCTAssertEqual(wrongPipelineDisposition, .stale)

        await gate.release()
        try await assertNonGitTerminal(settledResult(store: store, ticket: ticket))
        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: alpha.standardizedRelativePath,
            newContent: "struct AlphaChanged {}\n"
        )

        let staleToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            firstPage.token
        )
        XCTAssertEqual(staleToken, .stale)
        let staleProjection = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(staleProjection, .stale)
        let refreshedPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        ))
        XCTAssertNotEqual(refreshedPage.token, firstPage.token)
        XCTAssertEqual(refreshedPage.entries.first?.pathGeneration, ticket.pathGeneration + 1)

        await store.unloadRoot(id: loaded.id)
        let supersededProjection = await catalog.publishProjection(.segment(segment))
        XCTAssertEqual(supersededProjection, .superseded)
        let unloadedToken = await catalog.revalidateProjectionCatalogToken(
            ticket.rootEpoch,
            refreshedPage.token
        )
        XCTAssertEqual(unloadedToken, .unavailable(.rootNotCurrent))
    }

    func testFrozenPresentationBundleRetainsReadyHandleLeaseAcrossAwaitAndRendersLogicalPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Alpha.swift": """
                protocol AlphaProtocol {
                    func alpha() -> String
                }

                struct Alpha: AlphaProtocol {
                    func alpha() -> String { "alpha" }
                }
                """,
                "Sources/Zeta.swift": """
                protocol ZetaProtocol {
                    func zeta() -> String
                }

                struct Zeta: ZetaProtocol {
                    func zeta() -> String { "zeta" }
                }
                """
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let suspensionGate = CodemapSuspensionGate()
        addTeardownBlock {
            await suspensionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let zeta = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Zeta.swift"
        })
        let alphaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let alphaArtifactKey: CodeMapArtifactKey
        do {
            let alphaReady = try await readyResult(
                settledResult(store: store, ticket: alphaTicket)
            )
            alphaArtifactKey = alphaReady.snapshot.artifactKey
        }
        let zetaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: zeta.id)
        )
        let zetaArtifactKey: CodeMapArtifactKey
        do {
            let zetaReady = try await readyResult(
                settledResult(store: store, ticket: zetaTicket)
            )
            zetaArtifactKey = zetaReady.snapshot.artifactKey
        }
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: root.path,
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedFullPath
        ))
        let alphaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        let zetaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: zeta.standardizedRelativePath
        ))
        let engine = try fixture.runtime().bindingEngine()
        let accountingBeforeFreeze = await engine.accounting()

        var callerBundle: WorkspaceCodemapFrozenPresentationBundle? = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: zetaTicket, logicalPath: zetaPath),
                WorkspaceCodemapPresentationRequest(ticket: alphaTicket, logicalPath: alphaPath)
            ])
        )
        do {
            let bundle = try XCTUnwrap(callerBundle)
            XCTAssertEqual(bundle.rootEpoch, alphaTicket.rootEpoch)
            XCTAssertEqual(
                bundle.entries.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey),
                [alphaArtifactKey, zetaArtifactKey]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey.pipelineIdentity),
                [
                    alphaArtifactKey.pipelineIdentity,
                    zetaArtifactKey.pipelineIdentity
                ]
            )

            let rendered = try await renderedPresentationEntries(
                store.renderCodemapPresentation(bundle)
            )
            XCTAssertEqual(
                rendered.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertTrue(rendered[0].text.contains("File: Logical Workspace/Sources/Alpha.swift"))
            XCTAssertTrue(rendered[1].text.contains("File: Logical Workspace/Sources/Zeta.swift"))
            XCTAssertFalse(rendered.contains { $0.text.contains(root.path) })
            XCTAssertTrue(rendered.allSatisfy { $0.tokenCount > 0 })

            let accountingAfterRender = await engine.accounting()
            XCTAssertEqual(
                accountingAfterRender.counters.validatedWorktreeReads,
                accountingBeforeFreeze.counters.validatedWorktreeReads
            )
            XCTAssertEqual(accountingAfterRender.counters.builds, accountingBeforeFreeze.counters.builds)
            XCTAssertEqual(
                accountingAfterRender.counters.manifestLoads,
                accountingBeforeFreeze.counters.manifestLoads
            )
            XCTAssertEqual(fixture.buildCount.value, 2)
        }
        var suspendedRenderTask: Task<WorkspaceCodemapPresentationRenderDisposition, Never>?
        if let bundle = callerBundle {
            suspendedRenderTask = Task { [bundle] in
                await suspensionGate.enterAndWait()
                return await store.renderCodemapPresentation(bundle)
            }
        }
        let suspensionEntered = await suspensionGate.waitUntilEntered()
        XCTAssertTrue(suspensionEntered)
        if let bundle = callerBundle {
            let bundleReleased = await store.releaseCodemapPresentation(bundle)
            XCTAssertTrue(bundleReleased)
        } else {
            XCTFail("The caller bundle must remain alive until its gated owner captures it.")
        }
        callerBundle = nil
        let didCancelAlphaDemand = await store.cancelCodemapArtifactDemand(alphaTicket)
        let didCancelZetaDemand = await store.cancelCodemapArtifactDemand(zetaTicket)
        XCTAssertTrue(didCancelAlphaDemand)
        XCTAssertTrue(didCancelZetaDemand)

        await store.unloadRoot(id: loaded.id)
        let runtime = try fixture.runtime()
        let leaseClock = ContinuousClock()
        let callerRetainedAccounting = await runtime.artifactStore.accounting()
        XCTAssertGreaterThanOrEqual(callerRetainedAccounting.activeLeaseCount, 2)
        XCTAssertGreaterThan(callerRetainedAccounting.activeLeaseBytes, 0)
        let expectedRemainingLeaseCount = callerRetainedAccounting.activeLeaseCount - 2

        await suspensionGate.release()
        let suspendedRender = await suspendedRenderTask?.value
        if let suspendedRender {
            assertPresentationRenderUnavailable(suspendedRender, equals: .bundleNotRetained)
        } else {
            XCTFail("The suspended caller render task must exist.")
        }
        suspendedRenderTask = nil

        let fullyReleasedDeadline = leaseClock.now.advanced(by: .seconds(2))
        var fullyReleasedAccounting = await runtime.artifactStore.accounting()
        while fullyReleasedAccounting.activeLeaseCount != expectedRemainingLeaseCount,
              leaseClock.now < fullyReleasedDeadline
        {
            try await Task.sleep(for: .milliseconds(25))
            fullyReleasedAccounting = await runtime.artifactStore.accounting()
        }
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseCount, expectedRemainingLeaseCount)
        XCTAssertLessThan(fullyReleasedAccounting.activeLeaseBytes, callerRetainedAccounting.activeLeaseBytes)
    }

    func testOperationPresentationCoordinatesMultiRootLogicalOutputAndReleasesAllRetains() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "physical-first-secret",
            files: ["Sources/First.swift": "protocol FirstProtocol { func first() -> String }\nstruct First: FirstProtocol { func first() -> String { \"first\" } }\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "physical-second-secret",
            files: ["Sources/Second.swift": "protocol SecondProtocol { func second() -> String }\nstruct Second: SecondProtocol { func second() -> String { \"second\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let secondFile = try XCTUnwrap(secondFiles.first)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [secondFile.id, firstFile.id], completeRootSet: false),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [
                    firstLoaded.id: "LogicalFirst",
                    secondLoaded.id: "LogicalSecond"
                ]
            )

        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.orderedEntries.count, 2)
        XCTAssertEqual(Set(presentation.orderedEntries.map(\.rootEpoch)).count, 2)
        XCTAssertEqual(
            presentation.orderedEntries.map(\.logicalPath.displayPath),
            ["LogicalFirst/Sources/First.swift", "LogicalSecond/Sources/Second.swift"]
        )
        XCTAssertTrue(presentation.orderedEntries.allSatisfy { $0.tokenCount == TokenCalculationService.estimateTokens(for: $0.text) })
        XCTAssertFalse(presentation.orderedEntries.contains { $0.text.contains(firstRoot.path) || $0.text.contains(secondRoot.path) })
        let receipt = try XCTUnwrap(presentation.publicationReceipt)
        for ticket in receipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in receipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationMixedReadyAndPendingPublishesReadyReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { func value() -> Int { 1 } }\n",
                "Sources/Pending.swift": "struct Pending { func value() -> Int { 2 } }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let pendingFileID = CodemapLockedValues<UUID>()
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            if pendingFileID.values.contains(ticket.fileID) {
                return .busy(retryAfterMilliseconds: 1000)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let ready = try XCTUnwrap(files.first { $0.name == "Ready.swift" })
        let pending = try XCTUnwrap(files.first { $0.name == "Pending.swift" })
        pendingFileID.append(pending.id)
        let warmResult = await store.requestCodemapArtifact(forFileID: ready.id)
        let warmReady: WorkspaceCodemapArtifactDemandReady
        switch warmResult {
        case let .ready(value):
            warmReady = value
        case let .pending(ticket):
            warmReady = try await readyResult(
                settledResult(store: store, ticket: ticket)
            )
        case let .unavailable(reason):
            XCTFail("Expected ready warm demand, got \(reason)")
            throw CodemapStoreTestError.timedOut
        }
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            ),
            beforePublicationRevalidation: { receipts.append($0) }
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [pending.id, ready.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case .partial = presentation.coverage else {
            return XCTFail("A ready sibling must remain publishable while another demand is pending")
        }
        XCTAssertEqual(presentation.orderedEntries.map(\.fileID), [ready.id])
        let receipt = try XCTUnwrap(receipts.values.first)
        XCTAssertEqual(receipt.candidates.map(\.fileID), [ready.id])
        XCTAssertEqual(receipt.demandTickets.map(\.fileID), [ready.id])
        XCTAssertTrue(receipt.bundles.allSatisfy { bundle in
            bundle.entries.allSatisfy { $0.ticket.fileID == ready.id }
        })
        _ = await store.cancelCodemapArtifactDemand(warmReady.ticket)
    }

    func testStaleEngineCompletionMapsToStaleCurrentness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Stale.swift": "struct Stale {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let demandResults = CodemapLockedCounter()
        let store = fixture.makeStore(demandResultHook: { _, result in
            demandResults.increment()
            if demandResults.value == 1 {
                return .rejected(.staleCompletion)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)

        let initial = await store.requestCodemapArtifact(forFileID: file.id)
        let result: WorkspaceCodemapArtifactDemandResult = switch initial {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        case .ready, .unavailable:
            initial
        }

        assertStale(result)

        let retryInitial = await store.requestCodemapArtifact(forFileID: file.id)
        let retryResult: WorkspaceCodemapArtifactDemandResult = switch retryInitial {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        case .ready, .unavailable:
            retryInitial
        }
        let ready = try readyResult(retryResult)
        XCTAssertEqual(demandResults.value, 2)
        _ = await store.cancelCodemapArtifactDemand(ready.ticket)
    }

    func testStructureSeedDemandLimitRejectsBeforeRuntimeOrBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        XCTAssertEqual(files.count, 2)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumCandidateDemandCount: 1
            )
        )
        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: files.map(\.id),
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(presentation.outcome, .budget)
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(presentation.resolvedSeedCount, 0)
        XCTAssertTrue(presentation.issues.contains {
            if case .seedDemandLimit(attempted: 2, limit: 1) = $0 { return true }
            return false
        })
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            operationsAfter.structureSeedAdmissionRequests - operationsBefore.structureSeedAdmissionRequests,
            1
        )
        XCTAssertEqual(
            operationsAfter.selectedMetadataResolutionRequests - operationsBefore.selectedMetadataResolutionRequests,
            0
        )
        XCTAssertEqual(
            operationsAfter.presentationCandidateRequests - operationsBefore.presentationCandidateRequests,
            0
        )
        XCTAssertEqual(operationsAfter.artifactDemandRequests - operationsBefore.artifactDemandRequests, 0)
        XCTAssertEqual(operationsAfter.presentationFreezeRequests - operationsBefore.presentationFreezeRequests, 0)
        XCTAssertEqual(operationsAfter.setupTasksCreated - operationsBefore.setupTasksCreated, 0)
        XCTAssertEqual(operationsAfter.demandTasksCreated - operationsBefore.demandTasksCreated, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testStructureSeedAdmissionIgnoresStaleAndOutOfScopeSeedsWithoutLosingIssues() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let allowedRootURL = try repositoryFixture.makeRepository(
            named: "allowed",
            files: ["Sources/Allowed.swift": "struct Allowed {}\n"]
        )
        let outsideRootURL = try repositoryFixture.makeRepository(
            named: "outside",
            files: ["Sources/Outside.swift": "struct Outside {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let allowedRoot = try await store.loadRoot(path: allowedRootURL.path)
        let outsideRoot = try await store.loadRoot(path: outsideRootURL.path)
        let allowedFiles = await store.files(inRoot: allowedRoot.id)
        let outsideFiles = await store.files(inRoot: outsideRoot.id)
        let allowedFile = try XCTUnwrap(allowedFiles.first)
        let outsideFile = try XCTUnwrap(outsideFiles.first)
        let staleFileID = UUID()
        let allowedRootRef = WorkspaceRootRef(
            id: allowedRoot.id,
            name: allowedRoot.name,
            fullPath: allowedRoot.standardizedFullPath
        )
        let rootScope = WorkspaceLookupRootScope.validatedSessionBoundWorkspace(
            canonicalRoots: [allowedRootRef],
            physicalRoots: [allowedRootRef]
        )
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumCandidateDemandCount: 1
            )
        )
        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [staleFileID, outsideFile.id, allowedFile.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 1,
                maximumEdgeCount: 1,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 1, maximumCodemapTokenCount: 0),
            rootScope: rootScope
        )

        XCTAssertFalse(presentation.issues.contains {
            if case .seedDemandLimit = $0 { return true }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case let .candidate(.fileNotCataloged(fileID)) = $0 {
                return fileID == staleFileID
            }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case let .candidate(.fileOutsideRootScope(fileID)) = $0 {
                return fileID == outsideFile.id
            }
            return false
        })
        XCTAssertTrue(presentation.issues.contains {
            if case .tokenLimit = $0 { return true }
            return false
        })
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            operationsAfter.structureSeedAdmissionRequests - operationsBefore.structureSeedAdmissionRequests,
            1
        )
        XCTAssertEqual(
            operationsAfter.presentationCandidateRequests - operationsBefore.presentationCandidateRequests,
            1
        )
        XCTAssertEqual(operationsAfter.artifactDemandRequests - operationsBefore.artifactDemandRequests, 0)
        XCTAssertEqual(operationsAfter.presentationFreezeRequests - operationsBefore.presentationFreezeRequests, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testStructurePresentationSeedUsesPairedCodemapRenderAndReleasesReceiptResources() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let releasedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            releasedTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .structurePresentation(
                seedFileIDs: [file.id],
                direction: nil,
                traversalLimits: .init(
                    maximumDepth: 0,
                    maximumNodeCount: 10,
                    maximumEdgeCount: 10,
                    maximumByteCount: 4096
                ),
                outputLimits: .init(
                    maximumFileCount: 10,
                    maximumCodemapTokenCount: 6000
                ),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
            )

        XCTAssertEqual(presentation.outcome, .ready)
        let rendered = try XCTUnwrap(presentation.entries.first)
        XCTAssertTrue(rendered.isSeed)
        XCTAssertEqual(rendered.depth, 0)
        XCTAssertEqual(rendered.entry.logicalPath.displayPath, "Logical/Sources/Feature.swift")
        XCTAssertEqual(rendered.entry.tokenCount, TokenCalculationService.estimateTokens(for: rendered.entry.text))
        XCTAssertFalse(rendered.entry.text.contains(root.path))
        let ticket = try XCTUnwrap(releasedTickets.values.last)
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testStructureWarmPublishedArtifactBypassesDemandFreezeGraphAndGitIdentity() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(store: store)
        let traversalLimits = WorkspaceCodemapStructureTraversalLimits(
            maximumDepth: 0,
            maximumNodeCount: 10,
            maximumEdgeCount: 10,
            maximumByteCount: 4096
        )
        let outputLimits = WorkspaceCodemapStructureOutputLimits(
            maximumFileCount: 10,
            maximumCodemapTokenCount: 6000
        )

        let published = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        XCTAssertEqual(published.outcome, .ready)

        let rendered = try XCTUnwrap(published.entries.first)
        let markerCleared = await store.clearCodemapMarkerReadinessForTesting(
            rootEpoch: rendered.entry.rootEpoch,
            fileID: file.id
        )
        XCTAssertTrue(markerCleared)
        let clearedMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let clearedMarkerSnapshot = try XCTUnwrap(clearedMarkerSnapshotValue)
        XCTAssertTrue(clearedMarkerSnapshot.changes.isEmpty)

        let operationsBefore = await store.codemapPresentationOperationCountsForTesting()
        let engine = try fixture.runtime().bindingEngine()
        let engineBefore = await engine.accounting()
        let buildCountBefore = fixture.buildCount.value
        let firstWarm = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        let firstMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let firstMarkerSnapshot = try XCTUnwrap(firstMarkerSnapshotValue)
        let secondWarm = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: traversalLimits,
            outputLimits: outputLimits,
            rootScope: .allLoaded,
            logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
        )
        let secondMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rendered.entry.rootEpoch
        )
        let secondMarkerSnapshot = try XCTUnwrap(secondMarkerSnapshotValue)
        let operationsAfter = await store.codemapPresentationOperationCountsForTesting()
        let engineAfter = await engine.accounting()

        for warm in [firstWarm, secondWarm] {
            XCTAssertEqual(warm.outcome, .ready)
            XCTAssertEqual(warm.entries.map(\.entry.logicalPath.displayPath), ["Logical/Sources/Feature.swift"])
            XCTAssertEqual(warm.entries.map(\.entry.text), published.entries.map(\.entry.text))
        }
        XCTAssertEqual(firstMarkerSnapshot.revision, clearedMarkerSnapshot.revision + 1)
        XCTAssertEqual(firstMarkerSnapshot.changes.map(\.fileID), [file.id])
        XCTAssertEqual(firstMarkerSnapshot.changes.first?.state, .ready)
        XCTAssertEqual(secondMarkerSnapshot.revision, firstMarkerSnapshot.revision)
        XCTAssertEqual(secondMarkerSnapshot.changes, firstMarkerSnapshot.changes)
        XCTAssertEqual(operationsAfter, operationsBefore)
        XCTAssertEqual(fixture.buildCount.value, buildCountBefore)
        XCTAssertEqual(engineAfter.counters.capabilityResolutions, engineBefore.counters.capabilityResolutions)
        XCTAssertEqual(engineAfter.counters.classifications, engineBefore.counters.classifications)
        XCTAssertEqual(engineAfter.counters.manifestLoads, engineBefore.counters.manifestLoads)
        XCTAssertEqual(engineAfter.counters.manifestWrites, engineBefore.counters.manifestWrites)
        XCTAssertEqual(engineAfter.counters.builds, engineBefore.counters.builds)
        XCTAssertEqual(engineAfter.counters.materializations, engineBefore.counters.materializations)
        XCTAssertEqual(engineAfter.counters.validatedWorktreeReads, engineBefore.counters.validatedWorktreeReads)
        XCTAssertEqual(engineAfter.counters.projectionPreloadsStarted, engineBefore.counters.projectionPreloadsStarted)
        XCTAssertEqual(engineAfter.counters.projectionCatalogPages, engineBefore.counters.projectionCatalogPages)
        XCTAssertEqual(engineAfter.counters.projectionSegmentsPublished, engineBefore.counters.projectionSegmentsPublished)
        XCTAssertEqual(engineAfter.counters.projectionBuildsStarted, engineBefore.counters.projectionBuildsStarted)
        XCTAssertEqual(engineAfter.activeRequestCount, engineBefore.activeRequestCount)
        XCTAssertEqual(engineAfter.projectionJobCount, engineBefore.projectionJobCount)
        XCTAssertEqual(
            engineAfter.counters.publishedArtifactProjectionCASHits,
            engineBefore.counters.publishedArtifactProjectionCASHits + 2
        )
    }

    func testStructurePublicationRevocationRetriesThenReturnsTypedStale() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let publicationCount = CodemapLockedCounter()
        let structureAttempts = CodemapLockedValues<Int>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            ),
            beforePublicationRevalidation: { _ in
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            },
            structureAttemptDidBegin: { structureAttempts.append($0) }
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(
            presentation.outcome,
            .stale,
            "issues=\(presentation.issues), publications=\(publicationCount.value)"
        )
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(structureAttempts.values, [0, 1])
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertTrue(presentation.issues.contains {
            if case .publicationStale = $0 { return true }
            return false
        })
    }

    func testOperationPresentationRevocationBeforePublicationRetriesAndReturnsIncomplete() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "protocol FeatureProtocol { func feature() -> String }\nstruct Feature: FeatureProtocol { func feature() -> String { \"feature\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let publicationCount = CodemapLockedCounter()
        let operationCount = CodemapLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            beforePublicationRevalidation: { receipt in
                receipts.append(receipt)
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            }
        )

        let presentation = try await coordinator.withPresentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        ) { presentation in
            operationCount.increment()
            return presentation
        }

        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        guard case .unavailable = presentation.coverage else {
            return XCTFail("Revoked publication must return typed incomplete coverage")
        }
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertEqual(operationCount.value, 2)
        let firstReceipt = try XCTUnwrap(receipts.values.first)
        for ticket in firstReceipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in firstReceipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationCancellationDuringPendingWaitReleasesOwnedDemandOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let waiterGate = CodemapSuspensionGate()
        let cleanupGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await cleanupGate.release()
            await waiterGate.release()
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
            await cleanupGate.enterAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            waiter: WorkspaceCodemapPresentationWaiter { _ in
                await waiterGate.enterAndWait()
                try Task.checkCancellation()
            }
        )
        let task = Task {
            try await coordinator.presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        }

        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let waiterEntered = await waiterGate.waitUntilEntered()
        XCTAssertTrue(waiterEntered)
        task.cancel()
        await waiterGate.release()
        await resolutionGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let cleanupEntered = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupEntered)
        let cancelledTicket = try XCTUnwrap(cancelledTickets.values.first)
        XCTAssertEqual(cancelledTickets.values.count, 1)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(cancelledTicket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: cancelledTicket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
        await cleanupGate.release()
    }

    func testScopedOperationCancellationAfterRenderReleasesDemandAndPresentationOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct ScopedCancellationFeature { func renderable() {} }\n"]
        )
        let operationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await operationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let operationReceiptTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(store: store)
        let task = Task {
            try await coordinator.withPresentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            ) { presentation in
                XCTAssertEqual(presentation.orderedEntries.count, 1)
                let receipt = try XCTUnwrap(presentation.publicationReceipt)
                XCTAssertEqual(receipt.demandTickets.count, 1)
                let receiptTicket = try XCTUnwrap(receipt.demandTickets.first)
                operationReceiptTickets.append(receiptTicket)
                await operationGate.enterAndWait()
                try Task.checkCancellation()
                return presentation
            }
        }

        let operationEntered = await operationGate.waitUntilEntered()
        XCTAssertTrue(operationEntered)
        task.cancel()
        await operationGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let receiptTicket = try XCTUnwrap(operationReceiptTickets.values.first)
        XCTAssertEqual(operationReceiptTickets.values.count, 1)
        let cleanupTickets = cancelledTickets.values
        XCTAssertLessThanOrEqual(cleanupTickets.count, 1)
        if let cleanupTicket = cleanupTickets.first {
            XCTAssertEqual(cleanupTicket, receiptTicket)
        }
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(receiptTicket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: receiptTicket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testOperationPresentationPendingIsTypedAndReleasedWithoutFallback() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            )
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case let .pending(issues) = presentation.coverage else {
            return XCTFail("Expected typed pending coverage")
        }
        let ticket = try XCTUnwrap(issues.compactMap { issue -> WorkspaceCodemapArtifactDemandTicket? in
            if case let .pending(_, ticket) = issue { return ticket }
            return nil
        }.first)
        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        XCTAssertNil(presentation.publicationReceipt)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
        await resolutionGate.release()
    }

    func testPresentationFreezeRejectsPendingForeignEpochDuplicateAndLogicalPathMismatch() async throws {
        let resolutionGate = CodemapResolutionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: firstFile.standardizedRelativePath
        ))
        let secondPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Second Logical Root",
            standardizedRelativePath: secondFile.standardizedRelativePath
        ))
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .pending(firstTicket)
        )

        await resolutionGate.release()
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: secondTicket, logicalPath: secondPath)
            ]),
            equals: .mixedRootEpoch
        )
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .duplicateFileID(firstFile.id)
        )

        let mismatchedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: "Sources/Elsewhere.swift"
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstTicket,
                    logicalPath: mismatchedPath
                )
            ]),
            equals: .logicalPathMismatch(firstFile.id)
        )

        let unretainedEntry = WorkspaceCodemapFrozenPresentationEntry(
            ticket: firstTicket,
            logicalPath: firstPath,
            artifactKey: firstReady.snapshot.artifactKey,
            outcome: firstReady.snapshot.outcome
        )
        let unretainedBundle = WorkspaceCodemapFrozenPresentationBundle(
            rootEpoch: firstTicket.rootEpoch,
            entries: [unretainedEntry],
            handles: [firstReady.handle]
        )
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unretainedBundle),
            equals: .bundleNotRetained
        )

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": "struct Plain {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: plainFile.id)
        )
        let plainSettled = try await settledResult(store: store, ticket: plainTicket)
        assertNonGitTerminal(plainSettled)
        let plainPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Plain Logical Root",
            standardizedRelativePath: plainFile.standardizedRelativePath
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: plainTicket, logicalPath: plainPath)
            ]),
            equals: .demandUnavailable(plainTicket, .gitTerminal(.nonGit))
        )

        let validBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ])
        )
        let validBundleReleased = await store.releaseCodemapPresentation(validBundle)
        XCTAssertTrue(validBundleReleased)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testPresentationRenderFailsClosedAfterDemandCancellationCatalogAdvanceAndUnload() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let cancellationRoot = try repositoryFixture.makeRepository(
            named: "cancellation",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let catalogRoot = try repositoryFixture.makeRepository(
            named: "catalog",
            files: ["Sources/Catalog.swift": "struct Catalog {}\n"]
        )
        let unloadRoot = try repositoryFixture.makeRepository(
            named: "unload",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let cancellationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await cancellationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(cancellationCleanupHook: { _ in
            await cancellationGate.enterAndWait()
        })

        let cancellationLoaded = try await store.loadRoot(path: cancellationRoot.path)
        let cancellationFiles = await store.files(inRoot: cancellationLoaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(cancellationFiles.count, 2)
        let firstCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[0].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: firstCancellationTicket)
        )
        let secondCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[1].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: secondCancellationTicket)
        )
        let cancellationBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[0].standardizedRelativePath
                    ))
                ),
                WorkspaceCodemapPresentationRequest(
                    ticket: secondCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[1].standardizedRelativePath
                    ))
                )
            ])
        )

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(firstCancellationTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(cancellationBundle),
            equals: .bundleNotRetained
        )
        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)

        let catalogLoaded = try await store.loadRoot(path: catalogRoot.path)
        let catalogFiles = await store.files(inRoot: catalogLoaded.id)
        let catalogFile = try XCTUnwrap(catalogFiles.first)
        let catalogTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: catalogFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: catalogTicket))
        let catalogPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Catalog Logical Root",
            standardizedRelativePath: catalogFile.standardizedRelativePath
        ))
        let releaseBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let catalogBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let firstRelease = await store.releaseCodemapPresentation(releaseBundle)
        let secondRelease = await store.releaseCodemapPresentation(releaseBundle)
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(secondRelease)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(releaseBundle),
            equals: .bundleNotRetained
        )

        try Self.write(
            "struct Added {}\n",
            to: catalogRoot.appendingPathComponent("Sources/Added.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            catalogRoot.appendingPathComponent("Sources/Added.swift").path
        ])
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(catalogBundle),
            equals: .bundleNotRetained
        )

        let unloadLoaded = try await store.loadRoot(path: unloadRoot.path)
        let unloadFiles = await store.files(inRoot: unloadLoaded.id)
        let unloadFile = try XCTUnwrap(unloadFiles.first)
        let unloadTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unloadFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: unloadTicket))
        let unloadBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: unloadTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Unload Logical Root",
                        standardizedRelativePath: unloadFile.standardizedRelativePath
                    ))
                )
            ])
        )
        await store.unloadRoot(id: unloadLoaded.id)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unloadBundle),
            equals: .bundleNotRetained
        )

        await store.unloadRoot(id: cancellationLoaded.id)
        await store.unloadRoot(id: catalogLoaded.id)
    }

    func testReadyPublicationsTargetFreezeIndividuallyAndCoalesceOneRootGraphFreeze() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let graphGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(files.count, 2)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: files[0].id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: files[1].id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        let blockedCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(blockedCounts.targetedReadyFreezes, 2)
        XCTAssertEqual(blockedCounts.graphBatchSignals, 2)
        XCTAssertEqual(blockedCounts.graphBatchFlushes, 0)
        XCTAssertEqual(blockedCounts.fullRootGraphFreezes, 0)
        XCTAssertEqual(blockedCounts.graphWorkerStarts, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await graphGate.release()
        let graphPublished = await graphProbe.waitUntilPublished(rootEpoch: firstTicket.rootEpoch)
        XCTAssertTrue(graphPublished)

        let publishedCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(publishedCounts.targetedReadyFreezes, 2)
        XCTAssertEqual(publishedCounts.graphBatchSignals, 2)
        XCTAssertEqual(publishedCounts.graphBatchFlushes, 1)
        XCTAssertEqual(publishedCounts.fullRootGraphFreezes, 1)
        XCTAssertEqual(publishedCounts.graphWorkerStarts, 1)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsBlockedGraphPublicationFlightWithoutLateWorker() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let graphGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        await store.unloadRoot(id: loaded.id)

        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.targetedReadyFreezes, 1)
        XCTAssertEqual(counts.fullRootGraphFreezes, 0)
        XCTAssertEqual(counts.graphWorkerStarts, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testReadyArtifactProducesFileTreeMarkerBeforeGraphPublication() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Target {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let graphGate = CodemapGraphPublicationGate()
        addTeardownBlock {
            await graphGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            graphPublicationWaiter: { rootEpoch in
                await graphGate.enterAndWait(rootEpoch)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        let graphWaiterEntered = await graphGate.waitUntilInvocationCount(1)
        XCTAssertTrue(graphWaiterEntered)

        let markerBeforeTreeValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let markerBeforeTree = try XCTUnwrap(markerBeforeTreeValue)
        XCTAssertEqual(markerBeforeTree.changes.map(\.fileID), [file.id])
        let engineBeforeTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: loaded.id
        )
        let engineBeforeTree = try XCTUnwrap(engineBeforeTreeValue)
        let buildCountBeforeTree = fixture.buildCount.value
        let graphFactoryCountBeforeTree = graphProbe.factoryCount
        let countsBeforeTree = await store.codemapPresentationOperationCountsForTesting()

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(
                rootScope: .allLoaded,
                bindingProjection: nil
            )
        )

        XCTAssertTrue(tree.content.contains("Feature.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("(+ denotes code-map available)"), tree.content)
        XCTAssertEqual(fixture.buildCount.value, buildCountBeforeTree)
        let markerAfterTree = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(markerAfterTree?.revision, markerBeforeTree.revision)
        XCTAssertEqual(markerAfterTree?.changes, markerBeforeTree.changes)
        let engineAfterTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: loaded.id
        )
        let engineAfterTree = try XCTUnwrap(engineAfterTreeValue)
        XCTAssertEqual(engineAfterTree, engineBeforeTree)
        let countsAfterTree = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(countsAfterTree, countsBeforeTree)
        XCTAssertEqual(graphProbe.factoryCount, graphFactoryCountBeforeTree)

        await graphGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testGetFileTreeCurrentSnapshotDoesNotAwaitOrRetainBlockedCodemapDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            resolutionGate: resolutionGate,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let markerReady = expectation(description: "marker readiness published")
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let readinessObservation = Task {
            for await event in readinessStream
                where event.rootEpoch == ticket.rootEpoch && event.changes.contains(where: {
                    $0.fileID == file.id && $0.state == .ready
                })
            {
                markerReady.fulfill()
                return
            }
        }

        let countsBeforePendingTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountBeforePendingTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let request = WorkspaceFileTreePresentationRequest(
            mode: .full,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: false,
            showCodeMapMarkers: true,
            rootScope: .allLoaded
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: .allLoaded,
            bindingProjection: nil
        )

        let pendingTreeClock = ContinuousClock()
        let pendingTreeDeadline = pendingTreeClock.now.advanced(by: .seconds(1))
        let pendingTreeCompletion = CodemapBoundedCompletionState()
        let pendingTreeTask = Task {
            let tree = await store.makeCurrentSnapshotFileTreePresentation(
                selection: StoredSelection(),
                request: request,
                lookupContext: lookupContext,
                profile: .mcpRead
            )
            pendingTreeCompletion.recordCompletion(
                beforeDeadline: pendingTreeClock.now < pendingTreeDeadline
            )
            return tree
        }
        let pendingTreeCompleted = await waitForCompletionBeforeExternalDeadline(
            pendingTreeCompletion,
            clock: pendingTreeClock,
            deadline: pendingTreeDeadline
        )
        guard pendingTreeCompleted else {
            await resolutionGate.release()
            pendingTreeTask.cancel()
            let drained = await waitForBoundedCompletionDrain(pendingTreeCompletion)
            readinessObservation.cancel()
            await readinessObservation.value
            return XCTFail(
                "File-tree render awaited blocked codemap demand; bounded drain completed: \(drained)."
            )
        }
        let pendingTree = await pendingTreeTask.value

        XCTAssertTrue(pendingTree.content.contains("Feature.swift"), pendingTree.content)
        XCTAssertFalse(pendingTree.content.contains("Feature.swift +"), pendingTree.content)
        let countsAfterPendingTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountAfterPendingTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(countsAfterPendingTree, countsBeforePendingTree)
        XCTAssertEqual(retainCountAfterPendingTree, retainCountBeforePendingTree)

        await resolutionGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        await fulfillment(of: [markerReady], timeout: 1)
        readinessObservation.cancel()
        await readinessObservation.value
        let countsBeforeReadyTree = await store.codemapPresentationOperationCountsForTesting()
        let readyTree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: request,
            lookupContext: lookupContext,
            profile: .mcpRead
        )

        XCTAssertTrue(readyTree.content.contains("Feature.swift +"), readyTree.content)
        let countsAfterReadyTree = await store.codemapPresentationOperationCountsForTesting()
        let retainCountAfterReadyTree = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        // Ready demand publication owns graph publication asynchronously. While the passive
        // file-tree render awaits snapshot/logical-root work, already-scheduled graph
        // publication may advance. This path must still avoid demand, presentation, and
        // retain work.
        XCTAssertEqual(
            countsAfterReadyTree.structureSeedAdmissionRequests,
            countsBeforeReadyTree.structureSeedAdmissionRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.selectedMetadataResolutionRequests,
            countsBeforeReadyTree.selectedMetadataResolutionRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.presentationCandidateRequests,
            countsBeforeReadyTree.presentationCandidateRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.artifactDemandRequests,
            countsBeforeReadyTree.artifactDemandRequests
        )
        XCTAssertEqual(
            countsAfterReadyTree.presentationFreezeRequests,
            countsBeforeReadyTree.presentationFreezeRequests
        )
        XCTAssertEqual(countsAfterReadyTree.setupTasksCreated, countsBeforeReadyTree.setupTasksCreated)
        XCTAssertEqual(countsAfterReadyTree.demandTasksCreated, countsBeforeReadyTree.demandTasksCreated)
        XCTAssertEqual(
            countsAfterReadyTree.targetedReadyFreezes,
            countsBeforeReadyTree.targetedReadyFreezes
        )
        XCTAssertEqual(retainCountAfterReadyTree, retainCountBeforePendingTree)

        _ = await store.cancelCodemapArtifactDemand(ticket)
        await store.unloadRoot(id: loaded.id)
    }

    func testGetFileTreeCurrentSnapshotOmitsMarkerForReadyNoSymbols() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Empty.swift": "// no symbols\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        XCTAssertEqual(ready.snapshot.outcome, .readyNoSymbols)
        _ = await store.cancelCodemapArtifactDemand(ticket)
        let firstMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let firstMarkerSnapshot = try XCTUnwrap(firstMarkerSnapshotValue)

        let repeatedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let repeatedReady = try await readyResult(settledResult(store: store, ticket: repeatedTicket))
        XCTAssertEqual(repeatedReady.snapshot.outcome, .readyNoSymbols)
        _ = await store.cancelCodemapArtifactDemand(repeatedTicket)
        let repeatedMarkerSnapshotValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: ticket.rootEpoch
        )
        let repeatedMarkerSnapshot = try XCTUnwrap(repeatedMarkerSnapshotValue)
        XCTAssertEqual(
            repeatedMarkerSnapshot.revision,
            firstMarkerSnapshot.revision,
            "Every marker event advances revision; repeated readyNoSymbols must emit neither."
        )
        XCTAssertEqual(repeatedMarkerSnapshot.changes, firstMarkerSnapshot.changes)
        let countsBeforeTree = await store.codemapPresentationOperationCountsForTesting()

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: true,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(
                rootScope: .allLoaded,
                bindingProjection: nil
            ),
            profile: .mcpRead
        )

        XCTAssertTrue(tree.content.contains("Empty.swift"), tree.content)
        XCTAssertFalse(tree.content.contains("Empty.swift +"), tree.content)
        let countsAfterTree = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(countsAfterTree, countsBeforeTree)

        await store.unloadRoot(id: loaded.id)
    }

    func testDurableProjectionPublishesMarkerReadinessAfterDemandRelease() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let readinessPublished = expectation(description: "durable marker readiness published")
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let readinessObservation = Task {
            for await event in readinessStream
                where event.rootEpoch.rootID == loaded.id && event.changes.contains(where: {
                    $0.fileID == file.id && $0.state == .ready
                })
            {
                readinessPublished.fulfill()
                return
            }
        }

        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        _ = await store.cancelCodemapArtifactDemand(ticket)
        await fulfillment(of: [readinessPublished], timeout: 1)
        readinessObservation.cancel()
        await readinessObservation.value

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("Feature.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionManifestFailureDoesNotPublishMarkerReadiness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let manifestFailureCount = CodemapLockedCounter()
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true,
            manifestStoreFaultAction: { point in
                guard point == .afterTemporaryWrite else { return .proceed }
                manifestFailureCount.increment()
                return .simulateProcessTermination
            }
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )

        let completeCoverage = await graphProbe.waitUntilCompleteCoverage(rootEpoch: rootEpoch)
        XCTAssertTrue(completeCoverage)
        XCTAssertGreaterThan(manifestFailureCount.value, 0)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("Feature.swift"), tree.content)
        XCTAssertFalse(tree.content.contains("Feature.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionManifestFailureRecoveredByLaterBatchPublishesAllMarkers() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let repositoryFiles = [
            "File000.swift": "struct Target000 {}\n",
            "File010.swift": "struct Target010 {}\n"
        ]
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let manifestWriteAttempts = CodemapManifestWriteAttemptLatch()
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true,
            bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy(
                maximumQueuedProjectionManifestMutationByteCountPerRoot: 8 * 1024,
                maximumQueuedProjectionManifestMutationByteCount: 64 * 1024
            ),
            manifestStoreFaultAction: { point in
                guard point == .afterTemporaryWrite else { return .proceed }
                return manifestWriteAttempts.recordAttempt() == 1
                    ? .simulateProcessTermination
                    : .proceed
            }
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let readinessStream = await store.codemapMarkerReadinessUpdates()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "File000.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "File010.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let observedFirstWrite = await manifestWriteAttempts.waitForAttemptCount(1, timeout: .seconds(5))
        guard observedFirstWrite else {
            await store.unloadRoot(id: loaded.id)
            return XCTFail("Explicit engine admission produced zero manifest writes.")
        }

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let recoveredMarkers = expectation(description: "failed manifest batch recovered by later persistence")
        let readinessObservation = Task {
            var firstReady = false
            var secondReady = false
            for await event in readinessStream where event.rootEpoch == firstTicket.rootEpoch {
                for change in event.changes where change.state == .ready {
                    if change.fileID == firstTicket.fileID,
                       change.standardizedRelativePath == first.standardizedRelativePath,
                       change.requestGeneration == firstTicket.requestGeneration,
                       change.pathGeneration == firstTicket.pathGeneration
                    {
                        firstReady = true
                    }
                    if change.fileID == secondTicket.fileID,
                       change.standardizedRelativePath == second.standardizedRelativePath,
                       change.requestGeneration == secondTicket.requestGeneration,
                       change.pathGeneration == secondTicket.pathGeneration
                    {
                        secondReady = true
                    }
                }
                if firstReady, secondReady {
                    recoveredMarkers.fulfill()
                    return
                }
            }
        }
        let observedRecoveryWrite = await manifestWriteAttempts.waitForAttemptCount(2, timeout: .seconds(5))
        XCTAssertTrue(
            observedRecoveryWrite,
            "Recovery requires a later durable manifest write after the injected first failure."
        )
        await fulfillment(of: [recoveredMarkers], timeout: 5)
        readinessObservation.cancel()
        await readinessObservation.value

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("File000.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("File010.swift +"), tree.content)

        _ = await store.cancelCodemapArtifactDemand(firstTicket)
        _ = await store.cancelCodemapArtifactDemand(secondTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testTargetedInvalidationClearsOnlyAffectedMarkerReadiness() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Changed.swift": "struct Changed {}\n",
                "Sources/Stable.swift": "struct Stable {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let changed = try XCTUnwrap(files.first { $0.name == "Changed.swift" })
        let stable = try XCTUnwrap(files.first { $0.name == "Stable.swift" })
        for file in [changed, stable] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }

        try Self.write(
            "struct Changed { let edited = true }\n",
            to: root.appendingPathComponent("Sources/Changed.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Changed.swift", nil)]
        )

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertFalse(tree.content.contains("Changed.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("Stable.swift +"), tree.content)

        await store.unloadRoot(id: loaded.id)
    }

    func testMarkerReadinessIgnoresCrossRootAndStaleEpochUpdates() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRootURL = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRootURL = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let firstRoot = try await store.loadRoot(path: firstRootURL.path)
        let secondRoot = try await store.loadRoot(path: secondRootURL.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: firstFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: ticket))
        _ = await store.cancelCodemapArtifactDemand(ticket)

        let firstLifetimeID = try await store.rootLifetimeIDForTesting(rootID: firstRoot.id)
        let firstEpoch = WorkspaceCodemapRootEpoch(
            rootID: firstRoot.id,
            rootLifetimeID: firstLifetimeID
        )
        let crossRootAccepted = await store.acceptCodemapMarkerReadinessUpdateForTesting(
            WorkspaceCodemapMarkerReadinessUpdate(
                rootEpoch: firstEpoch,
                changes: [
                    WorkspaceCodemapMarkerReadinessChange(
                        fileID: secondFile.id,
                        standardizedRelativePath: secondFile.standardizedRelativePath,
                        requestGeneration: 0,
                        pathGeneration: 0,
                        state: .unavailable
                    )
                ]
            )
        )
        XCTAssertTrue(crossRootAccepted)

        let staleAccepted = await store.acceptCodemapMarkerReadinessUpdateForTesting(
            WorkspaceCodemapMarkerReadinessUpdate(
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: firstRoot.id,
                    rootLifetimeID: UUID()
                ),
                changes: [
                    WorkspaceCodemapMarkerReadinessChange(
                        fileID: firstFile.id,
                        standardizedRelativePath: firstFile.standardizedRelativePath,
                        requestGeneration: 0,
                        pathGeneration: 0,
                        state: .unavailable
                    )
                ]
            )
        )
        XCTAssertFalse(staleAccepted)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                rootScope: .allLoaded
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            profile: .mcpRead
        )
        XCTAssertTrue(tree.content.contains("First.swift +"), tree.content)
        XCTAssertFalse(tree.content.contains("Second.swift +"), tree.content)

        await store.unloadRoot(id: firstRoot.id)
        await store.unloadRoot(id: secondRoot.id)
    }

    func testAcceptedReadyOverlayLazilyBuildsOneExactEpochGraphButStrictQueryRemainsIncomplete() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let firstPublicationGate = CodemapArmableSuspensionGate()
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let initialGraphPolicy = WorkspaceCodemapSelectionGraphRuntimePolicy.initial
        let graphProbe = CodemapSelectionGraphProbe(runtimePolicy: .init(
            maximumActiveRebuildCount: initialGraphPolicy.maximumActiveRebuildCount,
            maximumReservedBindingCount: initialGraphPolicy.maximumReservedBindingCount,
            maximumInputBindingCount: initialGraphPolicy.maximumInputBindingCount,
            maximumSelectedSourceCountPerQuery: 1,
            maximumResolvedTargetCountPerQuery: initialGraphPolicy.maximumResolvedTargetCountPerQuery,
            maximumReferenceFailureCountPerQuery: initialGraphPolicy.maximumReferenceFailureCountPerQuery,
            graphSizePolicy: initialGraphPolicy.graphSizePolicy
        ))
        addTeardownBlock {
            await firstPublicationGate.release()
            await pendingPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await firstPublicationGate.enterIfArmedAndWait()
                await pendingPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let pending = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })

        await firstPublicationGate.arm()
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        let firstPublicationEntered = await firstPublicationGate.waitUntilEntered()
        XCTAssertTrue(firstPublicationEntered)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await firstPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let publicationDrainClock = ContinuousClock()
        let publicationDrained = await store.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: publicationDrainClock.now.advanced(by: .seconds(5))
        )
        XCTAssertTrue(publicationDrained)
        let sourceQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)
        ])
        let result = await store.queryCodemapSelectionGraph(sourceQuery)
        guard case let .incomplete(.definitionUniverse(rootEpoch, progress, remaining, retry)) = result
        else { return XCTFail("Live overlay must not materialize strict targets before a seal.") }
        XCTAssertEqual(rootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(progress, .notStarted)
        XCTAssertNil(remaining)
        XCTAssertNil(retry)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        let budgetedQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: targetTicket)
            ])
        )
        guard case let .incomplete(.definitionUniverse(
            budgetRootEpoch,
            budgetProgress,
            budgetRemaining,
            budgetRetry
        )) = budgetedQuery else {
            return XCTFail("Strict multi-source query must remain incomplete before a seal.")
        }
        XCTAssertEqual(budgetRootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(budgetProgress, .notStarted)
        XCTAssertNil(budgetRemaining)
        XCTAssertNil(budgetRetry)

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: pending.id)
        )
        let pendingPublicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(pendingPublicationEntered)
        let whilePending = await store.queryCodemapSelectionGraph(sourceQuery)
        guard case .incomplete = whilePending else {
            return XCTFail("Pending live work must leave strict graph queries incomplete.")
        }
        let pendingQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: pendingTicket)
            ])
        )
        XCTAssertEqual(pendingQuery, .unavailable(.sourceNotReady(pending.id)))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))

        try Self.write(
            "struct CatalogAdvance {}\n",
            to: root.appendingPathComponent("Sources/CatalogAdvance.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            root.appendingPathComponent("Sources/CatalogAdvance.swift").path
        ])
        let staleAfterCatalogAdvance = await store.queryCodemapSelectionGraph(sourceQuery)
        XCTAssertEqual(
            staleAfterCatalogAdvance,
            .stale(.currentness(sourceTicket.rootEpoch))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testStagedIncompleteResidentGraphReturnsTypedStructureCoverageWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let didPublish = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(didPublish)
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: sourceTicket.rootEpoch))
        let initialAccounting = await graph.accounting()
        let key = try XCTUnwrap(initialAccounting.currentObservedKey)
        let token = WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: sourceTicket.rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: key.catalogGeneration,
            ingressGeneration: sourceTicket.ingressGeneration,
            projectionInvalidationGeneration: 1
        )
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: token,
            repositoryAuthority: key.repositoryAuthority,
            contributionGeneration: key.contributionGeneration,
            schemaVersion: key.schemaVersion,
            policyVersion: key.policyVersion
        )
        let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: sourceTicket.rootEpoch.rootID,
            rootLifetimeID: sourceTicket.rootEpoch.rootLifetimeID,
            fileID: source.id,
            standardizedRootPath: loaded.standardizedFullPath,
            standardizedRelativePath: source.standardizedRelativePath,
            standardizedFullPath: source.standardizedFullPath
        ))
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let entry = WorkspaceCodemapProjectionEntry(
            identity: identity,
            requestGeneration: sourceTicket.requestGeneration,
            pathGeneration: sourceTicket.pathGeneration,
            pipelineIdentity: pipeline,
            outcome: .terminalExcluded(.securityExcluded)
        )
        let byteCount: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: [entry]
        ) {
        case let .success(value):
            byteCount = value
        case let .failure(error):
            return XCTFail("Unexpected projection byte accounting failure: \(error)")
        }
        let counts = WorkspaceCodemapProjectionCounts(
            supportedCandidateCount: 2,
            processedCandidateCount: 1,
            contributedCount: 0,
            emptyCount: 0,
            terminalArtifactCount: 0,
            terminalExcludedCount: 1,
            transientCount: 0
        )
        let progress = WorkspaceCodemapProjectionProgress(
            phase: .publishingProjectionSegment,
            counts: counts,
            catalogPageCount: 1,
            catalogPathByteCount: UInt64(source.standardizedRelativePath.utf8.count),
            publishedSegmentCount: 1,
            publishedSegmentByteCount: byteCount,
            catalogCompletion: nil
        )
        let segment: WorkspaceCodemapProjectionSegment
        switch WorkspaceCodemapProjectionSegment.validated(
            generation: generation,
            sequence: 0,
            entries: [entry],
            progress: progress,
            byteCount: byteCount
        ) {
        case let .success(value):
            segment = value
        case let .failure(error):
            return XCTFail("Unexpected projection segment failure: \(error)")
        }
        let segmentDisposition = await graph.applyProjectionSnapshot(.segment(segment))
        XCTAssertEqual(segmentDisposition, .accepted(progress))
        let stagedAccounting = await graph.accounting()
        XCTAssertEqual(stagedAccounting.publishedSummary?.nodeCount, 2)

        let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.incomplete(
            progress: progress,
            remainingCount: nil,
            retry: nil
        )
        let disposition = await store.queryCodemapStructureGraph(
            WorkspaceCodemapStructureTraversalQuery(
                seeds: [WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)],
                direction: .both,
                limits: .init(
                    maximumDepth: 2,
                    maximumNodeCount: 10,
                    maximumEdgeCount: 10,
                    maximumByteCount: 4096
                )
            )
        )
        XCTAssertEqual(
            disposition,
            .unavailable(.definitionUniverse(
                rootEpoch: sourceTicket.rootEpoch,
                coverage: coverage
            ))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testGraphQueryRejectsForeignEpochAndUnreadySourcesWithoutCrossRootTargets() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/ForeignReference.swift":
                    "struct ForeignReference { let value: SharedDefinition }\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/SharedDefinition.swift": "struct SharedDefinition {}\n"
            ]
        )
        XCTAssertEqual(firstRoot.lastPathComponent, secondRoot.lastPathComponent)

        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .engine
        )
        let projectionCatalogGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await projectionCatalogGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await projectionCatalogGate.enterAndWait(rootEpoch)
        }
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let projectionCatalogsBlocked = await projectionCatalogGate.waitUntilInvocationCount(2)
        XCTAssertTrue(projectionCatalogsBlocked)
        await projectionCatalogGate.release()
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: firstTicket
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: secondTicket
        )

        let firstOnly = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(firstOnly.roots.count, 1)
        let firstRootResult = try XCTUnwrap(firstOnly.roots.first)
        XCTAssertFalse(firstRootResult.result.targets.contains {
            $0.fileID == secondFile.id
        })
        XCTAssertTrue(firstRootResult.result.targets.allSatisfy {
            $0.rootEpoch == firstTicket.rootEpoch
        })

        let combined = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: secondTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(Set(combined.roots.map(\.rootEpoch)), [
            firstTicket.rootEpoch,
            secondTicket.rootEpoch
        ])
        for rootResult in combined.roots {
            XCTAssertTrue(rootResult.result.targets.allSatisfy {
                $0.rootEpoch == rootResult.rootEpoch
            })
            XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
                $0.source.rootEpoch == rootResult.rootEpoch &&
                    $0.target.rootEpoch == rootResult.rootEpoch
            })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)

        let foreign = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                    rootEpoch: secondTicket.rootEpoch,
                    ticket: firstTicket
                )
            ])
        )
        XCTAssertEqual(foreign, .unavailable(.foreignRootEpoch(firstFile.id)))

        let resolutionGate = CodemapResolutionGate()
        let pendingFixture = try CodemapStoreFixture(
            name: #function + "-pending",
            projectionAuthority: .none,
            resolutionGate: resolutionGate
        )
        let pendingProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await pendingFixture.shutdown()
        }
        let pendingStore = pendingFixture.makeStore(selectionGraphFactory: pendingProbe.factory)
        let pendingLoaded = try await pendingStore.loadRoot(path: firstRoot.path)
        let pendingFiles = await pendingStore.files(inRoot: pendingLoaded.id)
        let pendingFile = try XCTUnwrap(pendingFiles.first)
        let unreadyTicket = try await pendingTicket(
            pendingStore.requestCodemapArtifact(forFileID: pendingFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let unready = await pendingStore.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unreadyTicket)
            ])
        )
        XCTAssertEqual(unready, .unavailable(.sourceNotReady(pendingFile.id)))
        XCTAssertEqual(pendingProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: pendingStore, ticket: unreadyTicket)
        await pendingStore.unloadRoot(id: pendingLoaded.id)

        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testMultiRootGraphQueryEnforcesAggregateBudgetBeforeNPlusOneMaterialization() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let thirdRepository = try ReviewGitRepositoryFixture(name: #function + "-third")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "struct First { let value: MissingFirst }\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Source.swift": "struct Second { let value: MissingSecond }\n"]
        )
        let thirdRoot = try thirdRepository.makeRepository(
            named: "third",
            files: ["Sources/Source.swift": "struct Third { let value: MissingThird }\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .engine
        )
        let projectionCatalogGate = CodemapGraphPublicationGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await projectionCatalogGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
            thirdRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100,
                maximumByteCount: 521
            )
        )
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await projectionCatalogGate.enterAndWait(rootEpoch)
        }

        var loadedRoots: [WorkspaceRootRecord] = []
        var tickets: [WorkspaceCodemapArtifactDemandTicket] = []
        for root in [firstRoot, secondRoot, thirdRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let file = try XCTUnwrap(files.first)
            let ticket = try await pendingTicket(
                store.requestCodemapArtifact(forFileID: file.id)
            )
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            tickets.append(ticket)
        }
        let projectionCatalogsBlocked = await projectionCatalogGate.waitUntilInvocationCount(2)
        XCTAssertTrue(projectionCatalogsBlocked)
        await projectionCatalogGate.release()
        for ticket in tickets {
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: ticket
            )
        }

        let firstTwoQuery = WorkspaceCodemapStoreSelectionGraphQuery(
            selectedSources: tickets
                .prefix(2)
                .map(WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:))
        )
        let firstTwo = await store.queryCodemapSelectionGraph(firstTwoQuery)
        guard case let .readyPartial(firstTwoResult) = firstTwo else {
            return XCTFail("Expected the N-root query to fit the aggregate budget.")
        }
        XCTAssertEqual(firstTwoResult.roots.count, 2)
        XCTAssertEqual(
            firstTwoResult.roots.reduce(0) { $0 + $1.result.referenceFailures.count },
            2
        )
        let afterNMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNMaterializations, 2)

        let nPlusOneQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: tickets.map(
            WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:)
        ))
        let nPlusOne = await store.queryCodemapSelectionGraph(nPlusOneQuery)
        XCTAssertEqual(
            nPlusOne,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterNPlusOneMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNPlusOneMaterializations - afterNMaterializations, 2)

        let automaticSources = tickets.map {
            WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: $0.rootEpoch,
                fileID: $0.fileID,
                catalogGeneration: $0.catalogGeneration
            )
        }
        let beforeAutomaticN = await graphProbe.materializedQueryResultCount()
        let automaticN = try await store.resolveAutomaticCodemapSelection(
            sources: Array(automaticSources.prefix(2)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(automaticN.roots.count, 2)
        let afterAutomaticN = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticN - beforeAutomaticN, 2)

        let automaticNPlusOne = try await store.resolveAutomaticCodemapSelection(
            sources: automaticSources,
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(automaticNPlusOne.roots.isEmpty)
        XCTAssertTrue(automaticNPlusOne.targets.isEmpty)
        XCTAssertNil(automaticNPlusOne.publicationReceipt)
        XCTAssertEqual(
            automaticNPlusOne.aggregateCoverage,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterAutomaticNPlusOne = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticNPlusOne - afterAutomaticN, 2)

        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let buildGate = CodemapSelectionGraphBuildGate(autoReleaseTimeout: nil)
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let blockedGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let isFailClosedQueuedState: (WorkspaceCodemapStoreSelectionGraphQueryDisposition) -> Bool = {
            disposition in
            switch disposition {
            case let .unavailable(.notActivated(rootEpoch)),
                 let .busy(.runtime(rootEpoch: rootEpoch, reason: .rebuilding)),
                 let .stale(.runtime(
                     rootEpoch: rootEpoch,
                     reason: .staleCurrentness(currentKey: _)
                 )):
                rootEpoch == firstTicket.rootEpoch
            default:
                false
            }
        }
        let queryClock = ContinuousClock()
        let initialQueryStarted = queryClock.now
        let whileInitialBuildQueued = await store.queryCodemapSelectionGraph(firstQuery)
        let initialQueryDuration = initialQueryStarted.duration(to: queryClock.now)
        XCTAssertEqual(
            whileInitialBuildQueued,
            .unavailable(.notActivated(firstTicket.rootEpoch))
        )
        XCTAssertLessThan(initialQueryDuration, .seconds(1))

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let query = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let queryStarted = queryClock.now
        let whileNewerContributionQueued = await store.queryCodemapSelectionGraph(query)
        let queryDuration = queryStarted.duration(to: queryClock.now)
        XCTAssertTrue(
            isFailClosedQueuedState(whileNewerContributionQueued),
            "Expected queued latest-wins work to hide the older shard."
        )
        XCTAssertLessThan(queryDuration, .seconds(1))

        buildGate.release(generation: blockedGeneration)
        let latestGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: blockedGeneration)
        )
        let accountingBeforeUnload = await oldGraph.accounting()
        XCTAssertEqual(
            accountingBeforeUnload.currentObservedKey?.contributionGeneration.rawValue,
            latestGeneration
        )
        XCTAssertEqual(accountingBeforeUnload.publishedCount, 0)
        XCTAssertEqual(accountingBeforeUnload.emptyPublishedCount, 0)
        XCTAssertNil(accountingBeforeUnload.publishedSummary)

        let unloadTask = Task {
            await store.unloadRoot(id: loaded.id)
        }
        let revocationDeadline = queryClock.now.advanced(by: .seconds(5))
        var afterRevocation = await store.queryCodemapSelectionGraph(query)
        while afterRevocation != .stale(.currentness(firstTicket.rootEpoch)),
              queryClock.now < revocationDeadline
        {
            XCTAssertTrue(
                isFailClosedQueuedState(afterRevocation),
                "Expected the blocked graph to remain fail closed while unload revocation completed."
            )
            await Task.yield()
            afterRevocation = await store.queryCodemapSelectionGraph(query)
        }
        XCTAssertEqual(afterRevocation, .stale(.currentness(firstTicket.rootEpoch)))
        buildGate.release(generation: latestGeneration)
        buildGate.releaseAll()
        await unloadTask.value

        let oldAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldAccounting.publishedCount, 0)
        XCTAssertEqual(oldAccounting.emptyPublishedCount, 0)
        XCTAssertNil(oldAccounting.publishedSummary)
        XCTAssertEqual(
            oldAccounting.currentUnavailableReason,
            .explicitRootUnavailable(.rootUnloaded)
        )

        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFirst = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFirst.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        let reloadedPublished = await graphProbe.waitUntilPublished(
            rootEpoch: reloadedTicket.rootEpoch
        )
        XCTAssertTrue(reloadedPublished)
        XCTAssertNotEqual(reloadedTicket.rootEpoch, firstTicket.rootEpoch)
        let oldLifetimeQuery = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(oldLifetimeQuery, .stale(.currentness(firstTicket.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let blockerRoot = try repositoryFixture.makeRepository(
            named: "blocker",
            files: ["Sources/Blocker.swift": "struct Blocker {}\n"]
        )
        let selectionRoot = try repositoryFixture.makeRepository(
            named: "selection",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let buildGate = CodemapSelectionGraphBuildGate()
        let admissionWaitGate = CodemapSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe(
            buildGate: buildGate,
            admissionPolicy: .init(
                maximumActiveReservationCount: 1,
                maximumReservedBindingCount: 100_000
            ),
            processAdmissionWaitHook: {
                await admissionWaitGate.enterAndWait()
            }
        )
        addTeardownBlock {
            await admissionWaitGate.release()
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let blocker = try await store.loadRoot(path: blockerRoot.path)
        let selection = try await store.loadRoot(path: selectionRoot.path)

        let blockerFiles = await store.files(inRoot: blocker.id)
        let blockerFile = try XCTUnwrap(blockerFiles.first)
        let blockerTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: blockerFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: blockerTicket))
        let blockerGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())

        let selectionFiles = await store.files(inRoot: selection.id)
        let first = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let admissionWaitEntered = await admissionWaitGate.waitUntilEntered()
        XCTAssertTrue(admissionWaitEntered)
        let selectionGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstAccounting = await selectionGraph.accounting()
        let firstObservedKey = try XCTUnwrap(firstAccounting.currentObservedKey)

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let latestObservedKey = await graphProbe.waitUntilObservedKey(
            rootEpoch: firstTicket.rootEpoch,
            after: firstObservedKey.contributionGeneration
        )
        XCTAssertNotNil(latestObservedKey)

        await admissionWaitGate.release()
        buildGate.release(generation: blockerGeneration)
        buildGate.releaseAll()

        let latestPublished = await graphProbe.waitUntilPublished(
            rootEpoch: firstTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(latestPublished)
        let finalAccounting = await selectionGraph.accounting()
        XCTAssertEqual(finalAccounting.currentObservedKey, latestObservedKey)
        XCTAssertEqual(finalAccounting.publishedSummary?.key, latestObservedKey)
        // `publishedCount` is cumulative runtime accounting and can include an intermediate publication
        // under scheduler interleavings; this seam test verifies final currentness and worker coalescing.
        XCTAssertGreaterThanOrEqual(finalAccounting.publishedCount, 1)
        let operationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(operationCounts.graphWorkerStarts, 2)

        await store.unloadRoot(id: selection.id)
        await store.unloadRoot(id: blocker.id)
    }

    func testNonGitDemandBecomesTerminalWithoutSourceReadManifestBuildOrGraphWork() async throws {
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        let preflightCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let first = await store.requestCodemapArtifact(forFileID: file.id)
        let second = await store.requestCodemapArtifact(forFileID: file.id)
        assertNonGitTerminal(first)
        assertNonGitTerminal(second)
        XCTAssertEqual(preflightCount.value, 1)
        let firstOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(firstOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(firstOperationCounts.demandTasksCreated, 0)

        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        await assertNonGitTerminal(store.requestCodemapArtifact(forFileID: reloadedFile.id))
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        let reloadedOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(reloadedOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(reloadedOperationCounts.demandTasksCreated, 0)
        await store.unloadRoot(id: reloaded.id)
    }

    func testNonGitPresentationPlanStartsNoCodemapRuntimeDemandBuildOrCASWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(codemapGitEligibilityProbe: .production())
        _ = try await store.loadRoot(path: root.path)

        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: .selected,
            selection: StoredSelection(
                selectedPaths: ["Sources/Feature.swift"],
                codemapAutoEnabled: false
            ),
            store: store,
            rootScope: .allLoaded,
            profile: .uiAssisted
        )
        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(for: plan.intent, rootScope: .allLoaded)
        let merged = WorkspaceCodemapPresentationIntentResolver.merging(
            presentation,
            preflightIssues: plan.preflightIssues
        )

        XCTAssertTrue(merged.orderedEntries.isEmpty)
        XCTAssertTrue(merged.issues.contains {
            if case .unavailable(_, .gitTerminal(.nonGit)) = $0 { return true }
            return false
        })
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testCatalogAdvanceFencesPendingTicketAndExactRegistryRoute() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let routed = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(ticket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(routed?.identity.fileID, file.id)

        try Self.write("struct Added {}\n", to: root.appendingPathComponent("Sources/Added.swift"))
        let replayTask = Task {
            await store.ensureIndexedFiles(paths: [
                root.appendingPathComponent("Sources/Added.swift").path
            ])
        }

        await gate.release()
        _ = await replayTask.value
        await assertStale(store.codemapArtifactDemandStatus(ticket))

        let currentFiles = await store.files(inRoot: loaded.id)
        let currentFile = try XCTUnwrap(currentFiles.first {
            $0.standardizedRelativePath == file.standardizedRelativePath
        })
        let successorDemand = await store.requestCodemapArtifact(forFileID: currentFile.id)
        let successorTicket: WorkspaceCodemapArtifactDemandTicket
        switch successorDemand {
        case let .pending(ticket):
            successorTicket = ticket
        case let .ready(ready):
            successorTicket = ready.ticket
        case let .unavailable(reason):
            return XCTFail("Expected current successor demand, got \(reason)")
        }
        XCTAssertEqual(successorTicket.rootEpoch, ticket.rootEpoch)
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        XCTAssertNotEqual(successorTicket, ticket)
        let successorStatus = await store.codemapArtifactDemandStatus(successorTicket)
        if case .unavailable(.staleCurrentness) = successorStatus {
            XCTFail("Expected successor ticket to remain current")
        }
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        _ = await store.cancelCodemapArtifactDemand(successorTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testManifestCandidateAfterPathInvalidationUsesSuccessorPathGeneration() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))

        try Self.write(
            "struct Feature { let changed = true }\n",
            to: root.appendingPathComponent(file.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(file.standardizedRelativePath, nil)]
        )
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))

        let currentFileValue = await store.file(
            rootID: loaded.id,
            relativePath: file.standardizedRelativePath
        )
        let currentFile = try XCTUnwrap(currentFileValue)
        let successorDemand = await store.requestCodemapArtifact(forFileID: currentFile.id)
        let successorTicket: WorkspaceCodemapArtifactDemandTicket
        let successorResult: WorkspaceCodemapArtifactDemandResult
        switch successorDemand {
        case let .pending(ticket):
            successorTicket = ticket
            successorResult = try await settledResult(store: store, ticket: ticket)
        case let .ready(ready):
            successorTicket = ready.ticket
            successorResult = .ready(ready)
        case let .unavailable(reason):
            return XCTFail("Expected successor demand after path invalidation, got \(reason).")
        }
        XCTAssertGreaterThan(successorTicket.pathGeneration, firstTicket.pathGeneration)
        XCTAssertEqual(successorTicket.requestGeneration, successorTicket.pathGeneration)
        let routed = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            file.standardizedRelativePath
        )
        XCTAssertEqual(routed?.identity.fileID, file.id)
        XCTAssertEqual(routed?.requestGeneration, successorTicket.requestGeneration)
        XCTAssertEqual(routed?.pathGeneration, successorTicket.pathGeneration)
        XCTAssertEqual(routed?.ingressGeneration, successorTicket.ingressGeneration)
        let successorReady = try readyResult(successorResult)
        XCTAssertEqual(successorReady.snapshot.requestGeneration, successorTicket.requestGeneration)
        XCTAssertEqual(fixture.buildCount.value, 2)
        _ = await store.cancelCodemapArtifactDemand(successorTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAndReloadFenceOldLifetimeAndDrainCodemapRootState() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: root.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let unloadTask = Task {
            await store.unloadRoot(id: firstRoot.id)
        }
        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: firstTicket,
            relativePath: firstFile.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        await gate.release()
        await unloadTask.value

        let secondRoot = try await store.loadRoot(path: root.path)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )

        XCTAssertNotEqual(secondRoot.id, firstRoot.id)
        XCTAssertNotEqual(secondTicket.rootEpoch, firstTicket.rootEpoch)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        try await assertNonGitTerminal(settledResult(store: store, ticket: secondTicket))
        await store.unloadRoot(id: secondRoot.id)
        let engineRootCountIsZero = try await engineRootCountBecomesZero(fixture: fixture)
        XCTAssertTrue(engineRootCountIsZero)
    }

    func testReadyDemandsReuseInjectedRuntimeRegistryAndEngineSingletons() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let firstFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let secondFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        let secondReady = try await readyResult(
            settledResult(store: store, ticket: secondTicket)
        )

        XCTAssertEqual(firstTicket.rootEpoch, secondTicket.rootEpoch)
        XCTAssertEqual(firstReady.identity.fileID, firstFile.id)
        XCTAssertEqual(firstReady.snapshot.fileID, firstFile.id)
        XCTAssertEqual(try firstReady.handle.artifactKey(), firstReady.snapshot.artifactKey)
        XCTAssertEqual(secondReady.identity.fileID, secondFile.id)
        XCTAssertEqual(secondReady.snapshot.fileID, secondFile.id)
        XCTAssertEqual(try secondReady.handle.artifactKey(), secondReady.snapshot.artifactKey)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        XCTAssertTrue(try fixture.runtime().bindingIntegrationRegistry === fixture.registry)

        let firstCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                firstTicket.rootEpoch,
                firstFile.standardizedRelativePath
            )
        let secondCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                secondTicket.rootEpoch,
                secondFile.standardizedRelativePath
            )
        XCTAssertEqual(firstCandidate?.identity.fileID, firstFile.id)
        XCTAssertEqual(secondCandidate?.identity.fileID, secondFile.id)

        await store.unloadRoot(id: loaded.id)
        XCTAssertThrowsError(try firstReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try secondReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
    }

    func testCancellationAfterReadyRevokesRetainedHandleIdempotently() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )
        XCTAssertEqual(try ready.handle.artifactKey(), ready.snapshot.artifactKey)
        let retainCountBeforeCancellation = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(retainCountBeforeCancellation, 1)
        let cleanupBeforeCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupBeforeCancellation,
            .init(
                demandRecordPresent: true,
                bundlePresent: true,
                ownerCount: 0,
                liveOverlayPresent: true
            )
        )

        let firstCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(firstCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanupAfterFirstCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupAfterFirstCancellation,
            .init(
                demandRecordPresent: false,
                bundlePresent: false,
                ownerCount: 0,
                liveOverlayPresent: false
            )
        )

        let secondCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertFalse(secondCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanupAfterSecondCancellation = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanupAfterSecondCancellation,
            cleanupAfterFirstCancellation
        )

        await store.unloadRoot(id: loaded.id)
    }

    func testFinalReadyRetainReleaseRemovesDemandBundleOwnerAndLiveOverlay() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )

        let released = await store.releaseReadyCodemapArtifactDemandRetain(ticket)
        XCTAssertTrue(released)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let cleanup = await store.codemapArtifactDemandCleanupSnapshotForTesting(ticket)
        XCTAssertEqual(
            cleanup,
            .init(
                demandRecordPresent: false,
                bundlePresent: false,
                ownerCount: 0,
                liveOverlayPresent: false
            )
        )
        let releasedAgain = await store.releaseReadyCodemapArtifactDemandRetain(ticket)
        XCTAssertFalse(releasedAgain)
        await store.unloadRoot(id: loaded.id)
    }

    func testReadyCancellationCleanupCannotCancelSamePathSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        let cancelledRequestIDs = CodemapLockedValues<UUID>()
        let cancellationGate = CodemapSuspensionGate()
        let successorPublicationGate = CodemapArmableSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await cancellationGate.release()
            await successorPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { ticket in
                guard cancelledRequestIDs.values.contains(ticket.requestID) else { return }
                await cancellationGate.enterAndWait()
            },
            readyPublicationHook: { _ in
                await successorPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let cancelledTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        cancelledRequestIDs.append(cancelledTicket.requestID)
        let cancelledReady = try await readyResult(
            settledResult(store: store, ticket: cancelledTicket)
        )
        let cancelledGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: cancelledTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(cancelledGraphPublished)
        let epochGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: cancelledTicket.rootEpoch))
        let cancelledGraphAccounting = await epochGraph.accounting()
        let cancelledGraphKey = try XCTUnwrap(cancelledGraphAccounting.currentObservedKey)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await successorPublicationGate.arm()

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(cancelledTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertCancelled(store.codemapArtifactDemandStatus(cancelledTicket))
        XCTAssertThrowsError(try cancelledReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }

        try Self.write(
            "struct Feature { let successorGeneration = true }\n",
            to: root.appendingPathComponent(file.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(file.standardizedRelativePath, nil)]
        )
        let refreshedFiles = await store.files(inRoot: loaded.id)
        let refreshedFile = try XCTUnwrap(refreshedFiles.first {
            $0.standardizedRelativePath == file.standardizedRelativePath
        })
        let successorTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: refreshedFile.id)
        )
        XCTAssertNotEqual(successorTicket, cancelledTicket)
        XCTAssertNotEqual(successorTicket.requestID, cancelledTicket.requestID)
        XCTAssertNotEqual(successorTicket.retainID, cancelledTicket.retainID)
        XCTAssertEqual(successorTicket.rootEpoch, cancelledTicket.rootEpoch)
        XCTAssertEqual(successorTicket.fileID, cancelledTicket.fileID)
        XCTAssertGreaterThan(successorTicket.requestGeneration, cancelledTicket.requestGeneration)
        XCTAssertGreaterThan(successorTicket.pathGeneration, cancelledTicket.pathGeneration)
        let successorPublicationEntered = await successorPublicationGate.waitUntilEntered()
        XCTAssertTrue(successorPublicationEntered)

        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)
        let gatedSuccessor = await store.codemapArtifactDemandCleanupSnapshotForTesting(successorTicket)
        XCTAssertTrue(gatedSuccessor.demandRecordPresent)
        XCTAssertTrue(gatedSuccessor.liveOverlayPresent)
        await successorPublicationGate.release()
        let successorReady = try await readyResult(
            settledResult(store: store, ticket: successorTicket)
        )
        XCTAssertEqual(successorReady.ticket, successorTicket)
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        let survivingReady = try await readyResult(
            store.codemapArtifactDemandStatus(successorTicket)
        )
        XCTAssertEqual(try survivingReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        let successorGraphKey = await graphProbe.waitUntilObservedKey(
            rootEpoch: successorTicket.rootEpoch,
            after: cancelledGraphKey.contributionGeneration
        )
        XCTAssertNotNil(successorGraphKey)
        XCTAssertTrue(graphProbe.graph(rootEpoch: successorTicket.rootEpoch) === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        XCTAssertNotEqual(reloadedTicket.rootEpoch, successorTicket.rootEpoch)
        let reloadedGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: reloadedTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(reloadedGraphPublished)
        let reloadedGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: reloadedTicket.rootEpoch))
        XCTAssertFalse(reloadedGraph === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        await store.unloadRoot(id: reloaded.id)
    }

    func testWatcherRenamePairFencesOnlyOldAndNewPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Old.swift": "struct Old {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let old = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Old.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let oldTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: old.id))
        let oldReady = try await readyResult(settledResult(store: store, ticket: oldTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: unrelatedTicket
        )
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        let unrelatedQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
        ])
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent(old.standardizedRelativePath),
            to: root.appendingPathComponent("Sources/New.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [
                .fileRemoved(old.standardizedRelativePath),
                .fileAdded("Sources/New.swift")
            ]
        )

        await assertStale(store.codemapArtifactDemandStatus(oldTicket))
        XCTAssertThrowsError(try oldReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        let renamedValue = await store.file(rootID: loaded.id, relativePath: "Sources/New.swift")
        let renamed = try XCTUnwrap(renamedValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamed.id))
        XCTAssertGreaterThan(renamedTicket.pathGeneration, oldTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: renamedTicket
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: renamedTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testPathRepairPublishesReadyContributionCompletedDuringRebuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "struct Affected {}\n",
                "Sources/Late.swift": "struct Late { let survivor: Survivor }\n",
                "Sources/Survivor.swift": "struct Survivor {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual
        )
        let buildGate = CodemapSelectionGraphBuildGate()
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let late = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Late.swift" })
        let survivor = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Survivor.swift" })
        let survivorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: survivor.id))
        let survivorReady = try await readyResult(settledResult(store: store, ticket: survivorTicket))
        let initialGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        buildGate.release(generation: initialGeneration)
        let initialGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: survivorTicket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(initialGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: survivorTicket,
            contributionsByFileID: [
                survivor.id: CodeMapSelectionGraphContribution(
                    artifactKey: survivorReady.snapshot.artifactKey,
                    definitions: ["Survivor"],
                    references: []
                )
            ]
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: survivorTicket
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: survivorTicket)
            ])
        )

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        let repairTask = Task {
            await store.replayObservedFileSystemDeltas(
                rootID: loaded.id,
                deltas: [.fileModified(affected.standardizedRelativePath, nil)]
            )
        }
        let repairGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: initialGeneration)
        )

        let lateTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: late.id))
        let lateReady = try await readyResult(settledResult(store: store, ticket: lateTicket))
        buildGate.release(generation: repairGeneration)
        buildGate.releaseAll()
        await repairTask.value
        let repairedGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: lateTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(repairedGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: lateTicket,
            contributionsByFileID: [
                late.id: CodeMapSelectionGraphContribution(
                    artifactKey: lateReady.snapshot.artifactKey,
                    definitions: ["Late"],
                    references: ["Survivor"]
                ),
                survivor.id: CodeMapSelectionGraphContribution(
                    artifactKey: survivorReady.snapshot.artifactKey,
                    definitions: ["Survivor"],
                    references: []
                )
            ]
        )
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: lateTicket
        )

        let result = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: lateTicket)
            ])
        )
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertTrue(rootResult.result.sourceCoverage.contains {
            $0.source.fileID == late.id && $0.state == .covered
        })
        XCTAssertTrue(rootResult.result.targets.contains {
            $0.fileID == survivor.id
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherModifyDeleteAndGapAwaitPresentationGraphAndEngineFences() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "func affected() {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphFactory: graphProbe.factory
        )

        func requireReadyDemand(
            _ ticket: WorkspaceCodemapArtifactDemandTicket,
            phase: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> WorkspaceCodemapArtifactDemandReady {
            let result = try await settledResult(store: store, ticket: ticket)
            guard case let .ready(ready) = result else {
                XCTFail("Expected \(phase) ready, got \(result).", file: file, line: line)
                throw CodemapStoreTestError.expectedReady
            }
            return ready
        }

        func withReadyProjectionDemand<Value>(
            sourceTickets: [WorkspaceCodemapArtifactDemandTicket],
            phase: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            body: (WorkspaceCodemapProjectionDemandTicket) async throws -> Value
        ) async throws -> Value {
            let projectionTicket = try await requireReadyProjectionDemand(
                store: store,
                sourceTickets: sourceTickets,
                phase: phase,
                file: file,
                line: line
            )
            do {
                let value = try await body(projectionTicket)
                await assertProjectionDemandReleased(
                    store: store,
                    projectionTicket,
                    phase: phase,
                    file: file,
                    line: line
                )
                return value
            } catch {
                _ = await store.releaseCodemapProjectionDemand(projectionTicket)
                throw error
            }
        }

        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let affectedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        let affectedReady = try await requireReadyDemand(
            affectedTicket,
            phase: "initial affected demand"
        )
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await requireReadyDemand(
            unrelatedTicket,
            phase: "initial unrelated demand"
        )
        let (unrelatedPresentation, graph) = try await withReadyProjectionDemand(
            sourceTickets: [affectedTicket, unrelatedTicket],
            phase: "initial affected/unrelated projection demand"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: unrelatedTicket
            )
            let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "Workspace",
                standardizedRelativePath: unrelated.standardizedRelativePath
            ))
            let unrelatedPresentation = try await frozenPresentationBundle(
                store.freezeCodemapPresentation([
                    WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
                ])
            )
            _ = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: affectedTicket),
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
                ])
            )
            let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: affectedTicket.rootEpoch))
            return (unrelatedPresentation, graph)
        }

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(affected.standardizedRelativePath, nil)]
        )

        await assertStale(store.codemapArtifactDemandStatus(affectedTicket))
        XCTAssertThrowsError(try affectedReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        XCTAssertGreaterThan(successorTicket.pathGeneration, affectedTicket.pathGeneration)
        let successorReady = try await requireReadyDemand(
            successorTicket,
            phase: "successor affected demand after modification"
        )
        let successorPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: affected.standardizedRelativePath
        ))
        let successorPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: successorTicket, logicalPath: successorPath)
            ])
        )
        try await withReadyProjectionDemand(
            sourceTickets: [successorTicket, unrelatedTicket],
            phase: "successor affected/unrelated projection demand after modification"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: successorTicket
            )
            let successorGraph = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket),
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
                ])
            )
            XCTAssertEqual(successorGraph.roots.first?.rootEpoch, successorTicket.rootEpoch)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(unrelated.standardizedRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileRemoved(unrelated.standardizedRelativePath)]
        )
        await assertStale(store.codemapArtifactDemandStatus(unrelatedTicket))
        XCTAssertThrowsError(try unrelatedReady.handle.artifactKey())
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(successorPresentation)
        )
        try await withReadyProjectionDemand(
            sourceTickets: [successorTicket],
            phase: "post-delete successor projection demand"
        ) { _ in
            _ = try await generationMatchedCompleteSeal(
                catalogClient: fixture.registry.makeBindingCatalogClient(),
                graphProbe: graphProbe,
                ticket: successorTicket
            )
            let postDeleteSuccessorGraph = try await readyGraphQuery(
                store: store,
                query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                    WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket)
                ])
            )
            let postDeleteRoot = try XCTUnwrap(postDeleteSuccessorGraph.roots.first)
            XCTAssertEqual(postDeleteRoot.rootEpoch, successorTicket.rootEpoch)
            XCTAssertTrue(postDeleteRoot.result.sourceCoverage.contains {
                $0.source.fileID == affected.id && $0.state == .covered
            })
        }

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: successorTicket.rootEpoch.rootLifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.authorityRevoked))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            affected.standardizedRelativePath
        )
        XCTAssertNil(route)
        await store.unloadRoot(id: loaded.id)
    }

    func testStoreEditRenameAndDeleteAwaitCodemapAuthorityFenceBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Mutable.swift": "struct Mutable {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let initialFiles = await store.files(inRoot: loaded.id)
        let mutable = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Mutable.swift" })
        let unrelated = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let mutableTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: mutable.id))
        _ = try await readyResult(settledResult(store: store, ticket: mutableTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath,
            newContent: "struct Mutable { let edited = true }\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(mutableTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let editedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath
        )
        let editedFile = try XCTUnwrap(editedFileValue)
        let editedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: editedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: editedTicket))
        try await store.moveFile(
            rootID: loaded.id,
            from: mutable.standardizedRelativePath,
            to: "Sources/Renamed.swift"
        )
        await assertStale(store.codemapArtifactDemandStatus(editedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let renamedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: "Sources/Renamed.swift"
        )
        let renamedFile = try XCTUnwrap(renamedFileValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        try await store.deleteFile(rootID: loaded.id, relativePath: "Sources/Renamed.swift")
        await assertStale(store.codemapArtifactDemandStatus(renamedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testCheckoutAndCatalogAdvanceFenceOldAuthorityBeforeSuccessorDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        let service = WorkspaceCheckoutRefreshService(
            store: store,
            searchService: WorkspaceSearchService()
        )
        _ = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Checkout must revoke the retained presentation before returning.")
        }
        try await assertEngineRootCount(1, fixture: fixture)
        let oldGraphAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldGraphAccounting.activeRebuildCount, 0)

        let successorFileValue = await store.file(
            rootID: loaded.id,
            relativePath: feature.standardizedRelativePath
        )
        let successorFile = try XCTUnwrap(successorFileValue)
        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: successorFile.id))
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        let successorResult = try await settledResult(store: store, ticket: successorTicket)
        guard case .ready = successorResult else {
            return XCTFail("Expected checkout successor ready, got \(successorResult).")
        }
        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/CatalogReplacement.swift",
            content: "struct CatalogReplacement {}\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAwaitsPresentationGraphAndEngineRevocationBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        await store.unloadRoot(id: loaded.id)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Unload must revoke the retained presentation before returning.")
        }
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.rootUnloaded))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        try await assertEngineRootCount(0, fixture: fixture)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            ticket.rootEpoch,
            feature.standardizedRelativePath
        )
        XCTAssertNil(route)
    }

    func testProvisionalAutomaticSelectionPublishesReadyTargetWithIncompleteDiagnostics() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let rootEpoch = targetTicket.rootEpoch
        let candidate = try automaticSelectionCandidate(
            file: target,
            root: loaded,
            ticket: targetTicket
        )
        let incomplete = WorkspaceCodemapAutomaticSelectionIncompleteReason.graph(
            .definitionUniverse(
                rootEpoch: rootEpoch,
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        )
        let plan = WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan(
            candidates: [candidate],
            rootScopeEpochs: [rootEpoch],
            incompleteReasons: [incomplete]
        )

        let result = await store.provisionalAutomaticCodemapSelectionResult(
            sources: [sourceIdentity],
            plan: plan,
            readyCandidates: [candidate],
            pendingReasons: [],
            partialReasons: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(result.roots.first?.targets.map(\.fileID), [target.id])
        guard case let .provisional(incompleteReasons, pendingReasons, partialReasons) = result.aggregateCoverage else {
            return XCTFail("Expected provisional aggregate coverage.")
        }
        XCTAssertEqual(incompleteReasons, [incomplete])
        XCTAssertTrue(pendingReasons.isEmpty)
        XCTAssertTrue(partialReasons.isEmpty)
        let receipt = try XCTUnwrap(result.publicationReceipt)
        XCTAssertTrue(receipt.graphKeys.isEmpty)
        XCTAssertTrue(receipt.coverageProofs.isEmpty)
        guard case let .provisionalCandidates(receiptCandidates) = receipt.publicationBasis else {
            return XCTFail("Expected provisional candidate publication basis.")
        }
        XCTAssertEqual(receiptCandidates, [candidate])
        let publicationDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(publicationDisposition, .current(result.targets))

        let duplicatePermit = WorkspaceCodemapAutomaticSelectionPublicationPermit()
        let duplicateReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: UUID(),
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: receipt.targets + receipt.targets,
            publicationBasis: .provisionalCandidates(receiptCandidates + receiptCandidates),
            publicationPermit: duplicatePermit
        )
        let duplicateResult = WorkspaceCodemapAutomaticSelectionResult(
            roots: result.roots,
            aggregateCoverage: result.aggregateCoverage,
            publicationReceipt: duplicateReceipt
        )
        XCTAssertNil(duplicateResult.publicationReceipt)

        let sourceCandidate = try automaticSelectionCandidate(
            file: source,
            root: loaded,
            ticket: sourceTicket
        )
        let targetReceipt = try XCTUnwrap(receipt.targets.first)
        let alternateLogicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Alternate",
            standardizedRelativePath: target.standardizedRelativePath
        ))
        let duplicateSlotTarget = WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: targetReceipt.rootEpoch,
            fileID: targetReceipt.fileID,
            catalogGeneration: targetReceipt.catalogGeneration,
            requestGeneration: targetReceipt.requestGeneration,
            logicalPath: alternateLogicalPath
        )
        let duplicateTargetSlotReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: UUID(),
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: [],
            coverageProofs: [],
            targets: [targetReceipt, duplicateSlotTarget],
            publicationBasis: .provisionalCandidates([candidate, sourceCandidate]),
            publicationPermit: WorkspaceCodemapAutomaticSelectionPublicationPermit()
        )
        let duplicateSlotDisposition = await store.revalidateAutomaticCodemapSelectionForPublication(
            duplicateTargetSlotReceipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(duplicateSlotDisposition, .stale(.publicationReceipt))
        await store.unloadRoot(id: loaded.id)
    }

    func testProvisionalAutomaticSelectionDropsStaleCandidateWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let rootEpoch = targetTicket.rootEpoch
        let candidate = try automaticSelectionCandidate(
            file: target,
            root: loaded,
            ticket: targetTicket
        )
        let incomplete = WorkspaceCodemapAutomaticSelectionIncompleteReason.graph(
            .definitionUniverse(
                rootEpoch: rootEpoch,
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        )
        let plan = WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan(
            candidates: [candidate],
            rootScopeEpochs: [rootEpoch],
            incompleteReasons: [incomplete]
        )

        try Self.write(
            "struct Target { let changed = true }\n",
            to: root.appendingPathComponent("Sources/Target.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Target.swift", nil)]
        )

        let result = await store.provisionalAutomaticCodemapSelectionResult(
            sources: [sourceIdentity],
            plan: plan,
            readyCandidates: [candidate],
            pendingReasons: [],
            partialReasons: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .provisional(incompleteReasons, pendingReasons, partialReasons) = result.aggregateCoverage else {
            return XCTFail("Expected provisional aggregate coverage.")
        }
        XCTAssertEqual(incompleteReasons, [incomplete])
        XCTAssertTrue(pendingReasons.isEmpty)
        XCTAssertEqual(partialReasons, [
            .candidateUnavailable(
                rootEpoch: rootEpoch,
                fileID: target.id,
                reason: .staleCurrentness
            )
        ])
        await store.unloadRoot(id: loaded.id)
    }

    func testSecondFlushRecoveryRetiresFlightAndCoalescesSignalsIntoOneSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let recoveryGate = CodemapSuspensionGate()
        addTeardownBlock {
            await recoveryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        for file in await warmStore.files(inRoot: warmRoot.id) {
            let ticket = try await pendingTicket(warmStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        await warmStore.unloadRoot(id: warmRoot.id)

        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let coldFiles = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let unrelated = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: setupTicket
        )

        await store.setCodemapProjectionRecoveryObserverWillWaitHandlerForTesting { epoch in
            guard epoch == rootEpoch else { return }
            await recoveryGate.enterAndWait()
        }
        let before = await store.codemapPresentationOperationCountsForTesting()
        let sourceContributionTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: sourceContributionTicket)
        )

        let recoveryEntered = await recoveryGate.waitUntilEntered()
        XCTAssertTrue(recoveryEntered)
        guard recoveryEntered else { return }
        let stalled = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(stalled.flightActive)
        XCTAssertTrue(stalled.observerActive)
        let stalledSerial = try XCTUnwrap(stalled.observerLatestSignalSerial)

        let newerContributionTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unrelated.id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: newerContributionTicket)
        )
        let revokedNewerContribution = await store
            .revokeReadyCodemapArtifactContributionForTesting(newerContributionTicket)
        XCTAssertTrue(revokedNewerContribution)
        let coalesced = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(coalesced.flightActive)
        XCTAssertTrue(coalesced.observerActive)
        XCTAssertGreaterThan(try XCTUnwrap(coalesced.observerLatestSignalSerial), stalledSerial)
        let whileStalled = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            whileStalled.projectionRecoveryObserversStarted,
            before.projectionRecoveryObserversStarted + 1
        )

        await recoveryGate.release()
        let publicationClock = ContinuousClock()
        let publicationDeadline = publicationClock.now.advanced(by: .seconds(5))
        let publicationCurrent = await store.waitForCodemapGraphPublication(
            rootEpoch: rootEpoch,
            deadline: publicationDeadline
        )
        guard publicationCurrent else {
            return XCTFail("Timed out waiting for the bounded recovery publication.")
        }
        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        let finished = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        XCTAssertFalse(finished.flightActive)
        XCTAssertFalse(finished.observerActive)
        let after = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(
            after.projectionRecoveryObserversStarted,
            before.projectionRecoveryObserversStarted + 1,
            "the bounded successor must reuse the single recovery observer"
        )
        XCTAssertGreaterThanOrEqual(
            after.projectionRecoveryObserverRearms,
            before.projectionRecoveryObserverRearms + 1,
            "the real newer overlay contribution must re-arm the same observer after equivalence fails"
        )
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        _ = await store.cancelCodemapArtifactDemand(sourceContributionTicket)
        _ = await store.cancelCodemapArtifactDemand(newerContributionTicket)
        await store.unloadRoot(id: loaded.id)
    }
}

final class WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests:
    WorkspaceFileContextStoreCodemapSeamTestSupport
{
    func testAutomaticPresentationWatcherInvalidationDuringReconstructionNeverPublishesTargetsWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )

        let reconstructionCount = CodemapLockedCounter()
        let publicationRevalidationCount = CodemapLockedCounter()
        let operationCount = CodemapLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .seconds(2)
            ),
            beforePublicationRevalidation: { _ in
                publicationRevalidationCount.increment()
            },
            afterAutomaticCandidateReconstruction: { _ in
                reconstructionCount.increment()
                try Self.write(
                    "struct Target { let generation = \(reconstructionCount.value) }\n",
                    to: root.appendingPathComponent("Sources/Target.swift")
                )
                await store.replayObservedFileSystemDeltas(
                    rootID: loaded.id,
                    deltas: [.fileModified("Sources/Target.swift", nil)]
                )
            }
        )

        let presentation = try await coordinator.withPresentation(
            for: .automatic(sourceFileIDs: [source.id]),
            rootScope: .visibleWorkspace
        ) { presentation in
            operationCount.increment()
            XCTAssertTrue(presentation.orderedEntries.isEmpty)
            XCTAssertNil(presentation.publicationReceipt)
            return presentation
        }

        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        XCTAssertNil(presentation.publicationReceipt)
        XCTAssertEqual(operationCount.value, 1)
        XCTAssertEqual(publicationRevalidationCount.value, 0)
        XCTAssertTrue((1 ... 2).contains(reconstructionCount.value))
        switch presentation.coverage {
        case .pending, .unavailable:
            break
        case .complete, .partial:
            XCTFail("Watcher-stale automatic targets must return typed retry coverage")
        }
        XCTAssertTrue(presentation.issues.contains { issue in
            switch issue {
            case .automatic(.incomplete(_)), .automatic(.pending(_)), .automatic(.stale(_)),
                 .publicationStale(.automatic(_)):
                true
            case .coordinationUnavailable, .cancelled, .candidate, .pending, .unavailable,
                 .automatic, .freezeUnavailable, .renderUnavailable, .publicationStale:
                false
            }
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionWithIncompleteDefinitionUniversePublishesNoTargets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .none,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { _, _ in
                .definitionUniverse(.incomplete(
                    progress: .notStarted,
                    remainingCount: nil,
                    retry: nil
                ))
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })

        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceIdentity.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        let providerCount = fixture.providerAccessCount.value
        let buildCount = fixture.buildCount.value
        let manifestReadCount = fixture.manifestReadCount.value

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 1)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .incomplete(reasons) = result.roots.first?.coverage,
              case let .graph(.definitionUniverse(rootEpoch, _, _, _)) = reasons.first
        else { return XCTFail("Expected typed incomplete definition-universe coverage") }
        XCTAssertEqual(rootEpoch, sourceIdentity.rootEpoch)
        XCTAssertNotEqual(target.id, source.id)
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(fixture.buildCount.value, buildCount)
        XCTAssertEqual(fixture.manifestReadCount.value, manifestReadCount)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDoesNotResolveForeignOnlyDefinition() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func value() -> ForeignDefinition
                }
                """
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/ForeignDefinition.swift": "struct ForeignDefinition {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [firstFile, secondFile] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let firstReady = try XCTUnwrap(readyByFileID[firstFile.id])
        let secondReady = try XCTUnwrap(readyByFileID[secondFile.id])
        let firstGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: firstReady.ticket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(firstGraphPublished)
        let secondGraphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: secondReady.ticket.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(secondGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: firstReady.ticket,
            contributionsByFileID: [
                firstFile.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["ForeignDefinition"]
                )
            ]
        )
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: secondReady.ticket,
            contributionsByFileID: [
                secondFile.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["ForeignDefinition"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.targets.contains { $0.fileID == secondFile.id })
        XCTAssertEqual(result.roots.first?.rootEpoch.rootID, firstLoaded.id)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionQueriesTwoRootsIndependentlyAndMergesAtResponseBoundary() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol FirstSource {
                    func value() -> FirstTarget
                }
                """,
                "Sources/Target.swift": "struct FirstTarget {}\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": """
                protocol SecondSource {
                    func value() -> SecondTarget
                }
                """,
                "Sources/Target.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        var targetIDs = Set<UUID>()
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
            let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
            sourceIDs.append(source.id)
            targetIDs.insert(target.id)
            let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
            let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
            let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
            let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceTicket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceTicket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [root == firstRoot ? "FirstSource" : "SecondSource"],
                        references: [root == firstRoot ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [root == firstRoot ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: Array(sourceIDs.reversed()),
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(Set(result.targets.map(\.fileID)), targetIDs)
        XCTAssertEqual(Set(result.roots.map(\.rootEpoch.rootID)), Set(loadedRoots.map(\.id)))
        for rootResult in result.roots {
            XCTAssertTrue(rootResult.targets.allSatisfy { $0.rootEpoch == rootResult.rootEpoch })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)
        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionReportsMissingPendingUnavailableAndStaleSourcesWithoutNewWork() async throws {
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Pending.swift": "struct Pending {}\n"]
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let pending = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let missing = try WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000")),
            catalogGeneration: identity.catalogGeneration
        )
        let stale = WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: file.id,
            catalogGeneration: identity.catalogGeneration &+ 1
        )
        let providerCount = fixture.providerAccessCount.value

        let expectedIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue] = [
            .notCataloged(missing),
            .pending(identity, pending),
            .staleCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        ]
        let firstResult = try await store.resolveAutomaticCodemapSelection(
            sources: [identity, missing, stale],
            rootScope: .visibleWorkspace
        )
        let secondResult = try await store.resolveAutomaticCodemapSelection(
            sources: [stale, identity, missing],
            rootScope: .visibleWorkspace
        )

        let expectedCoverage = WorkspaceCodemapAutomaticSelectionCoverage.stale(
            .sourceCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        )
        XCTAssertEqual(firstResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(secondResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(firstResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(secondResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: store, ticket: pending)

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Unavailable.swift": "struct Unavailable {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainIdentities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [plainFile.id],
            rootScope: .visibleWorkspace
        )
        let plainIdentity = try XCTUnwrap(plainIdentities.first)
        let plainTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: plainFile.id))
        let unavailable = try await settledResult(store: store, ticket: plainTicket)
        guard case let .unavailable(unavailableReason) = unavailable else {
            return XCTFail("Expected non-Git demand to become unavailable.")
        }
        let unavailableResult = try await store.resolveAutomaticCodemapSelection(
            sources: [plainIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(
            unavailableResult.roots.first?.sourceIssues,
            [.unavailable(plainIdentity, unavailableReason)]
        )
        await store.unloadRoot(id: loaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testAutomaticSelectionRejectsSourceOutsideRequestedRootScopeBeforeGraphQuery() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let secondOnlyScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [secondRoot.path],
            physicalRootPaths: []
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: secondOnlyScope
        )

        XCTAssertEqual(result.targets, [])
        XCTAssertEqual(result.roots.first?.sourceIssues, [.outsideRootScope(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionRootReloadDropsOldTargets() async throws {
        let graphProbe = CodemapSelectionGraphProbe()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let targetReady = try XCTUnwrap(readyByFileID[target.id])
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceReady.ticket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let beforeReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertFalse(beforeReload.targets.isEmpty)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let afterReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(afterReload.targets.isEmpty)
        XCTAssertEqual(afterReload.roots.first?.coverage, .stale(.rootEpochNotCurrent(identity.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testAutomaticSelectionGraphProofRevocationAfterQueryFailsClosedWithoutTargets() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { _ in
                await queryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let targetReady = try XCTUnwrap(readyByFileID[target.id])
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceReady.ticket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let current = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(current.targets.map(\.fileID), [target.id])
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let targetCancelled = await store.cancelCodemapArtifactDemand(targetReady.ticket)
        XCTAssertTrue(targetCancelled)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertTrue(rootResult.targetIssues.isEmpty)
        XCTAssertEqual(
            rootResult.coverage,
            .unavailable(.graph(.invalidGraphResult(identity.rootEpoch)))
        )
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDropsResultWhenSourceChangesAfterGraphQuery() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(automaticSelectionQueryHook: { _ in
            await queryGate.enterIfArmedAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        var sourceTicket: WorkspaceCodemapArtifactDemandTicket?
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            if file.id == source.id { sourceTicket = ticket }
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let ticket = try XCTUnwrap(sourceTicket)
        let cancelled = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(cancelled)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(
            result.roots.first?.coverage,
            .stale(.graph(.currentness(identity.rootEpoch)))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesWhenPendingSourceBecomesReadyDuringGraphAwait() async throws {
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { let missing: Missing }\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await pendingPublicationGate.release()
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await pendingPublicationGate.enterIfArmedAndWait()
            },
            automaticSelectionQueryHook: { _ in
                await queryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let readyFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Ready.swift"
        })
        let pendingFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })
        let readyTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: readyFile.id
        ))
        _ = try await readyResult(settledResult(store: store, ticket: readyTicket))
        let graphPublished = await graphProbe.waitUntilPublished(rootEpoch: readyTicket.rootEpoch)
        XCTAssertTrue(graphPublished)

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: pendingFile.id
        ))
        let publicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [readyFile.id, pendingFile.id],
            rootScope: .visibleWorkspace
        )
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)

        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))
        await queryGate.release()
        let result = try await task.value

        XCTAssertFalse(result.roots.flatMap(\.sourceIssues).contains {
            if case .pending = $0 { return true }
            return false
        })
        XCTAssertFalse(result.roots.contains {
            if case .stale(.sourceStateChanged(_)) = $0.coverage { return true }
            return false
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionResnapshotsScopeChangeBetweenRootPartitions() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": "struct FirstSource { let target: FirstTarget }\n",
                "Sources/Target.swift": "struct FirstTarget {}\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": "struct SecondSource { let target: SecondTarget }\n",
                "Sources/Target.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryGate = CodemapRootSuspensionGate()
        let queriedRootEpochs = CodemapLockedValues<WorkspaceCodemapRootEpoch>()
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { rootEpoch in
                queriedRootEpochs.append(rootEpoch)
                await queryGate.enterAndWait(rootEpoch)
            }
        )
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        var targetIDs = Set<UUID>()
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Source.swift"
            })
            let target = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Target.swift"
            })
            sourceIDs.append(source.id)
            targetIDs.insert(target.id)
            var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
            for file in [source, target] {
                let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
                readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
            }
            let sourceReady = try XCTUnwrap(readyByFileID[source.id])
            let targetReady = try XCTUnwrap(readyByFileID[target.id])
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceReady.ticket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            let isFirstRoot = root == firstRoot
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceReady.ticket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [isFirstRoot ? "FirstSource" : "SecondSource"],
                        references: [isFirstRoot ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [isFirstRoot ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceIDs,
            rootScope: .visibleWorkspace
        )
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let entered = await queryGate.waitUntilEntered()
        let enteredRootEpoch = try XCTUnwrap(entered)
        let removedRoot = try XCTUnwrap(loadedRoots.first {
            $0.id != enteredRootEpoch.rootID
        })
        await store.unloadRoot(id: removedRoot.id)
        await queryGate.release()
        let result = try await task.value

        XCTAssertEqual(queriedRootEpochs.values, [enteredRootEpoch, enteredRootEpoch])
        XCTAssertEqual(targetIDs.count, 2)
        XCTAssertEqual(result.roots.count, 1)
        let removedResult = try XCTUnwrap(result.roots.first {
            $0.rootEpoch.rootID == removedRoot.id
        })
        XCTAssertEqual(
            removedResult.coverage,
            .stale(.rootEpochNotCurrent(removedResult.rootEpoch))
        )
        XCTAssertTrue(removedResult.targets.isEmpty)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.targets.allSatisfy { !targetIDs.contains($0.fileID) })
        XCTAssertNil(result.publicationReceipt)
        for loaded in loadedRoots where loaded.id != removedRoot.id {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionLaterRootBudgetDiscardsEarlierTargetsAndReceipt() async throws {
        let graphProbe = CodemapSelectionGraphProbe()
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": "protocol FirstSource { var target: FirstTarget { get } }\n",
                "Sources/Target.swift": "struct FirstTarget {}\n"
            ]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": "protocol SecondSource { var target: SecondTarget { get } }\n",
                "Sources/Target.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await store.loadRoot(path: rootURL.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Source.swift"
            })
            let target = try XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Target.swift"
            })
            sourceIDs.append(source.id)
            let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
            let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
            let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
            let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
            let graphPublished = await graphProbe.waitUntilPublished(
                rootEpoch: sourceTicket.rootEpoch,
                minimumNodeCount: 2
            )
            XCTAssertTrue(graphPublished)
            _ = try await publishCompleteAutomaticSelectionProjection(
                fixture: fixture,
                graphProbe: graphProbe,
                ticket: sourceTicket,
                contributionsByFileID: [
                    source.id: CodeMapSelectionGraphContribution(
                        artifactKey: sourceReady.snapshot.artifactKey,
                        definitions: [rootURL == firstRootURL ? "FirstSource" : "SecondSource"],
                        references: [rootURL == firstRootURL ? "FirstTarget" : "SecondTarget"]
                    ),
                    target.id: CodeMapSelectionGraphContribution(
                        artifactKey: targetReady.snapshot.artifactKey,
                        definitions: [rootURL == firstRootURL ? "FirstTarget" : "SecondTarget"],
                        references: []
                    )
                ]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceIDs,
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .budget(reason) = result.aggregateCoverage else {
            return XCTFail("Expected aggregate target budget")
        }
        XCTAssertEqual(reason, .targetLimit(attempted: 2, limit: 1))
        for root in loadedRoots {
            await store.unloadRoot(id: root.id)
        }
    }

    func testAutomaticSelectionReturnsTypedTargetLimitBudgetCoverage() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let budgetGraphProbe = CodemapSelectionGraphProbe()
        let budgetStore = fixture.makeStore(
            selectionGraphFactory: budgetGraphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        let loaded = try await budgetStore.loadRoot(path: root.path)
        let files = await budgetStore.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, first, second] {
            let ticket = try await pendingTicket(budgetStore.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: budgetStore, ticket: ticket))
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let firstReady = try XCTUnwrap(readyByFileID[first.id])
        let secondReady = try XCTUnwrap(readyByFileID[second.id])
        let identities = await budgetStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let budgetGraphPublished = await budgetGraphProbe.waitUntilPublished(
            rootEpoch: identity.rootEpoch,
            minimumNodeCount: files.count
        )
        XCTAssertTrue(budgetGraphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: budgetGraphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["FirstTarget", "SecondTarget"]
                ),
                first.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["FirstTarget"],
                    references: []
                ),
                second.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["SecondTarget"],
                    references: []
                )
            ]
        )
        let budgetResult = try await budgetStore.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(budgetResult.roots.isEmpty)
        XCTAssertTrue(budgetResult.targets.isEmpty)
        XCTAssertNil(budgetResult.publicationReceipt)
        XCTAssertEqual(
            budgetResult.aggregateCoverage,
            .budget(.targetLimit(attempted: 2, limit: 1))
        )
        await budgetStore.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionTranslatesRebuildingRuntimeToBusyConsumerCoverage() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Source.swift": "struct Source {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.rebuilding)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: identity.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: ready.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: []
                )
            ]
        )
        let busyReason = WorkspaceCodemapStoreSelectionGraphQueryBusyReason.runtime(
            rootEpoch: identity.rootEpoch,
            reason: .rebuilding
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        let rootResult = try XCTUnwrap(result.roots.first)

        XCTAssertEqual(queryCount.value, 1)
        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(rootResult.rootEpoch, identity.rootEpoch)
        XCTAssertEqual(rootResult.targets, [])
        XCTAssertEqual(rootResult.sourceIssues, [])
        XCTAssertEqual(rootResult.targetIssues, [])
        XCTAssertEqual(rootResult.coverage, .busy(busyReason))
        XCTAssertEqual(rootResult.graphTargetCount, 0)
        XCTAssertEqual(rootResult.graphResolutionCount, 0)
        XCTAssertEqual(rootResult.graphReferenceFailureCount, 0)
        XCTAssertEqual(rootResult.graphByteCount, 0)
        XCTAssertNil(rootResult.graphKey)
        XCTAssertEqual(result.aggregateCoverage, .busy(busyReason))
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesTransientGraphReadinessThenPublishesReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                switch queryCount.incrementAndGet() {
                case 1:
                    return .unavailable(.notBuilt)
                case 2:
                    return .unavailable(.staleCurrentness(currentKey: query.key))
                default:
                    return nil
                }
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertGreaterThanOrEqual(queryCount.value, 3)
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        let receipt = try XCTUnwrap(result.publicationReceipt)
        XCTAssertEqual(receipt.targets, result.targets)
        guard case let .complete(proofs) = result.aggregateCoverage else {
            return XCTFail("Expected complete coverage after transient graph readiness retries, got \(result.aggregateCoverage)")
        }
        XCTAssertEqual(receipt.coverageProofs, proofs)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRuntimeBudgetRemainsTerminalWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.outputBudgetExceeded(.resolvedTargets))
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        guard case .budget = result.aggregateCoverage else {
            return XCTFail("Expected terminal budget coverage, got \(result.aggregateCoverage)")
        }
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertLessThanOrEqual(queryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRuntimeInvalidSnapshotRemainsTerminalWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.invalidSnapshot)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(
            result.aggregateCoverage,
            .unavailable(.graph(.runtime(rootEpoch: identity.rootEpoch, reason: .invalidSnapshot)))
        )
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(queryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionAccountingEqualityBoundaryFailsBeforeGraphQuery() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let queryCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumSourceIssueCount: 1,
                maximumTargetCount: 1,
                maximumResolutionCount: 1,
                maximumReferenceFailureCount: 1,
                maximumByteCount: 1
            ),
            automaticSelectionAccountingMaximum: 1,
            automaticSelectionQueryHook: { _ in queryCount.increment() }
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots, [])
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .budget(.accountingOverflow))
        XCTAssertEqual(queryCount.value, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
    }

    func testAutomaticSelectionAccountingOverflowFailsClosedWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let queryCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            ),
            automaticSelectionAccountingMaximum: 1,
            automaticSelectionQueryHook: { _ in queryCount.increment() }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        _ = try XCTUnwrap(identities.first)

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots, [])
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .budget(.accountingOverflow))
        XCTAssertEqual(queryCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionWithoutExistingDemandPerformsNoIOOrArtifactWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let root = try fixture.makePlainRoot(files: [
            "Sources/Source.swift": "struct Source {}\n"
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.first?.sourceIssues, [.notDemanded(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": "struct Target {}\n",
                "Sources/Source.swift": "struct Source { let target: Target }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let busyOutcomes = CodemapLockedCounter()
        let sequence = CodemapAutomaticSelectionSequenceHarness()
        let settledOutcomes = CodemapLockedValues<WorkspaceCodemapArtifactDemandResult>()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await sequence.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory,
            demandResultHook: { ticket, result in
                guard selectionPhase.value > 0,
                      sourceFileIDs.values.contains(ticket.fileID)
                else { return result }
                let invocation = await sequence.recordDemand(ticket)
                sourceDemandInvocations.increment()
                if invocation <= 2 {
                    busyOutcomes.increment()
                    return .busy(retryAfterMilliseconds: 1)
                }
                return result
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: warmSourceTicket
        )
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(10)
            ),
            automaticSelectionWaiter: .init { _ in try await sequence.wait() }
        )

        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let operation = Task { () throws -> WorkspaceCodemapAutomaticSelectionResult in
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            for demandIndex in 1 ... 3 {
                let pendingWaitIndex = demandIndex * 2 - 1
                guard await sequence.waitUntilWaitCount(pendingWaitIndex, timeout: .seconds(2)),
                      let tickets = await sequence.waitUntilDemandCount(demandIndex, timeout: .seconds(2)),
                      let ticket = tickets.last
                else { throw CodemapStoreTestError.timedOut }
                try await settledOutcomes.append(settledResult(
                    store: store,
                    ticket: ticket,
                    timeout: .seconds(2)
                ))
                await sequence.releaseWait(pendingWaitIndex)
                if demandIndex < 3 {
                    let retryWaitIndex = pendingWaitIndex + 1
                    guard await sequence.waitUntilWaitCount(retryWaitIndex, timeout: .seconds(2)) else {
                        throw CodemapStoreTestError.timedOut
                    }
                    await sequence.releaseWait(retryWaitIndex)
                }
            }
            return try await resolution.value
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            operation.cancel()
            await sequence.releaseAll()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy-retry cleanup did not drain within its external bound")
            return XCTFail("Busy-retry sequence did not complete within the external bound")
        }
        let result = try await operation.value

        XCTAssertEqual(sourceDemandInvocations.value, 3)
        XCTAssertEqual(busyOutcomes.value, 2)
        let selectionTickets = await sequence.recordedTickets
        let waitCount = await sequence.waitCount
        XCTAssertEqual(selectionTickets.count, 3)
        XCTAssertEqual(waitCount, 5)
        XCTAssertEqual(settledOutcomes.values.count, 3)
        for outcome in settledOutcomes.values.prefix(2) {
            guard case .unavailable(.busy) = outcome else {
                return XCTFail("Expected the first two scoped demand outcomes to be busy")
            }
        }
        guard let finalOutcome = settledOutcomes.values.last,
              case .ready = finalOutcome
        else {
            return XCTFail("Expected the third scoped demand outcome to be ready")
        }
        XCTAssertEqual(result.targets.map(\.fileID), [setup.id])
        let receipt = try XCTUnwrap(
            result.publicationReceipt,
            "Expected receipt for \(result.aggregateCoverage)"
        )
        guard case let .complete(proofs) = result.aggregateCoverage else {
            return XCTFail("Expected complete proof-backed coverage after busy retries")
        }
        XCTAssertEqual(receipt.coverageProofs, proofs)
        XCTAssertEqual(receipt.targets, result.targets)
        XCTAssertNotNil(receipt.publicationLease)
        let publication = await store.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(publication, .current(result.targets))
        for ticket in selectionTickets {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
        }
        let receiptSourceTicket = try XCTUnwrap(receipt.sourceTickets.first)
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: receiptSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionBusySourceRoundBoundStopsBeforeDeadline() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": "struct Setup {}\n",
                "Sources/Source.swift": "struct Source {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let sequence = CodemapAutomaticSelectionSequenceHarness()
        let settledOutcomes = CodemapLockedValues<WorkspaceCodemapArtifactDemandResult>()
        addTeardownBlock {
            await sequence.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            guard selectionPhase.value > 0,
                  sourceFileIDs.values.contains(ticket.fileID)
            else { return result }
            _ = await sequence.recordDemand(ticket)
            sourceDemandInvocations.increment()
            return .busy(retryAfterMilliseconds: 1)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(10)
            ),
            automaticSelectionWaiter: .init { _ in try await sequence.wait() }
        )

        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let operation = Task { () throws -> WorkspaceCodemapAutomaticSelectionResult in
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            for demandIndex in 1 ... 3 {
                let pendingWaitIndex = demandIndex * 2 - 1
                guard await sequence.waitUntilWaitCount(pendingWaitIndex, timeout: .seconds(2)),
                      let tickets = await sequence.waitUntilDemandCount(demandIndex, timeout: .seconds(2)),
                      let ticket = tickets.last
                else { throw CodemapStoreTestError.timedOut }
                try await settledOutcomes.append(settledResult(
                    store: store,
                    ticket: ticket,
                    timeout: .seconds(2)
                ))
                await sequence.releaseWait(pendingWaitIndex)
                if demandIndex < 3 {
                    let retryWaitIndex = pendingWaitIndex + 1
                    guard await sequence.waitUntilWaitCount(retryWaitIndex, timeout: .seconds(2)) else {
                        throw CodemapStoreTestError.timedOut
                    }
                    await sequence.releaseWait(retryWaitIndex)
                }
            }
            return try await resolution.value
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            operation.cancel()
            await sequence.releaseAll()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy round-bound cleanup did not drain within its external bound")
            return XCTFail("Busy round-bound sequence did not complete within the external bound")
        }
        let result = try await operation.value

        XCTAssertEqual(sourceDemandInvocations.value, 3)
        let selectionTickets = await sequence.recordedTickets
        let waitCount = await sequence.waitCount
        XCTAssertEqual(selectionTickets.count, 3)
        XCTAssertEqual(waitCount, 5)
        XCTAssertEqual(settledOutcomes.values.count, 3)
        for outcome in settledOutcomes.values {
            guard case .unavailable(.busy) = outcome else {
                return XCTFail("Expected every scoped demand outcome to remain busy")
            }
        }
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .pending(reasons) = result.aggregateCoverage else {
            return XCTFail("Expected bounded busy pending coverage")
        }
        XCTAssertEqual(reasons.count, 1)
        if case let .sourceBusy(_, attempts) = reasons[0] {
            XCTAssertEqual(attempts, 2)
        } else {
            XCTFail("Expected source busy reason")
        }
        for ticket in selectionTickets {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: warmSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionBusySourceDeadlineStopsBeforeRoundBound() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": "struct Setup {}\n",
                "Sources/Source.swift": "struct Source {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let selectionTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            guard selectionPhase.value > 0,
                  sourceFileIDs.values.contains(ticket.fileID)
            else { return result }
            sourceDemandInvocations.increment()
            selectionTickets.append(ticket)
            return .busy(retryAfterMilliseconds: 1)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 100,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .milliseconds(500)
            ),
            automaticSelectionWaiter: .production
        )
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let resolution = Task {
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            return try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy deadline cleanup did not drain within its external bound")
            return XCTFail("Busy deadline resolution did not complete within the external bound")
        }
        let result = try await resolution.value

        XCTAssertGreaterThan(sourceDemandInvocations.value, 0)
        XCTAssertLessThan(sourceDemandInvocations.value, 100)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .stale(.publicationReceipt))
        for ticket in selectionTickets.values {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: warmSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSourceDemandLimitAllowsNAndRejectsNPlusOneBeforeFanout() async throws {
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try fixture.makePlainRoot(files: [
            "Sources/First.swift": "struct First {}\n",
            "Sources/Second.swift": "struct Second {}\n",
            "Sources/Third.swift": "struct Third {}\n"
        ])
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumRawSourceCount: 2,
                maximumUniqueSourceCount: 2,
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        let demandCount = CodemapLockedCounter()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, _ in demandCount.increment() }
        )

        _ = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: Array(files.prefix(2).map(\.id)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)

        let rejected = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: files.map(\.id),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)
        XCTAssertEqual(rejected.targets, [])
        XCTAssertNil(rejected.publicationReceipt)
        XCTAssertEqual(rejected.aggregateCoverage, .budget(.sourceLimit(attempted: 3, limit: 2)))
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRequiresReadySourceCoverageInEveryRoot() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let repositoryRoot = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": "struct Plain {}\n"
        ])
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let repository = try await store.loadRoot(path: repositoryRoot.path)
        let plain = try await store.loadRoot(path: plainRoot.path)
        let repositoryFiles = await store.files(inRoot: repository.id)
        let source = try XCTUnwrap(repositoryFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let plainFiles = await store.files(inRoot: plain.id)
        let plainSource = try XCTUnwrap(plainFiles.first)
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id, plainSource.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(result.aggregateCoverage, .unavailable(.noReadySources))
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: repository.id)
        await store.unloadRoot(id: plain.id)
    }

    func testAutomaticSelectionCancellationMidSourceFanoutCancelsOnlyIssuedTickets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fanoutGate = CodemapSuspensionGate()
        let readyPublicationGate = CodemapSuspensionGate()
        addTeardownBlock {
            await fanoutGate.release()
            await readyPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(
            cancellationCleanupHook: { ticket in
                cancelledTickets.append(ticket)
            },
            readyPublicationHook: { _ in
                await readyPublicationGate.enterAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        let demandCount = CodemapLockedCounter()
        let issuedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, result in
                demandCount.increment()
                if case let .pending(ticket) = result {
                    issuedTickets.append(ticket)
                } else if case let .ready(ready) = result {
                    issuedTickets.append(ready.ticket)
                }
                if demandCount.value == 1 {
                    await fanoutGate.enterAndWait()
                }
            }
        )
        let task = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: files.map(\.id),
                rootScope: .visibleWorkspace
            )
        }
        let fanoutEntered = await fanoutGate.waitUntilEntered()
        XCTAssertTrue(fanoutEntered)
        let readyPublicationEntered = await readyPublicationGate.waitUntilEntered()
        XCTAssertTrue(readyPublicationEntered)
        let selectionTicket = try XCTUnwrap(issuedTickets.values.first)
        let joinedResult = await store.requestCodemapArtifact(forFileID: files[0].id)
        let joinedTicket: WorkspaceCodemapArtifactDemandTicket
        switch joinedResult {
        case let .pending(ticket):
            joinedTicket = ticket
        case let .ready(ready):
            joinedTicket = ready.ticket
        case let .unavailable(reason):
            return XCTFail("Expected joined demand, got \(reason)")
        }
        XCTAssertNotEqual(selectionTicket.retainID, joinedTicket.retainID)
        let joinedRetainCount = await store.codemapArtifactDemandRetainCountForTesting(selectionTicket)
        XCTAssertEqual(joinedRetainCount, 2)
        task.cancel()
        await fanoutGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(demandCount.value, 1)
        XCTAssertEqual(issuedTickets.values.count, 1)
        let survivingRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(survivingRetainCount, 1)
        XCTAssertTrue(cancelledTickets.values.isEmpty)
        let survivingStatus = await store.codemapArtifactDemandStatus(joinedTicket)
        guard case .pending = survivingStatus else {
            return XCTFail("Expected the surviving retain to remain pending behind the publication gate")
        }
        await readyPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: joinedTicket))
        XCTAssertTrue(cancelledTickets.values.isEmpty)

        let released = await store.cancelCodemapArtifactDemand(joinedTicket)
        XCTAssertTrue(released)
        let finalRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(finalRetainCount, 0)
        XCTAssertEqual(cancelledTickets.values, [joinedTicket])
        let releasedStatus = await store.codemapArtifactDemandStatus(joinedTicket)
        guard case .unavailable(.staleCurrentness) = releasedStatus else {
            return XCTFail("Expected the released caller token to become stale")
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionAboveManifestCacheCountPermitsSmallSealedMatch() async throws {
        let manifestAdoptionLimit = 3
        let supportedCandidateCount = manifestAdoptionLimit + 1
        var repositoryFiles = [
            "Sources/Source.swift": "struct Source { let target: Target }\n",
            "Sources/Target.swift": "struct Target {}\n"
        ]
        let extraSupportedCandidateCount = supportedCandidateCount - repositoryFiles.count
        for index in 0 ..< extraSupportedCandidateCount {
            repositoryFiles[String(format: "Sources/Enterprise/File%03d.swift", index)] =
                "struct Enterprise\(index) {}\n"
        }
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true,
            bindingEnginePolicy: smallManifestAdoptionPolicy(recordLimit: manifestAdoptionLimit)
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        let proof = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(proof.catalogCompletion.supportedCandidateCount, UInt64(supportedCandidateCount))
        XCTAssertGreaterThan(
            proof.catalogCompletion.supportedCandidateCount,
            UInt64(manifestAdoptionLimit)
        )
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertNotNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness() async throws {
        let unsupportedInventoryCount = 8193
        let selectionQueryGate = CodemapArmableSuspensionGate()
        let selectionQueryCount = CodemapLockedCounter()
        let repositoryFiles = [
            "Sources/Source.swift": "struct Source { let target: Target }\n",
            "Sources/Target.swift": "struct Target {}\n"
        ]
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        addTeardownBlock {
            repositoryFixture.cleanup()
        }
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let unsupportedDirectory = root.appendingPathComponent("Assets/Unsupported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsupportedDirectory,
            withIntermediateDirectories: true
        )
        let unsupportedSeed = unsupportedDirectory.appendingPathComponent(
            String(format: "File%05d.txt", 0)
        )
        try Self.write("ignored\n", to: unsupportedSeed)
        for index in 1 ..< unsupportedInventoryCount {
            let linkedFile = unsupportedDirectory.appendingPathComponent(
                String(format: "File%05d.txt", index)
            )
            try FileManager.default.linkItem(at: unsupportedSeed, to: linkedFile)
        }
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await selectionQueryGate.release()
            await fixture.shutdown()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { _ in
                selectionQueryCount.increment()
                await selectionQueryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        let proof = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let selectionQueryCountBeforeSelection = selectionQueryCount.value
        let buildCountBeforeSelection = fixture.buildCount.value

        await selectionQueryGate.arm()
        let selectionTask = Task {
            try await WorkspaceSelectionMutationService(store: store)
                .resolveAutomaticCodemapSelection(
                    sourceFileIDs: [source.id],
                    rootScope: .visibleWorkspace
                )
        }
        let queryEntered = await selectionQueryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        XCTAssertEqual(selectionQueryCount.value - selectionQueryCountBeforeSelection, 1)
        let responsiveInventory = await store.files(inRoot: loaded.id)
        let unsupportedResponsiveInventory = responsiveInventory.filter {
            $0.standardizedRelativePath.hasPrefix("Assets/Unsupported/")
        }
        XCTAssertEqual(proof.catalogCompletion.supportedCandidateCount, 2)
        XCTAssertEqual(responsiveInventory.count, 2 + unsupportedInventoryCount)
        XCTAssertEqual(unsupportedResponsiveInventory.count, unsupportedInventoryCount)
        XCTAssertEqual(
            responsiveInventory.count - Int(proof.catalogCompletion.supportedCandidateCount),
            unsupportedInventoryCount
        )
        await selectionQueryGate.release()
        let result = try await selectionTask.value

        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertNotNil(result.publicationReceipt)
        XCTAssertGreaterThan(selectionQueryCount.value - selectionQueryCountBeforeSelection, 0)
        XCTAssertEqual(fixture.buildCount.value - buildCountBeforeSelection, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSealedGraphMatchedTargetBudgetFailsClosed() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var first: FirstTarget { get }; var second: SecondTarget { get } }\n",
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, first, second] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let firstReady = try XCTUnwrap(readyByFileID[first.id])
        let secondReady = try XCTUnwrap(readyByFileID[second.id])
        _ = await graphProbe.waitUntilPublished(rootEpoch: sourceReady.ticket.rootEpoch, minimumNodeCount: 3)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["FirstTarget", "SecondTarget"]
                ),
                first.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["FirstTarget"],
                    references: []
                ),
                second.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["SecondTarget"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(maximumCandidateDemandCount: 1)
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.aggregateCoverage, .budget(.candidateDemandLimit(attempted: 2, limit: 1)))
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSealedGraphResultByteBudgetFailsClosed() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100,
                maximumByteCount: 1
            )
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        _ = await graphProbe.waitUntilPublished(rootEpoch: sourceTicket.rootEpoch, minimumNodeCount: 2)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        guard case let .budget(.byteLimit(attempted, limit)) = result.aggregateCoverage else {
            return XCTFail("Expected fail-closed result-byte budget")
        }
        XCTAssertGreaterThan(attempted, limit)
        XCTAssertEqual(limit, 1)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testColdAutomaticSelectionNeverPlansSameNamedDefinitionFromAnotherRoot() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n"]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Target.swift": "struct Target {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let warmStore = fixture.makeStore()
        var warmRoots: [WorkspaceRootRecord] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await warmStore.loadRoot(path: rootURL.path)
            warmRoots.append(loaded)
            for file in await warmStore.files(inRoot: loaded.id) {
                let ticket = try await pendingTicket(
                    warmStore.requestCodemapArtifact(forFileID: file.id)
                )
                _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            }
        }
        for root in warmRoots {
            await warmStore.unloadRoot(id: root.id)
        }

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let firstColdRoot = try await coldStore.loadRoot(path: firstRootURL.path)
        let secondColdRoot = try await coldStore.loadRoot(path: secondRootURL.path)
        let firstColdEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: firstColdRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: firstColdRoot.id)
        )
        let secondColdEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: secondColdRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: secondColdRoot.id)
        )
        let firstCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: firstColdEpoch
        )
        let secondCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: secondColdEpoch
        )
        XCTAssertTrue(firstCoverageComplete)
        XCTAssertTrue(secondCoverageComplete)
        let firstFiles = await coldStore.files(inRoot: firstColdRoot.id)
        let source = try XCTUnwrap(firstFiles.first)
        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.roots.contains { $0.rootEpoch.rootID == secondColdRoot.id })
        await coldStore.unloadRoot(id: firstColdRoot.id)
        await coldStore.unloadRoot(id: secondColdRoot.id)
    }

    func testColdAutomaticSelectionBuildsOnlyMatchedMissingCASTargetAtBackgroundPriority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        var targetKey: CodeMapArtifactKey?
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            let ready = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            if file.standardizedRelativePath == "Sources/Target.swift" {
                targetKey = ready.snapshot.artifactKey
            }
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)
        try FileManager.default.removeItem(at: fixture.artifactURL(for: XCTUnwrap(targetKey)))

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = try fixture.makeFreshStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldRootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: coldRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: coldRoot.id)
        )
        let coldCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch
        )
        XCTAssertTrue(coldCoverageComplete)
        let coldGraph = try XCTUnwrap(coldGraphProbe.graph(rootEpoch: coldRootEpoch))
        let initialColdGraphAccounting = await coldGraph.accounting()
        let initialColdGraphKey = try XCTUnwrap(initialColdGraphAccounting.currentObservedKey)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let sourceTicket = try await pendingTicket(
            coldStore.requestCodemapArtifact(forFileID: source.id)
        )
        addTeardownBlock {
            _ = await coldStore.cancelCodemapArtifactDemand(sourceTicket)
        }
        _ = try await readyResult(settledResult(store: coldStore, ticket: sourceTicket))
        let sourceGraphClock = ContinuousClock()
        let sourceGraphPublished = await coldStore.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: sourceGraphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(sourceGraphPublished)
        let sourceCoverageKeyValue = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch,
            after: initialColdGraphKey.contributionGeneration
        )
        let sourceCoverageKey = try XCTUnwrap(sourceCoverageKeyValue)
        let sourceIdentities = await coldStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let planDisposition = await coldStore.planAutomaticCodemapSelectionCandidates(
            sources: sourceIdentities,
            rootScope: .visibleWorkspace
        )
        guard case let .ready(candidatePlan) = planDisposition else {
            XCTFail("Expected ready candidate plan, got \(planDisposition)")
            return
        }
        XCTAssertEqual(
            candidatePlan.candidates.map(\.identity.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        let targetCandidate = try XCTUnwrap(candidatePlan.candidates.first)
        let ownedTargetValue = await coldStore.requestAutomaticCodemapArtifactWithOwnership(
            candidate: targetCandidate,
            rootScope: .visibleWorkspace,
            rootScopeEpochs: candidatePlan.rootScopeEpochs,
            coverageProofs: candidatePlan.coverageProofs
        )
        let ownedTarget = try XCTUnwrap(ownedTargetValue)
        let targetTicket: WorkspaceCodemapArtifactDemandTicket = switch ownedTarget.ownership {
        case let .created(ticket), let .joined(ticket):
            ticket
        case .notAcquired:
            try pendingTicket(ownedTarget.result)
        }
        addTeardownBlock {
            _ = await coldStore.cancelCodemapArtifactDemand(targetTicket)
        }
        _ = try await readyResult(settledResult(store: coldStore, ticket: targetTicket))
        let targetGraphClock = ContinuousClock()
        let targetGraphPublished = await coldStore.waitForCodemapGraphPublication(
            rootEpoch: targetTicket.rootEpoch,
            deadline: targetGraphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(targetGraphPublished)
        let targetCoverageKey = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch,
            after: sourceCoverageKey.contributionGeneration
        )
        XCTAssertNotNil(targetCoverageKey)

        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount + 1)
        XCTAssertEqual(fixture.buildPriorities.values.last, .background)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        await coldStore.unloadRoot(id: coldRoot.id)
    }

    func testAutomaticSelectionFinalizationDeadlineFailsClosedWhileCleanupContinues() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let cleanupGate = CodemapSuspensionGate()
        addTeardownBlock {
            await cleanupGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        for file in await warmStore.files(inRoot: warmRoot.id) {
            let ticket = try await pendingTicket(warmStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        await warmStore.unloadRoot(id: warmRoot.id)

        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { _ in
                await cleanupGate.enterAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let coverageComplete = await graphProbe.waitUntilCompleteCoverage(rootEpoch: rootEpoch)
        XCTAssertTrue(coverageComplete)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let resolution = Task {
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            return try await WorkspaceSelectionMutationService(store: store)
                .resolveAutomaticCodemapSelection(
                    sourceFileIDs: [source.id],
                    rootScope: .visibleWorkspace
                )
        }

        let cleanupEntered = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupEntered)
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            await cleanupGate.release()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Finalization cleanup did not drain within its external bound")
            return XCTFail("Finalization deadline did not fail closed within the external bound")
        }
        let result = try await resolution.value
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .stale(.publicationReceipt))
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        let targetRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: rootEpoch,
            fileID: target.id
        )
        XCTAssertEqual(targetRetainCount, 0)

        await cleanupGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled
        )
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            let warmResult = try await settledResult(store: warmStore, ticket: ticket)
            guard case .ready = warmResult else {
                XCTFail("Expected warm codemap demand for \(file.standardizedRelativePath) to be ready, got \(warmResult)")
                throw CodemapStoreTestError.expectedReady
            }
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldRootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: coldRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: coldRoot.id)
        )
        let coldCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch
        )
        XCTAssertTrue(coldCoverageComplete)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        // This test verifies cold CAS candidate discovery/publication semantics, not the mutation
        // service's default short round-bound transient pending behavior. Under CI load, the
        // background candidate demand may need more than six status checks to become ready.
        let service = WorkspaceSelectionMutationService(
            store: coldStore,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 64,
                maximumTotalWait: .seconds(10)
            )
        )
        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let coldResultDiagnostics = """
        aggregateCoverage: \(result.aggregateCoverage)
        roots: \(result.roots)
        sourceIssues: \(result.roots.flatMap(\.sourceIssues))
        targetIssues: \(result.roots.flatMap(\.targetIssues))
        """

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"],
            coldResultDiagnostics
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let receipt = try XCTUnwrap(result.publicationReceipt, coldResultDiagnostics)
        let actualTarget = try XCTUnwrap(receipt.targets.first)
        let unrelated = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let unrelatedLogicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: actualTarget.logicalPath.rootDisplayName,
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let staleExtraTarget = WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: actualTarget.rootEpoch,
            fileID: unrelated.id,
            catalogGeneration: actualTarget.catalogGeneration,
            requestGeneration: actualTarget.requestGeneration,
            logicalPath: unrelatedLogicalPath
        )
        let forgedReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: receipt.requestID,
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: receipt.graphKeys,
            coverageProofs: receipt.coverageProofs,
            targets: receipt.targets + [staleExtraTarget],
            publicationPermit: receipt.publicationPermit
        )
        let forgedResult = WorkspaceCodemapAutomaticSelectionResult(
            roots: result.roots,
            aggregateCoverage: result.aggregateCoverage,
            publicationReceipt: forgedReceipt
        )
        let queryCountBeforeRefresh = await coldGraphProbe.materializedQueryResultCount()
        let rejectedRefresh = await coldStore.refreshAutomaticCodemapSelectionResultForCurrentProjection(
            forgedResult,
            sourceTickets: receipt.sourceTickets,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(rejectedRefresh)
        let queryCountAfterRefresh = await coldGraphProbe.materializedQueryResultCount()
        XCTAssertGreaterThan(queryCountAfterRefresh, queryCountBeforeRefresh)

        let sourceRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(receipt.sourceTickets[0])
        XCTAssertEqual(sourceRetainBeforePublication, 1)
        let targetIdentity = try XCTUnwrap(result.targets.first)
        let targetRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(
                rootEpoch: targetIdentity.rootEpoch,
                fileID: targetIdentity.fileID
            )
        XCTAssertEqual(
            targetRetainBeforePublication,
            0,
            "candidate/provisional ownership must not escape into the publication receipt"
        )
        let publication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        guard case let .current(targets) = publication else {
            return XCTFail("Expected current publication receipt")
        }
        XCTAssertEqual(targets, result.targets)
        let sourceRetainAfterPublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(receipt.sourceTickets[0])
        XCTAssertEqual(sourceRetainAfterPublication, 0)

        let repeated = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let repeatedReceipt = try XCTUnwrap(repeated.publicationReceipt)
        let repeatedRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(repeatedReceipt.sourceTickets[0])
        XCTAssertEqual(repeatedRetainBeforePublication, 1)
        _ = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            repeatedReceipt,
            rootScope: .visibleWorkspace
        )
        let repeatedRetainAfterPublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(repeatedReceipt.sourceTickets[0])
        XCTAssertEqual(
            repeatedRetainAfterPublication,
            0,
            "repeated resolve/revalidate cycles must not grow retainers"
        )

        let target = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        try Self.write(
            "struct Target { let changed = true }\n",
            to: root.appendingPathComponent(target.standardizedRelativePath)
        )
        await coldStore.replayObservedFileSystemDeltas(
            rootID: coldRoot.id,
            deltas: [.fileModified(target.standardizedRelativePath, nil)]
        )
        var committedAfterWatcherInvalidation = false
        let permitCommit = receipt.publicationPermit.withCurrent {
            committedAfterWatcherInvalidation = true
        }
        XCTAssertNil(permitCommit)
        XCTAssertFalse(committedAfterWatcherInvalidation)
        let watcherStalePublication = await coldStore
            .revalidateAutomaticCodemapSelectionForPublication(
                receipt,
                rootScope: .visibleWorkspace
            )
        XCTAssertEqual(watcherStalePublication, .stale(.publicationReceipt))

        await coldStore.unloadRoot(id: coldRoot.id)
        let stalePublication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(stalePublication, .stale(.publicationReceipt))
    }
}

private enum CodemapStoreTestError: Error {
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

private final class CodemapStoreFixture: @unchecked Sendable {
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

private final class CodemapSelectionGraphProbe: @unchecked Sendable {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch),
               let summary = await (graph.accounting()).publishedSummary,
               summary.nodeCount >= minimumNodeCount
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitUntilProcessBusy(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch),
               await (graph.accounting()).processBusyCount > 0
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitUntilCompleteCoverage(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch) {
                let accounting = await graph.accounting()
                if let summary = accounting.publishedSummary,
                   accounting.currentObservedKey == summary.key,
                   case .complete = summary.definitionUniverseCoverage
                {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitUntilCompleteCoverage(
        rootEpoch: WorkspaceCodemapRootEpoch,
        after contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        timeout: Duration = .seconds(5)
    ) async -> WorkspaceCodemapSelectionGraphRuntimeKey? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch) {
                let accounting = await graph.accounting()
                if let summary = accounting.publishedSummary,
                   summary.key.contributionGeneration > contributionGeneration,
                   accounting.currentObservedKey == summary.key,
                   case .complete = summary.definitionUniverseCoverage
                {
                    return summary.key
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func waitUntilObservedKey(
        rootEpoch: WorkspaceCodemapRootEpoch,
        after contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        timeout: Duration = .seconds(5)
    ) async -> WorkspaceCodemapSelectionGraphRuntimeKey? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch),
               let key = await (graph.accounting()).currentObservedKey,
               key.contributionGeneration > contributionGeneration
            {
                return key
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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

private final class CodemapSelectionGraphBuildGate: @unchecked Sendable {
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

private final class CodemapBoundedCompletionState: @unchecked Sendable {
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

private final class CodemapManifestWriteAttemptLatch: @unchecked Sendable {
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

private final class CodemapLockedCounter: @unchecked Sendable {
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

private final class CodemapLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class CodemapRetryTestClock: @unchecked Sendable {
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

private actor CodemapAutomaticSelectionSequenceHarness {
    private var demandTickets: [WorkspaceCodemapArtifactDemandTicket] = []
    private var waiterInvocationCount = 0
    private var releasedWaits = Set<Int>()
    private var releaseAllWaits = false
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]

    var recordedTickets: [WorkspaceCodemapArtifactDemandTicket] {
        demandTickets
    }

    var waitCount: Int {
        waiterInvocationCount
    }

    func recordDemand(_ ticket: WorkspaceCodemapArtifactDemandTicket) -> Int {
        demandTickets.append(ticket)
        return demandTickets.count
    }

    func wait() async throws {
        try Task.checkCancellation()
        waiterInvocationCount += 1
        let invocation = waiterInvocationCount
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
        for continuation in pending {
            continuation.resume(returning: ())
        }
    }

    func waitUntilDemandCount(
        _ expectedCount: Int,
        timeout: Duration
    ) async -> [WorkspaceCodemapArtifactDemandTicket]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while demandTickets.count < expectedCount, clock.now < deadline {
            guard !Task.isCancelled else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return nil
            }
        }
        return demandTickets.count >= expectedCount ? demandTickets : nil
    }

    func waitUntilWaitCount(_ expectedCount: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while waiterInvocationCount < expectedCount, clock.now < deadline {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return waiterInvocationCount >= expectedCount
    }

    private func cancelWait(_ invocation: Int) {
        continuations.removeValue(forKey: invocation)?.resume(throwing: CancellationError())
    }
}

private actor CodemapRetrySleepGate {
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

private actor CodemapSuspensionGate {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
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

private actor CodemapArmableSuspensionGate {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
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

private actor CodemapGraphPublicationGate {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while invocationRoots.count < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return invocationRoots.count >= expectedCount
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

private actor CodemapRootSuspensionGate {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while enteredRootEpoch == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return enteredRootEpoch
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

private actor CodemapResolutionGate {
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
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
