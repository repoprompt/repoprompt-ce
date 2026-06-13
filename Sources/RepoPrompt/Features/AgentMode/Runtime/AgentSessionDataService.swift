import Foundation

// MARK: - Agent Session Data Error

enum AgentSessionDataError: Error {
    case invalidFilename(String)
    case decodingFailed(Error)
    case loadFailed(Error)
    case saveFailed(Error)
    case noActiveWorkspace
}

// MARK: - Agent Session Metadata

/// Lightweight metadata for agent session listing
struct AgentSessionMeta {
    let id: UUID
    let composeTabID: UUID?
    let name: String
    let lastModified: Date
    let itemCount: Int
    let agentKind: String?
    let agentModel: String?
    let lastRunState: String?
    let parentSessionID: UUID?
    let isMCPOriginated: Bool
    let worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    let activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
}

private actor AgentSessionDiskWriter {
    private struct PendingWrite {
        var pendingData: Data?
        var isWriting: Bool
        var waiters: [CheckedContinuation<Void, Error>]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]

    func enqueueAndWait(data: Data, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var pending = pendingByURL[url] ?? PendingWrite(
                pendingData: nil,
                isWriting: false,
                waiters: []
            )
            pending.pendingData = data
            pending.waiters.append(continuation)
            let shouldStartWriter = !pending.isWriting
            pending.isWriting = true
            pendingByURL[url] = pending
            if shouldStartWriter {
                Task { await self.drainWrites(for: url) }
            }
        }
    }

    private func drainWrites(for url: URL) async {
        var lastError: Error?
        while true {
            guard var pending = pendingByURL[url] else { return }
            guard let data = pending.pendingData else {
                pending.isWriting = false
                let waiters = pending.waiters
                pendingByURL.removeValue(forKey: url)
                for waiter in waiters {
                    if let lastError {
                        waiter.resume(throwing: lastError)
                    } else {
                        waiter.resume(returning: ())
                    }
                }
                return
            }
            pending.pendingData = nil
            pendingByURL[url] = pending

            let writeResult: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try data.write(to: url, options: .atomic)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case .success:
                lastError = nil
            case let .failure(error):
                lastError = error
            }
        }
    }
}

// MARK: - Agent Session Data Service

