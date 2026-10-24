import Foundation

// MARK: - Scanner Protocol

/// Protocol for cross-workspace session metadata scanning.
/// Used for dependency injection in the MCP tool service (WI-3).
protocol HistorySessionScanning: Sendable {
    /// Discover all workspace directories and read their session metadata indexes.
    /// Returns one result per workspace that has an AgentSessions directory.
    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult]

    /// Same as ``scanAllWorkspaces()`` but force a fresh scan, bypassing the
    /// cross-workspace inventory TTL cache. Used to resolve a session id that was
    /// saved after the cache was populated (e.g. a `get_session` lookup that missed).
    /// The per-workspace index signature cache still applies, so unchanged indexes
    /// are not re-decoded, and the result repopulates the TTL cache.
    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult]

    /// Budget-aware inventory entry point used by the MCP history service. Implementations
    /// may pre-narrow exact workspace UUID/storage-directory scopes before opening indexes.
    func scanWorkspaces(matching workspace: String?) async throws -> HistoryInventoryScan
    func scanWorkspaces(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan

    /// Cache-bypassed budget-aware inventory used by the just-saved session fallback.
    func scanWorkspacesRefreshing(matching workspace: String?) async throws -> HistoryInventoryScan
    func scanWorkspacesRefreshing(
        matching workspace: String?,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan

    /// Resolve an exact session file without hydrating the cross-workspace inventory.
    func locateSession(sessionID: UUID) async throws -> HistoryDirectSessionLookup
    func locateSession(
        sessionID: UUID,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryDirectSessionLookup

    /// Load the session name and transcript through the same signature-checked cache.
    func loadSessionForHistory(sessionID: UUID, workspaceDir: URL) async throws -> HistoryLoadedSession
    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> HistoryLoadedSession

    /// Filter metadata records across all workspaces.
    /// Calls ``scanAllWorkspaces()`` internally, then applies the given filters.
    func sessionsMatchingFilters(
        _ records: [HistoryWorkspaceScanResult],
        workspace: String?,
        agentKind: String?,
        model: String?,
        filePath: String?,
        from: Date?,
        to: Date?
    ) -> [HistoryFilteredSessionRecord]

    /// Lazily load a full transcript for a specific session.
    /// Used by the ``search`` operation to walk turns for text matching.
    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL
    ) async throws -> AgentTranscript
    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> AgentTranscript

    /// Whether the session file for `record` has changed since its stored observed
    /// signature was recorded — i.e., persisted transcript-derived fields may be
    /// stale and should be recomputed from the live transcript.
    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL
    ) async -> Bool
    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget: HistoryRequestBudget
    ) async throws -> Bool

    func loadSessionForHistory(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> HistoryLoadedSession

    func loadTranscriptForSearch(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> AgentTranscript

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord, sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> Bool
}

extension HistorySessionScanning {
    func scanWorkspaces(matching _: String?) async throws -> HistoryInventoryScan {
        try await HistoryInventoryScan(workspaces: scanAllWorkspaces())
    }

    func scanWorkspaces(
        matching workspace: String?,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try await scanWorkspaces(matching: workspace)
    }

    func scanWorkspacesRefreshing(matching _: String?) async throws -> HistoryInventoryScan {
        try await HistoryInventoryScan(workspaces: scanAllWorkspacesRefreshing())
    }

    func scanWorkspacesRefreshing(
        matching workspace: String?,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryInventoryScan {
        try await scanWorkspacesRefreshing(matching: workspace)
    }

    func locateSession(sessionID _: UUID) async throws -> HistoryDirectSessionLookup {
        HistoryDirectSessionLookup(location: nil)
    }

    func locateSession(
        sessionID: UUID,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryDirectSessionLookup {
        try await locateSession(sessionID: sessionID)
    }

    func loadSessionForHistory(sessionID: UUID, workspaceDir: URL) async throws -> HistoryLoadedSession {
        try await HistoryLoadedSession(
            name: nil,
            transcript: loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir)
        )
    }

    func loadSessionForHistory(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> HistoryLoadedSession {
        try await loadSessionForHistory(sessionID: sessionID, workspaceDir: workspaceDir)
    }

    func loadTranscriptForSearch(
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> AgentTranscript {
        try await loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir)
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord,
        sessionID: UUID,
        workspaceDir: URL,
        requestBudget _: HistoryRequestBudget
    ) async throws -> Bool {
        await transcriptDerivedFieldsAreStale(
            for: record,
            sessionID: sessionID,
            workspaceDir: workspaceDir
        )
    }

    func loadSessionForHistory(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> HistoryLoadedSession {
        try await loadSessionForHistory(sessionID: sessionID, workspaceDir: workspaceDir, requestBudget: requestBudget)
    }

    func loadTranscriptForSearch(
        sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> AgentTranscript {
        try await loadTranscriptForSearch(sessionID: sessionID, workspaceDir: workspaceDir, requestBudget: requestBudget)
    }

    func transcriptDerivedFieldsAreStale(
        for record: AgentSessionMetadataRecord, sessionID: UUID, workspaceDir: URL, requestBudget: HistoryRequestBudget,
        workspaceLocation: HistoryWorkspaceLocation?
    ) async throws -> Bool {
        try await transcriptDerivedFieldsAreStale(for: record, sessionID: sessionID, workspaceDir: workspaceDir, requestBudget: requestBudget)
    }
}
