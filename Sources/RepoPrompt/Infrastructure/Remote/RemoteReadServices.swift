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

    init(
        sessionID: UUID,
        items: [RemoteTranscriptItem],
        nextSequenceIndex: Int? = nil,
        hasMore: Bool = false,
        pagingMode: RemoteTranscriptPagingMode? = nil,
        olderCursor: RemoteTranscriptCursor? = nil,
        hasOlder: Bool? = nil,
        transcriptRevision: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.items = items
        self.nextSequenceIndex = nextSequenceIndex
        self.hasMore = hasMore
        self.pagingMode = pagingMode
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
        self.transcriptRevision = transcriptRevision
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
        var revisionFingerprint: RemoteTranscriptRevisionFingerprint?
        var liveMutationRevision: UInt64?
        var liveOwnerID: ObjectIdentifier?
        var retainedAttachmentRoot: URL?
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
                if previewItemID != nil {
                    retainedAttachmentRoot = context.agentMode.attachmentLocation(for: liveSession)?.retainedRoot
                }
                break
            }

            for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral {
                if let persisted = try? await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace) {
                    transcript = persisted.transcript ?? .empty
                    revisionFingerprint = .persisted(transcript: transcript ?? .empty)
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

        let attachmentStore = retainedAttachmentRoot.map { AgentSessionAttachmentStore(rootURL: $0) }
        let allItems = Self.project(transcript: transcript, includeDetails: includeDetails) { id, attachment in
            guard id == previewItemID, attachment.kind == .image,
                  let url = attachmentStore?.locateRetainedFile(attachmentID: attachment.id, sessionID: sessionID),
                  let thumbnail = try? AttachmentPreviewRenderer.jpegData(fromFileAt: url, kind: .image),
                  thumbnail.count <= 128 * 1024
            else { return nil }
            return thumbnail
        }
        if case let .exactItem(itemID) = paging,
           !allItems.contains(where: { $0.id == itemID })
        {
            throw RemoteReadServiceError.transcriptItemNotFound
        }
        let transcriptRevision: UInt64? = if let liveMutationRevision, let liveOwnerID {
            revisionTracker?.observeLive(
                sessionID: sessionID,
                transcript: transcript,
                mutationRevision: liveMutationRevision,
                ownerID: liveOwnerID
            )
        } else {
            revisionTracker?.observe(
                sessionID: sessionID,
                fingerprint: revisionFingerprint ?? .persisted(transcript: transcript)
            )
        }
        return Self.page(
            sessionID: sessionID,
            allItems: allItems,
            paging: paging,
            limit: boundedLimit,
            transcriptRevision: transcriptRevision
        )
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
        transcriptRevision: UInt64? = nil
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
                transcriptRevision: transcriptRevision
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
                transcriptRevision: transcriptRevision
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
                projected.append(
                    RemoteTranscriptItem(
                        id: request.id,
                        turnID: turn.id,
                        timestamp: request.timestamp,
                        sequenceIndex: request.sequenceIndex,
                        kind: .request,
                        semanticKind: .userRequest,
                        role: "user",
                        text: sanitizeVisibleText(request.text),
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
