import Foundation
import RepoPromptDomainRuntime

// The canonical transcript an observer may `read` from a live target endpoint.
//
// Owns `AgentSessionLinkCanonicalTranscript` — the exact user-visible conversation plus the cursor
// metadata — the runtime accessor that snapshots it for one generation-bearing endpoint, and the
// `read` accessor that hands that snapshot to `AgentSessionLinkTranscriptSanitizer` for the coarse,
// budgeted, redacted page the tool returns. It authors no sanitization rule of its own. Invariant:
// the snapshot names the exact incarnation it was taken from, so a rebind cannot serve a
// predecessor's transcript.

// MARK: - Canonical transcript snapshot

/// The canonical user-visible conversation for one live endpoint, plus the metadata the sanitizer
/// and read cursors need.
///
/// This is deliberately **not** the target window's presentation state: `visibleRows`, reveal
/// toggles, collapse degradation, and the window-local presentation revision all change for
/// display-only reasons and would make an observer's history depend on what the target's user
/// happened to have expanded.
struct AgentSessionLinkCanonicalTranscript: Equatable {
    /// Archived + working projection rows in stable `(sequenceIndex, timestamp)` order.
    let rows: [AgentChatItem]
    /// Rows whose owning render block is a compacted-summary block.
    let summaryRowIDs: Set<UUID>
    /// Non-authoritative diagnostic hint only. It never determines cursor validity: anchor existence
    /// does.
    let sourceItemsRevision: UInt64?
}

/// Why an overseen transcript could not be read right now.
enum AgentSessionLinkReadUnavailableReason: String, Error, Equatable {
    /// Retryable: the target has not finished hydrating its persisted state.
    case targetLoading = "target_loading"
    /// The exact endpoint incarnation is gone.
    case endpointInvalidated = "endpoint_invalidated"
}

