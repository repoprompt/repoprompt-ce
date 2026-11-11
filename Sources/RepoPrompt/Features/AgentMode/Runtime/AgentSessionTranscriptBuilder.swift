import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

/// Pure transcript construction shared by live sessions and window-free saved payloads.
/// Cache reuse, identity, sanitization and instrumentation stay single-sourced here.
enum AgentSessionTranscriptBuilder {
    nonisolated static func buildTranscriptPresentation(
        from transcript: AgentTranscript,
        sourceItems: [AgentChatItem],
        precomputedEphemeralPayloadByItemID: [UUID: String]? = nil,
        precomputedEphemeralPayloadRevisionByItemID: [UUID: Int]? = nil,
        selectedAgent: AgentProviderKind,
        previousPerformanceSnapshot: AgentTranscriptPerformanceSnapshot,
        trackedLocalInputIDs: Set<UUID> = [],
        previousSanitizedTranscript: AgentTranscript? = nil,
        previousBaseProjection: AgentTranscriptProjection? = nil,
        previousTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:],
        previousProjectionProtection: AgentTranscriptProjectionProtection = .none,
        projectionProtection: AgentTranscriptProjectionProtection = .none,
        isCompressedHistoryRevealed: Bool = false,
        isColdLoad: Bool = false,
        trustedIncrementalFinalTurnStartSequenceIndex: Int? = nil,
        quietDisplayCandidate: AgentRunQuietLedger.DisplayCandidate? = nil
    ) -> AgentBuiltTranscriptPresentation {
        let processingContext = AgentToolResultProcessingContext()
        #if DEBUG || EDIT_FLOW_PERF
            let buildStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let projectionSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.projectionBuild,
            EditFlowPerf.Dimensions(sourceItemCount: sourceItems.count)
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let payloadSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.payloadMap,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: sourceItems.count
            )
        )
        let capturedPayloadByItemID: [UUID: String]
        let capturedPayloadRevisionByItemID: [UUID: Int]
        let payloadScannedItemCount: Int
        if let precomputedEphemeralPayloadByItemID {
            capturedPayloadByItemID = precomputedEphemeralPayloadByItemID
            capturedPayloadRevisionByItemID = precomputedEphemeralPayloadRevisionByItemID ?? [:]
            payloadScannedItemCount = 0
        } else {
            capturedPayloadByItemID = rebuildEphemeralToolResultPayloadMap(from: sourceItems, context: processingContext)
            capturedPayloadRevisionByItemID = Dictionary(
                uniqueKeysWithValues: capturedPayloadByItemID.keys.map { ($0, 1) }
            )
            payloadScannedItemCount = sourceItems.count
        }
        #if DEBUG || EDIT_FLOW_PERF
            let capturedPayloadBytes = capturedPayloadByItemID.values.reduce(0) {
                $0 + $1.lengthOfBytes(using: .utf8)
            }
        #else
            let capturedPayloadBytes = 0
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.payloadMap,
            payloadSignpost,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: payloadScannedItemCount,
                retainedPayloadCount: capturedPayloadByItemID.count,
                retainedPayloadBytes: capturedPayloadBytes
            )
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - payloadCaptureStartedAt) * 1000)
            var performanceSnapshot = previousPerformanceSnapshot
            let sanitizeStartedAt = CFAbsoluteTimeGetCurrent()
        #else
            var performanceSnapshot = AgentTranscriptPerformanceSnapshot.empty
        #endif
        let sanitizeSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.sanitize,
            EditFlowPerf.Dimensions(sourceItemCount: sourceItems.count)
        )
        let sanitizeReusableTurnCount = commonEqualTurnPrefixCount(
            in: transcript,
            previousTranscript: previousSanitizedTranscript
        )
        #if DEBUG || EDIT_FLOW_PERF
            if sanitizeReusableTurnCount > 0 {
                performanceSnapshot.sanitizeReuseAttemptCount += 1
            }
        #endif
        let sanitizeMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            reusablePrefixTurnCount: sanitizeReusableTurnCount > 0 ? sanitizeReusableTurnCount : nil,
            trustedIncrementalFinalTurnStartSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
            context: processingContext,
            purpose: .runtimePresentation
        )
        let sanitizedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: sanitizeMetrics.transcript,
            reusablePrefixTurnCount: sanitizeMetrics.reusedTurnCount
        )
        #if DEBUG || EDIT_FLOW_PERF
            if sanitizeReusableTurnCount > 0 {
                if sanitizeMetrics.reusedTurnCount > 0 {
                    performanceSnapshot.sanitizeReuseSuccessCount += 1
                } else {
                    performanceSnapshot.sanitizeReuseFallbackCount += 1
                }
                performanceSnapshot.lastSanitizeReusedTurnCount = sanitizeMetrics.reusedTurnCount
            } else {
                performanceSnapshot.lastSanitizeReusedTurnCount = nil
            }
            let sanitizeDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - sanitizeStartedAt) * 1000)
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.sanitize,
            sanitizeSignpost,
            EditFlowPerf.Dimensions(
                outcome: sanitizeMetrics.reusedTurnCount > 0 ? "reused_prefix" : "rebuilt",
                sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount
            )
        )
        let localDisplayTranscript = AgentTranscriptIO.stagingQuietCandidate(quietDisplayCandidate, in: sanitizedTranscript)
        let projectionReusableTurnCount = AgentTranscriptIO.validatedReusableFrozenPrefixTurnCount(in: localDisplayTranscript) ?? 0
        let baseProjection: AgentTranscriptProjection
        let updatedTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
        if projectionReusableTurnCount > 0,
           let previousSanitizedTranscript,
           !previousSanitizedTranscript.turns.isEmpty,
           let previousBaseProjection
        {
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.projectionReuseAttemptCount += 1
            #endif
            if let reusedProjection = AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(
                from: localDisplayTranscript,
                previousTranscript: previousSanitizedTranscript,
                previousProjection: previousBaseProjection,
                previousProtection: previousProjectionProtection,
                previousExcludingQuiet: true,
                previousReplyPresentation: true,
                protection: projectionProtection,
                reusableFrozenPrefixTurnCount: projectionReusableTurnCount,
                turnCaches: previousTurnProjectionCaches,
                context: processingContext,
                excludingQuiet: true,
                replyPresentation: true
            ) {
                baseProjection = reusedProjection.projection
                updatedTurnProjectionCaches = reusedProjection.updatedTurnCaches
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseSuccessCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = projectionReusableTurnCount
                #endif
            } else {
                let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: localDisplayTranscript,
                    protection: projectionProtection,
                    turnCaches: previousTurnProjectionCaches,
                    context: processingContext,
                    excludingQuiet: true,
                    replyPresentation: true
                )
                baseProjection = buildResult.projection
                updatedTurnProjectionCaches = buildResult.updatedTurnCaches
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseFallbackCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = 0
                #endif
            }
        } else {
            let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: localDisplayTranscript,
                protection: projectionProtection,
                turnCaches: previousTurnProjectionCaches,
                context: processingContext,
                excludingQuiet: true,
                replyPresentation: true
            )
            baseProjection = buildResult.projection
            updatedTurnProjectionCaches = buildResult.updatedTurnCaches
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.lastProjectionReusedTurnCount = nil
            #endif
        }
        let visibleRetainedIDs = visibleToolResultIDs(in: baseProjection)
        let rawToolResultPayloadRenderRevisionByItemID = Dictionary(
            uniqueKeysWithValues: visibleRetainedIDs.compactMap { itemID in
                capturedPayloadRevisionByItemID[itemID].map { (itemID, $0) }
            }
        )
        let fullProjection = degradeCollapsedTranscriptBlocksIfNeeded(
            baseProjection,
            isColdLoad: isColdLoad
        )
        let workingProjection = AgentTranscriptProjectionBuilder.workingProjection(from: fullProjection)
        let archivedSnapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: fullProjection)
        // The sanitizer already validated the equal prefix. With the same turn envelope and
        // protection, a changed final full-detail turn cannot change any archived projection.
        // Forward that existing proof; do not compare/scan the archive a second time here.
        let reusesPreviousArchive = !isColdLoad
            && trustedIncrementalFinalTurnStartSequenceIndex != nil
            && previousBaseProjection != nil
            && projectionProtection == previousProjectionProtection
            && sanitizeMetrics.reusedTurnCount > 0
            && sanitizeMetrics.reusedTurnCount == sanitizedTranscript.turns.count - 1
            && previousSanitizedTranscript?.turns.count == sanitizedTranscript.turns.count
            && previousSanitizedTranscript?.turns.last?.id == sanitizedTranscript.turns.last?.id
            && previousSanitizedTranscript?.turns.last?.retentionTier == .full
            && sanitizedTranscript.turns.last?.retentionTier == .full
        let projection = isCompressedHistoryRevealed ? fullProjection : workingProjection
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: baseProjection)
        let canonicalVisibleRowCount = projectionCounts.canonicalVisibleRowCount
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled, let previousBaseProjection {
                // Keep identity hashing lazy when only other metrics are requested.
                AgentTranscriptDebugInstrumentation.emitProjectionIdentity({
                    let previousRows = previousBaseProjection.archivedRows + previousBaseProjection.workingRows
                    let newRows = baseProjection.archivedRows + baseProjection.workingRows
                    let previousBlocks = previousBaseProjection.archivedBlocks + previousBaseProjection.workingBlocks
                    let newBlocks = baseProjection.archivedBlocks + baseProjection.workingBlocks
                    let previousRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(previousRows)
                    let newRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(newRows)
                    let previousRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(previousRows)
                    let newRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(newRows)
                    let previousBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(previousBlocks)
                    let newBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(newBlocks)
                    let previousBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(previousBlocks)
                    let newBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(newBlocks)
                    return .init(
                        previousRowCount: previousRows.count,
                        newRowCount: newRows.count,
                        previousBlockCount: previousBlocks.count,
                        newBlockCount: newBlocks.count,
                        rowSemanticDigest: newRowSemanticDigest,
                        previousRowSemanticDigest: previousRowSemanticDigest,
                        rowIdentityDigest: newRowIdentityDigest,
                        previousRowIdentityDigest: previousRowIdentityDigest,
                        blockSemanticDigest: newBlockSemanticDigest,
                        previousBlockSemanticDigest: previousBlockSemanticDigest,
                        blockIdentityDigest: newBlockIdentityDigest,
                        previousBlockIdentityDigest: previousBlockIdentityDigest,
                        rowIdentityDrift: newRowSemanticDigest == previousRowSemanticDigest && newRowIdentityDigest != previousRowIdentityDigest,
                        blockIdentityDrift: newBlockSemanticDigest == previousBlockSemanticDigest && newBlockIdentityDigest != previousBlockIdentityDigest
                    )
                }())
            }
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let buildDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - buildStartedAt) * 1000)
            performanceSnapshot.projectionBuildCount += 1
            performanceSnapshot.lastProjectionBuildDurationMS = buildDurationMS
            performanceSnapshot.lastPayloadCaptureDurationMS = payloadCaptureDurationMS
            performanceSnapshot.maxPayloadCaptureDurationMS = max(
                performanceSnapshot.maxPayloadCaptureDurationMS ?? 0,
                payloadCaptureDurationMS
            )
            performanceSnapshot.lastSanitizeDurationMS = sanitizeDurationMS
            performanceSnapshot.maxSanitizeDurationMS = max(
                performanceSnapshot.maxSanitizeDurationMS ?? 0,
                sanitizeDurationMS
            )
            performanceSnapshot.maxProjectionBuildDurationMS = max(
                performanceSnapshot.maxProjectionBuildDurationMS ?? 0,
                buildDurationMS
            )
            performanceSnapshot.lastPayloadCaptureScannedItemCount = payloadScannedItemCount
            performanceSnapshot.lastSanitizedActivityCount = sanitizeMetrics.sanitizedActivityCount
            performanceSnapshot.retainedRawPayloadEntryCount = capturedPayloadByItemID.count
            performanceSnapshot.retainedRawPayloadTotalBytes = capturedPayloadBytes
            let toolProcessingMetrics = processingContext.snapshotMetrics()
            performanceSnapshot.lastToolProcessingMetrics = toolProcessingMetrics
            performanceSnapshot.cumulativeToolProcessingMetrics.add(toolProcessingMetrics)
            EditFlowPerf.event(
                EditFlowPerf.Stage.Transcript.toolProcessing,
                EditFlowPerf.Dimensions(
                    sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes,
                    jsonParseAttemptCount: toolProcessingMetrics.jsonParseAttemptCount,
                    jsonParseCacheHitCount: toolProcessingMetrics.jsonParseCacheHitCount,
                    jsonParseCacheMissCount: toolProcessingMetrics.jsonParseCacheMissCount,
                    jsonParseSuccessCount: toolProcessingMetrics.jsonParseSuccessCount,
                    jsonParseFailureCount: toolProcessingMetrics.jsonParseFailureCount,
                    jsonParseByteCount: toolProcessingMetrics.jsonParseByteCount,
                    toolExecutionCacheHitCount: toolProcessingMetrics.toolExecutionCacheHitCount,
                    toolExecutionCacheMissCount: toolProcessingMetrics.toolExecutionCacheMissCount,
                    bashMetadataCacheHitCount: toolProcessingMetrics.bashMetadataCacheHitCount,
                    bashMetadataCacheMissCount: toolProcessingMetrics.bashMetadataCacheMissCount,
                    regexCaptureCallCount: toolProcessingMetrics.regexCaptureCallCount
                )
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.projectionBuild,
                projectionSignpost,
                EditFlowPerf.Dimensions(
                    outcome: performanceSnapshot.lastProjectionReusedTurnCount.map { $0 > 0 ? "reused_prefix" : "fallback" } ?? "built",
                    lineCount: canonicalVisibleRowCount,
                    sourceItemCount: sourceItems.count,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes
                )
            )
            if isColdLoad {
                performanceSnapshot.lastColdLoadProjectionBuildDurationMS = buildDurationMS
            }
        #endif
        var localInputSeed = AgentSessionLinkRetainedLocalInputIndex.Seed(trackedIDs: trackedLocalInputIDs)
        let analytics = AgentTranscriptAnalyticsBuilder.build(
            from: sanitizedTranscript, selectedAgent: selectedAgent,
            visitRequest: { localInputSeed.append($0) }
        )
        return AgentBuiltTranscriptPresentation(
            localInputSeed: localInputSeed,
            transcript: sanitizedTranscript,
            baseProjection: baseProjection,
            fullProjection: fullProjection,
            workingProjection: workingProjection,
            projection: projection,
            turnProjectionCaches: updatedTurnProjectionCaches,
            archivedSnapshot: archivedSnapshot,
            reusesPreviousArchive: reusesPreviousArchive,
            projectionProtection: projectionProtection,
            canonicalVisibleRowCount: canonicalVisibleRowCount,
            projectionCounts: projectionCounts,
            analyticsSnapshot: analytics,
            sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
            performanceSnapshot: performanceSnapshot,
            rawToolResultPayloadRenderRevisionByItemID: rawToolResultPayloadRenderRevisionByItemID
        )
    }

    nonisolated static func rebuildEphemeralToolResultPayloadMap(
        from items: [AgentChatItem],
        context: AgentToolResultProcessingContext? = nil,
        diagnosticContext: String? = nil
    ) -> [UUID: String] {
        var payloadByItemID: [UUID: String] = [:]
        var firstRetainedItemByID: [UUID: (index: Int, item: AgentChatItem)] = [:]
        for (index, item) in items.enumerated() {
            guard let retainedPayload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item, context: context) else {
                continue
            }
            if let firstPayload = payloadByItemID[item.id] {
                let first = firstRetainedItemByID[item.id] ?? (index: index, item: item)
                AgentSourceItemIDRepair.logDuplicateRetainedToolResultPayload(
                    duplicateID: item.id,
                    firstIndex: first.index,
                    duplicateIndex: index,
                    firstItem: first.item,
                    duplicateItem: item,
                    firstPayload: firstPayload,
                    duplicatePayload: retainedPayload,
                    context: diagnosticContext,
                    toolResultContext: context
                )
                continue
            }
            payloadByItemID[item.id] = retainedPayload
            firstRetainedItemByID[item.id] = (index, item)
        }
        return payloadByItemID
    }

    nonisolated static func commonEqualTurnPrefixCount(
        in transcript: AgentTranscript,
        previousTranscript: AgentTranscript?
    ) -> Int {
        guard let previousTranscript else { return 0 }
        let limit = min(transcript.turns.count, previousTranscript.turns.count)
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit,
              transcript.turns[count] == previousTranscript.turns[count]
        {
            count += 1
        }
        return count
    }

    private nonisolated static func visibleToolResultIDs(in projection: AgentTranscriptProjection) -> Set<UUID> {
        AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: projection)
    }

    private nonisolated static func degradeCollapsedTranscriptBlocksIfNeeded(
        _ projection: AgentTranscriptProjection,
        isColdLoad: Bool
    ) -> AgentTranscriptProjection {
        guard isColdLoad else { return projection }
        return AgentTranscriptProjection(
            workingBlocks: projection.workingBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            archivedBlocks: projection.archivedBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            workingRows: projection.workingRows,
            archivedRows: projection.archivedRows,
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex,
            workingUnitCount: projection.workingUnitCount
        )
    }

    private nonisolated static func degradeCollapsedTranscriptBlockIfNeeded(
        _ block: AgentTranscriptRenderBlock
    ) -> AgentTranscriptRenderBlock {
        guard block.defaultPresentation == .collapsed else { return block }
        if block.kind == .activityCluster, !block.rows.isEmpty {
            return AgentTranscriptRenderBlock(
                id: block.id,
                kind: block.kind,
                turnID: block.turnID,
                spanID: block.spanID,
                retentionTier: block.retentionTier,
                rows: [],
                isArchived: block.isArchived,
                primaryAnchor: block.primaryAnchor,
                anchorActivityID: block.anchorActivityID,
                activityIDs: block.activityIDs,
                clusterSummary: block.clusterSummary,
                groupedHistory: block.groupedHistory,
                defaultPresentation: block.defaultPresentation
            )
        }
        guard block.kind == .groupedHistory,
              let groupedHistory = block.groupedHistory,
              !groupedHistory.sections.isEmpty
        else {
            return block
        }
        return AgentTranscriptRenderBlock(
            id: block.id,
            kind: block.kind,
            turnID: block.turnID,
            spanID: block.spanID,
            retentionTier: block.retentionTier,
            rows: block.rows,
            isArchived: block.isArchived,
            primaryAnchor: block.primaryAnchor,
            anchorActivityID: block.anchorActivityID,
            activityIDs: block.activityIDs,
            clusterSummary: block.clusterSummary,
            groupedHistory: .init(summary: groupedHistory.summary, sections: []),
            defaultPresentation: block.defaultPresentation
        )
    }
}
