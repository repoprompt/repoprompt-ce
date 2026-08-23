import Foundation
import RepoPromptServerHost
import RepoPromptDomainRuntime
import RepoPromptServiceProtocol

enum RepoPromptPortalSessionProjection {
    static let maximumPromptBytes = 64_000
    static let maximumModelBytes = 256
    static let maximumEntryBytes = 128 * 1024
    static let maximumPageBytes = 1 * 1024 * 1024

    static func tools() -> [PortalToolSummary] {
        MCPDomainToolCatalog.entries.map {
            PortalToolSummary(
                name: $0.name,
                scope: $0.scope.rawValue,
                capability: $0.capability.externalName,
                admissionClass: $0.admissionClass.rawValue
            )
        }
    }

    static func project(_ project: ProjectSnapshot) -> PortalProjectSummary {
        PortalProjectSummary(
            projectID: project.projectID,
            name: project.name,
            state: project.state,
            rootNames: project.roots.map(\.logicalName)
        )
    }

    static func project(_ session: SessionSnapshot) -> PortalSessionSummary {
        PortalSessionSummary(
            sessionID: session.sessionID,
            projectID: session.projectID,
            parentSessionID: session.parentSessionID,
            title: title(for: session),
            provider: session.provider,
            providerSettingsID: session.providerSettingsID,
            model: session.model,
            state: session.state,
            revision: session.revision,
            runGeneration: session.runGeneration,
            lastActivityAt: session.transcript.last?.timestamp,
            contextUsage: session.contextUsage
        )
    }

    static func title(for session: SessionSnapshot) -> String {
        guard let firstHuman = session.transcript.first(where: {
            $0.kind == .human && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "Agent Session"
        }
        let normalized = firstHuman.content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Agent Session" }
        let prefix = String(normalized.prefix(80))
        return normalized.count > prefix.count ? "\(prefix)…" : prefix
    }

    static func snapshotTitles(sessions: [SessionSnapshot], agents: [AgentSnapshot]) -> [String: String] {
        let labels = agents.reduce(into: [UUID: String]()) { result, agent in
            guard let label = agent.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return }
            result[agent.sessionID] = label
        }
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            (session.sessionID.uuidString, labels[session.sessionID] ?? title(for: session))
        })
    }

    static func transcriptPage(
        session: SessionSnapshot,
        limit: Int,
        beforeSequence: Int64?,
        afterSequence: Int64?
    ) throws -> PortalTranscriptPage {
        guard (1 ... 500).contains(limit) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Transcript limit is outside the portal bound")
        }
        guard beforeSequence == nil || afterSequence == nil else {
            throw ServiceAPIError(code: .invalidRequest, message: "Use either beforeSequence or afterSequence, not both")
        }
        if let beforeSequence, beforeSequence <= 0 {
            throw ServiceAPIError(code: .invalidRequest, message: "beforeSequence must be positive")
        }
        if let afterSequence, afterSequence < 0 {
            throw ServiceAPIError(code: .invalidRequest, message: "afterSequence cannot be negative")
        }

        let ordered = session.transcript.sorted { $0.sessionSequence < $1.sessionSequence }
        let eligibleIndices: [Int]
        if let beforeSequence {
            eligibleIndices = ordered.indices.filter { ordered[$0].sessionSequence < beforeSequence }
        } else if let afterSequence {
            eligibleIndices = ordered.indices.filter { ordered[$0].sessionSequence > afterSequence }
        } else {
            eligibleIndices = Array(ordered.indices)
        }

        let selectedIndices: [Int]
        if beforeSequence != nil || (beforeSequence == nil && afterSequence == nil) {
            selectedIndices = Array(eligibleIndices.suffix(limit))
        } else {
            selectedIndices = Array(eligibleIndices.prefix(limit))
        }

        var remainingBytes = maximumPageBytes
        var items: [PortalTranscriptEntry] = []
        var includedIndices: [Int] = []
        for index in selectedIndices {
            guard remainingBytes > 0 else { break }
            let entry = ordered[index]
            let sourceBytes = Array(entry.content.utf8)
            let byteLimit = min(maximumEntryBytes, remainingBytes)
            let truncated = sourceBytes.count > byteLimit
            let content = truncated
                ? String(decoding: sourceBytes.prefix(byteLimit), as: UTF8.self)
                : entry.content
            remainingBytes -= min(sourceBytes.count, byteLimit)
            items.append(PortalTranscriptEntry(
                entryID: entry.entryID,
                sessionSequence: entry.sessionSequence,
                kind: entry.kind,
                content: content,
                timestamp: entry.timestamp,
                truncated: truncated
            ))
            includedIndices.append(index)
        }

        let firstIndex = includedIndices.first
        let lastIndex = includedIndices.last
        return PortalTranscriptPage(
            session: project(session),
            items: items,
            hasMoreBefore: firstIndex.map { $0 > ordered.startIndex } ?? false,
            hasMoreAfter: lastIndex.map { $0 < ordered.index(before: ordered.endIndex) } ?? false,
            earliestSequence: items.first?.sessionSequence,
            latestSequence: items.last?.sessionSequence
        )
    }

    static func validatedCreateInput(
        _ request: PortalCreateSessionRequest,
        provider: ProviderSettingsSnapshot,
        resolvedModel: String?,
        reasoningEffort: String?,
        runtimeDefaults: PortalDesktopSettingsService.RuntimeDefaults
    ) throws -> CreateSessionInput {
        let prompt = request.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before starting a session")
        }
        guard prompt.utf8.count <= maximumPromptBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Initial prompt exceeds its portal bound")
        }
        guard (request.providerID == nil || provider.providerID == request.providerID),
              provider.deploymentAllowed,
              provider.effectiveEnabled,
              let runtimeKind = provider.providerID.runtimeKind
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "The selected provider is not available for new sessions", retryable: true)
        }
        if let model = resolvedModel {
            guard model.utf8.count <= maximumModelBytes,
                  provider.capabilities.supportsModelSelection,
                  provider.models.contains(where: { $0.id == model })
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "The selected model is not advertised by this provider")
            }
        }
        var providerSettings = runtimeDefaults.providerSettings
        providerSettings["provider.settingsID"] = provider.providerID.rawValue
        if let reasoningEffort { providerSettings["provider.reasoningEffort"] = reasoningEffort }
        return CreateSessionInput(
            projectID: request.projectID,
            provider: runtimeKind,
            providerSettingsID: provider.providerID,
            model: resolvedModel,
            visibility: .privateSession,
            initialPrompt: prompt,
            startImmediately: true,
            initialPermissionMode: runtimeDefaults.mode,
            initialProviderSettings: providerSettings
        )
    }

    static func validatedSendCommand(_ request: PortalSendMessageRequest) throws -> SessionCommand {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.expectedRevision > 0 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Session revision is invalid")
        }
        guard !text.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before sending")
        }
        guard text.utf8.count <= maximumPromptBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Message exceeds its portal bound")
        }
        return .sendFollowup(text: text, expectedSessionRevision: request.expectedRevision)
    }
}