extension AgentSessionLinkExecutionRuntime {
    /// Read admission carries exact session and scope incarnation without admitting a mutation.
    func transcriptWriter(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Result<AgentSessionRuntimeStore.Writer, AgentSessionLinkReadUnavailableReason> {
        guard let scope, !scope.isRetiring, !scope.hasReleasedWriterClaims, commands.isAvailable(),
              routeID == candidate.windowID, let session = sessions[candidate.tabID],
              let binding = session.persistentSessionBindingIdentity,
              binding.sessionID == candidate.sessionID, binding.workspaceID == candidate.workspaceID,
              binding.generation == candidate.persistentBindingGeneration,
              session.bindingTransitionGeneration == candidate.bindingTransitionGeneration,
              commands.workspaceID(session) == candidate.workspaceID,
              !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: candidate.sessionID),
              !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: candidate.sessionID)
        else { return .failure(.endpointInvalidated) }
        switch scope.resolveWriter(sessionID: candidate.sessionID, expectedWorkspaceID: candidate.workspaceID) {
        case let .unique(writer) where writer.scope === scope && writer.session === session:
            guard session.hasLoadedPersistedState, !scope.isAwaitingWorkspaceAdoption else { return .failure(.targetLoading) }
            return .success(writer)
        case .unavailable(.bindingTransition):
            return .failure(.targetLoading)
        default:
            return .failure(.endpointInvalidated)
        }
    }

    /// Pure canonical projection: runtime tool-result policy, then the canonical archived + working
    /// projection builder.
    ///
    /// `nonisolated` and `static` because it is a pure function of its inputs, which is what makes
    /// the projection/summary-classification behaviour testable without constructing a view model.
    ///
    /// **Cost, why it runs off the actor, and why it is not memoized.** This is `O(transcript)` for
    /// every authorized read: `runtimeTranscript` rebuilds the projection and re-runs the tool-result
    /// policy until the visible tool-result set stabilizes, and the merge below sorts every row. The
    /// sanitizer's page walk downstream *is* page-bounded, so this is the whole remaining
    /// transcript-proportional cost of a read — the page-bounded claim belongs to the walk, not to
    /// the read as a whole. Because it is a pure function of a `Sendable` snapshot, the read path
    /// runs it off the `@MainActor` (see `agentSessionLinkTranscriptPage`), so a `max_items: 1` read
    /// against a long transcript no longer stalls the target's UI. Genuine `O(page)` still needs a
    /// transcript-side revision or a revision-scoped canonical projection maintained by the refresh
    /// pipeline; that is a change to the transcript contract, not to oversight.
    ///
    /// Memoizing it needs a key that changes whenever `session.transcript` changes, and no such key
    /// exists at this layer. `sourceItemsRevision` counts mutations to `session.items`, while
    /// `session.transcript` is rewritten later and asynchronously by the derived-transcript refresh
    /// at an *unchanged* revision. A revision-keyed cache would therefore pin the pre-refresh
    /// projection and withhold rows the target has already produced — the same silent-skip failure
    /// the cursor rules exist to prevent. A sound cache needs a transcript-side revision, or reuse of
    /// the session's own derived-transcript sync token, which is a change to the transcript refresh
    /// contract rather than to oversight.
    nonisolated static func canonicalTranscript(
        from transcript: AgentTranscript,
        sourceItemsRevision: UInt64?
    ) -> AgentSessionLinkCanonicalTranscript {
        // `runtimeTranscript` applies the shared tool-result policy and returns the projection it
        // stabilized against, so the rows below match the policy-sanitized transcript exactly. The
        // oversight-only sanitizer then applies its stricter final layer on top of every row.
        let materialized = AgentTranscriptPolicyPipeline.runtimeTranscript(transcript)
        let projection = materialized.projection
        let rows = (projection.archivedRows + projection.workingRows).sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        var summaryRowIDs: Set<UUID> = []
        for block in projection.archivedBlocks + projection.workingBlocks
            where AgentSessionLinkTranscriptSanitizer.summaryBlockKinds.contains(block.kind)
        {
            summaryRowIDs.formUnion(block.rows.map(\.id))
        }
        return AgentSessionLinkCanonicalTranscript(
            rows: rows,
            summaryRowIDs: summaryRowIDs,
            sourceItemsRevision: sourceItemsRevision
        )
    }

    /// Sanitized, bounded transcript page for one exact live endpoint.
    ///
    /// Three steps, in this order: prove the endpoint and snapshot the transcript on the actor,
    /// materialize and page the snapshot **off** the actor, then re-prove the exact endpoint before
    /// releasing the page.
    ///
    /// The snapshot is a `Sendable` value copy, so the off-actor step observes no mutable view-model
    /// state and the page can only be as stale as the instant it was taken — which is harmless,
    /// because cursors only move forward. The recheck is the security-relevant half: authority was
    /// proven before a suspension point, and an in-place rebind can land inside it, so the page is
    /// released only if the *same* incarnation is still the one the read was authorized against. It
    /// is the identical predicate used to take the snapshot, not a weaker one.
    ///
    /// - Parameter readerSessionID: the reading observer, used only to mark its own previously
    ///   delivered cross-session rows. It never widens what the page may contain.
    func agentSessionLinkTranscriptPage(
        for candidate: AgentSessionLinkEndpointCandidate,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID?,
        sourceIsAvailable: @MainActor () -> Bool = { true }
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        guard sourceIsAvailable(), !Task.isCancelled else { return .failure(.endpointInvalidated) }
        let identity: AgentSessionRuntimeStore.WriterIdentity
        let transcript: AgentTranscript
        let sourceItemsRevision: UInt64
        switch transcriptWriter(for: candidate) {
        case let .success(writer):
            identity = writer.identity
            transcript = writer.session.transcript
            sourceItemsRevision = UInt64(max(0, writer.session.sourceItemsRevision))
        case let .failure(reason):
            return .failure(reason)
        }

        let page = await Task.detached(priority: .userInitiated) {
            let canonical = AgentSessionLinkExecutionRuntime.canonicalTranscript(
                from: transcript,
                sourceItemsRevision: sourceItemsRevision
            )
            return AgentSessionLinkTranscriptSanitizer.page(
                rows: canonical.rows,
                summaryRowIDs: canonical.summaryRowIDs,
                anchor: anchor,
                direction: direction,
                maxItems: maxItems,
                maxOutputBytes: maxOutputBytes,
                readerSessionID: readerSessionID
            )
        }.value

        #if DEBUG
            // Stands in for a lifecycle change landing inside the materialization above: the page
            // exists, and the gate below has not decided yet. See
            // `test_afterSessionLinkTranscriptPageMaterialized`.
            await test_afterSessionLinkTranscriptPageMaterialized?()
        #endif
        guard sourceIsAvailable(), !Task.isCancelled else { return .failure(.endpointInvalidated) }
        switch transcriptWriter(for: candidate) {
        case let .success(current) where current.identity == identity:
            return .success(page)
        case let .failure(reason):
            return .failure(reason)
        default:
            return .failure(.endpointInvalidated)
        }
    }
}