/// An actor that reads/writes AgentSessions from each workspace's "AgentSessions" folder.
actor AgentSessionDataService {
    static let shared = AgentSessionDataService()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diskWriter = AgentSessionDiskWriter()
    private static let sidebarStreamMetadataIndexReconciliationDelaySeconds: TimeInterval = 2.0

    private struct MetadataIndexReconciliationTaskState {
        let id: UUID
        let task: Task<Void, Never>
        let delaySeconds: TimeInterval
    }

    private var metadataIndexCacheByFolder: [URL: AgentSessionMetadataIndex] = [:]
    private var metadataIndexReconciliationTasksByFolder: [URL: MetadataIndexReconciliationTaskState] = [:]
    private var metadataIndexReconciledThisProcess: Set<URL> = []

    private enum AgentSessionMetadataIndexLoadMode {
        case fast
        case backfillIfMissing
        case forceReconcile
    }

    enum FastMetadataRecordsSource: String {
        case memoryIndex
        case diskIndex
    }

    struct FastMetadataRecordsResult {
        let records: [AgentSessionMetadataRecord]
        let source: FastMetadataRecordsSource
    }

    // MARK: - Lightweight decode helpers

    private struct AgentSessionHeader: Decodable {
        let id: UUID
        let serializationVersion: Int?
        let workspaceID: UUID?
        let composeTabID: UUID?
        let name: String
        let savedAt: Date
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
        let agentKind: String?
        let agentModel: String?
        let agentReasoningEffort: String?
        let lastRunState: String?
        let providerSessionID: String?
        let autoEditEnabled: Bool
        let codexConversationID: String?
        let codexRolloutPath: String?
        let codexModel: String?
        let codexReasoningEffort: String?
        let codexContextWindow: Int?
        let codexLastTotalTokens: Int?
        let codexTotalTotalTokens: Int?
        let codexMcpSessionKey: String?
        let parentSessionID: UUID?
        let worktreeBindings: [AgentSessionWorktreeBinding]?
        let worktreeMergeOperations: [AgentSessionWorktreeMergeOperation]?
        let pendingHandoffPayload: String?
        let pendingHandoffCreatedAt: Date?
        let pendingHandoffSourceItemID: UUID?
        let pendingHandoffDefersProviderLockUntilSend: Bool?
        let isMCPOriginated: Bool?
    }

    private func computeLastUserMessageAt(in items: [AgentChatItemPersist]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items.map { $0.toItem() })
    }

    private func computeLastUserMessageAt(in transcript: AgentTranscript) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: transcript)
    }

    private func computeProjectionCounts(in transcript: AgentTranscript) -> AgentTranscriptProjectionCounts {
        AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
    }

    private struct NormalizedLoadedSession {
        let runtimeSession: AgentSession
        let persistedSessionToRewrite: AgentSession?
    }

    enum SavePreparation {
        case canonicalize
        case alreadyCanonicalTranscript
    }

    private struct PreparedSessionMetadata {
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
    }

    private func preparedSessionMetadata(
        transcript: AgentTranscript?,
        workingItems: [AgentChatItem],
        existingItemCount: Int?,
        existingProjectionCounts: AgentTranscriptProjectionCounts?,
        existingLastUserMessageAt: Date?,
        trustedCanonicalItemCount: Int? = nil,
        preserveProvidedValues: Bool
    ) -> PreparedSessionMetadata {
        if let transcript {
            let computedProjectionCounts = computeProjectionCounts(in: transcript)
            return PreparedSessionMetadata(
                itemCount: trustedCanonicalItemCount ?? computedProjectionCounts.canonicalVisibleRowCount,
                transcriptProjectionCounts: computedProjectionCounts,
                lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? computeLastUserMessageAt(in: transcript)) : computeLastUserMessageAt(in: transcript)
            )
        }
        guard !workingItems.isEmpty else {
            return PreparedSessionMetadata(
                itemCount: preserveProvidedValues ? existingItemCount : nil,
                transcriptProjectionCounts: preserveProvidedValues ? existingProjectionCounts : nil,
                lastUserMessageAt: preserveProvidedValues ? existingLastUserMessageAt : nil
            )
        }
        let fallbackItemCount = preserveProvidedValues ? (existingItemCount ?? workingItems.count) : workingItems.count
        let fallbackProjectionCounts = preserveProvidedValues
            ? (existingProjectionCounts ?? .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            ))
            : .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            )
        return PreparedSessionMetadata(
            itemCount: fallbackItemCount,
            transcriptProjectionCounts: fallbackProjectionCounts,
            lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItems)) : AgentTranscriptIO.lastUserInteractionDate(in: workingItems)
        )
    }

    private func sessionPreparedForStorage(
        _ session: AgentSession,
        fileURL: URL? = nil,
        savedAt: Date? = nil,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil
    ) -> AgentSession {
        var stored = session
        let lastRunState = stored.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        var workingItemsCache: [AgentChatItem]?
        func workingItems() -> [AgentChatItem] {
            if let workingItemsCache {
                return workingItemsCache
            }
            let items = stored.items.map { $0.toItem() }
            workingItemsCache = items
            return items
        }

        switch preparation {
        case .alreadyCanonicalTranscript:
            if stored.transcript == nil {
                let canonicalWorkingItems = workingItems()
                if !canonicalWorkingItems.isEmpty {
                    let nextSequenceIndex = max((canonicalWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1, 0)
                    stored.transcript = AgentTranscriptIO.buildTranscript(
                        from: canonicalWorkingItems,
                        terminalState: lastRunState,
                        nextSequenceIndex: nextSequenceIndex,
                        policy: .canonical
                    )
                }
            }
            if let transcript = stored.transcript {
                stored.transcript = AgentTranscriptIO.persistedTranscript(transcript)
            }
        case .canonicalize:
            if stored.transcript == nil {
                let canonicalWorkingItems = workingItems()
                if !canonicalWorkingItems.isEmpty {
                    let nextSequenceIndex = max((canonicalWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1, 0)
                    stored.transcript = AgentTranscriptIO.buildTranscript(
                        from: canonicalWorkingItems,
                        terminalState: lastRunState,
                        nextSequenceIndex: nextSequenceIndex,
                        policy: .canonical
                    )
                }
            }
            if let transcript = stored.transcript {
                stored.transcript = AgentTranscriptIO.persistedTranscript(transcript)
            }
        }
        stored.items = []
        stored.serializationVersion = AgentSession.currentSerializationVersion
        if let fileURL {
            stored.fileURL = fileURL
        }
        if let savedAt {
            stored.savedAt = savedAt
        }
        let metadata = preparedSessionMetadata(
            transcript: stored.transcript,
            workingItems: workingItemsCache ?? [],
            existingItemCount: stored.itemCount,
            existingProjectionCounts: stored.transcriptProjectionCounts,
            existingLastUserMessageAt: stored.lastUserMessageAt,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            preserveProvidedValues: preparation == .alreadyCanonicalTranscript
        )
        stored.itemCount = metadata.itemCount
        stored.transcriptProjectionCounts = metadata.transcriptProjectionCounts
        stored.lastUserMessageAt = metadata.lastUserMessageAt
        return stored
    }

    private func normalizeLoadedSession(
        _ session: AgentSession,
        fileURL: URL
    ) -> NormalizedLoadedSession {
        let policy = AgentTranscriptImportPolicy.canonical
        let persistedLastRunState = session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        let restoredLastRunStateRaw = AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(session.lastRunState)
        let repairTerminalState = (persistedLastRunState?.isActive == true) ? nil : persistedLastRunState
        let importTerminalState = persistedLastRunState
        let repairContext = AgentTranscriptQualityRepair.Context.coldRestore(agentKindRaw: session.agentKind)
        let storedTranscript = session.transcript
        var workingItems: [AgentChatItem] = {
            if session.items.isEmpty, let storedTranscript {
                return AgentTranscriptIO.workingSourceItems(from: storedTranscript)
            }
            return session.items.map { $0.toItem() }
        }()
        let repairedWorkingCount: Int = if let repairTerminalState {
            AgentTranscriptQualityRepair.finalizePendingTerminalTools(
                in: &workingItems,
                terminalState: repairTerminalState,
                context: repairContext,
                nonToolBoundary: 200
            )
        } else {
            0
        }
        let nextSequenceIndex = max(
            storedTranscript?.nextSequenceIndex ?? 0,
            (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
        )
        let normalizedTranscript: AgentTranscript?
        if let storedTranscript {
            let shouldRebuildFromWorkingItems = repairedWorkingCount > 0
                || AgentTranscriptIO.containsRowsExcludedByPolicy(in: storedTranscript, policy: policy)
                || (repairTerminalState != nil && AgentTranscriptQualityRepair.terminalMetadataRepairNeeded(in: storedTranscript))
            if shouldRebuildFromWorkingItems {
                normalizedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: storedTranscript,
                    workingItems: workingItems,
                    terminalState: importTerminalState,
                    nextSequenceIndex: nextSequenceIndex,
                    policy: policy
                )
            } else {
                normalizedTranscript = AgentTranscriptIO.runtimeNormalizedTranscript(storedTranscript)
            }
        } else if !workingItems.isEmpty {
            normalizedTranscript = AgentTranscriptIO.buildTranscript(
                from: workingItems,
                terminalState: importTerminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: policy
            )
        } else {
            normalizedTranscript = nil
        }
        let runtimeTranscript = normalizedTranscript.map {
            let runtimeNormalized = AgentTranscriptPolicyPipeline.runtimeTranscript($0).transcript
            return AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(runtimeNormalized)
        }
        let runtimeWorkingItems = runtimeTranscript.map(AgentTranscriptIO.workingSourceItems(from:)) ?? workingItems
        var runtimeSession = session
        runtimeSession.serializationVersion = AgentSession.currentSerializationVersion
        runtimeSession.fileURL = fileURL
        runtimeSession.lastRunState = restoredLastRunStateRaw
        runtimeSession.transcript = runtimeTranscript
        runtimeSession.items = runtimeWorkingItems.map {
            AgentChatItemPersist(from: $0, sanitizeToolResults: false)
        }
        if let runtimeTranscript {
            let projectionCounts = computeProjectionCounts(in: runtimeTranscript)
            runtimeSession.itemCount = projectionCounts.canonicalVisibleRowCount
            runtimeSession.transcriptProjectionCounts = projectionCounts
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeTranscript)
        } else if !runtimeWorkingItems.isEmpty {
            runtimeSession.itemCount = runtimeWorkingItems.count
            runtimeSession.transcriptProjectionCounts = .init(
                canonicalVisibleRowCount: runtimeWorkingItems.count,
                defaultPresentedRowCount: runtimeWorkingItems.count
            )
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeSession.items)
        }
        let persistedSession = sessionPreparedForStorage(
            runtimeSession,
            fileURL: fileURL,
            savedAt: session.savedAt,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: runtimeSession.itemCount
        )
        let needsRewrite = session.serializationVersion < AgentSession.currentSerializationVersion
            || !session.items.isEmpty
            || session.lastRunState != persistedSession.lastRunState
            || session.transcript != persistedSession.transcript
            || session.itemCount != persistedSession.itemCount
            || session.transcriptProjectionCounts != persistedSession.transcriptProjectionCounts
            || session.lastUserMessageAt != persistedSession.lastUserMessageAt
        return NormalizedLoadedSession(
            runtimeSession: runtimeSession,
            persistedSessionToRewrite: needsRewrite ? persistedSession : nil
        )
    }

    private func writeDataAtomically(_ data: Data, to fileURL: URL) async throws {
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
    }

    // MARK: - Metadata Index Helpers

    private func canonicalMetadataFolderKey(_ folder: URL) -> URL {
        folder.standardizedFileURL
    }

    private func metadataIndexFileURL(forAgentSessionsFolder folder: URL) -> URL {
        folder.appendingPathComponent("AgentSessionIndex.json")
    }

    private func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }

    private func agentSessionFileURL(id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(agentSessionFilename(for: id))
    }

    private func agentSessionID(fromFilename filename: String) -> UUID? {
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else { return nil }
        let prefixLength = "AgentSession-".count
        let suffixLength = ".json".count
        guard filename.count > prefixLength + suffixLength else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefixLength)
        let end = filename.index(filename.endIndex, offsetBy: -suffixLength)
        return UUID(uuidString: String(filename[start ..< end]))
    }

    private func metadataResourceValues(for fileURL: URL) -> (size: Int64?, modified: Date?) {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init)
        return (size, values?.contentModificationDate)
    }

    private func metadataRecord(from session: AgentSession, fileURL: URL) -> AgentSessionMetadataRecord {
        let values = metadataResourceValues(for: fileURL)
        return AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: values.size,
            observedFileModificationDate: values.modified
        )
    }

    private func readMetadataIndexIfAvailable(folder: URL, preferCache: Bool = true) async -> AgentSessionMetadataIndex? {
        #if DEBUG
            let readStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        if preferCache, let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.memoryRead status=hit entries=\(cached.entries.count) quarantined=\(cached.quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return cached
        }
        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=missing duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                #if DEBUG
                    if let readStartMS {
                        WorkspaceRestorePerfLog.log(
                            "agentSessionIndex.diskRead status=schemaMismatch entries=\(index.entries.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                        )
                    }
                #endif
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=hit entries=\(index.entries.count) quarantined=\(index.quarantinedFiles.count) bytes=\(data.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return index
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=error duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS)) error=\(String(describing: error))"
                    )
                }
            #endif
            return nil
        }
    }

    private func writeMetadataIndex(_ index: AgentSessionMetadataIndex, folder: URL) async throws {
        #if DEBUG
            let writeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        var normalized = index
        normalized.schemaVersion = AgentSessionMetadataIndex.currentSchemaVersion
        normalized.entries = normalized.entries.sortedForAgentSessionMetadataIndex()
        let data = try encoder.encode(normalized)
        metadataIndexCacheByFolder[key] = normalized
        try data.write(to: metadataIndexFileURL(forAgentSessionsFolder: folder), options: .atomic)
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.metadata.writeIndex",
                startMS: writeStartMS,
                fields: [
                    "entries": String(normalized.entries.count),
                    "quarantined": String(normalized.quarantinedFiles.count)
                ]
            )
        #endif
    }

    private func upsertMetadataRecord(_ record: AgentSessionMetadataRecord, folder: URL) async {
        do {
            let key = canonicalMetadataFolderKey(folder)
            var index: AgentSessionMetadataIndex = if let cached = metadataIndexCacheByFolder[key] {
                cached
            } else if let existing = await readMetadataIndexIfAvailable(folder: folder) {
                existing
            } else {
                AgentSessionMetadataIndex()
            }
            index.entries.removeAll { existing in
                existing.id == record.id || existing.filename == record.filename
            }
            index.entries.append(record)
            index.generatedAt = Date()
            metadataIndexCacheByFolder[key] = index
            try await writeMetadataIndex(index, folder: folder)
        } catch {
            // Session files remain authoritative; a later backfill/reconcile can repair the index.
        }
    }

    private func upsertMetadataRecordIfIndexPresent(_ session: AgentSession, fileURL: URL) async {
        let folder = fileURL.deletingLastPathComponent()
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let record = metadataRecord(from: session, fileURL: fileURL)
        if let existing = index.entries.first(where: { $0.id == record.id }),
           existing.matchesIndexedSessionMetadata(record)
        {
            return
        }
        index.entries.removeAll { existing in
            existing.id == record.id || existing.filename == record.filename
        }
        index.entries.append(record)
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func removeMetadataRecords(
        matching shouldRemove: (AgentSessionMetadataRecord) -> Bool,
        folder: URL
    ) async {
        #if DEBUG
            let removeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            var debugEntriesBefore = 0
            var debugEntriesAfter = 0
            var debugChanged = false
            defer {
                AgentModePerfDiagnostics.durationEvent(
                    "cleanup.metadata.removeRecords",
                    startMS: removeStartMS,
                    fields: [
                        "entriesBefore": String(debugEntriesBefore),
                        "entriesAfter": String(debugEntriesAfter),
                        "changed": String(debugChanged)
                    ]
                )
            }
        #endif
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let originalCount = index.entries.count
        #if DEBUG
            debugEntriesBefore = originalCount
            debugEntriesAfter = originalCount
        #endif
        index.entries.removeAll(where: shouldRemove)
        #if DEBUG
            debugEntriesAfter = index.entries.count
            debugChanged = index.entries.count != originalCount
        #endif
        guard index.entries.count != originalCount else { return }
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func agentSessionFiles(in folder: URL) throws -> [URL] {
        #if DEBUG
            let scanStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let jsonFiles = contents.filter {
            $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent.starts(with: "AgentSession-")
        }
        let sorted = jsonFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        #if DEBUG
            if let scanStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.fileScan scannedSessionFiles=\(sorted.count) directoryEntries=\(contents.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: scanStartMS))"
                )
            }
        #endif
        return sorted
    }

    private func metadataIndexNeedsFilenameReconciliation(_ index: AgentSessionMetadataIndex, folder: URL) throws -> Bool {
        #if DEBUG
            let reconcileCheckStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let fileNames = try Set(agentSessionFiles(in: folder).map(\.lastPathComponent))
        let indexedNames = Set(index.entries.map(\.filename))
        let needsReconciliation = fileNames != indexedNames
        #if DEBUG
            if let reconcileCheckStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.reconcileCheck needsRebuild=\(needsReconciliation) scannedSessionFiles=\(fileNames.count) indexedEntries=\(indexedNames.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: reconcileCheckStartMS))"
                )
            }
        #endif
        return needsReconciliation
    }

    private func rebuildMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        let key = canonicalMetadataFolderKey(folder)
        #if DEBUG
            let rebuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let now = Date()
        let files = try agentSessionFiles(in: folder)
        var records: [AgentSessionMetadataRecord] = []
        var quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
        records.reserveCapacity(files.count)

        for fileURL in files {
            let values = metadataResourceValues(for: fileURL)
            do {
                let stub = try await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                )
                records.append(
                    AgentSessionMetadataRecord.record(
                        from: stub,
                        fileURL: fileURL,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        lastIndexedAt: now
                    )
                )
            } catch {
                quarantinedFiles.append(
                    AgentSessionMetadataQuarantineRecord(
                        filename: fileURL.lastPathComponent,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        errorDescription: String(describing: error),
                        lastAttemptedAt: now
                    )
                )
            }
        }

        let index = AgentSessionMetadataIndex(
            generatedAt: now,
            lastReconciledAt: now,
            entries: records.sortedForAgentSessionMetadataIndex(),
            quarantinedFiles: quarantinedFiles
        )
        try? await writeMetadataIndex(index, folder: folder)
        metadataIndexReconciledThisProcess.insert(key)
        #if DEBUG
            if let rebuildStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.rebuild scannedSessionFiles=\(files.count) records=\(records.count) quarantined=\(quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: rebuildStartMS))"
                )
            }
        #endif
        return index
    }

    private func reconcileMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        try await rebuildMetadataIndex(folder: folder)
    }

    private func scheduleMetadataIndexReconciliationIfNeeded(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        reason: String = "metadataIndexBackfill",
        workspaceID: UUID? = nil
    ) {
        let key = canonicalMetadataFolderKey(folder)
        let alreadyReconciled = metadataIndexReconciledThisProcess.contains(key)
        let existingTaskState = metadataIndexReconciliationTasksByFolder[key]
        let alreadyScheduled = existingTaskState != nil
        let effectiveDelaySeconds = max(delaySeconds, 0)
        let promotesDelayedReconciliation = existingTaskState.map {
            $0.delaySeconds > 0 && effectiveDelaySeconds == 0
        } ?? false
        let willSchedule = !alreadyReconciled && (!alreadyScheduled || promotesDelayedReconciliation)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.reconcileScheduled",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspaceID),
                    "delayMS": "\(Int((effectiveDelaySeconds * 1000).rounded()))",
                    "reason": reason,
                    "alreadyScheduled": "\(alreadyScheduled)",
                    "alreadyReconciled": "\(alreadyReconciled)",
                    "scheduled": "\(willSchedule)"
                ]
            )
        #endif
        guard willSchedule else { return }
        if promotesDelayedReconciliation {
            existingTaskState?.task.cancel()
        }
        let taskID = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await reconcileMetadataIndexInBackground(
                folder: folder,
                delaySeconds: effectiveDelaySeconds,
                taskID: taskID
            )
        }
        metadataIndexReconciliationTasksByFolder[key] = MetadataIndexReconciliationTaskState(
            id: taskID,
            task: task,
            delaySeconds: effectiveDelaySeconds
        )
    }

    private func reconcileMetadataIndexInBackground(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        taskID: UUID
    ) async {
        let key = canonicalMetadataFolderKey(folder)
        defer {
            if metadataIndexReconciliationTasksByFolder[key]?.id == taskID {
                metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            }
        }
        if delaySeconds > 0 {
            let nanoseconds = UInt64(min(delaySeconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
        }
        do {
            _ = try await reconcileMetadataIndex(folder: folder)
        } catch {
            // Best-effort: session files remain authoritative, and explicit force-reconcile can repair later.
        }
    }

    private func metadataIndex(
        for workspace: WorkspaceModel,
        mode: AgentSessionMetadataIndexLoadMode
    ) async throws -> AgentSessionMetadataIndex? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        switch mode {
        case .fast:
            return await readMetadataIndexIfAvailable(folder: folder)
        case .backfillIfMissing:
            if let index = await readMetadataIndexIfAvailable(folder: folder) {
                scheduleMetadataIndexReconciliationIfNeeded(folder: folder)
                return index
            }
            return try await rebuildMetadataIndex(folder: folder)
        case .forceReconcile:
            return try await reconcileMetadataIndex(folder: folder)
        }
    }

    func fastMetadataRecordsIfAvailable(for workspace: WorkspaceModel) async throws -> FastMetadataRecordsResult? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let key = canonicalMetadataFolderKey(folder)
        if let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            return FastMetadataRecordsResult(
                records: cached.entries.sortedForAgentSessionMetadataIndex(),
                source: .memoryIndex
            )
        }

        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            return FastMetadataRecordsResult(
                records: index.entries.sortedForAgentSessionMetadataIndex(),
                source: .diskIndex
            )
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }
    }

    func metadataRecordForSessionID(_ id: UUID, for workspace: WorkspaceModel) async throws -> AgentSessionMetadataRecord? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: id, in: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let stub = try await loadAgentSessionStub(
            from: fileURL,
            recoverMissingMetadata: false,
            persistRecoveredMetadata: false
        )
        return metadataRecord(from: stub, fileURL: fileURL)
    }

    private func metadataRecords(
        for workspace: WorkspaceModel,
        limit: Int? = nil
    ) async throws -> [AgentSessionMetadataRecord] {
        let index = try await metadataIndex(for: workspace, mode: .backfillIfMissing)
        let records = index?.entries.sortedForAgentSessionMetadataIndex() ?? []
        guard let limit else { return records }
        return Array(records.prefix(max(limit, 0)))
    }

    func indexedAgentSessionMetadataRecords(for workspace: WorkspaceModel) async throws -> [AgentSessionMetadataRecord] {
        try await metadataRecords(for: workspace)
    }

    func sidebarStreamMetadataRecords(for workspace: WorkspaceModel) async throws -> [AgentSessionMetadataRecord] {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        if let index = await readMetadataIndexIfAvailable(folder: folder) {
            scheduleMetadataIndexReconciliationIfNeeded(
                folder: folder,
                delaySeconds: Self.sidebarStreamMetadataIndexReconciliationDelaySeconds,
                reason: "sidebarStreamHotIndex",
                workspaceID: workspace.id
            )
            return index.entries.sortedForAgentSessionMetadataIndex()
        }
        let index = try await rebuildMetadataIndex(folder: folder)
        return index.entries.sortedForAgentSessionMetadataIndex()
    }

    // MARK: - Public API

    /// Save an AgentSession for a given workspace, returning the file URL on success.
    func saveAgentSession(
        _ session: AgentSession,
        for workspace: WorkspaceModel,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil
    ) async throws -> URL {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)

        let filename = "AgentSession-\(session.id.uuidString).json"
        let fileURL = agentSessionsFolder.appendingPathComponent(filename)

        let sessionToSave = sessionPreparedForStorage(
            session,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount
        )
        let freshEncoder = JSONEncoder()
        let data = try freshEncoder.encode(sessionToSave)
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
        await upsertMetadataRecord(metadataRecord(from: sessionToSave, fileURL: fileURL), folder: agentSessionsFolder)
        return fileURL
    }

    func renameAgentSession(
        id: UUID,
        to newName: String,
        for workspace: WorkspaceModel
    ) async throws {
        let validatedName = AgentSession.validatedName(newName)
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard var session = try await loadAgentSession(id: id, for: workspace) else { return }
        guard session.name != validatedName else { return }
        session.name = validatedName
        _ = try await saveAgentSession(session, for: workspace)
    }

    /// Load an AgentSession from disk.
    func loadAgentSession(from fileURL: URL) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let session = try decoder.decode(AgentSession.self, from: data)
            let normalized = normalizeLoadedSession(session, fileURL: fileURL)
            var runtimeSession = normalized.runtimeSession
            var persistedSessionToRewrite = normalized.persistedSessionToRewrite
            let reconciledMergeOperations = await AgentSessionWorktreeMergeReconciler.reconcile(runtimeSession.worktreeMergeOperations)
            if reconciledMergeOperations != runtimeSession.worktreeMergeOperations {
                runtimeSession.worktreeMergeOperations = reconciledMergeOperations
                persistedSessionToRewrite = sessionPreparedForStorage(
                    runtimeSession,
                    fileURL: fileURL,
                    savedAt: session.savedAt,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: runtimeSession.itemCount
                )
            }
            if let persistedSession = persistedSessionToRewrite {
                let encoded = try encoder.encode(persistedSession)
                try await writeDataAtomically(encoded, to: fileURL)
                await upsertMetadataRecord(
                    metadataRecord(from: persistedSession, fileURL: fileURL),
                    folder: fileURL.deletingLastPathComponent()
                )
            } else {
                await upsertMetadataRecordIfIndexPresent(runtimeSession, fileURL: fileURL)
            }
            return runtimeSession
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Load a lightweight AgentSession suitable for session lists without decoding full items.
    func loadAgentSessionStub(
        from fileURL: URL,
        recoverMissingMetadata: Bool = false,
        persistRecoveredMetadata: Bool = false
    ) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let header = try decoder.decode(AgentSessionHeader.self, from: data)
            var recoveredLastUserMessageAt = header.lastUserMessageAt
            var recoveredProjectionCounts = header.transcriptProjectionCounts
            var count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? header.itemCount ?? 0

            if recoverMissingMetadata,
               header.lastUserMessageAt == nil || header.itemCount == nil || header.transcriptProjectionCounts == nil,
               let fullSession = try? decoder.decode(AgentSession.self, from: data)
            {
                let normalized = normalizeLoadedSession(fullSession, fileURL: fileURL)
                if let transcript = normalized.runtimeSession.transcript {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? computeLastUserMessageAt(in: transcript)
                    let projectionCounts = computeProjectionCounts(in: transcript)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? projectionCounts
                    if header.itemCount == nil {
                        count = projectionCounts.canonicalVisibleRowCount
                    }
                } else {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? computeLastUserMessageAt(in: normalized.runtimeSession.items)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? .init(
                        canonicalVisibleRowCount: normalized.runtimeSession.items.count,
                        defaultPresentedRowCount: normalized.runtimeSession.items.count
                    )
                    if header.itemCount == nil {
                        count = normalized.runtimeSession.items.count
                    }
                }
                count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? count
                if persistRecoveredMetadata,
                   let persistedSession = normalized.persistedSessionToRewrite
                {
                    do {
                        let encoded = try encoder.encode(persistedSession)
                        try await writeDataAtomically(encoded, to: fileURL)
                        await upsertMetadataRecord(
                            metadataRecord(from: persistedSession, fileURL: fileURL),
                            folder: fileURL.deletingLastPathComponent()
                        )
                    } catch {
                        // Best-effort migration only; continue serving recovered values in-memory.
                    }
                }
            }
            return AgentSession(
                id: header.id,
                serializationVersion: header.serializationVersion ?? AgentSession.legacyUnversionedSerializationVersion,
                workspaceID: header.workspaceID,
                composeTabID: header.composeTabID,
                name: header.name,
                savedAt: header.savedAt,
                fileURL: fileURL,
                items: [],
                transcript: nil,
                itemCount: count,
                transcriptProjectionCounts: recoveredProjectionCounts,
                lastUserMessageAt: recoveredLastUserMessageAt,
                agentKind: header.agentKind,
                agentModel: header.agentModel,
                agentReasoningEffort: header.agentReasoningEffort,
                lastRunState: AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(header.lastRunState),
                providerSessionID: header.providerSessionID,
                autoEditEnabled: header.autoEditEnabled,
                codexConversationID: header.codexConversationID,
                codexRolloutPath: header.codexRolloutPath,
                codexModel: header.codexModel,
                codexReasoningEffort: header.codexReasoningEffort,
                codexContextWindow: header.codexContextWindow,
                codexLastTotalTokens: header.codexLastTotalTokens,
                codexTotalTotalTokens: header.codexTotalTotalTokens,
                codexMcpSessionKey: header.codexMcpSessionKey,
                parentSessionID: header.parentSessionID,
                pendingHandoffPayload: header.pendingHandoffPayload,
                pendingHandoffCreatedAt: header.pendingHandoffCreatedAt,
                pendingHandoffSourceItemID: header.pendingHandoffSourceItemID,
                pendingHandoffDefersProviderLockUntilSend: header.pendingHandoffDefersProviderLockUntilSend ?? false,
                isMCPOriginated: header.isMCPOriginated ?? false,
                worktreeBindings: header.worktreeBindings ?? [],
                worktreeMergeOperations: header.worktreeMergeOperations ?? []
            )
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Returns a list of AgentSession files in the workspace's AgentSessions folder, sorted by mod date desc.
    func listAgentSessions(for workspace: WorkspaceModel) async throws -> [URL] {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)

        let contents = try FileManager.default.contentsOfDirectory(
            at: agentSessionsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let jsonFiles = contents.filter {
            agentSessionID(fromFilename: $0.lastPathComponent) != nil
        }

        let datedFiles = jsonFiles.map { url in
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url: url, modificationDate: modificationDate)
        }
        return datedFiles.sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }.map(\.url)
    }

    /// Get metadata for recent agent sessions without loading full content.
    func recentSessions(for workspace: WorkspaceModel, limit: Int = 10) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            var metadataList: [AgentSessionMeta] = []

            for fileURL in files.prefix(max(limit, 0)) {
                do {
                    let session = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? session.savedAt

                    let meta = AgentSessionMeta(
                        id: session.id,
                        composeTabID: session.composeTabID,
                        name: session.name,
                        lastModified: lastModified,
                        itemCount: session.effectiveItemCount,
                        agentKind: session.agentKind,
                        agentModel: session.agentModel,
                        lastRunState: session.lastRunState,
                        parentSessionID: session.parentSessionID,
                        isMCPOriginated: session.isMCPOriginated,
                        worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                        activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                    )
                    metadataList.append(meta)
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Get lightweight metadata for agent sessions without loading full transcript content.
    func listAgentSessionsMeta(
        for workspace: WorkspaceModel,
        limit: Int? = nil
    ) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            let boundedFiles: ArraySlice<URL> = if let limit {
                files.prefix(max(limit, 0))
            } else {
                files[...]
            }

            var metadataList: [AgentSessionMeta] = []
            metadataList.reserveCapacity(boundedFiles.count)

            for fileURL in boundedFiles {
                do {
                    let session = try await loadAgentSessionStub(
                        from: fileURL,
                        recoverMissingMetadata: false,
                        persistRecoveredMetadata: false
                    )
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ?? session.savedAt
                    metadataList.append(
                        AgentSessionMeta(
                            id: session.id,
                            composeTabID: session.composeTabID,
                            name: session.name,
                            lastModified: lastModified,
                            itemCount: session.effectiveItemCount,
                            agentKind: session.agentKind,
                            agentModel: session.agentModel,
                            lastRunState: session.lastRunState,
                            parentSessionID: session.parentSessionID,
                            isMCPOriginated: session.isMCPOriginated,
                            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                        )
                    )
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Resolves a session reference (UUID string only) to a session ID.
    func resolveAgentSessionID(
        reference: String,
        for workspace: WorkspaceModel
    ) async throws -> UUID? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return try await loadAgentSession(id: uuid, for: workspace) != nil ? uuid : nil
    }

    func loadAgentSession(
        reference: String,
        for workspace: WorkspaceModel
    ) async throws -> AgentSession? {
        guard let sessionID = try await resolveAgentSessionID(reference: reference, for: workspace) else {
            return nil
        }
        return try await loadAgentSession(id: sessionID, for: workspace)
    }

    /// Find an agent session by its ID for a workspace.
    func findAgentSession(id: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            let filename = fileURL.lastPathComponent
            if filename == "AgentSession-\(id.uuidString).json" {
                return try await loadAgentSession(from: fileURL)
            }
        }

        return nil
    }

    /// Load an agent session by ID without scanning the session directory.
    func loadAgentSession(id: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let filename = "AgentSession-\(id.uuidString).json"
        let fileURL = agentSessionsFolder.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try await loadAgentSession(from: fileURL)
    }

    /// Find an agent session by compose tab ID.
    func findAgentSessionForTab(_ tabID: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        if let records = try? await metadataRecords(for: workspace),
           let best = records
           .filter({ $0.composeTabID == tabID })
           .sortedForAgentSessionMetadataIndex()
           .first
        {
            if let session = try await loadAgentSession(id: best.id, for: workspace) {
                return session
            }
            let folder = try ensureAgentSessionsFolder(for: workspace)
            await removeMetadataRecords(matching: { $0.id == best.id }, folder: folder)
        }

        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            do {
                let stub = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                if stub.composeTabID == tabID {
                    return try await loadAgentSession(from: fileURL)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Delete a particular agent session file.
    func deleteAgentSessionFile(_ fileURL: URL) async throws {
        let folder = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        let parsedID = agentSessionID(fromFilename: filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        await removeMetadataRecords(
            matching: { record in
                record.filename == filename || parsedID.map { record.id == $0 } == true
            },
            folder: folder
        )
    }

    /// Delete an agent session by ID.
    func deleteAgentSession(id: UUID, for workspace: WorkspaceModel) async throws {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let filename = agentSessionFilename(for: id)
        let fileURL = agentSessionsFolder.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        await removeMetadataRecords(matching: { $0.id == id || $0.filename == filename }, folder: agentSessionsFolder)
    }

    func deleteAgentSessions(forComposeTabID tabID: UUID, for workspace: WorkspaceModel) async throws {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        var candidateFilesByPath: [String: URL] = [:]
        if let index = await readMetadataIndexIfAvailable(folder: agentSessionsFolder) {
            for record in index.entries where record.composeTabID == tabID {
                candidateFilesByPath[agentSessionsFolder.appendingPathComponent(record.filename).path] = agentSessionsFolder.appendingPathComponent(record.filename)
            }
        }

        let files = try await listAgentSessions(for: workspace)
        for fileURL in files {
            guard
                let stub = try? await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                ),
                stub.composeTabID == tabID
            else { continue }
            candidateFilesByPath[fileURL.path] = fileURL
        }

        for fileURL in candidateFilesByPath.values {
            try? FileManager.default.removeItem(at: fileURL)
        }
        await removeMetadataRecords(matching: { $0.composeTabID == tabID }, folder: agentSessionsFolder)
    }

    #if DEBUG
        func test_clearMetadataIndexCache(forAgentSessionsFolder folder: URL) {
            let key = canonicalMetadataFolderKey(folder)
            metadataIndexCacheByFolder.removeValue(forKey: key)
            metadataIndexReconciliationTasksByFolder[key]?.task.cancel()
            metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            metadataIndexReconciledThisProcess.remove(key)
        }

        func test_markMetadataIndexReconciledThisProcess(forAgentSessionsFolder folder: URL) {
            metadataIndexReconciledThisProcess.insert(canonicalMetadataFolderKey(folder))
        }

        func test_cachedMetadataIndexEntryCount(forAgentSessionsFolder folder: URL) -> Int? {
            metadataIndexCacheByFolder[canonicalMetadataFolderKey(folder)]?.entries.count
        }

        func test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder folder: URL) -> Bool {
            metadataIndexReconciliationTasksByFolder[canonicalMetadataFolderKey(folder)] != nil
        }
    #endif

    // MARK: - Folder Helpers

    /// Creates (if needed) and returns the "AgentSessions" subfolder for the given workspace.
    private func ensureAgentSessionsFolder(for workspace: WorkspaceModel) throws -> URL {
        let baseFolder = try workspaceFolderURL(for: workspace)
        let agentSessionsFolder = baseFolder.appendingPathComponent("AgentSessions")

        if !FileManager.default.fileExists(atPath: agentSessionsFolder.path) {
            try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        }
        return agentSessionsFolder
    }

    /// Return the main folder for the workspace (with custom or default path).
    private func workspaceFolderURL(for workspace: WorkspaceModel) throws -> URL {
        if let customURL = workspace.customStoragePath {
            return customURL
        } else {
            let root = MCPFilesystemConstants.identity.applicationSupportRootURL()
                .appendingPathComponent("Workspaces", isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let folderName = "Workspace-\(workspace.name)-\(workspace.id.uuidString)"
            let workspaceDir = root.appendingPathComponent(folderName)
            if !FileManager.default.fileExists(atPath: workspaceDir.path) {
                try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            }
            return workspaceDir
        }
    }
}
