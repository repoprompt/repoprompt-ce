import CryptoKit
import Darwin
import Foundation
import RepoPromptDomainRuntime
import RepoPromptRemoteProtocol

struct RemoteTranscriptPageRecord {
    let sessionID: UUID
    let items: [RemoteTranscriptItem]
    let nextSequenceIndex: Int?
    let hasMore: Bool
    let pagingMode: RemoteTranscriptPagingMode?
    let olderCursor: RemoteTranscriptCursor?
    let hasOlder: Bool?
    let transcriptRevision: UInt64?
    let chatConfiguration: RemoteChatConfiguration?

    init(
        sessionID: UUID,
        items: [RemoteTranscriptItem],
        nextSequenceIndex: Int? = nil,
        hasMore: Bool = false,
        pagingMode: RemoteTranscriptPagingMode? = nil,
        olderCursor: RemoteTranscriptCursor? = nil,
        hasOlder: Bool? = nil,
        transcriptRevision: UInt64? = nil,
        chatConfiguration: RemoteChatConfiguration? = nil
    ) {
        self.sessionID = sessionID
        self.items = items
        self.nextSequenceIndex = nextSequenceIndex
        self.hasMore = hasMore
        self.pagingMode = pagingMode
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
        self.transcriptRevision = transcriptRevision
        self.chatConfiguration = chatConfiguration
    }
}

enum RemoteTranscriptPageRequest: Equatable {
    case legacyForward(afterSequenceIndex: Int?)
    case recentBackward(before: RemoteTranscriptCursor?)
    case exactItem(UUID)
}

enum RemoteTranscriptCursorCodec {
    static func encode(_ cursor: RemoteTranscriptCursor) throws -> String {
        try JSONEncoder().encode(cursor)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func decode(_ encoded: String) throws -> RemoteTranscriptCursor {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64) else {
            throw RemoteReadServiceError.invalidCursor
        }
        do {
            return try JSONDecoder().decode(RemoteTranscriptCursor.self, from: data)
        } catch {
            throw RemoteReadServiceError.invalidCursor
        }
    }
}

@MainActor
protocol RemoteTranscriptReadService: AnyObject {
    func transcript(
        sessionID: UUID,
        paging: RemoteTranscriptPageRequest,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPageRecord
}

@MainActor
protocol RemoteHistoryReadService: AnyObject {
    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage
}

/// Read-only adapters for the mobile conversation surfaces. They prefer the
/// authoritative live TabSession and fall back to the persisted AgentSession
/// store for closed or unloaded sessions.
@MainActor
final class WindowRemoteReadService: RemoteTranscriptReadService, RemoteHistoryReadService {
    private let contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]
    private let revisionTracker: RemoteTranscriptRevisionTracker?

