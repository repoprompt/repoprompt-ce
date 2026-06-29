import Foundation

extension AgentSessionDataService {
    func buildSidebarIndexStream(
        _ request: AgentSessionSidebarBuildRequest,
        batchSize: Int = 8
    ) -> AsyncThrowingStream<AgentSessionSidebarBuildBatch, Error> {
        AsyncThrowingStream { continuation in
            let service = self
            let effectiveBatchSize = max(batchSize, 1)
            let task = Task {
                #if DEBUG
                    let streamStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                    var yieldedBatchCount = 0
                    var yieldedEntryCount = 0
                    var preferredEntriesYielded = 0
                    var nonPreferredEntriesYielded = 0
                    var prioritizedYielded = false
                    var yieldDurationMS: Double = 0
                    func logYieldComplete() {
                        WorkspaceRestorePerfLog.event(
                            "agentSessionIndex.streamYieldComplete",
                            fields: [
                                "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                                "batches": "\(yieldedBatchCount)",
                                "entriesYielded": "\(yieldedEntryCount)",
                                "preferredEntriesYielded": "\(preferredEntriesYielded)",
                                "nonPreferredEntriesYielded": "\(nonPreferredEntriesYielded)",
                                "prioritizedYielded": "\(prioritizedYielded)",
                                "yieldDuration": WorkspaceRestorePerfLog.formatMS(yieldDurationMS),
                                "total": streamStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                            ]
                        )
                    }
                #endif
                do {
                    #if DEBUG
                        let metadataStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                    #endif
                    let records = try await service.sidebarStreamMetadataRecords(for: request.workspace)
                    #if DEBUG
                        WorkspaceRestorePerfLog.event(
                            "agentSessionIndex.streamMetadataFetched",
                            fields: [
                                "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                                "records": "\(records.count)",
                                "duration": metadataStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                                "batchSize": "\(effectiveBatchSize)",
                                "hasPrioritizedTab": "\(request.prioritizedTabID != nil)"
                            ]
                        )
                    #endif
                    try Task.checkCancellation()
                    #if DEBUG
                        let projectionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                    #endif
                    let projection = Self.projectSidebarIndex(records: records, request: request)
                    #if DEBUG
                        WorkspaceRestorePerfLog.event(
                            "agentSessionIndex.streamProjected",
                            fields: [
                                "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                                "entries": "\(projection.entriesBySessionID.count)",
                                "preferredTabs": "\(projection.preferredEntryByTabID.count)",
                                "orderedPreferred": "\(projection.orderedPreferredEntries.count)",
                                "duration": projectionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                            ]
                        )
                    #endif
                    var emittedSessionIDs: Set<UUID> = []

                    func yieldBatch(entries: [AgentSessionIndexEntry]) {
                        guard !entries.isEmpty else { return }
                        var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
                        var preferredSessionIDByTabID: [UUID: UUID] = [:]
                        for entry in entries {
                            entriesBySessionID[entry.id] = entry
                            preferredSessionIDByTabID[entry.tabID] = entry.id
                            emittedSessionIDs.insert(entry.id)
                        }
                        continuation.yield(
                            AgentSessionSidebarBuildBatch(
                                entriesBySessionID: entriesBySessionID,
                                preferredSessionIDByTabID: preferredSessionIDByTabID
                            )
                        )
                        #if DEBUG
                            yieldedBatchCount += 1
                            yieldedEntryCount += entries.count
                            preferredEntriesYielded += entries.count
                        #endif
                    }

                    if let prioritizedTabID = request.prioritizedTabID,
                       let prioritizedEntry = projection.preferredEntryByTabID[prioritizedTabID]
                    {
                        #if DEBUG
                            let yieldStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                        #endif
                        yieldBatch(entries: [prioritizedEntry])
                        #if DEBUG
                            if let yieldStartMS {
                                yieldDurationMS += WorkspaceRestorePerfLog.elapsedMS(since: yieldStartMS)
                            }
                            prioritizedYielded = true
                        #endif
                    }

                    var pending: [AgentSessionIndexEntry] = []
                    for entry in projection.orderedPreferredEntries where !emittedSessionIDs.contains(entry.id) {
                        try Task.checkCancellation()
                        pending.append(entry)
                        if pending.count >= effectiveBatchSize {
                            #if DEBUG
                                let yieldStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                            #endif
                            yieldBatch(entries: pending)
                            #if DEBUG
                                if let yieldStartMS {
                                    yieldDurationMS += WorkspaceRestorePerfLog.elapsedMS(since: yieldStartMS)
                                }
                            #endif
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    #if DEBUG
                        let pendingYieldStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                    #endif
                    yieldBatch(entries: pending)
                    #if DEBUG
                        if let pendingYieldStartMS, !pending.isEmpty {
                            yieldDurationMS += WorkspaceRestorePerfLog.elapsedMS(since: pendingYieldStartMS)
                        }
                    #endif

                    let nonPreferredEntries = projection.entriesBySessionID.values
                        .filter { !emittedSessionIDs.contains($0.id) }
                    guard nonPreferredEntries.isEmpty else {
                        var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
                        for entry in nonPreferredEntries {
                            entriesBySessionID[entry.id] = entry
                        }
                        #if DEBUG
                            let yieldStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                        #endif
                        continuation.yield(
                            AgentSessionSidebarBuildBatch(
                                entriesBySessionID: entriesBySessionID,
                                preferredSessionIDByTabID: [:]
                            )
                        )
                        #if DEBUG
                            if let yieldStartMS {
                                yieldDurationMS += WorkspaceRestorePerfLog.elapsedMS(since: yieldStartMS)
                            }
                            yieldedBatchCount += 1
                            yieldedEntryCount += nonPreferredEntries.count
                            nonPreferredEntriesYielded += nonPreferredEntries.count
                            logYieldComplete()
                        #endif
                        continuation.finish()
                        return
                    }
                    #if DEBUG
                        logYieldComplete()
                    #endif
                    continuation.finish()
                } catch {
                    #if DEBUG
                        if !Task.isCancelled {
                            WorkspaceRestorePerfLog.event(
                                "agentSessionIndex.streamFailure",
                                fields: [
                                    "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                                    "batches": "\(yieldedBatchCount)",
                                    "entriesYielded": "\(yieldedEntryCount)",
                                    "total": streamStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured",
                                    "error": String(describing: error)
                                ]
                            )
                        }
                    #endif
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func buildSidebarIndex(
        _ request: AgentSessionSidebarBuildRequest
    ) async throws -> AgentSessionSidebarBuildResult {
        var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
        var preferredSessionIDByTabID: [UUID: UUID] = [:]
        for try await batch in buildSidebarIndexStream(request, batchSize: Int.max) {
            entriesBySessionID.merge(batch.entriesBySessionID) { _, new in new }
            preferredSessionIDByTabID.merge(batch.preferredSessionIDByTabID) { _, new in new }
        }
        return AgentSessionSidebarBuildResult(
            entriesBySessionID: entriesBySessionID,
            preferredSessionIDByTabID: preferredSessionIDByTabID
        )
    }

    func buildPrioritizedSidebarIndex(
        _ request: AgentSessionSidebarBuildRequest
    ) async throws -> AgentSessionSidebarBuildResult {
        #if DEBUG
            let targetedStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            func logTargetedBuilt(
                source: String,
                tabID: UUID?,
                explicitSessionID: UUID?,
                recordsScanned: Int?,
                result: AgentSessionSidebarBuildResult
            ) {
                WorkspaceRestorePerfLog.event(
                    "agentSessionIndex.prioritizedTargetedBuilt",
                    fields: [
                        "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                        "tabID": WorkspaceRestorePerfLog.shortID(tabID),
                        "explicitSession": WorkspaceRestorePerfLog.shortID(explicitSessionID),
                        "source": source,
                        "recordsScanned": recordsScanned.map { "\($0)" } ?? "unknown",
                        "entries": "\(result.entriesBySessionID.count)",
                        "preferredTabs": "\(result.preferredSessionIDByTabID.count)",
                        "duration": targetedStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            }
        #endif

        guard request.validTabIDs.count == 1,
              let tabID = request.validTabIDs.first
        else {
            let result = try await buildSidebarIndex(request)
            #if DEBUG
                logTargetedBuilt(
                    source: "fallbackFull",
                    tabID: request.prioritizedTabID,
                    explicitSessionID: nil,
                    recordsScanned: nil,
                    result: result
                )
            #endif
            return result
        }

        let tabName = request.tabNameByID[tabID]
        let explicitSessionID = request.boundSessionIDByTabID[tabID]
        if let fastRecords = try await fastMetadataRecordsIfAvailable(for: request.workspace) {
            let projection = Self.projectPrioritizedSidebarIndex(
                records: fastRecords.records,
                tabID: tabID,
                tabName: tabName,
                explicitSessionID: explicitSessionID
            )
            #if DEBUG
                logTargetedBuilt(
                    source: fastRecords.source.rawValue,
                    tabID: tabID,
                    explicitSessionID: explicitSessionID,
                    recordsScanned: projection.recordsScanned,
                    result: projection.result
                )
            #endif
            return projection.result
        }

        guard let explicitSessionID else {
            // Targeted restore is best-effort; without an explicit binding or a fast
            // metadata index, avoid rebuilding the full index on the foreground path.
            let result = AgentSessionSidebarBuildResult(
                entriesBySessionID: [:],
                preferredSessionIDByTabID: [:]
            )
            #if DEBUG
                logTargetedBuilt(
                    source: "emptyNoIndex",
                    tabID: tabID,
                    explicitSessionID: nil,
                    recordsScanned: 0,
                    result: result
                )
            #endif
            return result
        }

        let record: AgentSessionMetadataRecord?
        do {
            record = try await metadataRecordForSessionID(explicitSessionID, for: request.workspace)
        } catch let error as CancellationError {
            throw error
        } catch {
            record = nil
        }
        guard let entry = record?.sidebarEntry(
            tabID: tabID,
            displayName: tabName ?? record?.name
        ) else {
            let result = AgentSessionSidebarBuildResult(
                entriesBySessionID: [:],
                preferredSessionIDByTabID: [:]
            )
            #if DEBUG
                logTargetedBuilt(
                    source: "missingExplicitSessionFile",
                    tabID: tabID,
                    explicitSessionID: explicitSessionID,
                    recordsScanned: 0,
                    result: result
                )
            #endif
            return result
        }

        let result = AgentSessionSidebarBuildResult(
            entriesBySessionID: [entry.id: entry],
            preferredSessionIDByTabID: [tabID: entry.id]
        )
        #if DEBUG
            logTargetedBuilt(
                source: "explicitSessionFile",
                tabID: tabID,
                explicitSessionID: explicitSessionID,
                recordsScanned: 1,
                result: result
            )
        #endif
        return result
    }

    private struct SidebarIndexProjection {
        let entriesBySessionID: [UUID: AgentSessionIndexEntry]
        let preferredEntryByTabID: [UUID: AgentSessionIndexEntry]
        let orderedPreferredEntries: [AgentSessionIndexEntry]
    }

    private struct PrioritizedSidebarProjection {
        let result: AgentSessionSidebarBuildResult
        let recordsScanned: Int
    }

    private static func projectPrioritizedSidebarIndex(
        records: [AgentSessionMetadataRecord],
        tabID: UUID,
        tabName: String?,
        explicitSessionID: UUID?
    ) -> PrioritizedSidebarProjection {
        var recordsScanned = 0
        if let explicitSessionID {
            for record in records {
                recordsScanned += 1
                guard record.id == explicitSessionID else { continue }
                guard let entry = record.sidebarEntry(
                    tabID: tabID,
                    displayName: tabName ?? record.name
                ) else {
                    break
                }
                return PrioritizedSidebarProjection(
                    result: AgentSessionSidebarBuildResult(
                        entriesBySessionID: [entry.id: entry],
                        preferredSessionIDByTabID: [tabID: entry.id]
                    ),
                    recordsScanned: recordsScanned
                )
            }
            return PrioritizedSidebarProjection(
                result: AgentSessionSidebarBuildResult(
                    entriesBySessionID: [:],
                    preferredSessionIDByTabID: [:]
                ),
                recordsScanned: recordsScanned
            )
        }

        var preferredEntries: [AgentSessionIndexEntry] = []
        for record in records {
            recordsScanned += 1
            guard record.composeTabID == tabID,
                  let entry = record.sidebarEntry(
                      tabID: tabID,
                      displayName: tabName ?? record.name
                  )
            else {
                continue
            }
            preferredEntries.append(entry)
        }

        let preferredEntry = AgentSessionRestoreSupport.preferredEntriesByTabID(from: preferredEntries)[tabID]
        guard let preferredEntry else {
            return PrioritizedSidebarProjection(
                result: AgentSessionSidebarBuildResult(
                    entriesBySessionID: [:],
                    preferredSessionIDByTabID: [:]
                ),
                recordsScanned: recordsScanned
            )
        }

        return PrioritizedSidebarProjection(
            result: AgentSessionSidebarBuildResult(
                entriesBySessionID: [preferredEntry.id: preferredEntry],
                preferredSessionIDByTabID: [tabID: preferredEntry.id]
            ),
            recordsScanned: recordsScanned
        )
    }

    private static func projectSidebarIndex(
        records: [AgentSessionMetadataRecord],
        request: AgentSessionSidebarBuildRequest
    ) -> SidebarIndexProjection {
        #if DEBUG
            let projectionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let sortStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let sortedRecords = records.sortedForAgentSessionMetadataIndex()
        #if DEBUG
            let sortDurationMS = sortStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            let recordMapStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        var recordBySessionID: [UUID: AgentSessionMetadataRecord] = [:]
        for record in sortedRecords where recordBySessionID[record.id] == nil {
            recordBySessionID[record.id] = record
        }
        #if DEBUG
            let recordMapDurationMS = recordMapStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            let explicitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var explicitCandidates = 0
            var explicitEntries = 0
        #endif

        var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
        var preferredEntryByTabID: [UUID: AgentSessionIndexEntry] = [:]
        var explicitTabIDBySessionID: [UUID: UUID] = [:]

        for (tabID, sessionID) in request.boundSessionIDByTabID where request.validTabIDs.contains(tabID) {
            #if DEBUG
                explicitCandidates += 1
            #endif
            guard let record = recordBySessionID[sessionID],
                  let entry = record.sidebarEntry(
                      tabID: tabID,
                      displayName: request.tabNameByID[tabID] ?? record.name
                  )
            else {
                continue
            }
            explicitTabIDBySessionID[entry.id] = tabID
            entriesBySessionID[entry.id] = entry
            preferredEntryByTabID[tabID] = entry
            #if DEBUG
                explicitEntries += 1
            #endif
        }
        #if DEBUG
            let explicitDurationMS = explicitStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            let preferredStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var preferredCandidates = 0
        #endif

        let explicitlyBoundTabIDs = Set(preferredEntryByTabID.keys)
        var fallbackPreferredCandidates: [AgentSessionIndexEntry] = []
        for record in sortedRecords {
            guard let tabID = record.composeTabID,
                  request.validTabIDs.contains(tabID)
            else {
                continue
            }
            #if DEBUG
                preferredCandidates += 1
            #endif
            if let explicitTabID = explicitTabIDBySessionID[record.id], explicitTabID != tabID {
                continue
            }
            guard let entry = record.sidebarEntry(
                tabID: tabID,
                displayName: request.tabNameByID[tabID] ?? record.name
            ) else {
                continue
            }
            if entriesBySessionID[entry.id] == nil {
                entriesBySessionID[entry.id] = entry
            }
            guard !explicitlyBoundTabIDs.contains(tabID) else { continue }
            fallbackPreferredCandidates.append(entry)
        }
        for (tabID, entry) in AgentSessionRestoreSupport.preferredEntriesByTabID(from: fallbackPreferredCandidates) {
            preferredEntryByTabID[tabID] = entry
        }
        #if DEBUG
            let preferredDurationMS = preferredStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            let orderedSortStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        let orderedPreferredEntries = preferredEntryByTabID.values.sorted { lhs, rhs in
            let lhsActivity = AgentSessionRestoreSupport.sidebarActivityDate(
                lastUserMessageAt: lhs.lastUserMessageAt,
                savedAt: lhs.savedAt
            )
            let rhsActivity = AgentSessionRestoreSupport.sidebarActivityDate(
                lastUserMessageAt: rhs.lastUserMessageAt,
                savedAt: rhs.savedAt
            )
            if lhsActivity != rhsActivity {
                return lhsActivity > rhsActivity
            }
            if lhs.savedAt != rhs.savedAt {
                return lhs.savedAt > rhs.savedAt
            }
            if lhs.tabID.uuidString != rhs.tabID.uuidString {
                return lhs.tabID.uuidString < rhs.tabID.uuidString
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        #if DEBUG
            let orderedSortDurationMS = orderedSortStartMS.map { WorkspaceRestorePerfLog.elapsedMS(since: $0) }
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.projection",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                    "records": "\(records.count)",
                    "sortedRecords": "\(sortedRecords.count)",
                    "recordMapCount": "\(recordBySessionID.count)",
                    "validTabs": "\(request.validTabIDs.count)",
                    "boundSessions": "\(request.boundSessionIDByTabID.count)",
                    "explicitCandidates": "\(explicitCandidates)",
                    "explicitEntries": "\(explicitEntries)",
                    "preferredCandidates": "\(preferredCandidates)",
                    "preferredEntries": "\(preferredEntryByTabID.count)",
                    "entries": "\(entriesBySessionID.count)",
                    "orderedPreferred": "\(orderedPreferredEntries.count)",
                    "sortDuration": sortDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured",
                    "recordMapDuration": recordMapDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured",
                    "explicitDuration": explicitDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured",
                    "preferredDuration": preferredDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured",
                    "orderedSortDuration": orderedSortDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notMeasured",
                    "total": projectionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        return SidebarIndexProjection(
            entriesBySessionID: entriesBySessionID,
            preferredEntryByTabID: preferredEntryByTabID,
            orderedPreferredEntries: orderedPreferredEntries
        )
    }

    func preparePersistedHydration(
        _ request: AgentSessionHydrationRequest
    ) async throws -> AgentSessionHydrationPayload? {
        #if DEBUG
            let prepareStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var loadDurationMS: Double?
            var transcriptDurationMS: Double?
            var presentationDurationMS: Double?
            func logPrepare(
                outcome: String,
                canonicalLiveItems: Int? = nil,
                turns: Int? = nil,
                needsReloadMigrationSave: Bool? = nil,
                frozenTailLimitNormalizationNeeded: Bool? = nil,
                error: Error? = nil
            ) {
                var fields: [String: String] = [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(request.workspace.id),
                    "tabID": WorkspaceRestorePerfLog.shortID(request.tabID),
                    "sessionID": WorkspaceRestorePerfLog.shortID(request.sessionID),
                    "outcome": outcome,
                    "loadDuration": loadDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun",
                    "transcriptDuration": transcriptDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun",
                    "presentationDuration": presentationDurationMS.map(WorkspaceRestorePerfLog.formatMS) ?? "notRun",
                    "canonicalLiveItems": canonicalLiveItems.map { "\($0)" } ?? "notRun",
                    "turns": turns.map { "\($0)" } ?? "notRun",
                    "needsReloadMigrationSave": needsReloadMigrationSave.map { "\($0)" } ?? "notRun",
                    "frozenTailLimitNormalizationNeeded": frozenTailLimitNormalizationNeeded.map { "\($0)" } ?? "notRun",
                    "total": prepareStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
                if let error {
                    fields["error"] = String(describing: error)
                }
                WorkspaceRestorePerfLog.event("agentSessionHydration.prepare", fields: fields)
            }
        #endif
        do {
            try Task.checkCancellation()
            #if DEBUG
                let loadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            guard let agentSession = try await loadAgentSession(
                id: request.sessionID,
                for: request.workspace
            ) else {
                #if DEBUG
                    if let loadStartMS {
                        loadDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: loadStartMS)
                    }
                    logPrepare(outcome: "missingSession")
                #endif
                return nil
            }
            #if DEBUG
                if let loadStartMS {
                    loadDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: loadStartMS)
                }
                let transcriptStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif

            let persistedRunState = agentSession.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
            let normalizedRunState = AgentSessionRestoreSupport.normalizeColdRestoredRunState(persistedRunState)
            let normalizedSelection = AgentModelCatalog.normalizePersistedSelection(
                agentRaw: agentSession.agentKind,
                modelRaw: agentSession.agentModel
            )
            let transcriptPolicy = AgentTranscriptImportPolicy.liveSession(
                hidePendingQuestionToolCall: request.hasPendingQuestionUI
            )
            let persistedWorkingItems = agentSession.workingSourceItems()
            let loadedTranscript: AgentTranscript = {
                if let transcript = agentSession.transcript {
                    if AgentTranscriptIO.containsRowsExcludedByPolicy(in: transcript, policy: transcriptPolicy) {
                        return AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                            existingTranscript: transcript,
                            workingItems: persistedWorkingItems,
                            terminalState: normalizedRunState,
                            nextSequenceIndex: transcript.nextSequenceIndex,
                            policy: transcriptPolicy
                        )
                    }
                    return transcript
                }
                return AgentTranscriptIO.buildTranscript(
                    from: persistedWorkingItems,
                    terminalState: normalizedRunState,
                    nextSequenceIndex: (persistedWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1,
                    policy: transcriptPolicy
                )
            }()
            let compactedTranscript = AgentTranscriptProjectionBuilder
                .normalizedFrozenDetailedToolTailLimits(in: loadedTranscript)
            let frozenTailLimitNormalizationNeeded = compactedTranscript != loadedTranscript
            let canonicalLiveItems = AgentTranscriptIO.workingSourceItems(from: compactedTranscript)
            let projectionProtection = AgentSessionRestoreSupport.transcriptProjectionProtection(
                for: compactedTranscript,
                viewportState: request.transcriptViewportState
            )
            #if DEBUG
                if let transcriptStartMS {
                    transcriptDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: transcriptStartMS)
                }
            #endif

            try Task.checkCancellation()
            #if DEBUG
                let presentationStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            #endif
            let builtPresentation = AgentSessionRestoreSupport.buildTranscriptPresentation(
                from: compactedTranscript,
                sourceItems: canonicalLiveItems,
                selectedAgent: normalizedSelection.agent,
                previousPerformanceSnapshot: request.initialPerformanceSnapshot,
                projectionProtection: projectionProtection,
                isCompressedHistoryRevealed: request.isCompressedHistoryRevealed,
                isColdLoad: true
            )
            #if DEBUG
                if let presentationStartMS {
                    presentationDurationMS = WorkspaceRestorePerfLog.elapsedMS(since: presentationStartMS)
                }
            #endif
            try Task.checkCancellation()

            let lastUserMessageAt = agentSession.lastUserMessageAt
                ?? AgentTranscriptIO.lastUserInteractionDate(in: compactedTranscript)
                ?? AgentSessionRestoreSupport.computeLastUserMessageDate(in: canonicalLiveItems)
            let restoredIndexEntry = AgentSessionRestoreSupport.buildSidebarIndexEntry(
                from: agentSession,
                tabID: request.tabID,
                name: request.resolvedDisplayName,
                lastUserMessageAt: lastUserMessageAt,
                itemCount: compactedTranscript.turns.isEmpty
                    ? canonicalLiveItems.count
                    : builtPresentation.projectionCounts.canonicalVisibleRowCount
            )
            let needsReloadMigrationSave = agentSession.transcript != compactedTranscript
                || agentSession.itemCount == nil
                || agentSession.lastUserMessageAt == nil
                || frozenTailLimitNormalizationNeeded

            #if DEBUG
                logPrepare(
                    outcome: "payload",
                    canonicalLiveItems: canonicalLiveItems.count,
                    turns: compactedTranscript.turns.count,
                    needsReloadMigrationSave: needsReloadMigrationSave,
                    frozenTailLimitNormalizationNeeded: frozenTailLimitNormalizationNeeded
                )
            #endif
            return AgentSessionHydrationPayload(
                sessionID: request.sessionID,
                persistedSession: agentSession,
                canonicalLiveItems: canonicalLiveItems,
                transcript: compactedTranscript,
                builtPresentation: builtPresentation,
                normalizedRunState: normalizedRunState,
                normalizedSelection: normalizedSelection,
                lastUserMessageAt: lastUserMessageAt,
                restoredIndexEntry: restoredIndexEntry,
                needsReloadMigrationSave: needsReloadMigrationSave
            )
        } catch {
            #if DEBUG
                let outcome = (error is CancellationError || Task.isCancelled) ? "cancelled" : "error"
                logPrepare(outcome: outcome, error: error)
            #endif
            throw error
        }
    }
}
