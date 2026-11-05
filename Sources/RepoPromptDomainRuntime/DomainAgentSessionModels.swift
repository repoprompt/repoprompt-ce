import Foundation
import MCP

package enum DomainAgentRunEpochTransitionKind: String, Codable, Equatable, Hashable, Sendable {
    case initial
    case relatedFollowUp
    case steering
    case unrelated
}

package struct DomainAgentRunTurnEpoch: Codable, Equatable, Hashable, Sendable {
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let sessionID: UUID
    package let activationID: UUID
    package let registrationGeneration: UInt64
    package let id: UUID
    package let ordinal: UInt64
    package let continuityGeneration: UInt64
    package let transitionKind: DomainAgentRunEpochTransitionKind

    package init(
        runtimeID: UUID = DomainRuntimeCompatibilityIdentity.runtimeID,
        runtimeGeneration: UInt64 = 0,
        sessionID: UUID,
        activationID: UUID,
        registrationGeneration: UInt64,
        id: UUID,
        ordinal: UInt64,
        continuityGeneration: UInt64,
        transitionKind: DomainAgentRunEpochTransitionKind
    ) {
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.sessionID = sessionID
        self.activationID = activationID
        self.registrationGeneration = registrationGeneration
        self.id = id
        self.ordinal = ordinal
        self.continuityGeneration = continuityGeneration
        self.transitionKind = transitionKind
    }
}

package struct DomainAgentRunTerminalPublicationEnvelope: Equatable, Sendable {
    package let epoch: DomainAgentRunTurnEpoch
    package let snapshot: DomainAgentRunSnapshot

    package init(epoch: DomainAgentRunTurnEpoch, snapshot: DomainAgentRunSnapshot) {
        self.epoch = epoch
        self.snapshot = snapshot
    }
}

package enum DomainAgentRunTerminalPublicationResult: Equatable, Sendable {
    case accepted(successorEpoch: DomainAgentRunTurnEpoch?)
    case stale
    case rejected(reason: String)

    package var successorEpoch: DomainAgentRunTurnEpoch? {
        guard case let .accepted(successorEpoch) = self else { return nil }
        return successorEpoch
    }

    package var isResolved: Bool {
        switch self {
        case .accepted, .stale:
            true
        case .rejected:
            false
        }
    }
}

