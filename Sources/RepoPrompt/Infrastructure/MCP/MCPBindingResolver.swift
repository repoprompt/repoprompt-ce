import Foundation
import MCP
import RepoPromptCore

struct MCPContextBindingMatch {
    let windowID: Int
    let runtimeID: WorkspaceRuntimeID
    let mappingGeneration: UInt64
    let tabID: UUID
    let workspaceID: UUID
    let workspaceName: String
    let repoPaths: [String]
    let sessionID: WorkspaceSessionID
    let sessionAvailability: WorkspaceSessionAvailability
}

struct MCPLogicalContextResolution {
    let tabID: UUID
    let workspaceID: UUID
    let workspaceName: String
    let repoPaths: [String]
    let windowIDs: [Int]
}

struct MCPLogicalContextBindingResolution {
    let logicalContext: MCPLogicalContextResolution
    let windowID: Int
    let runtimeID: WorkspaceRuntimeID
    let mappingGeneration: UInt64
    let sessionID: WorkspaceSessionID
    let sessionAvailability: WorkspaceSessionAvailability
}

/// Exact workspace-session capability admitted for one MCP request.
///
/// Session identity and activation token are intentionally inseparable so downstream
/// routing cannot accidentally combine a resolved window with a token reacquired from a
/// replacement session.
struct MCPAdmittedContextBinding: Equatable, @unchecked Sendable {
    let windowID: Int
    let tabID: UUID?
    let workspaceID: UUID?
    let sessionID: WorkspaceSessionID
    let admissionToken: WorkspaceSessionAdmissionToken

    init?(
        windowID: Int,
        tabID: UUID?,
        workspaceID: UUID?,
        sessionID: WorkspaceSessionID,
        admissionToken: WorkspaceSessionAdmissionToken
    ) {
        guard admissionToken.sessionID == sessionID else { return nil }
        self.windowID = windowID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.admissionToken = admissionToken
    }

    @MainActor
    func isCurrent(in windowState: WindowState) -> Bool {
        guard windowState.windowID == windowID,
              windowState.workspaceSessionID == sessionID,
              let client = windowState.workspaceSessionCommandClient,
              let snapshot = client.snapshot,
              isCurrent(
                  clientSessionID: client.sessionID,
                  snapshot: snapshot,
                  currentAdmissionToken: client.admissionToken
              )
        else { return false }
        return true
    }

    func isCurrent(
        clientSessionID: WorkspaceSessionID,
        snapshot: WorkspaceSessionSnapshot,
        currentAdmissionToken: WorkspaceSessionAdmissionToken?
    ) -> Bool {
        clientSessionID == sessionID
            && snapshot.sessionID == sessionID
            && (snapshot.availability == .active || snapshot.availability == .switching)
            && currentAdmissionToken?.activationID == admissionToken.activationID
    }

    @MainActor
    func execute(
        _ command: WorkspaceSessionCommand,
        source: String,
        in windowState: WindowState
    ) async -> WorkspaceSessionCommandResult? {
        guard isCurrent(in: windowState),
              let client = windowState.workspaceSessionCommandClient,
              let snapshot = client.snapshot
        else { return nil }
        return await client.execute(
            command,
            source: WorkspaceSessionCommandSource(kind: source),
            exactAdmissionToken: admissionToken,
            expectedGeneration: snapshot.stateGeneration
        )
    }
}

struct MCPBindingResolver {
    private struct LogicalContextKey: Hashable {
        let tabID: UUID
        let normalizedRepoPaths: [String]
        let fallbackWorkspaceIDForEmptyRoots: UUID?

        init(match: MCPContextBindingMatch) {
            tabID = match.tabID
            normalizedRepoPaths = WorkspaceRootSetKey(paths: match.repoPaths).normalizedPaths
            fallbackWorkspaceIDForEmptyRoots = normalizedRepoPaths.isEmpty ? match.workspaceID : nil
        }
    }

    let collectMatchesForContextID: (UUID) async -> [MCPContextBindingMatch]
    let collectMatchesForWorkingDirs: ([String]) async -> [MCPContextBindingMatch]
    let existingWindowIDForConnection: (UUID) async -> Int?
    let clientIdentifier: (UUID) async -> String?
    let reusableWindowForClient: (UUID, String) async -> Int?
    let sessionKeyForConnection: (UUID) async -> String?
    let preferredLiveRunWindowID: (String, String?) async -> Int?
    let preferredWindowID: (String, String?) async -> Int?

    func resolveLogicalContextBinding(
        connectionID: UUID,
        explicitContextID: UUID?,
        legacyTabID: UUID?,
        workingDirs: [String],
        requestedWindowID: Int?
    ) async throws -> MCPLogicalContextBindingResolution? {
        if let explicitContextID,
           let legacyTabID,
           explicitContextID != legacyTabID
        {
            throw MCPError.invalidParams(
                "Conflicting binding identifiers: context_id '\(explicitContextID.uuidString)' does not match _tabID '\(legacyTabID.uuidString)'. Pass only one, or make them match."
            )
        }

        let sourceDescription: String
        let matches: [MCPContextBindingMatch]
        if let explicitContextID {
            sourceDescription = "context_id '\(explicitContextID.uuidString)'"
            matches = await collectMatchesForContextID(explicitContextID)
        } else if let legacyTabID {
            sourceDescription = "_tabID '\(legacyTabID.uuidString)'"
            matches = await collectMatchesForContextID(legacyTabID)
        } else if !workingDirs.isEmpty {
            sourceDescription = "working_dirs [\(workingDirs.joined(separator: ", "))]"
            matches = await collectMatchesForWorkingDirs(workingDirs)
        } else {
            return nil
        }

        let logicalContext = try collapseLogicalContextMatches(matches, sourceDescription: sourceDescription)
        let windowID = try await resolveWindowForLogicalContext(
            logicalContext,
            connectionID: connectionID,
            requestedWindowID: requestedWindowID
        )
        guard let selectedMatch = matches.first(where: { $0.windowID == windowID }) else {
            throw MCPError.invalidParams("The resolved RepoPrompt window no longer hosts the requested context.")
        }
        return MCPLogicalContextBindingResolution(
            logicalContext: logicalContext,
            windowID: windowID,
            runtimeID: selectedMatch.runtimeID,
            mappingGeneration: selectedMatch.mappingGeneration,
            sessionID: selectedMatch.sessionID,
            sessionAvailability: selectedMatch.sessionAvailability
        )
    }