    init(
        contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)],
        revisionTracker: RemoteTranscriptRevisionTracker? = nil
    ) {
        self.contexts = contexts
        self.revisionTracker = revisionTracker
    }

    func transcript(
        sessionID: UUID,
        paging: RemoteTranscriptPageRequest,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPageRecord {
        let boundedLimit = min(max(limit, 1), 200)
        var transcript: AgentTranscript?
        var persistedSavedAt: Date?
        var liveMutationRevision: UInt64?
        var liveOwnerID: ObjectIdentifier?
        var liveToolResults: [UUID: String] = [:]
        var chatConfiguration: RemoteChatConfiguration?
        let includesChatConfiguration = switch paging {
        case .recentBackward(before: nil), .legacyForward(afterSequenceIndex: nil): true
        default: false
        }

        for context in contexts {
            if let liveSession = context.agentMode.sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) {
                transcript = liveSession.transcript
                liveMutationRevision = liveSession.remoteTranscriptMutationRevision
                liveOwnerID = ObjectIdentifier(liveSession)
                liveToolResults = liveSession.ephemeralToolResultPayloadByItemID
                if includesChatConfiguration {
                    let capabilities = context.agentMode.mcpSessionSelectionCapabilities(
                        tabID: liveSession.tabID, sessionID: sessionID,
                        discoveryAgents: context.agentMode.remoteDiscoveryAgents()
                    )
                    chatConfiguration = Self.chatConfiguration(
                        agent: liveSession.selectedAgent.rawValue,
                        model: liveSession.selectedModelRaw,
                        reasoningEffort: liveSession.selectedReasoningEffortRaw,
                        capabilities: capabilities
                    )
                }
                break
            }
        }

        if transcript == nil {
            persistedSearch: for context in contexts {
                for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral {
                    guard let persisted = try? await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
                    else { continue }
                    transcript = persisted.transcript ?? .empty
                    persistedSavedAt = persisted.savedAt
                    if includesChatConfiguration {
                        let selection = AgentModelCatalog.normalizePersistedSelection(
                            agentRaw: persisted.agentKind, modelRaw: persisted.agentModel
                        )
                        let capabilities = context.agentMode.mcpPersistedSessionSelectionCapabilities(
                            agentRaw: selection.agent.rawValue, modelRaw: selection.modelRaw,
                            reasoningEffortRaw: persisted.agentReasoningEffort,
                            isMutable: AgentModeRemoteSessionQueryService.isConfigurationMutable(
                                runState: AgentModeRemoteSessionQueryService.mapPersistedRunState(persisted.lastRunState)
                            ),
                            discoveryAgents: context.agentMode.remoteDiscoveryAgents()
                        )
                        chatConfiguration = Self.chatConfiguration(
                            agent: selection.agent.rawValue, model: selection.modelRaw,
                            reasoningEffort: persisted.agentReasoningEffort, capabilities: capabilities
                        )
                    }
                    break persistedSearch
                }
            }
        }

        guard let transcript else {
            throw RemoteReadServiceError.sessionNotFound
        }

        let transcriptRevision: UInt64? = if let liveMutationRevision, let liveOwnerID {
            revisionTracker?.observeLive(
                sessionID: sessionID,
                transcript: transcript,
                mutationRevision: liveMutationRevision,
                ownerID: liveOwnerID
            )
        } else if let persistedSavedAt {
            revisionTracker?.observePersisted(sessionID: sessionID, savedAt: persistedSavedAt, fingerprint: .persisted(transcript: transcript))
        } else {
            nil
        }
        let page = Self.page(
            sessionID: sessionID,
            rows: Self.transcriptRows(transcript: transcript, includeDetails: includeDetails, liveToolResults: liveToolResults),
            paging: paging,
            limit: boundedLimit,
            transcriptRevision: transcriptRevision,
            chatConfiguration: chatConfiguration
        )
        if case .exactItem = paging, page.items.isEmpty {
            throw RemoteReadServiceError.transcriptItemNotFound
        }
        return page
    }

    static func chatConfiguration(
        agent: String?, model: String?, reasoningEffort: String?,
        capabilities: AgentSessionSelectionCapabilities?
    ) -> RemoteChatConfiguration? {
        guard let agent, let model, !agent.isEmpty, !model.isEmpty else { return nil }
        return RemoteChatConfiguration(
            selection: RemoteAgentSelection(
                agentID: agent,
                modelID: capabilities?.resolvedModelRaw ?? model,
                reasoningEffort: capabilities.map(\.resolvedReasoningEffortRaw) ?? reasoningEffort
            ),
            controls: capabilities.map(AgentModeRemoteSessionQueryService.remoteConfigurationControls)
        )
    }

    private static func imageAttachments(in transcript: AgentTranscript, itemID: UUID) -> [AgentFileAttachment] {
        for turn in transcript.turns {
            if let request = turn.request, request.id == itemID {
                return request.attachments
            }
            if let activity = turn.allActivities.first(where: { $0.id == itemID }) {
                return activity.attachments
            }
        }
        return []
    }

    func imageAttachment(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk {
        guard request.isValid else { throw RemoteImageReadError.invalidImage }
        let url = try await imageURL(for: request)
        let worker = Task.detached(priority: .userInitiated) {
            try Self.readImage(at: url, request: request)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func imageURL(for request: RemoteImageAttachmentRequest) async throws -> URL {
        // Search live owners across every window before hitting a potentially older saved transcript.
        for context in contexts {
            guard let live = context.agentMode.sessions.values.first(where: { $0.activeAgentSessionID == request.sessionID })
            else { continue }

            if let attachment = Self.imageAttachment(in: live.transcript, request: request) {
                let location = context.agentMode.attachmentLocation(for: live)
                let retainedRoot = location?.retainedRoot ?? context.workspaceManager
                    .workspace(withID: live.persistentSessionBindingIdentity?.workspaceID)
                    .flatMap { context.agentMode.sessionAttachmentsRootURL(for: $0) }
                if let url = Self.ownedImageURL(
                    attachment: attachment,
                    sessionID: request.sessionID,
                    retainedRoot: retainedRoot,
                    workspaceDirectory: location?.workspaceDirectory
                ) { return url }
            }
            if live.hasLoadedPersistedState { throw RemoteImageReadError.unavailable }
        }

        var visited: Set<UUID> = []
        for context in contexts {
            for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral && visited.insert(workspace.id).inserted {
                try Task.checkCancellation()
                guard let saved = try? await AgentSessionDataService.shared.loadAgentSession(id: request.sessionID, for: workspace)
                else { continue }
                guard let transcript = saved.transcript,
                      let attachment = Self.imageAttachment(in: transcript, request: request),
                      let url = Self.ownedImageURL(
                          attachment: attachment, sessionID: request.sessionID,
                          retainedRoot: context.agentMode.sessionAttachmentsRootURL(for: workspace),
                          workspaceDirectory: nil
                      )
                else { throw RemoteImageReadError.unavailable }
                return url
            }
        }
        throw RemoteImageReadError.unavailable
    }

    static func imageAttachment(in transcript: AgentTranscript, request: RemoteImageAttachmentRequest) -> AgentFileAttachment? {
        imageAttachments(in: transcript, itemID: request.itemID)
            .prefix(RemoteAttachmentLimits.maxCount)
            .first { $0.kind == .image && $0.id == request.attachmentID }
    }

    static func ownedImageURL(
        attachment: AgentFileAttachment, sessionID: UUID, retainedRoot: URL?, workspaceDirectory: URL?
    ) -> URL? {
        guard attachment.kind == .image else { return nil }
        if let retainedRoot, let retained = AgentSessionAttachmentStore(rootURL: retainedRoot)
            .locateRetainedFile(attachmentID: attachment.id, sessionID: sessionID)
        {
            return retained
        }
        // Live uploads may still be in the app-managed import directory. A transcript's arbitrary
        // local path or URL is never used as authority to read a file.
        guard let workspaceDirectory, case let .localFile(path) = attachment.source else { return nil }
        let root = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard candidate.deletingLastPathComponent().path == root.path,
              UUID(uuidString: candidate.deletingPathExtension().lastPathComponent) != nil,
              let values = try? candidate.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink == false,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false
        else { return nil }
        return candidate
    }

    nonisolated static func readImage(at url: URL, request: RemoteImageAttachmentRequest) throws -> RemoteImageAttachmentChunk {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw RemoteImageReadError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try imageRevision(descriptor)
        if request.variant == .thumbnail {
            guard let original = try handle.read(upToCount: before.size), original.count == before.size,
                  try imageRevision(descriptor) == before
            else { throw RemoteImageReadError.changed }
            guard let bytes = try AttachmentPreviewRenderer.jpegData(fromRetainedPhoto: original),
                  bytes.count <= RemoteImageAttachmentRequest.maxThumbnailBytes
            else { throw RemoteImageReadError.invalidImage }
            return RemoteImageAttachmentChunk(offset: 0, totalBytes: bytes.count, bytes: bytes)
        }

        guard request.revision == nil || request.revision == before.revision else { throw RemoteImageReadError.changed }
        guard request.offset >= 0, request.offset < before.size else { throw RemoteImageReadError.invalidImage }
        let count = min(RemoteImageAttachmentRequest.chunkBytes, before.size - request.offset)
        try handle.seek(toOffset: UInt64(request.offset))
        guard let bytes = try handle.read(upToCount: count), bytes.count == count,
              try imageRevision(descriptor) == before
        else { throw RemoteImageReadError.changed }
        return RemoteImageAttachmentChunk(offset: request.offset, totalBytes: before.size, revision: before.revision, bytes: bytes)
    }

    private nonisolated static func imageRevision(_ descriptor: Int32) throws -> (size: Int, revision: String) {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= RemoteAttachmentLimits.maxFileBytes
        else { throw RemoteImageReadError.invalidImage }

        let metadata = "\(attributes.st_dev):\(attributes.st_ino):\(attributes.st_size):\(attributes.st_mtimespec):\(attributes.st_ctimespec)"
        let revision = Data(SHA256.hash(data: Data(metadata.utf8))).base64EncodedString()
        return (Int(attributes.st_size), revision)
    }

    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage {
        let workspaceID = request.workspaceID
        let candidates = contexts.flatMap(\.workspaceManager.workspaces)
        var visited: Set<UUID> = []
        var entries: [RemoteHistoryEntry] = []

        for workspace in candidates where workspaceID == nil || workspace.id == workspaceID {
            guard visited.insert(workspace.id).inserted, !workspace.isEphemeral else { continue }
            try Task.checkCancellation()
            let records: [AgentSessionMetadataRecord] = if workspaceID != nil {
                try await AgentSessionDataService.shared.indexedAgentSessionMetadataRecords(
                    for: workspace, verifyInventory: request.before == nil
                )
            } else {
                await (try? AgentSessionDataService.shared.indexedAgentSessionMetadataRecords(for: workspace)) ?? []
            }
            entries += records.map { record in
                RemoteHistoryEntry(
                    id: record.id,
                    workspaceID: (workspaceID ?? record.workspaceID ?? workspace.id).uuidString,
                    sessionName: record.name,
                    lastActivityAt: record.lastActivityAt ?? record.lastUserMessageAt ?? record.savedAt,
                    turnCount: record.transcriptProjectionCounts?.canonicalVisibleRowCount ?? record.itemCount,
                    runState: AgentModeRemoteSessionQueryService.mapPersistedRunState(record.lastRunStateRaw)
                )
            }
        }
        if let workspaceID, !visited.contains(workspaceID) {
            throw RemoteReadServiceError.workspaceNotFound
        }
        return Self.historyPage(entries: entries, request: request)
    }

    static func historyPage(entries: [RemoteHistoryEntry], request: RemoteHistoryRPCRequest) -> RemoteHistoryPage {
        let limit = min(max(request.limit, 1), 100)
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var deduplicated: [UUID: RemoteHistoryEntry] = [:]
        for entry in entries {
            if let workspaceID = request.workspaceID, UUID(uuidString: entry.workspaceID) != workspaceID { continue }
            if let query, !query.isEmpty,
               !("\(entry.sessionName) \(entry.id.uuidString)".lowercased().contains(query))
            { continue }
            if let existing = deduplicated[entry.id], existing.lastActivityAt >= entry.lastActivityAt { continue }
            deduplicated[entry.id] = entry
        }

        let sorted = deduplicated.values
            .filter { entry in request.before.map { historyCursor(for: entry) < $0 } ?? true }
            .sorted { historyCursor(for: $0) > historyCursor(for: $1) }
        let page = Array(sorted.prefix(limit))
        let hasMore = sorted.count > page.count
        return RemoteHistoryPage(
            entries: page,
            hasMore: hasMore,
            workspaceID: request.workspaceID,
            olderCursor: hasMore && request.workspaceID != nil ? page.last.map(historyCursor(for:)) : nil
        )
    }

    private static func historyCursor(for entry: RemoteHistoryEntry) -> RemoteHistoryCursor {
        RemoteHistoryCursor(lastActivityAt: entry.lastActivityAt, sessionID: entry.id)
    }

    static func page(
        sessionID: UUID,
        allItems: [RemoteTranscriptItem],
        paging: RemoteTranscriptPageRequest,
        limit: Int,
        transcriptRevision: UInt64? = nil,
        chatConfiguration: RemoteChatConfiguration? = nil
    ) -> RemoteTranscriptPageRecord {
        page(
            sessionID: sessionID,
            rows: allItems.map { item in TranscriptRow(cursor: cursor(for: item), render: { item }) },
            paging: paging,
            limit: limit,
            transcriptRevision: transcriptRevision,
            chatConfiguration: chatConfiguration
        )
    }

    private struct TranscriptRow {
        let cursor: RemoteTranscriptCursor
        let render: () -> RemoteTranscriptItem
    }

    private static func page(
        sessionID: UUID,
        rows: [TranscriptRow],
        paging: RemoteTranscriptPageRequest,
        limit: Int,
        transcriptRevision: UInt64?,
        chatConfiguration: RemoteChatConfiguration?
    ) -> RemoteTranscriptPageRecord {
        switch paging {
        case let .exactItem(itemID):
            guard let row = rows.first(where: { $0.cursor.itemID == itemID }) else {
                return RemoteTranscriptPageRecord(
                    sessionID: sessionID,
                    items: [],
                    transcriptRevision: transcriptRevision
                )
            }
            return RemoteTranscriptPageRecord(
                sessionID: sessionID,
                items: [row.render()],
                transcriptRevision: transcriptRevision
            )

        case let .legacyForward(afterSequenceIndex):
            let start = afterSequenceIndex.map { index in
                rows.firstIndex(where: { $0.cursor.sequenceIndex > index }) ?? rows.count
            } ?? 0
            let end = min(start + limit, rows.count)
            let items = rows[start ..< end].map { $0.render() }
            let hasMore = end < rows.count
            return RemoteTranscriptPageRecord(
                sessionID: sessionID,
                items: items,
                nextSequenceIndex: hasMore ? items.last?.sequenceIndex : nil,
                hasMore: hasMore,
                transcriptRevision: transcriptRevision,
                chatConfiguration: chatConfiguration
            )

        case let .recentBackward(before):
            let candidates = before.map { cursor in
                rows.filter { $0.cursor < cursor }
            } ?? rows
            let pageCount = min(limit, candidates.count)
            let items = candidates.suffix(pageCount).map { $0.render() }
            let hasOlder = candidates.count > pageCount
            return RemoteTranscriptPageRecord(
                sessionID: sessionID,
                items: items,
                pagingMode: .recentBackward,
                olderCursor: hasOlder ? items.first.map(Self.cursor(for:)) : nil,
                hasOlder: hasOlder,
                transcriptRevision: transcriptRevision,
                chatConfiguration: chatConfiguration
            )
        }
    }

    static func project(transcript: AgentTranscript, includeDetails: Bool) -> [RemoteTranscriptItem] {
        transcriptRows(transcript: transcript, includeDetails: includeDetails).map { $0.render() }
    }

    private static func transcriptRows(
        transcript: AgentTranscript, includeDetails: Bool, liveToolResults: [UUID: String] = [:]
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for turn in transcript.turns {
            let turnID = turn.id
            let summaryOnly = turn.retentionTier != .full
            if let request = turn.request {
                let cursor = RemoteTranscriptCursor(
                    sequenceIndex: request.sequenceIndex, timestamp: request.timestamp, itemID: request.id
                )
                rows.append(TranscriptRow(cursor: cursor) {
                    let displayText = AgentModeViewModel.mcpResidentTaskDisplayText(
                        request.text, origin: request.userInputOrigin, attribution: request.crossSessionAttribution
                    )
                    return RemoteTranscriptItem(
                        id: request.id,
                        turnID: turnID,
                        timestamp: request.timestamp,
                        sequenceIndex: request.sequenceIndex,
                        kind: .request,
                        semanticKind: .userRequest,
                        role: "user",
                        text: sanitizeVisibleText(displayText),
                        summaryOnly: summaryOnly,
                        detailAvailable: false,
                        attachments: projectAttachments(request.attachments)
                    )
                })
            }

            let activities = turn.allActivities
            let conclusionActivityID = turn.conclusionActivityID
            for activity in activities {
                let cursor = RemoteTranscriptCursor(
                    sequenceIndex: activity.sequenceIndex, timestamp: activity.timestamp, itemID: activity.id
                )
                rows.append(TranscriptRow(cursor: cursor) {
                    projectActivity(
                        activity, turnID: turnID, conclusionActivityID: conclusionActivityID,
                        summaryOnly: summaryOnly, includeDetails: includeDetails,
                        liveToolResult: liveToolResults[activity.id]
                    )
                })
            }

            if summaryOnly,
               let summary = turn.summary,
               let text = summary.conclusionText
               ?? summary.compactConclusionText
               ?? summary.middleSummaryText
               ?? summary.requestText
            {
                let lastSequenceIndex = activities.map(\.sequenceIndex).max() ?? turn.request?.sequenceIndex ?? 0
                let cursor = RemoteTranscriptCursor(
                    sequenceIndex: lastSequenceIndex + 1,
                    timestamp: turn.lastActivityAt ?? turn.startedAt,
                    itemID: summary.middleSummaryItemID
                )
                rows.append(TranscriptRow(cursor: cursor) {
                    RemoteTranscriptItem(
                        id: cursor.itemID,
                        turnID: turnID,
                        timestamp: cursor.timestamp,
                        sequenceIndex: cursor.sequenceIndex,
                        kind: .summary,
                        semanticKind: .summary,
                        role: "summary",
                        text: sanitizeVisibleText(text),
                        summaryOnly: true,
                        detailAvailable: false
                    )
                })
            }
        }
        return rows.sorted { $0.cursor < $1.cursor }
    }

    private static func projectActivity(
        _ activity: AgentTranscriptActivity,
        turnID: UUID,
        conclusionActivityID: UUID?,
        summaryOnly: Bool,
        includeDetails: Bool,
        liveToolResult: String?
    ) -> RemoteTranscriptItem {
        let questionExchange = activity.toolExecution.flatMap(recordedQuestionExchange(for:))
        // Desktop cards also use the session's retained result after the live transcript compacts.
        let diff = activity.toolExecution.flatMap {
            recordedDiff(for: $0, resultJSON: liveToolResult ?? $0.resultJSON, includeDetails: includeDetails)
        }
        let semanticKind: RemoteTranscriptSemanticKind = if questionExchange != nil {
            .question
        } else if diff != nil {
            .compactActivity
        } else {
            semanticKind(for: activity, conclusionActivityID: conclusionActivityID)
        }
        let detail = includeDetails ? remoteDetail(for: activity, questionExchange: questionExchange, diffPreview: diff?.preview) : nil
        let visibleText: String? = if let questionExchange {
            recordedQuestionPreview(questionExchange)
        } else if let execution = activity.toolExecution,
                  let summary = compactToolSummary(execution)
        {
            sanitizeText(summary, characterLimit: 512)
        } else if let summary = activity.toolExecution?.summaryText,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sanitizeVisibleText(summary)
        } else if activity.toolExecution == nil, !activity.text.isEmpty {
            sanitizeVisibleText(activity.text)
        } else {
            nil
        }
        return RemoteTranscriptItem(
            id: activity.id,
            turnID: turnID,
            timestamp: activity.timestamp,
            sequenceIndex: activity.sequenceIndex,
            kind: semanticKind == .assistantAnswer ? .conclusion : .activity,
            semanticKind: semanticKind,
            role: activity.role.rawValue,
            text: visibleText,
            toolName: activity.toolExecution?.toolName,
            toolStatus: activity.toolExecution.map {
                $0.toolIsError == true ? AgentTranscriptToolStatus.failed.rawValue : $0.status.rawValue
            },
            summaryOnly: summaryOnly || activity.toolExecution?.summaryOnly == true,
            detailAvailable: hasDetail(for: activity),
            detailText: questionExchange == nil && diff == nil ? detail.map(renderDetail) : nil,
            detail: detail,
            attachments: projectAttachments(activity.attachments),
            diffSummary: diff?.summary
        )
    }

    private static func isAskUserTool(_ name: String?) -> Bool {
        let legacyPrefix = "mcp__repoprompt__"
        guard var normalized = normalizedToolCardName(name)?.lowercased() else { return false }
        if normalized.hasPrefix(legacyPrefix) {
            normalized.removeFirst(legacyPrefix.count)
        }
        return switch normalized {
        case "ask_user", "ask_user_question", "askuserquestion": true
        default: false
        }
    }

    private static func recordedQuestionExchange(for execution: AgentTranscriptToolExecution) -> RemoteRecordedQuestionExchange? {
        // Provider input can include secret fields. Only project the transcript's ask_user record.
        guard isAskUserTool(execution.toolName),
              let resultJSON = execution.resultJSON,
              let exchange = AgentAskUserTranscriptExchange.decode(
                  argsJSON: execution.argsJSON, resultJSON: resultJSON
              )
        else { return nil }

        let questions = exchange.questions.map { question in
            let answer = exchange.answers[question.id]
            let skipped = exchange.skipped || answer?.skipped == true
            return RemoteRecordedQuestionExchange.Question(
                header: question.header.map { sanitizeText($0, characterLimit: 120) },
                prompt: sanitizeText(question.question, characterLimit: 1200),
                answer: skipped ? nil : answer?.text.map { sanitizeText($0, characterLimit: 1200) },
                skipped: skipped
            )
        }
        let outcome: RemoteRecordedQuestionExchange.Outcome
        if exchange.timedOut {
            outcome = .timedOut
        } else if questions.allSatisfy(\.skipped) {
            outcome = .skipped
        } else {
            guard questions.contains(where: { $0.answer != nil || $0.skipped }) else { return nil }
            outcome = .answered
        }
        return RemoteRecordedQuestionExchange(
            title: exchange.title.map { sanitizeText($0, characterLimit: 240) },
            questions: questions,
            outcome: outcome
        )
    }

    private static func recordedQuestionPreview(_ exchange: RemoteRecordedQuestionExchange) -> String {
        switch exchange.outcome {
        case .skipped: return "Skipped"
        case .timedOut: return "Timed out"
        case .answered:
            let previews = exchange.questions.enumerated().compactMap { index, question -> String? in
                guard let answer = question.skipped ? "Skipped" : question.answer else { return nil }
                let preview = answer.split(whereSeparator: \.isNewline).joined(separator: " ")
                let label = question.header ?? (exchange.questions.count > 1 ? "Q\(index + 1)" : nil)
                return label.map { "\($0): \(preview)" } ?? preview
            }
            return sanitizeText(previews.joined(separator: " · "), characterLimit: 240)
        }
    }

    private typealias RecordedDiff = (summary: RemoteTranscriptDiffSummary, preview: RemoteTranscriptDiffPreview?)
    private static let diffPreviewFileLimit = 12

    private static func recordedDiff(
        for execution: AgentTranscriptToolExecution, resultJSON: String?, includeDetails: Bool
    ) -> RecordedDiff? {
        guard execution.status != .failed, execution.toolIsError != true,
              let name = normalizedToolCardName(execution.toolName)?.lowercased().components(separatedBy: "__").last
        else { return nil }

        switch name {
        case "apply_edits":
            return recordedEditDiff(for: execution, resultJSON: resultJSON, includeDetails: includeDetails)
        case "git":
            guard let result = ToolJSON.decodeResult(ToolResultDTOs.GitToolReplyDTO.self, from: resultJSON),
                  result.op == "diff", result.error == nil
            else { return nil }
            return recordedGitDiff(result, includeDetails: includeDetails)
        default:
            return nil
        }
    }

    private static func recordedEditDiff(
        for execution: AgentTranscriptToolExecution, resultJSON: String?, includeDetails: Bool
    ) -> RecordedDiff? {
        guard let edit = ToolJSON.decodeResult(ToolResultDTOs.EditSummary.self, from: resultJSON),
              let patch = edit.displayUnifiedDiff
        else { return nil }
        let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyEditsArgs.self, from: execution.argsJSON)
        let path = (args?.path ?? execution.keyPaths.first).map(diffDisplayPath)
        let summary = RemoteTranscriptDiffSummary(
            fileCount: 1, singleFilePath: path, additions: edit.addedLines, deletions: edit.deletedLines
        )
        let preview = includeDetails ? boundedDiffPreview([
            .init(path: path ?? "Diff", additions: edit.addedLines, deletions: edit.deletedLines, patch: patch)
        ], isTruncated: false) : nil
        return (summary, preview)
    }

    private static func recordedGitDiff(
        _ result: ToolResultDTOs.GitToolReplyDTO, includeDetails: Bool
    ) -> RecordedDiff? {
        let repoDiffs = result.repos?.compactMap { repo in repo.diff.map { (repo.repoName, $0) } } ?? []
        let diffs = result.diff.map { [(nil as String?, $0)] } ?? repoDiffs
        let totals = result.aggregate?.totals ?? result.diff?.totals
        guard let fileCount = totals?.files ?? result.summary?.files else { return nil }
        let recordedFileCount = diffs.reduce(0) { $0 + ($1.1.files?.count ?? 0) }
        let isTruncated = recordedFileCount > diffPreviewFileLimit || diffs.contains { $0.1.truncated == true }
        let files = diffs.lazy.flatMap { repoName, diff in
            (diff.files ?? []).lazy.map { file in (repoName, file) }
        }
        let summary = RemoteTranscriptDiffSummary(
            fileCount: fileCount,
            singleFilePath: fileCount == 1 ? files.first.map { diffDisplayPath($0.1.path) } : nil,
            additions: totals?.insertions ?? result.summary?.insertions,
            deletions: totals?.deletions ?? result.summary?.deletions,
            isTruncated: isTruncated
        )
        let preview = includeDetails ? boundedDiffPreview(files.prefix(diffPreviewFileLimit).map { repoName, file in
            let path = diffDisplayPath(file.path)
            return .init(
                path: repoName.map { sanitizeText($0, characterLimit: 120) + "/" + path } ?? path,
                additions: file.insertions,
                deletions: file.deletions,
                patch: file.hunks?.map { "\($0.header)\n\($0.patch)" }.joined(separator: "\n")
            )
        }, isTruncated: isTruncated) : nil
        return (summary, preview)
    }

    private static func diffDisplayPath(_ path: String) -> String {
        let displayPath = path.hasPrefix("/") ? (path as NSString).lastPathComponent : path
        return sanitizeText(displayPath, characterLimit: 240)
    }

    private static func boundedDiffPreview(
        _ files: [RemoteTranscriptDiffPreview.File], isTruncated: Bool
    ) -> RemoteTranscriptDiffPreview {
        var remainingBytes = 12000
        var isTruncated = isTruncated
        let boundedFiles = files.map { file in
            guard let patch = file.patch, !patch.isEmpty else { return file }
            let lines = patch.split(separator: "\n", maxSplits: 400, omittingEmptySubsequences: false)
            var redactedLines: [String] = []
            for line in lines.prefix(400) {
                guard line.utf8.prefix(remainingBytes + 1).count <= remainingBytes else { break }
                let redacted = sanitizeText(String(line), characterLimit: 12000)
                let size = redacted.utf8.count + 1
                guard size <= remainingBytes else { break }
                remainingBytes -= size
                redactedLines.append(redacted)
            }
            if redactedLines.count < lines.count { isTruncated = true }
            return RemoteTranscriptDiffPreview.File(
                path: file.path, additions: file.additions, deletions: file.deletions,
                patch: redactedLines.isEmpty ? nil : redactedLines.joined(separator: "\n")
            )
        }
        return RemoteTranscriptDiffPreview(files: boundedFiles, isTruncated: isTruncated)
    }

    static func compactToolSummary(_ execution: AgentTranscriptToolExecution) -> String? {
        guard let name = normalizedToolCardName(execution.toolName)?.lowercased() else { return nil }
        if name == "bash" {
            let exitCode = execution.exitCode ?? BashToolResultParser.parse(
                raw: boundedToolPayload(execution.resultJSON), argsJSON: nil
            ).exitCode
            return exitCode.map { "Shell command • Exit \($0)" } ?? "Shell command"
        }
        guard [
            "read",
            "read_file",
            "file_search",
            "grep",
            "glob",
            "list_files",
            "apply_edits",
            "apply_patch",
            "edit",
            "edit_file",
            "write_file"
        ].contains(name)
        else { return nil }

        // Large payloads still have their original summary and expandable, size-limited detail.
        let args = boundedToolPayload(execution.argsJSON)
        let rawResult = boundedToolPayload(execution.resultJSON)
        var subject = ToolCardRouter.callSubtitle(for: name, argsJSON: args) ?? execution.keyPaths.first
        var outcome: String?
        switch name {
        case "read", "read_file":
            if let read = ToolJSON.decodeResult(ToolResultDTOs.ReadFileReply.self, from: rawResult) {
                subject = read.displayPath ?? subject
                if read.firstLine > 0, read.lastLine >= read.firstLine {
                    outcome = read.firstLine == read.lastLine ? "Line \(read.firstLine)" : "Lines \(read.firstLine)–\(read.lastLine)"
                }
            }
        case "file_search", "grep", "glob", "list_files":
            if subject == nil {
                let arguments = ToolJSON.rawObject(from: args)
                subject = (arguments?["pattern"] ?? arguments?["query"]) as? String
            }
            let result = ToolJSON.structuredResultObject(from: rawResult)
            if let count = result?["total_matches"] as? Int {
                outcome = "\(count) \(count == 1 ? "match" : "matches")"
            }
        default:
            let result = ToolJSON.structuredResultObject(from: rawResult)
            if let patch = ToolJSON.decodeResult(ToolResultDTOs.ApplyPatchSummary.self, from: rawResult) {
                let paths = patch.changes.map(\.path)
                if let first = paths.first {
                    let count = max(paths.count, patch.changeCount)
                    subject = count == 1 ? first : "\(first) (+\(count - 1) more)"
                }
                if patch.summaryOnly != true {
                    outcome = diffLineSummary(patch.changes.map(\.diff))
                }
            } else if let added = result?["added_lines"] as? Int, let deleted = result?["deleted_lines"] as? Int {
                outcome = "+\(added) −\(deleted) lines"
            } else if let total = result?["total_lines_changed"] as? Int {
                outcome = "\(total) \(total == 1 ? "line" : "lines") changed"
            }
        }
        let summary = [subject, outcome].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " • ")
        return summary.isEmpty ? nil : summary
    }

    private static func boundedToolPayload(_ raw: String?) -> String? {
        guard let raw, raw.utf8.prefix(65537).count <= 65536 else { return nil }
        return sanitizeText(raw, characterLimit: 65536)
    }

    private static func diffLineSummary(_ diffs: [String]) -> String? {
        var additions = 0
        var deletions = 0
        for diff in diffs {
            var inHunk = false
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("@@") { inHunk = true }
                if line.hasPrefix("diff --git ") { inHunk = false }
                if inHunk, line.hasPrefix("+") { additions += 1 }
                if inHunk, line.hasPrefix("-") { deletions += 1 }
            }
        }
        guard additions + deletions > 0 else { return nil }
        return "+\(additions) −\(deletions) lines"
    }

    private static func projectAttachments(_ attachments: [AgentFileAttachment]) -> [RemoteTranscriptAttachment]? {
        guard !attachments.isEmpty else { return nil }
        return attachments.prefix(RemoteAttachmentLimits.maxCount).map { attachment in
            let name = attachment.facts.fileName
            return RemoteTranscriptAttachment(
                id: attachment.id,
                name: name.isEmpty ? "Attachment" : sanitizeDetailText(String(name.prefix(200))),
                isImage: attachment.kind == .image
            )
        }
    }

    private static func cursor(for item: RemoteTranscriptItem) -> RemoteTranscriptCursor {
        RemoteTranscriptCursor(
            sequenceIndex: item.sequenceIndex,
            timestamp: item.timestamp,
            itemID: item.id
        )
    }

    private static func semanticKind(
        for activity: AgentTranscriptActivity,
        conclusionActivityID: UUID?
    ) -> RemoteTranscriptSemanticKind {
        if activity.id == conclusionActivityID || activity.sealsAssistantBoundary {
            return .assistantAnswer
        }
        if activity.role == .assistant,
           AgentDisplayableText.hasDisplayableBody(activity.text)
        {
            return activity.isSubstantiveAssistant ? .assistantAnswer : .assistantPreamble
        }
        if activity.role == .error
            || activity.itemKind == .error
            || activity.toolExecution?.status == .failed
            || activity.toolExecution?.toolIsError == true
        {
            return .error
        }
        let toolName = activity.toolExecution?.toolName
        if isAskUserTool(toolName) { return .question }
        switch toolName?.lowercased() {
        case "request_user_input":
            return .question
        case "request_permission", "request_permissions":
            return .permission
        case "request_approval", "approval":
            return .approval
        default:
            return .compactActivity
        }
    }

    private static func hasDetail(for activity: AgentTranscriptActivity) -> Bool {
        guard let execution = activity.toolExecution else {
            return activity.reasoning?.isEmpty == false
        }
        return execution.argsJSON != nil
            || execution.resultJSON != nil
            || activity.reasoning?.isEmpty == false
            || !execution.keyPaths.isEmpty
            || execution.processID != nil
            || execution.exitCode != nil
            || execution.summaryText != nil
    }

    private static func remoteDetail(
        for activity: AgentTranscriptActivity,
        questionExchange: RemoteRecordedQuestionExchange?,
        diffPreview: RemoteTranscriptDiffPreview?
    ) -> RemoteTranscriptDetail? {
        guard hasDetail(for: activity) else { return nil }
        let execution = activity.toolExecution
        if let questionExchange {
            return RemoteTranscriptDetail(toolIsError: execution?.toolIsError, questionExchange: questionExchange)
        }
        return RemoteTranscriptDetail(
            argumentsJSON: execution?.argsJSON.map(sanitizeDetailText),
            resultJSON: execution?.resultJSON.map(sanitizeDetailText),
            reasoning: activity.reasoning.map(sanitizeDetailText),
            keyPaths: Array(execution?.keyPaths.prefix(100) ?? []),
            processID: execution?.processID,
            exitCode: execution?.exitCode,
            summaryText: execution?.summaryText.map(sanitizeDetailText),
            toolIsError: execution?.toolIsError,
            diffPreview: diffPreview
        )
    }

    private static func renderDetail(_ detail: RemoteTranscriptDetail) -> String {
        var sections: [String] = []
        if let args = detail.argumentsJSON, !args.isEmpty {
            sections.append("Arguments:\n\(args)")
        }
        if let result = detail.resultJSON, !result.isEmpty {
            sections.append("Result:\n\(result)")
        }
        if let reasoning = detail.reasoning, !reasoning.isEmpty {
            sections.append("Reasoning:\n\(reasoning)")
        }
        if !detail.keyPaths.isEmpty {
            sections.append("Files/worktree:\n\(detail.keyPaths.joined(separator: "\n"))")
        }
        if let summary = detail.summaryText, !summary.isEmpty {
            sections.append("Summary:\n\(summary)")
        }
        if let processID = detail.processID {
            sections.append("Process: \(processID)")
        }
        if let exitCode = detail.exitCode {
            sections.append("Exit code: \(exitCode)")
        }
        guard !sections.isEmpty else { return "No additional detail." }
        let rendered = sections.joined(separator: "\n\n")
        return rendered.count > 16000 ? String(rendered.prefix(16000)) + "\n…" : rendered
    }

    private static func sanitizeVisibleText(_ raw: String) -> String {
        sanitizeText(raw, characterLimit: 32000)
    }

    private static func sanitizeDetailText(_ raw: String) -> String {
        sanitizeText(raw, characterLimit: 8000)
    }

    private static func sanitizeText(_ raw: String, characterLimit: Int) -> String {
        var text = raw
        let secretPattern = #"(?i)("(?:api[_-]?key|token|password|secret|authorization)"\s*:\s*")([^"]*)(")"#
        if let regex = try? NSRegularExpression(pattern: secretPattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: "$1[REDACTED]$3"
            )
        }
        text = text.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        if text.count > characterLimit {
            text = String(text.prefix(characterLimit)) + "\n…"
        }
        return text
    }
}

enum RemoteReadServiceError: LocalizedError {
    case workspaceNotFound
    case sessionNotFound
    case transcriptItemNotFound
    case invalidCursor

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound: "The requested workspace was not found."
        case .sessionNotFound: "The requested session could not be found."
        case .transcriptItemNotFound: "The requested transcript item is no longer available."
        case .invalidCursor: "The transcript cursor is invalid."
        }
    }
}

enum RemoteImageReadError: Error {
    case unavailable
    case invalidImage
    case changed
}