package struct DomainAgentRunSnapshot: Equatable, Sendable {
    package static let startupPendingStatusText = "Queued to start"

    package enum Status: String, Codable, Equatable, Sendable {
        case running
        case waitingForInput = "waiting_for_input"
        case completed
        case failed
        case cancelled
        case expired

        package var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .expired:
                true
            case .running, .waitingForInput:
                false
            }
        }
    }

    package struct ModelParameterSelection: Codable, Equatable, Sendable {
        package let providerID: String
        package let baseModelRaw: String
        package let kind: String
        package let configID: String
        package let valueRaw: String

        package init(
            providerID: String,
            baseModelRaw: String,
            kind: String,
            configID: String,
            valueRaw: String
        ) {
            self.providerID = providerID
            self.baseModelRaw = baseModelRaw
            self.kind = kind
            self.configID = configID
            self.valueRaw = valueRaw
        }

        package func asObject() -> [String: Value] {
            [
                "provider_id": .string(providerID),
                "base_model": .string(baseModelRaw),
                "kind": .string(kind),
                "config_id": .string(configID),
                "value": .string(valueRaw)
            ]
        }
    }

    package struct WorktreeBinding: Codable, Equatable, Sendable {
        package let id: String
        package let repositoryID: String
        package let repoKey: String
        package let logicalRootPath: String
        package let logicalRootName: String?
        package let worktreeID: String
        package let worktreeRootPath: String
        package let worktreeName: String?
        package let branch: String?
        package let head: String?
        package let visualLabel: String?
        package let visualColorHex: String?
        package let boundAt: Date
        package let source: String
        package let unavailable: Bool

        package init(
            id: String,
            repositoryID: String,
            repoKey: String,
            logicalRootPath: String,
            logicalRootName: String?,
            worktreeID: String,
            worktreeRootPath: String,
            worktreeName: String?,
            branch: String?,
            head: String?,
            visualLabel: String?,
            visualColorHex: String?,
            boundAt: Date,
            source: String,
            unavailable: Bool
        ) {
            self.id = id
            self.repositoryID = repositoryID
            self.repoKey = repoKey
            self.logicalRootPath = logicalRootPath
            self.logicalRootName = logicalRootName
            self.worktreeID = worktreeID
            self.worktreeRootPath = worktreeRootPath
            self.worktreeName = worktreeName
            self.branch = branch
            self.head = head
            self.visualLabel = visualLabel
            self.visualColorHex = visualColorHex
            self.boundAt = boundAt
            self.source = source
            self.unavailable = unavailable
        }

        package func asObject() -> [String: Value] {
            [
                "id": .string(id),
                "repository_id": .string(repositoryID),
                "repo_key": .string(repoKey),
                "logical_root_path": .string(logicalRootPath),
                "logical_root_name": Self.stringOrNull(logicalRootName),
                "worktree_id": .string(worktreeID),
                "worktree_root_path": .string(worktreeRootPath),
                "worktree_name": Self.stringOrNull(worktreeName),
                "branch": Self.stringOrNull(branch),
                "head": Self.stringOrNull(head),
                "visual_label": Self.stringOrNull(visualLabel),
                "visual_color_hex": Self.stringOrNull(visualColorHex),
                "bound_at": .string(DomainAgentRunSnapshot.timestamp(boundAt)),
                "source": .string(source),
                "unavailable": .bool(unavailable)
            ]
        }

        private static func stringOrNull(_ value: String?) -> Value {
            value.map(Value.string) ?? .null
        }
    }

    package struct WorktreeMergeSummary: Codable, Equatable, Sendable {
        package let id: String
        package let status: String
        package let repositoryID: String
        package let repoKey: String
        package let sourceWorktreeID: String
        package let sourceLabel: String
        package let sourceBranch: String?
        package let sourcePath: String
        package let targetWorktreeID: String
        package let targetLabel: String
        package let targetBranch: String?
        package let targetPath: String
        package let conflictFileCount: Int
        package let updatedAt: Date

        package init(
            id: String,
            status: String,
            repositoryID: String,
            repoKey: String,
            sourceWorktreeID: String,
            sourceLabel: String,
            sourceBranch: String?,
            sourcePath: String,
            targetWorktreeID: String,
            targetLabel: String,
            targetBranch: String?,
            targetPath: String,
            conflictFileCount: Int,
            updatedAt: Date
        ) {
            self.id = id
            self.status = status
            self.repositoryID = repositoryID
            self.repoKey = repoKey
            self.sourceWorktreeID = sourceWorktreeID
            self.sourceLabel = sourceLabel
            self.sourceBranch = sourceBranch
            self.sourcePath = sourcePath
            self.targetWorktreeID = targetWorktreeID
            self.targetLabel = targetLabel
            self.targetBranch = targetBranch
            self.targetPath = targetPath
            self.conflictFileCount = conflictFileCount
            self.updatedAt = updatedAt
        }
    }

    package struct Interaction: Equatable, Sendable {
        package enum Kind: String, Equatable, Sendable {
            case instruction
            case question
            case userInput = "user_input"
            case approval
            case hookApproval = "hook_approval"
            case mcpElicitation = "mcp_elicitation"
        }

        package enum ResponseType: String, Equatable, Sendable {
            case text
            case choice
            case structured
            case decision
            case elicitation
        }

        package struct Option: Equatable, Sendable {
            package let label: String
            package let description: String?

            package init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }

            package func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "description": description.map(Value.string) ?? .null
                ]
            }
        }

        package struct Field: Equatable, Sendable {
            package let id: String
            package let header: String?
            package let prompt: String
            package let context: String?
            package let isSecret: Bool
            package let allowsOther: Bool
            package let allowsMultiple: Bool?
            package let allowsCustom: Bool?
            package let emitAllowsOther: Bool
            package let options: [Option]

            package init(
                id: String,
                header: String? = nil,
                prompt: String,
                context: String? = nil,
                isSecret: Bool,
                allowsOther: Bool,
                allowsMultiple: Bool? = nil,
                allowsCustom: Bool? = nil,
                emitAllowsOther: Bool = true,
                options: [Option]
            ) {
                self.id = id
                self.header = header
                self.prompt = prompt
                self.context = context
                self.isSecret = isSecret
                self.allowsOther = allowsOther
                self.allowsMultiple = allowsMultiple
                self.allowsCustom = allowsCustom
                self.emitAllowsOther = emitAllowsOther
                self.options = options
            }

            package func asObject() -> [String: Value] {
                var object: [String: Value] = [
                    "id": .string(id),
                    "header": header.map(Value.string) ?? .null,
                    "prompt": .string(prompt),
                    "is_secret": .bool(isSecret),
                    "options": .array(options.map { .object($0.asObject()) })
                ]
                if let context {
                    object["context"] = .string(context)
                }
                if emitAllowsOther {
                    object["allows_other"] = .bool(allowsOther)
                }
                if let allowsMultiple {
                    object["allows_multiple"] = .bool(allowsMultiple)
                }
                if let allowsCustom {
                    object["allows_custom"] = .bool(allowsCustom)
                }
                return object
            }
        }

        package struct Detail: Equatable, Sendable {
            package let label: String
            package let value: String
            package let isCode: Bool

            package init(label: String, value: String, isCode: Bool) {
                self.label = label
                self.value = value
                self.isCode = isCode
            }

            package func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "value": .string(value),
                    "is_code": .bool(isCode)
                ]
            }
        }

        package let id: UUID
        package let kind: Kind
        package let responseType: ResponseType
        package let title: String?
        package let prompt: String?
        package let context: String?
        package let allowsMultiple: Bool?
        package let options: [Option]
        package let fields: [Field]
        package let details: [Detail]

        package init(
            id: UUID,
            kind: Kind,
            responseType: ResponseType,
            title: String?,
            prompt: String?,
            context: String?,
            allowsMultiple: Bool?,
            options: [Option],
            fields: [Field],
            details: [Detail]
        ) {
            self.id = id
            self.kind = kind
            self.responseType = responseType
            self.title = title
            self.prompt = prompt
            self.context = context
            self.allowsMultiple = allowsMultiple
            self.options = options
            self.fields = fields
            self.details = details
        }

        package func asObject() -> [String: Value] {
            var object: [String: Value] = [
                "id": .string(id.uuidString),
                "kind": .string(kind.rawValue),
                "response_type": .string(responseType.rawValue),
                "title": title.map(Value.string) ?? .null,
                "prompt": prompt.map(Value.string) ?? .null
            ]
            if let context {
                object["context"] = .string(context)
            }
            if let allowsMultiple {
                object["allows_multiple"] = .bool(allowsMultiple)
            }
            if !options.isEmpty {
                object["options"] = .array(options.map { .object($0.asObject()) })
            }
            if !fields.isEmpty {
                object["fields"] = .array(fields.map { .object($0.asObject()) })
            }
            if !details.isEmpty {
                object["details"] = .array(details.map { .object($0.asObject()) })
            }
            return object
        }
    }

    package struct HookGate: Equatable, Sendable {
        package enum Status: String, Equatable, Sendable {
            case approvedAll = "approved_all"
            case approvedSelected = "approved_selected"
            case continuedWithoutHooks = "continued_without_hooks"
            case resolvedExternally = "resolved_externally"
        }

        package let status: Status
        package let approvedHookCount: Int
        package let skippedHookCount: Int?
        package let resolvedAt: Date

        package init(status: Status, approvedHookCount: Int, skippedHookCount: Int?, resolvedAt: Date) {
            self.status = status
            self.approvedHookCount = approvedHookCount
            self.skippedHookCount = skippedHookCount
            self.resolvedAt = resolvedAt
        }

        package func asObject() -> [String: Value] {
            var object: [String: Value] = [
                "status": .string(status.rawValue),
                "approved_hook_count": .int(approvedHookCount),
                "resolved_at": .string(DomainAgentRunSnapshot.timestamp(resolvedAt))
            ]
            if let skippedHookCount {
                object["skipped_hook_count"] = .int(skippedHookCount)
            }
            return object
        }
    }

    package enum FailureReason: String, Equatable, Sendable {
        case processCrash = "process_crash"
        case timeout
        case agentError = "agent_error"
        case resumeTimedOut = "resume_timed_out"
        case resumeHistoryTooLarge = "resume_history_too_large"
        case cancelled

        /// Fallback heuristic for restored/legacy snapshots whose terminal
        /// settlement did not stamp a canonical failure reason. Live terminal
        /// classification is resolved exactly once by the terminal settlement
        /// authority; this text inference must not become the primary path.
        package static func classify(status: Status, statusText: String?) -> FailureReason? {
            if status == .cancelled { return .cancelled }
            guard status == .failed else { return nil }
            guard let text = statusText?.lowercased(), !text.isEmpty else { return .agentError }
            if ["cancelled", "canceled", "interrupted", "aborted"].contains(where: text.contains) {
                return .cancelled
            }
            if text.hasPrefix("codex native resume failed:"),
               text.contains("no new thread was started"),
               ["timed out", "timeout", "deadline exceeded", "took too long"].contains(where: text.contains)
            {
                return .resumeTimedOut
            }
            if ["timed out", "timeout", "deadline exceeded", "took too long"].contains(where: text.contains) {
                return .timeout
            }
            if [
                "process not running", "transport closed", "connection closed", "broken pipe",
                "crashed", "crash", "exited unexpectedly", "terminated unexpectedly",
                "protocol error", "decode error", "spawn failed"
            ].contains(where: text.contains) {
                return .processCrash
            }
            return .agentError
        }
    }

    /// Effective worktree binding of the session as published on the MCP wire.
    ///
    /// `unknown` is reserved for projections that intentionally do not publish bindings
    /// (resident in-memory snapshots, expired handles); it must never be inferred from an
    /// empty binding list. On the wire `unknown` is represented by omitting
    /// `worktree_binding_state` and the binding keys entirely, which keeps those legacy
    /// payload shapes byte-identical; `bound`/`unbound` are always explicit.
    package enum WorktreeBindingState: String, Codable, Equatable, Sendable {
        case bound
        case unbound
        case unknown
    }

    /// Upper bound on the `assistant_text` content characters (extended grapheme clusters)
    /// published by `asObject()`; a truncated preview carries the marker in addition.
    ///
    /// Wait/poll/steer responses carry the child's last assistant reply only — never raw tool
    /// output — and this cap keeps that report bounded for the supervising session. Longer
    /// replies are truncated and flagged with `assistant_text_truncated`; the full transcript
    /// stays reachable through explicit log operations (`agent_manage get_log`).
    ///
    /// These limits bound the decoded text value, not its JSON encoding (escaping can expand
    /// it) or the whole response, which also carries metadata, bindings, and interactions.
    package static let assistantTextCharacterLimit = 16_000

    /// UTF-8 ceiling on the published `assistant_text`, truncation marker included. Characters
    /// are grapheme clusters of unbounded byte length, so a character cap alone is not a size cap.
    /// `assistant_text_characters` reports the original length in grapheme clusters, so it can
    /// be smaller than the published text (an oversized single grapheme reports `1`).
    package static let assistantTextUTF8ByteLimit = 64 * 1024

    package static let assistantTextTruncationMarker = "\n… [assistant_text truncated; read the full transcript with agent_manage get_log]"

    /// Upper bounds on the published `status_text`: up to `statusTextCharacterLimit` content
    /// characters plus the marker, with the byte ceiling covering both. Status text is a short
    /// label; producers keep full diagnostics in their own logs and classify failures from the
    /// untruncated text before publishing.
    package static let statusTextCharacterLimit = 2000
    package static let statusTextUTF8ByteLimit = 8 * 1024
    package static let statusTextTruncationMarker = " … [status_text truncated]"

    package static let unboundChildOfBoundParentWarning =
        "This child session is not bound to a worktree although its parent session is. It reads the logical root checkout, " +
        "not the parent's task worktree, so task-aware inspection may observe base/stale state. Start it with explicit " +
        "`worktree`/`worktree_id` arguments, or omit `inherit_worktree=false`, to bind it."

    package let sessionID: UUID
    package let runID: UUID?
    package let tabID: UUID?
    package let sessionName: String?
    package let agentRaw: String?
    package let agentDisplayName: String?
    package let modelRaw: String?
    package let reasoningEffortRaw: String?
    package let modelParameterSelections: [ModelParameterSelection]
    package let status: Status
    package let statusText: String?
    package let latestAssistantPreview: String?
    /// Internal-only truncation state of `latestAssistantPreview`: non-nil means the preview is
    /// an already-bounded projection (decoded from a published payload) of a reply with this
    /// many characters. It is republished through the existing `assistant_text_truncated` /
    /// `assistant_text_characters` keys. `nil` (the default) means the preview is the producer's
    /// own text, which `asObject()` bounds itself.
    package let latestAssistantPreviewTotalCharacters: Int?
    package let interaction: Interaction?
    package let hookGate: HookGate?
    package let transcriptItemCount: Int
    package let updatedAt: Date
    package let parentSessionID: UUID?
    package let failureReason: FailureReason?
    package let worktreeBindings: [WorktreeBinding]
    package let activeWorktreeMerges: [WorktreeMergeSummary]
    package let worktreeBindingState: WorktreeBindingState
    /// Whether the parent session (when any) holds worktree bindings. `nil` when there is no
    /// parent or the parent's bindings were not resolved.
    package let parentIsWorktreeBound: Bool?

    package init(
        sessionID: UUID,
        runID: UUID? = nil,
        tabID: UUID?,
        sessionName: String?,
        agentRaw: String?,
        agentDisplayName: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        modelParameterSelections: [ModelParameterSelection] = [],
        status: Status,
        statusText: String?,
        latestAssistantPreview: String?,
        latestAssistantPreviewTotalCharacters: Int? = nil,
        interaction: Interaction?,
        hookGate: HookGate? = nil,
        transcriptItemCount: Int,
        updatedAt: Date,
        parentSessionID: UUID?,
        failureReason: FailureReason?,
        worktreeBindings: [WorktreeBinding],
        activeWorktreeMerges: [WorktreeMergeSummary],
        worktreeBindingState: WorktreeBindingState? = nil,
        parentIsWorktreeBound: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.tabID = tabID
        self.sessionName = sessionName
        self.agentRaw = agentRaw
        self.agentDisplayName = agentDisplayName
        self.modelRaw = modelRaw
        self.reasoningEffortRaw = reasoningEffortRaw
        self.modelParameterSelections = modelParameterSelections
        self.status = status
        self.statusText = statusText
        self.latestAssistantPreview = latestAssistantPreview
        self.latestAssistantPreviewTotalCharacters = latestAssistantPreviewTotalCharacters
        self.interaction = interaction
        self.hookGate = hookGate
        self.transcriptItemCount = transcriptItemCount
        self.updatedAt = updatedAt
        self.parentSessionID = parentSessionID
        self.failureReason = failureReason
        self.worktreeBindings = worktreeBindings
        self.activeWorktreeMerges = activeWorktreeMerges
        self.worktreeBindingState = worktreeBindingState ?? (worktreeBindings.isEmpty ? .unbound : .bound)
        self.parentIsWorktreeBound = parentIsWorktreeBound
    }

    /// A child started under a worktree-bound parent that itself ended up unbound. Such a
    /// child inspects the logical root rather than the parent's task worktree.
    package var isUnboundChildOfBoundParent: Bool {
        parentSessionID != nil && worktreeBindingState == .unbound && parentIsWorktreeBound == true
    }

    /// Bounded `assistant_text` payload: the preview capped at `assistantTextCharacterLimit`
    /// characters and `assistantTextUTF8ByteLimit` bytes, plus whether it is truncated and the
    /// original length.
    ///
    /// `knownTotalCharacters` is the explicit truncation state of an already-bounded preview
    /// (see `latestAssistantPreviewTotalCharacters`). A non-nil value always reports
    /// truncation with that original count — even when the preview is short, as after
    /// byte-only truncation or an oversized single grapheme — and republishing such a
    /// preview leaves its text unchanged.
    package static func boundedAssistantText(
        _ text: String,
        knownTotalCharacters: Int? = nil
    ) -> (text: String, truncated: Bool, totalCharacters: Int) {
        let bounded = boundedText(
            text,
            characterLimit: assistantTextCharacterLimit,
            utf8ByteLimit: assistantTextUTF8ByteLimit,
            marker: assistantTextTruncationMarker
        )
        if let knownTotalCharacters {
            return (bounded.text, true, knownTotalCharacters)
        }
        return (bounded.text, bounded.truncated, bounded.characterCount)
    }

    /// Bounded `status_text`: capped at `statusTextCharacterLimit` characters and
    /// `statusTextUTF8ByteLimit` bytes; truncation is signalled by the trailing marker.
    package static func boundedStatusText(_ text: String) -> String {
        boundedText(
            text,
            characterLimit: statusTextCharacterLimit,
            utf8ByteLimit: statusTextUTF8ByteLimit,
            marker: statusTextTruncationMarker
        ).text
    }

    /// Keeps up to `characterLimit` content characters (extended grapheme clusters) plus
    /// `marker` when it truncates; the `utf8ByteLimit` ceiling covers content and marker
    /// together. Truncation stops before a grapheme that would cross either limit, even when
    /// that leaves an empty prefix. `characterCount` is the input's grapheme count.
    ///
    /// Idempotent: text that is already `<bounded head> + marker` is returned verbatim with
    /// `truncated == false`, so decode-and-republish round-trips never re-truncate or stack
    /// markers. Truncation state therefore has to travel separately (see
    /// `latestAssistantPreviewTotalCharacters`).
    package static func boundedText(
        _ text: String,
        characterLimit: Int,
        utf8ByteLimit: Int,
        marker: String
    ) -> (text: String, truncated: Bool, characterCount: Int) {
        // Grapheme counting is O(n); count once and hand it back to callers.
        let characterCount = text.count
        let utf8Count = text.utf8.count
        if utf8Count <= utf8ByteLimit, characterCount <= characterLimit {
            return (text, false, characterCount)
        }
        let markerBytes = marker.utf8.count
        let headByteBudget = max(0, utf8ByteLimit - markerBytes)
        if utf8Count >= markerBytes, text.utf8.suffix(markerBytes).elementsEqual(marker.utf8) {
            let headBytes = utf8Count - markerBytes
            if headBytes <= headByteBudget,
               String(decoding: text.utf8.prefix(headBytes), as: UTF8.self).count <= characterLimit
            {
                return (text, false, characterCount)
            }
        }
        var head = ""
        var headBytes = 0
        var headCharacters = 0
        for character in text {
            let characterBytes = character.utf8.count
            guard headCharacters < characterLimit, headBytes + characterBytes <= headByteBudget else { break }
            head.append(character)
            headBytes += characterBytes
            headCharacters += 1
        }
        return (head + marker, true, characterCount)
    }

    /// Removes `assistant_text` together with its truncation metadata from a published object,
    /// for decorations that intentionally suppress the preview.
    package static func removeAssistantText(from object: inout [String: Value]) {
        object.removeValue(forKey: "assistant_text")
        object.removeValue(forKey: "assistant_text_truncated")
        object.removeValue(forKey: "assistant_text_characters")
    }

    package var isActionableForMCPWait: Bool {
        interaction != nil || status == .waitingForInput || status.isTerminal
    }

    package var isStartupPendingForMCPWait: Bool {
        status == .running && runID == nil && statusText == Self.startupPendingStatusText
    }

    package func asObject() -> [String: Value] {
        var object: [String: Value] = [
            "session_id": .string(sessionID.uuidString),
            "status": .string(status.rawValue),
            "transcript_item_count": .int(transcriptItemCount),
            "updated_at": .string(Self.timestamp(updatedAt))
        ]
        if let runID {
            object["run_id"] = .string(runID.uuidString)
        }
        if let statusText, !statusText.isEmpty {
            object["status_text"] = .string(Self.boundedStatusText(statusText))
        }
        if let latestAssistantPreview, !latestAssistantPreview.isEmpty {
            let bounded = Self.boundedAssistantText(
                latestAssistantPreview,
                knownTotalCharacters: latestAssistantPreviewTotalCharacters
            )
            object["assistant_text"] = .string(bounded.text)
            if bounded.truncated {
                object["assistant_text_truncated"] = .bool(true)
                object["assistant_text_characters"] = .int(bounded.totalCharacters)
            }
        }
        if let interaction {
            object["interaction"] = .object(interaction.asObject())
            object["interaction_id"] = .string(interaction.id.uuidString)
        }
        if let hookGate {
            object["hook_gate"] = .object(hookGate.asObject())
        }
        if let failureReason {
            object["failure_reason"] = .string(failureReason.rawValue)
        }

        var session: [String: Value] = [
            "id": .string(sessionID.uuidString),
            "name": sessionName.map(Value.string) ?? .null
        ]
        if let tabID {
            session["context_id"] = .string(tabID.uuidString)
        }
        if let parentSessionID {
            session["parent_session_id"] = .string(parentSessionID.uuidString)
        }
        object["session"] = .object(session)

        if agentRaw != nil || modelRaw != nil {
            var agent: [String: Value] = [
                "id": agentRaw.map(Value.string) ?? .null,
                "name": agentDisplayName.map(Value.string) ?? .null,
                "model": modelRaw.map(Value.string) ?? .null,
                "reasoning_effort": reasoningEffortRaw.map(Value.string) ?? .null
            ]
            if !modelParameterSelections.isEmpty {
                agent["model_parameters"] = .array(modelParameterSelections.map { .object($0.asObject()) })
            }
            object["agent"] = .object(agent)
        }
        if worktreeBindingState != .unknown {
            object["worktree_binding_state"] = .string(worktreeBindingState.rawValue)
        }
        if !worktreeBindings.isEmpty {
            let values = worktreeBindings.map { Value.object($0.asObject()) }
            object["worktree_bindings"] = .array(values)
            object["worktree"] = values[0]
        } else if worktreeBindingState == .unbound {
            // An unbound session says so explicitly instead of omitting the keys, so a
            // supervisor cannot mistake "no binding fields" for "binding unknown".
            object["worktree_bindings"] = .array([])
            object["worktree"] = .null
        }
        if let parentIsWorktreeBound {
            object["parent_worktree_bound"] = .bool(parentIsWorktreeBound)
        }
        if isUnboundChildOfBoundParent {
            object["worktree_binding_warning"] = .string(Self.unboundChildOfBoundParentWarning)
        }
        if !activeWorktreeMerges.isEmpty {
            object["active_worktree_merges"] = .array(activeWorktreeMerges.map { .object(Self.mergeSummaryObject($0)) })
        }
        return object
    }

    package func toValue() -> Value {
        .object(asObject())
    }

    package static func expired(sessionID: UUID) -> DomainAgentRunSnapshot {
        expired(
            sessionID: sessionID,
            statusText: "This session control handle is no longer available. Start a new run or use a more recent session ID."
        )
    }

    package static func expired(sessionID: UUID, statusText: String) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: nil,
            agentRaw: nil,
            agentDisplayName: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: .expired,
            statusText: statusText,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            // An expired handle has no binding knowledge; it must not claim `unbound`.
            worktreeBindingState: .unknown
        )
    }

    private static func mergeSummaryObject(_ summary: WorktreeMergeSummary) -> [String: Value] {
        [
            "id": .string(summary.id),
            "status": .string(summary.status),
            "repository_id": .string(summary.repositoryID),
            "repo_key": .string(summary.repoKey),
            "source_worktree_id": .string(summary.sourceWorktreeID),
            "source_label": .string(summary.sourceLabel),
            "source_branch": summary.sourceBranch.map(Value.string) ?? .null,
            "source_path": .string(summary.sourcePath),
            "target_worktree_id": .string(summary.targetWorktreeID),
            "target_label": .string(summary.targetLabel),
            "target_branch": summary.targetBranch.map(Value.string) ?? .null,
            "target_path": .string(summary.targetPath),
            "conflict_file_count": .int(summary.conflictFileCount),
            "updated_at": .string(timestamp(summary.updatedAt))
        ]
    }

    fileprivate static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

package enum DomainRuntimeCompatibilityIdentity {
    package static let runtimeID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
