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
        var retainedAttachmentRoot: URL?
        var chatConfiguration: RemoteChatConfiguration?
        let includesChatConfiguration = switch paging {
        case .recentBackward(before: nil), .legacyForward(afterSequenceIndex: nil): true
        default: false
        }
        let previewItemID: UUID? = if case let .exactItem(itemID) = paging, includeDetails {
            itemID
        } else {
            nil
        }

        for context in contexts {
            if let liveSession = context.agentMode.sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) {
                transcript = liveSession.transcript
                liveMutationRevision = liveSession.remoteTranscriptMutationRevision
                liveOwnerID = ObjectIdentifier(liveSession)
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
                if previewItemID != nil,
                   let workspace = context.workspaceManager.workspace(withID: liveSession.persistentSessionBindingIdentity?.workspaceID)
                {
                    retainedAttachmentRoot = context.agentMode.sessionAttachmentsRootURL(for: workspace)
                }
                break
            }

            for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral {
                if let persisted = try? await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace) {
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
                    if previewItemID != nil {
                        retainedAttachmentRoot = context.agentMode.sessionAttachmentsRootURL(for: workspace)
                    }
                    break
                }
            }
            if transcript != nil { break }
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
        let thumbnails: [UUID: Data]
        if let previewItemID, let retainedAttachmentRoot {
            let attachments = Self.imageAttachments(in: transcript, itemID: previewItemID)
                .prefix(RemoteAttachmentLimits.maxCount).filter { $0.kind == .image }.map(\.id)
            let worker = Task.detached(priority: .userInitiated) {
                try Self.retainedPhotoThumbnails(
                    attachmentIDs: attachments, sessionID: sessionID, root: retainedAttachmentRoot
                )
            }
            thumbnails = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } else {
            thumbnails = [:]
        }
        let allItems = Self.project(transcript: transcript, includeDetails: includeDetails) { id, attachment in
            id == previewItemID ? thumbnails[attachment.id] : nil
        }
        if case let .exactItem(itemID) = paging,
           !allItems.contains(where: { $0.id == itemID })
        {
            throw RemoteReadServiceError.transcriptItemNotFound
        }
        return Self.page(
            sessionID: sessionID,
            allItems: allItems,
            paging: paging,
            limit: boundedLimit,
            transcriptRevision: transcriptRevision,
            chatConfiguration: chatConfiguration
        )
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

    private nonisolated static func retainedPhotoThumbnails(
        attachmentIDs: [UUID],
        sessionID: UUID,
        root: URL
    ) throws -> [UUID: Data] {
        let store = AgentSessionAttachmentStore(rootURL: root)
        var thumbnails: [UUID: Data] = [:]
        for id in attachmentIDs.prefix(RemoteAttachmentLimits.maxCount) {
            try Task.checkCancellation()
            guard let url = store.locateRetainedFile(attachmentID: id, sessionID: sessionID),
                  let thumbnail = try AttachmentPreviewRenderer.jpegData(fromRetainedPhotoAt: url),
                  thumbnail.count <= 128 * 1024
            else { continue }
            thumbnails[id] = thumbnail
        }
        return thumbnails
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
        switch paging {
        case let .exactItem(itemID):
            guard let item = allItems.first(where: { $0.id == itemID }) else {
                return RemoteTranscriptPageRecord(
                    sessionID: sessionID,
                    items: [],
                    transcriptRevision: transcriptRevision
                )
            }
            return RemoteTranscriptPageRecord(
                sessionID: sessionID,
                items: [item],
                transcriptRevision: transcriptRevision
            )

        case let .legacyForward(afterSequenceIndex):
            let start = afterSequenceIndex.map { index in
                allItems.firstIndex(where: { $0.sequenceIndex > index }) ?? allItems.count
            } ?? 0
            let end = min(start + limit, allItems.count)
            let items = Array(allItems[start ..< end])
            let hasMore = end < allItems.count
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
                allItems.filter { Self.cursor(for: $0) < cursor }
            } ?? allItems
            let pageCount = min(limit, candidates.count)
            let items = Array(candidates.suffix(pageCount))
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

    static func project(
        transcript: AgentTranscript,
        includeDetails: Bool,
        thumbnail: (UUID, AgentFileAttachment) -> Data? = { _, _ in nil }
    ) -> [RemoteTranscriptItem] {
        var projected: [RemoteTranscriptItem] = []
        for turn in transcript.turns {
            if let request = turn.request {
                let displayText = AgentModeViewModel.mcpResidentTaskDisplayText(
                    request.text, origin: request.userInputOrigin, attribution: request.crossSessionAttribution
                )
                projected.append(
                    RemoteTranscriptItem(
                        id: request.id,
                        turnID: turn.id,
                        timestamp: request.timestamp,
                        sequenceIndex: request.sequenceIndex,
                        kind: .request,
                        semanticKind: .userRequest,
                        role: "user",
                        text: sanitizeVisibleText(displayText),
                        summaryOnly: turn.retentionTier != .full,
                        detailAvailable: false,
                        attachments: projectAttachments(request.attachments) { thumbnail(request.id, $0) }
                    )
                )
            }

            for activity in turn.allActivities {
                let semanticKind = semanticKind(for: activity, conclusionActivityID: turn.conclusionActivityID)
                let detail = includeDetails ? remoteDetail(for: activity) : nil
                let visibleText: String? = if let summary = activity.toolExecution?.summaryText,
                                              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    sanitizeVisibleText(summary)
                } else if activity.toolExecution != nil {
                    nil
                } else if activity.text.isEmpty {
                    nil
                } else {
                    sanitizeVisibleText(activity.text)
                }
                projected.append(
                    RemoteTranscriptItem(
                        id: activity.id,
                        turnID: turn.id,
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
                        summaryOnly: turn.retentionTier != .full || activity.toolExecution?.summaryOnly == true,
                        detailAvailable: hasDetail(for: activity),
                        detailText: detail.map(renderDetail),
                        detail: detail,
                        attachments: projectAttachments(activity.attachments) { thumbnail(activity.id, $0) }
                    )
                )
            }

            if turn.retentionTier != .full,
               let summary = turn.summary,
               let text = summary.conclusionText
               ?? summary.compactConclusionText
               ?? summary.middleSummaryText
               ?? summary.requestText
            {
                let summarySequenceIndex = turn.allActivities.map(\.sequenceIndex).max()
                    ?? turn.request?.sequenceIndex
                    ?? 0
                projected.append(
                    RemoteTranscriptItem(
                        id: summary.middleSummaryItemID,
                        turnID: turn.id,
                        timestamp: turn.lastActivityAt ?? turn.startedAt,
                        sequenceIndex: summarySequenceIndex + 1,
                        kind: .summary,
                        semanticKind: .summary,
                        role: "summary",
                        text: sanitizeVisibleText(text),
                        summaryOnly: true,
                        detailAvailable: false
                    )
                )
            }
        }
        return projected.sorted {
            cursor(for: $0) < cursor(for: $1)
        }
    }

    private static func projectAttachments(
        _ attachments: [AgentFileAttachment],
        thumbnail: (AgentFileAttachment) -> Data?
    ) -> [RemoteTranscriptAttachment]? {
        guard !attachments.isEmpty else { return nil }
        return attachments.prefix(RemoteAttachmentLimits.maxCount).map { attachment in
            let name = attachment.facts.fileName
            return RemoteTranscriptAttachment(
                id: attachment.id,
                name: name.isEmpty ? "Attachment" : sanitizeDetailText(String(name.prefix(200))),
                isImage: attachment.kind == .image,
                thumbnail: thumbnail(attachment)
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
        switch activity.toolExecution?.toolName?.lowercased() {
        case "ask_user", "request_user_input":
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

    private static func remoteDetail(for activity: AgentTranscriptActivity) -> RemoteTranscriptDetail? {
        guard hasDetail(for: activity) else { return nil }
        let execution = activity.toolExecution
        return RemoteTranscriptDetail(
            argumentsJSON: execution?.argsJSON.map(sanitizeDetailText),
            resultJSON: execution?.resultJSON.map(sanitizeDetailText),
            reasoning: activity.reasoning.map(sanitizeDetailText),
            keyPaths: Array(execution?.keyPaths.prefix(100) ?? []),
            processID: execution?.processID,
            exitCode: execution?.exitCode,
            summaryText: execution?.summaryText.map(sanitizeDetailText),
            toolIsError: execution?.toolIsError
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