    private func collapseLogicalContextMatches(
        _ matches: [MCPContextBindingMatch],
        sourceDescription: String
    ) throws -> MCPLogicalContextResolution {
        guard !matches.isEmpty else {
            throw MCPError.invalidParams("No RepoPrompt tab context matches \(sourceDescription). Use bind_context op=list to discover available context_id values.")
        }

        let groupedMatches = Dictionary(grouping: matches) {
            LogicalContextKey(match: $0)
        }

        let resolutions = groupedMatches.compactMap { _, groupedMatches -> MCPLogicalContextResolution? in
            guard let representative = groupedMatches.sorted(by: Self.logicalContextRepresentativeSort).first else {
                return nil
            }
            let windowIDs = Array(Set(groupedMatches.map(\.windowID))).sorted()
            return MCPLogicalContextResolution(
                tabID: representative.tabID,
                workspaceID: representative.workspaceID,
                workspaceName: representative.workspaceName,
                repoPaths: representative.repoPaths,
                windowIDs: windowIDs
            )
        }.sorted {
            let lhsNameKey = $0.workspaceName.lowercased()
            let rhsNameKey = $1.workspaceName.lowercased()
            if lhsNameKey != rhsNameKey { return lhsNameKey < rhsNameKey }
            if $0.workspaceName != $1.workspaceName { return $0.workspaceName < $1.workspaceName }
            return $0.tabID.uuidString < $1.tabID.uuidString
        }
        guard resolutions.count == 1, let resolution = resolutions.first else {
            let details = describeLogicalContextCandidates(resolutions)
            throw MCPError.invalidParams("Ambiguous tab-context binding for \(sourceDescription). Matched multiple contexts:\n- \(details)")
        }
        return resolution
    }

    private static func logicalContextRepresentativeSort(_ lhs: MCPContextBindingMatch, _ rhs: MCPContextBindingMatch) -> Bool {
        if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
        let lhsNameKey = lhs.workspaceName.lowercased()
        let rhsNameKey = rhs.workspaceName.lowercased()
        if lhsNameKey != rhsNameKey { return lhsNameKey < rhsNameKey }
        if lhs.workspaceName != rhs.workspaceName { return lhs.workspaceName < rhs.workspaceName }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }

    private func resolveWindowForLogicalContext(
        _ logicalContext: MCPLogicalContextResolution,
        connectionID: UUID,
        requestedWindowID: Int?
    ) async throws -> Int {
        let windowIDs = logicalContext.windowIDs
        guard !windowIDs.isEmpty else {
            throw MCPError.invalidParams("No open RepoPrompt window can serve context_id '\(logicalContext.tabID.uuidString)'.")
        }

        if let requestedWindowID {
            guard windowIDs.contains(requestedWindowID) else {
                let available = windowIDs.map(String.init).joined(separator: ", ")
                throw MCPError.invalidParams("Window \(requestedWindowID) does not host context_id '\(logicalContext.tabID.uuidString)'. Available windows: \(available)")
            }
            return requestedWindowID
        }

        if let existingWindowID = await existingWindowIDForConnection(connectionID),
           windowIDs.contains(existingWindowID)
        {
            return existingWindowID
        }

        if let clientName = await clientIdentifier(connectionID) {
            if let reusedWindowID = await reusableWindowForClient(connectionID, clientName),
               windowIDs.contains(reusedWindowID)
            {
                return reusedWindowID
            }

            let sessionKey = await sessionKeyForConnection(connectionID)
            if let liveAffinityWindowID = await preferredLiveRunWindowID(clientName, sessionKey),
               windowIDs.contains(liveAffinityWindowID)
            {
                return liveAffinityWindowID
            }
            if let preferredWindowID = await preferredWindowID(clientName, sessionKey),
               windowIDs.contains(preferredWindowID)
            {
                return preferredWindowID
            }
        }

        if windowIDs.count == 1, let onlyWindowID = windowIDs.first {
            return onlyWindowID
        }

        let available = windowIDs.map(String.init).joined(separator: ", ")
        throw MCPError.invalidParams("Context_id '\(logicalContext.tabID.uuidString)' is open in multiple windows (\(available)). Pass context_id with _windowID, or bind the connection to a tab context first.")
    }

    private func describeLogicalContextCandidates(_ candidates: [MCPLogicalContextResolution]) -> String {
        candidates.map { candidate in
            let windows = candidate.windowIDs.map(String.init).joined(separator: ", ")
            let roots = WorkspaceRootSetKey(paths: candidate.repoPaths).normalizedPaths.joined(separator: ", ")
            return "context_id=\(candidate.tabID.uuidString) • workspace=\(candidate.workspaceName) • roots=[\(roots)] • windows=[\(windows)]"
        }.joined(separator: "\n- ")
    }
}
