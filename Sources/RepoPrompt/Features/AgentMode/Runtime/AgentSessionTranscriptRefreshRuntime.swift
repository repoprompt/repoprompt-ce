import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

enum AgentDerivedTranscriptRefreshReason: String {
    case liveMutation
    case saveSession
    case coldLoad
    case manualRefresh
}

/// Runtime transcript refresh and save snapshots. Optional publication is composed by the
/// caller after this synchronous state transition; no selected tab controls owned state.
@MainActor
enum AgentSessionTranscriptRefreshRuntime {
    nonisolated static let pendingToolFinalizationNonToolBoundary = 200

    struct SavePreparation {
        let snapshot: AgentPersistableTranscriptSnapshot
        let shouldRefreshPresentation: Bool
    }

    static func prepareSave(
        for session: AgentTabSession,
        isActiveOwnedForSave: Bool,
        perfRecorder: any AgentModePerfRecording,
        diagnosticPresentationID: @autoclosure () -> String,
        didRefreshDerivedState: (AgentTabSession) -> Void = { _ in }
    ) -> SavePreparation {
        let tabID = session.tabID
        var workingItemsSnapshot = session.items
        var shouldRefreshAfterPreparation = false
        let existingTranscript = session.transcript
        let previousBaseProjection = session.baseTranscriptProjection
        let previousProjection = session.transcriptProjection
        let previousProjectionProtection = session.transcriptProjectionProtection
        if !session.runState.isActive {
            let repairedCount = AgentTranscriptIO.finalizePendingToolCalls(
                in: &workingItemsSnapshot,
                terminalState: session.runState,
                includeExplicitRepoPromptToolCalls: session.selectedAgent == .codexExec || session.selectedAgent.acpProviderID != nil,
                nonToolBoundary: Self.pendingToolFinalizationNonToolBoundary
            )
            if repairedCount > 0 {
                session.setItemsSilentlyForPendingToolFinalizationRepair(workingItemsSnapshot)
                session.isDirty = true
                refreshDerivedTranscriptState(for: session, reason: .saveSession)
                didRefreshDerivedState(session)
                #if DEBUG
                    perfRecorder.increment("save.session.localPendingToolRepair", tabID: tabID)
                    perfRecorder.event(
                        "save.session.localPendingToolRepair",
                        tabID: tabID,
                        fields: [
                            "activeOwned": String(isActiveOwnedForSave),
                            "repairedCount": String(repairedCount)
                        ]
                    )
                #endif
            }
        }
        var projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: session.transcript
        )
        let importPolicy = AgentTranscriptImportPolicy.liveSession(
            hidePendingQuestionToolCall: session.hasPendingQuestionUI
        )
        if !isActiveOwnedForSave,
           session.derivedTranscriptRefreshTask != nil || session.pendingDerivedTranscriptRefreshReason != nil
        {
            let scheduledReason = session.pendingDerivedTranscriptRefreshReason ?? .liveMutation
            refreshDerivedTranscriptState(for: session, reason: scheduledReason)
            didRefreshDerivedState(session)
            projectionProtection = transcriptProjectionProtection(
                for: session,
                transcript: session.transcript
            )
        }
        let canReusePresentation = !shouldRefreshAfterPreparation
            && canReuseDerivedTranscriptForSave(
                for: session,
                projectionProtection: projectionProtection
            )
        let builtPresentation: AgentBuiltTranscriptPresentation?
        let persistableSnapshot: AgentPersistableTranscriptSnapshot
        if canReusePresentation {
            let reusedPresentation = builtTranscriptPresentationSnapshot(for: session)
            builtPresentation = reusedPresentation
            persistableSnapshot = AgentPersistableTranscriptSnapshot(
                transcript: reusedPresentation.transcript,
                projectionCounts: reusedPresentation.projectionCounts,
                canonicalVisibleRowCount: reusedPresentation.canonicalVisibleRowCount,
                lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: reusedPresentation.transcript)
                    ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItemsSnapshot)
            )
        } else if isActiveOwnedForSave {
            let transcriptSnapshot = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: existingTranscript,
                workingItems: workingItemsSnapshot,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            )
            let appliedPresentation = applyTranscriptPresentation(
                transcriptSnapshot,
                sourceItems: workingItemsSnapshot,
                to: session
            )
            builtPresentation = appliedPresentation
            persistableSnapshot = AgentPersistableTranscriptSnapshot(
                transcript: appliedPresentation.transcript,
                projectionCounts: appliedPresentation.projectionCounts,
                canonicalVisibleRowCount: appliedPresentation.canonicalVisibleRowCount,
                lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: appliedPresentation.transcript)
                    ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItemsSnapshot)
            )
        } else {
            builtPresentation = nil
            persistableSnapshot = persistableTranscriptSnapshot(
                for: session,
                workingItems: workingItemsSnapshot,
                existingTranscript: existingTranscript,
                importPolicy: importPolicy,
                projectionProtection: projectionProtection
            )
            #if DEBUG
                perfRecorder.increment("save.session.persistenceOnlySnapshot", tabID: tabID)
                perfRecorder.event(
                    "save.session.persistenceOnlySnapshot",
                    tabID: tabID,
                    fields: [
                        "currentTabID": diagnosticPresentationID(),
                        "sourceItemsRevision": String(session.sourceItemsRevision)
                    ]
                )
            #endif
        }
        let presentationChanged = isActiveOwnedForSave && !canReusePresentation && builtPresentation != nil && (
            session.transcript != existingTranscript
                || session.baseTranscriptProjection != previousBaseProjection
                || session.transcriptProjection != previousProjection
                || session.transcriptProjectionProtection != previousProjectionProtection
        )
        if isActiveOwnedForSave, let builtPresentation {
            let shouldReconcileWorkingItems = session.items == workingItemsSnapshot
                && (
                    AgentTranscriptIO.containsExcludedLegacyItems(workingItemsSnapshot, policy: importPolicy)
                        || AgentTranscriptIO.fullDetailTurnEnvelopeChanged(
                            from: existingTranscript,
                            to: builtPresentation.transcript
                        )
                        || (!canReusePresentation && builtPresentation.sanitizedActivityCount > 0)
                )
            if shouldReconcileWorkingItems {
                let trimmedWorkingItems = AgentTranscriptIO.workingSourceItems(from: builtPresentation.transcript)
                if trimmedWorkingItems != session.items {
                    session.setItemsSilentlyForRetentionCompaction(trimmedWorkingItems)
                    markDerivedTranscriptSynchronized(
                        for: session,
                        projectionProtection: builtPresentation.projectionProtection
                    )
                    workingItemsSnapshot = trimmedWorkingItems
                    shouldRefreshAfterPreparation = true
                }
            } else if session.items != workingItemsSnapshot {
                workingItemsSnapshot = session.items
            }
        } else if session.items != workingItemsSnapshot {
            workingItemsSnapshot = session.items
        }
        if presentationChanged {
            shouldRefreshAfterPreparation = true
        }
        return SavePreparation(snapshot: persistableSnapshot, shouldRefreshPresentation: shouldRefreshAfterPreparation)
    }

    private nonisolated static func logCodexDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableCodexDebugLogging") else { return }
            print(message())
        #endif
    }

    private static func markDerivedTranscriptSynchronized(for session: AgentTabSession, projectionProtection: AgentTranscriptProjectionProtection) {
        session.derivedTranscriptSyncState = AgentSessionTranscriptRuntime.syncState(for: session, projectionProtection: projectionProtection)
    }

    static func refreshDerivedTranscriptState(
        for session: AgentTabSession,
        reason: AgentDerivedTranscriptRefreshReason = .manualRefresh
    ) {
        session.derivedTranscriptRefreshGeneration &+= 1
        session.derivedTranscriptRefreshTask?.cancel()
        session.derivedTranscriptRefreshTask = nil
        let pendingMutationSummary = reason == .liveMutation ? session.pendingSourceItemsMutationSummary : nil
        session.pendingSourceItemsMutationSummary = nil
        session.pendingDerivedTranscriptRefreshReason = nil
        #if DEBUG || EDIT_FLOW_PERF
            let refreshStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let refreshSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.refreshTotal,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                sourceItemCount: session.items.count
            )
        )
        let workingItemsSnapshot = session.items
        let existingTranscript = session.transcript
        let projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: existingTranscript
        )
        #if DEBUG
            let debugMetricsEnabled = AgentTranscriptDebugInstrumentation.isEnabled
            let debugPendingMutationSummary: String?
            var debugIncrementalPath: String?
            let debugRefreshInputSignature: String?
            if debugMetricsEnabled {
                debugPendingMutationSummary = pendingMutationSummary.map {
                    [
                        "earliest=\($0.earliestChangedIndex)",
                        "latest=\($0.latestChangedIndex)",
                        "removal=\($0.containsRemoval)",
                        "replaceAll=\($0.containsReplaceAll)",
                        "user=\($0.containsUserMutation)",
                        "structural=\($0.containsStructuralMutation)",
                        "allowsIncremental=\($0.allowsIncrementalFinalTurnRebuild)"
                    ].joined(separator: ",")
                } ?? "nil"
                debugIncrementalPath = {
                    guard reason == .liveMutation else { return "full-rebuild:reason-\(reason.rawValue)" }
                    guard session.pendingAskUser == nil else { return "full-rebuild:pending-question" }
                    guard let pendingMutationSummary else { return "full-rebuild:missing-mutation-summary" }
                    guard pendingMutationSummary.allowsIncrementalFinalTurnRebuild else {
                        return "full-rebuild:mutation-disallows-incremental"
                    }
                    return "incremental-attempt"
                }()
                debugRefreshInputSignature = AgentTranscriptDebugInstrumentation.stableDigest([
                    AgentTranscriptDebugInstrumentation.itemIdentitySignature(workingItemsSnapshot),
                    "sourceRevision=\(session.sourceItemsRevision)",
                    "nextSequence=\(session.nextSequenceIndex)",
                    "runState=\(session.runState.rawValue)",
                    "agent=\(session.selectedAgent.rawValue)",
                    "hidePendingQuestion=\(session.hasPendingQuestionUI)",
                    "projectionProtection=\(String(describing: projectionProtection))",
                    "compressedRevealed=\(session.isCompressedHistoryRevealed)"
                ])
            } else {
                debugPendingMutationSummary = nil
                debugIncrementalPath = nil
                debugRefreshInputSignature = nil
            }
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            var performanceSnapshot = session.transcriptPerformanceSnapshot
            performanceSnapshot.lastSourceItemCount = workingItemsSnapshot.count
        #endif
        let importPolicy = AgentTranscriptImportPolicy.liveSession(
            hidePendingQuestionToolCall: session.hasPendingQuestionUI
        )
        Self.logCodexDebug(
            "[AgentModeVM][TranscriptOrder] refreshDerived tab=\(session.tabID) selectedAgent=\(session.selectedAgent.rawValue) sourceTail=\(Self.transcriptRowDebugWindow(workingItemsSnapshot))"
        )
        #if DEBUG || EDIT_FLOW_PERF
            let importStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let importSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.importTranscript,
            EditFlowPerf.Dimensions(status: reason.rawValue, sourceItemCount: workingItemsSnapshot.count)
        )
        let importedTranscript: AgentTranscript
        var trustedIncrementalFinalTurnStartSequenceIndex: Int?
        if reason == .liveMutation,
           session.pendingAskUser == nil,
           let mutationSummary = pendingMutationSummary,
           mutationSummary.allowsIncrementalFinalTurnRebuild
        {
            #if DEBUG || EDIT_FLOW_PERF
                let incrementalImportStartedAt = CFAbsoluteTimeGetCurrent()
                var incrementalImportOutcome = "fallback"
            #endif
            let incrementalImportSignpost = EditFlowPerf.begin(
                EditFlowPerf.Stage.Transcript.incrementalImport,
                EditFlowPerf.Dimensions(sourceItemCount: workingItemsSnapshot.count)
            )
            let usesDurableFrontier = (existingTranscript.compactionFrontier?.frozenPrefixTurnCount ?? 0) > 0
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.incrementalImportAttemptCount += 1
                if usesDurableFrontier {
                    performanceSnapshot.frontierReuseAttemptCount += 1
                }
            #endif
            if let incrementallyUpdatedTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
                existingTranscript: existingTranscript,
                items: workingItemsSnapshot,
                earliestChangedIndex: mutationSummary.earliestChangedIndex,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            ) {
                importedTranscript = incrementallyUpdatedTranscript
                if workingItemsSnapshot.indices.contains(mutationSummary.earliestChangedIndex) {
                    trustedIncrementalFinalTurnStartSequenceIndex =
                        workingItemsSnapshot[mutationSummary.earliestChangedIndex].sequenceIndex
                }
                #if DEBUG
                    debugIncrementalPath = usesDurableFrontier ? "incremental-success:frontier" : "incremental-success:no-frontier"
                #endif
                #if DEBUG || EDIT_FLOW_PERF
                    incrementalImportOutcome = "success"
                    performanceSnapshot.incrementalImportSuccessCount += 1
                    if usesDurableFrontier {
                        performanceSnapshot.frontierReuseSuccessCount += 1
                    }
                #endif
            } else {
                importedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: existingTranscript,
                    workingItems: workingItemsSnapshot,
                    terminalState: session.runState,
                    nextSequenceIndex: session.nextSequenceIndex,
                    policy: importPolicy,
                    protection: projectionProtection
                )
                #if DEBUG
                    debugIncrementalPath = usesDurableFrontier ? "incremental-fallback:frontier-rejected" : "incremental-fallback:no-frontier-rejected"
                #endif
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.incrementalImportFallbackCount += 1
                    if usesDurableFrontier {
                        performanceSnapshot.frontierReuseFallbackCount += 1
                    }
                #endif
            }
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Transcript.incrementalImport,
                    incrementalImportSignpost,
                    EditFlowPerf.Dimensions(
                        outcome: incrementalImportOutcome,
                        sourceItemCount: workingItemsSnapshot.count
                    )
                )
                let incrementalImportDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - incrementalImportStartedAt) * 1000)
                performanceSnapshot.lastIncrementalImportDurationMS = incrementalImportDurationMS
                performanceSnapshot.maxIncrementalImportDurationMS = max(
                    performanceSnapshot.maxIncrementalImportDurationMS ?? 0,
                    incrementalImportDurationMS
                )
            #else
                EditFlowPerf.end(EditFlowPerf.Stage.Transcript.incrementalImport, incrementalImportSignpost)
            #endif
        } else {
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.lastIncrementalImportDurationMS = nil
            #endif
            importedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: existingTranscript,
                workingItems: workingItemsSnapshot,
                terminalState: session.runState,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: importPolicy,
                protection: projectionProtection
            )
        }
        #if DEBUG
            if let debugPendingMutationSummary,
               let debugIncrementalPath,
               let debugRefreshInputSignature
            {
                AgentTranscriptDebugInstrumentation.emitRefreshAttempt(
                    tabID: session.tabID,
                    reason: reason.rawValue,
                    sourceItemsRevision: session.sourceItemsRevision,
                    itemCount: workingItemsSnapshot.count,
                    nextSequenceIndex: session.nextSequenceIndex,
                    runState: session.runState.rawValue,
                    selectedAgent: session.selectedAgent.rawValue,
                    projectionProtection: String(describing: projectionProtection),
                    pendingMutationSummary: debugPendingMutationSummary,
                    incrementalPath: debugIncrementalPath,
                    inputSignature: debugRefreshInputSignature
                )
            }
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.importTranscript,
            importSignpost,
            EditFlowPerf.Dimensions(status: reason.rawValue, sourceItemCount: workingItemsSnapshot.count)
        )
        #if DEBUG || EDIT_FLOW_PERF
            let importDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - importStartedAt) * 1000)
            performanceSnapshot.lastImportDurationMS = importDurationMS
            performanceSnapshot.maxImportDurationMS = max(
                performanceSnapshot.maxImportDurationMS ?? 0,
                importDurationMS
            )
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let previousPerformanceSnapshotForBuild = performanceSnapshot
        #else
            let previousPerformanceSnapshotForBuild = AgentTranscriptPerformanceSnapshot.empty
        #endif
        let builtPresentation = AgentSessionTranscriptBuilder.buildTranscriptPresentation(
            from: importedTranscript,
            sourceItems: workingItemsSnapshot,
            precomputedEphemeralPayloadByItemID: session.ephemeralToolResultPayloadByItemID,
            precomputedEphemeralPayloadRevisionByItemID: session.ephemeralToolResultPayloadRevisionByItemID,
            selectedAgent: session.selectedAgent,
            previousPerformanceSnapshot: previousPerformanceSnapshotForBuild,
            trackedLocalInputIDs: Set(session.localInputIndex.records.map(\.itemID)),
            previousSanitizedTranscript: existingTranscript,
            previousBaseProjection: session.baseTranscriptProjection,
            previousTurnProjectionCaches: session.turnProjectionCaches,
            previousProjectionProtection: session.transcriptProjectionProtection,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            isColdLoad: reason == .coldLoad,
            trustedIncrementalFinalTurnStartSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
            quietDisplayCandidate: session.quietDisplayCandidate
        )
        let fullDetailTurnEnvelopeChanged = AgentTranscriptIO.fullDetailTurnEnvelopeChanged(
            from: existingTranscript,
            to: builtPresentation.transcript
        )
        applyBuiltTranscriptPresentation(
            builtPresentation,
            sourceItems: workingItemsSnapshot,
            reconcilesQuietSourceRetirement: pendingMutationSummary?.containsStructuralMutation != false
                || fullDetailTurnEnvelopeChanged || builtPresentation.sanitizedActivityCount > 0,
            isLiveRefresh: reason == .liveMutation,
            to: session
        )
        let hasCompactedTranscriptPrefix = builtPresentation.transcript.turns.contains { $0.retentionTier != .full }
        let canReconcileForStandardRetention = (!session.runState.isActive || hasCompactedTranscriptPrefix)
            && (session.runState != .completed || hasCompactedTranscriptPrefix)
        let containsExcludedLegacyItems = AgentTranscriptIO.containsExcludedLegacyItems(
            workingItemsSnapshot,
            policy: importPolicy
        )
        let shouldReconcileWorkingItems: Bool = {
            guard session.items == workingItemsSnapshot,
                  canReconcileForStandardRetention
            else {
                return false
            }
            return containsExcludedLegacyItems
                || fullDetailTurnEnvelopeChanged
                || builtPresentation.sanitizedActivityCount > 0
        }()
        let mayCompactActiveSummaryOnlyToolResults = !shouldReconcileWorkingItems
            && session.items == workingItemsSnapshot
            && session.runState.isActive
            && !hasCompactedTranscriptPrefix
            && builtPresentation.sanitizedActivityCount > 0
        let didApplyIncrementalSummaryOnlyCompaction: Bool = {
            guard builtPresentation.sanitizedActivityCount > 0,
                  !containsExcludedLegacyItems,
                  !fullDetailTurnEnvelopeChanged,
                  let mutationSummary = pendingMutationSummary,
                  mutationSummary.earliestChangedIndex == mutationSummary.latestChangedIndex,
                  workingItemsSnapshot.indices.contains(mutationSummary.earliestChangedIndex)
            else {
                return false
            }
            let changedIndex = mutationSummary.earliestChangedIndex
            let sourceItem = workingItemsSnapshot[changedIndex]
            guard let compactedItem = Self.transcriptItem(
                in: builtPresentation.transcript,
                matching: sourceItem
            ),
                let retainedRawPayload = session.ephemeralToolResultPayloadByItemID[sourceItem.id],
                Self.canApplyActiveSummaryOnlyToolResultCompaction(
                    from: sourceItem,
                    to: compactedItem,
                    retainedPayload: retainedRawPayload
                ),
                session.replaceItemSilentlyForRetentionCompaction(
                    at: changedIndex,
                    with: compactedItem,
                    retainedRawPayload: retainedRawPayload
                )
            else {
                return false
            }
            markDerivedTranscriptSynchronized(
                for: session,
                projectionProtection: builtPresentation.projectionProtection
            )
            return true
        }()
        if !didApplyIncrementalSummaryOnlyCompaction,
           shouldReconcileWorkingItems || mayCompactActiveSummaryOnlyToolResults
        {
            let trimmedWorkingItems = AgentTranscriptIO.workingSourceItems(from: builtPresentation.transcript)
            let canApplyWorkingItems = shouldReconcileWorkingItems
                || Self.canApplyActiveSummaryOnlyToolResultCompaction(
                    from: workingItemsSnapshot,
                    to: trimmedWorkingItems,
                    retainedPayloadByItemID: session.ephemeralToolResultPayloadByItemID
                )
            if canApplyWorkingItems, trimmedWorkingItems != session.items {
                session.setItemsSilentlyForRetentionCompaction(trimmedWorkingItems)
                markDerivedTranscriptSynchronized(
                    for: session,
                    projectionProtection: builtPresentation.projectionProtection
                )
            }
        }
        #if DEBUG || EDIT_FLOW_PERF
            var finalPerformanceSnapshot = session.transcriptPerformanceSnapshot
            let refreshDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000)
            finalPerformanceSnapshot.lastRefreshTotalDurationMS = refreshDurationMS
            finalPerformanceSnapshot.maxRefreshTotalDurationMS = max(
                finalPerformanceSnapshot.maxRefreshTotalDurationMS ?? 0,
                refreshDurationMS
            )
            finalPerformanceSnapshot.lastSourceItemCount = session.items.count
            session.transcriptPerformanceSnapshot = finalPerformanceSnapshot
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.refreshTotal,
            refreshSignpost,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                lineCount: session.transcriptCanonicalVisibleRowCount,
                sourceItemCount: session.items.count
            )
        )
    }

    private nonisolated static func canApplyActiveSummaryOnlyToolResultCompaction(
        from sourceItems: [AgentChatItem],
        to compactedItems: [AgentChatItem],
        retainedPayloadByItemID: [UUID: String]
    ) -> Bool {
        guard sourceItems.count == compactedItems.count else { return false }
        var foundSummaryOnlyToolResultCompaction = false
        for (sourceItem, compactedItem) in zip(sourceItems, compactedItems) {
            guard sourceItem != compactedItem else { continue }
            let retainedPayload = retainedPayloadByItemID[sourceItem.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard canApplyActiveSummaryOnlyToolResultCompaction(
                from: sourceItem,
                to: compactedItem,
                retainedPayload: retainedPayload
            ) else { return false }
            foundSummaryOnlyToolResultCompaction = true
        }
        return foundSummaryOnlyToolResultCompaction
    }

    private nonisolated static func canApplyActiveSummaryOnlyToolResultCompaction(
        from sourceItem: AgentChatItem,
        to compactedItem: AgentChatItem,
        retainedPayload: String
    ) -> Bool {
        guard sourceItem.id == compactedItem.id,
              sourceItem.timestamp == compactedItem.timestamp,
              sourceItem.kind == compactedItem.kind,
              sourceItem.attachments == compactedItem.attachments,
              sourceItem.taggedFileAttachments == compactedItem.taggedFileAttachments,
              sourceItem.toolName == compactedItem.toolName,
              sourceItem.toolInvocationID == compactedItem.toolInvocationID,
              sourceItem.toolArgsJSON == compactedItem.toolArgsJSON,
              sourceItem.reasoning == compactedItem.reasoning,
              sourceItem.sequenceIndex == compactedItem.sequenceIndex,
              sourceItem.isStreaming == compactedItem.isStreaming,
              sourceItem.workflow == compactedItem.workflow,
              sourceItem.codexGoalMode == compactedItem.codexGoalMode,
              sourceItem.isLocalControlPlaneEcho == compactedItem.isLocalControlPlaneEcho,
              sourceItem.kind == .toolResult,
              !sourceItem.isStreaming
        else {
            return false
        }
        let sourceResultJSON = sourceItem.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let compactedResultJSON = compactedItem.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourceResultJSON.isEmpty,
              sourceResultJSON != compactedResultJSON,
              retainedPayload.trimmingCharacters(in: .whitespacesAndNewlines) == sourceResultJSON,
              AgentTranscriptToolNormalizer.isSummaryOnly(raw: compactedResultJSON)
        else {
            return false
        }
        var expectedCompactedItem = sourceItem
        expectedCompactedItem.text = compactedItem.text
        expectedCompactedItem.toolResultJSON = compactedItem.toolResultJSON
        expectedCompactedItem.toolIsError = compactedItem.toolIsError
        return expectedCompactedItem == compactedItem
    }

    private nonisolated static func transcriptItem(
        in transcript: AgentTranscript,
        matching sourceItem: AgentChatItem
    ) -> AgentChatItem? {
        guard let finalTurn = transcript.turns.last else { return nil }
        for span in finalTurn.responseSpans.reversed() {
            guard let firstSequenceIndex = span.activities.first?.sequenceIndex,
                  let lastSequenceIndex = span.activities.last?.sequenceIndex,
                  sourceItem.sequenceIndex >= firstSequenceIndex,
                  sourceItem.sequenceIndex <= lastSequenceIndex
            else {
                continue
            }
            var lowerBound = span.activities.startIndex
            var upperBound = span.activities.endIndex
            while lowerBound < upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                if span.activities[midpoint].sequenceIndex < sourceItem.sequenceIndex {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            guard lowerBound < span.activities.endIndex,
                  span.activities[lowerBound].sequenceIndex == sourceItem.sequenceIndex,
                  span.activities[lowerBound].id == sourceItem.id
            else {
                continue
            }
            return span.activities[lowerBound].toItem()
        }
        return nil
    }

    nonisolated static func transcriptProjectionProtection(
        for transcript: AgentTranscript,
        viewportState: AgentTranscriptViewportState
    ) -> AgentTranscriptProjectionProtection {
        guard !transcript.turns.isEmpty else { return .none }
        return AgentTranscriptProjectionBuilder.projectionProtection(
            for: transcript,
            viewportState: viewportState
        )
    }

    static func transcriptProjectionProtection(
        for session: AgentTabSession,
        transcript: AgentTranscript? = nil
    ) -> AgentTranscriptProjectionProtection {
        transcriptProjectionProtection(
            for: transcript ?? session.transcript,
            viewportState: session.transcriptViewportState
        )
    }

    private nonisolated static func persistableSnapshot(
        from transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript?,
        workingItems: [AgentChatItem]
    ) -> AgentPersistableTranscriptSnapshot {
        let sanitizeReusableTurnCount = AgentSessionTranscriptBuilder.commonEqualTurnPrefixCount(
            in: transcript,
            previousTranscript: previousSanitizedTranscript
        )
        let sanitizeMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            reusablePrefixTurnCount: sanitizeReusableTurnCount > 0 ? sanitizeReusableTurnCount : nil,
            context: AgentToolResultProcessingContext(),
            purpose: .runtimePresentation
        )
        let sanitizedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: sanitizeMetrics.transcript
        )
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: sanitizedTranscript)
        return AgentPersistableTranscriptSnapshot(
            transcript: sanitizedTranscript,
            projectionCounts: projectionCounts,
            canonicalVisibleRowCount: projectionCounts.canonicalVisibleRowCount,
            lastUserMessageAt: AgentTranscriptIO.lastUserInteractionDate(in: sanitizedTranscript)
                ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItems)
        )
    }

    static func persistableTranscriptSnapshot(
        for session: AgentTabSession,
        workingItems: [AgentChatItem],
        existingTranscript: AgentTranscript,
        importPolicy: AgentTranscriptImportPolicy,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> AgentPersistableTranscriptSnapshot {
        let transcriptSnapshot = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existingTranscript,
            workingItems: workingItems,
            terminalState: session.runState,
            nextSequenceIndex: session.nextSequenceIndex,
            policy: importPolicy,
            protection: projectionProtection
        )
        return Self.persistableSnapshot(
            from: transcriptSnapshot,
            previousSanitizedTranscript: existingTranscript,
            workingItems: workingItems
        )
    }

    static func canReuseDerivedTranscriptForSave(
        for session: AgentTabSession,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> Bool {
        session.derivedTranscriptSyncState == AgentSessionTranscriptRuntime.syncState(
            for: session,
            projectionProtection: projectionProtection
        )
    }

    static func builtTranscriptPresentationSnapshot(for session: AgentTabSession) -> AgentBuiltTranscriptPresentation {
        AgentBuiltTranscriptPresentation(
            transcript: session.transcript,
            baseProjection: session.baseTranscriptProjection,
            fullProjection: session.fullTranscriptProjection,
            workingProjection: session.workingTranscriptProjection,
            projection: session.transcriptProjection,
            turnProjectionCaches: session.turnProjectionCaches,
            archivedSnapshot: session.archivedTranscriptSnapshot,
            reusesPreviousArchive: false,
            projectionProtection: session.transcriptProjectionProtection,
            canonicalVisibleRowCount: session.transcriptCanonicalVisibleRowCount,
            projectionCounts: session.transcriptProjectionCounts,
            analyticsSnapshot: session.transcriptAnalyticsSnapshot,
            sanitizedActivityCount: 0,
            performanceSnapshot: session.transcriptPerformanceSnapshot,
            rawToolResultPayloadRenderRevisionByItemID: session.rawToolResultPayloadRenderRevisionByItemID
        )
    }

    static func applyBuiltTranscriptPresentation(
        _ presentation: AgentBuiltTranscriptPresentation,
        sourceItems: [AgentChatItem]? = nil,
        reconcilesQuietSourceRetirement: Bool = true,
        isLiveRefresh: Bool = false,
        to session: AgentTabSession
    ) {
        guard AgentSessionTranscriptRuntime.apply(
            presentation, sourceItems: sourceItems,
            reconcilesQuietSourceRetirement: reconcilesQuietSourceRetirement,
            isLiveRefresh: isLiveRefresh, to: session
        ) else {
            logCodexDebug(
                "[AgentModeVM][Transcript] skip applying stale built presentation tab=\(session.tabID) sourceItems=\(sourceItems?.count ?? 0) liveItems=\(session.items.count)"
            )
            return
        }
        logCodexDebug(
            "[AgentModeVM][TranscriptOrder] applyStructured tab=\(session.tabID) turns=\(presentation.transcript.turns.count) workingRowTail=\(transcriptRowDebugWindow(presentation.workingProjection.workingRows)) workingBlockTail=\(transcriptBlockDebugWindow(presentation.workingProjection.workingBlocks))"
        )
    }

    @discardableResult
    static func applyTranscriptPresentation(
        _ transcript: AgentTranscript,
        sourceItems: [AgentChatItem]? = nil,
        to session: AgentTabSession,
        isColdLoad: Bool = false
    ) -> AgentBuiltTranscriptPresentation {
        let canonicalSourceItems = sourceItems ?? session.items
        let projectionProtection = transcriptProjectionProtection(
            for: session,
            transcript: transcript
        )
        let builtPresentation = AgentSessionTranscriptBuilder.buildTranscriptPresentation(
            from: transcript,
            sourceItems: canonicalSourceItems,
            precomputedEphemeralPayloadByItemID: canonicalSourceItems == session.items ? session.ephemeralToolResultPayloadByItemID : nil,
            precomputedEphemeralPayloadRevisionByItemID: canonicalSourceItems == session.items ? session.ephemeralToolResultPayloadRevisionByItemID : nil,
            selectedAgent: session.selectedAgent,
            previousPerformanceSnapshot: session.transcriptPerformanceSnapshot,
            trackedLocalInputIDs: Set(session.localInputIndex.records.map(\.itemID)),
            previousSanitizedTranscript: session.transcript,
            previousBaseProjection: session.baseTranscriptProjection,
            previousTurnProjectionCaches: session.turnProjectionCaches,
            previousProjectionProtection: session.transcriptProjectionProtection,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: session.isCompressedHistoryRevealed,
            isColdLoad: isColdLoad,
            quietDisplayCandidate: session.quietDisplayCandidate
        )
        applyBuiltTranscriptPresentation(
            builtPresentation,
            sourceItems: canonicalSourceItems,
            to: session
        )
        return builtPresentation
    }

    private static func transcriptRowDebugSummary(_ item: AgentChatItem) -> String {
        let label = item.toolName ?? item.kind.rawValue
        return "\(item.sequenceIndex):\(item.kind.rawValue):\(label):stream=\(item.isStreaming)"
    }

    static func transcriptRowDebugWindow(_ items: [AgentChatItem], limit: Int = 8) -> String {
        guard !items.isEmpty else { return "[]" }
        let rows = Array(items.suffix(limit)).map(transcriptRowDebugSummary)
        return "[\(rows.joined(separator: ", "))]"
    }

    private static func transcriptBlockDebugSummary(_ block: AgentTranscriptRenderBlock) -> String {
        let rowSummary = block.rows.map { "\($0.sequenceIndex):\($0.kind.rawValue)" }.joined(separator: ",")
        return "\(block.kind.rawValue){\(rowSummary)}"
    }

    static func transcriptBlockDebugWindow(_ blocks: [AgentTranscriptRenderBlock], limit: Int = 8) -> String {
        guard !blocks.isEmpty else { return "[]" }
        let tail = Array(blocks.suffix(limit)).map(transcriptBlockDebugSummary)
        return "[\(tail.joined(separator: " | "))]"
    }
}
