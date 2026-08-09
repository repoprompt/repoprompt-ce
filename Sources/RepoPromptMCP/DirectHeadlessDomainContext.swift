import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessDomainContext {
    struct SessionRootMappingPreparation {
        let sessionID: UUID
        let resolvedMappings: [DirectHeadlessRootMapping]
        let previousMappings: [DirectHeadlessRootMapping]?
        let bindings: [DomainAgentRunSnapshot.WorktreeBinding]
    }

    enum Error: Swift.Error, LocalizedError {
        case routingUnavailable
        case workspaceUnavailable
        case contextUnavailable
        case rootMappingUnavailable
        case invalidWorkspaceDocument
        case stateConflict(String)
        case pathOutsideWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .routingUnavailable: "Standalone connection is not bound to a context"
            case .workspaceUnavailable: "Bound workspace is unavailable"
            case .contextUnavailable: "Bound context is unavailable"
            case .rootMappingUnavailable: "Direct-headless root mapping is incomplete or ambiguous"
            case .invalidWorkspaceDocument: "Workspace document is invalid"
            case let .stateConflict(reason): "Workspace state conflict: \(reason)"
            case let .pathOutsideWorkspace(path): "Path is outside the bound workspace roots: \(path)"
            }
        }
    }

    enum ContextMutation {
        case setPrompt(String)
        case setSelection([String])
    }

    struct Snapshot {
        let identity: DomainContextIdentity
        let workspace: DomainWorkspaceSnapshot
        let context: DomainContextSnapshot
        let canonicalRoots: [URL]
        let rootMappings: [DirectHeadlessRootMapping]
        let roots: [URL]
        let prompt: String
        let selection: [String]
    }

    let runtime: MCPDomainRuntime
    let scopeID: DomainStandaloneScopeID
    private let processRootMappings: [DirectHeadlessRootMapping]
    private var sessionRootMappings: [UUID: [DirectHeadlessRootMapping]] = [:]

    init(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        processRootMappings: [DirectHeadlessRootMapping] = []
    ) {
        self.runtime = runtime
        self.scopeID = scopeID
        self.processRootMappings = processRootMappings
    }

    func snapshot(for request: DomainPhysicalToolRequest) async throws -> Snapshot {
        guard let securityContext = request.securityContext else { throw Error.routingUnavailable }
        return try await snapshot(
            connectionID: securityContext.connectionID,
            sessionID: securityContext.principal.runID
        )
    }

    func snapshot(for request: DomainPhysicalReadRequest) async throws -> Snapshot {
        if let identity = request.context.handle?.context {
            return try await snapshot(
                identity: identity,
                sessionID: request.request.securityContext?.principal.runID
            )
        }
        guard let connectionID = request.context.connectionID else { throw Error.routingUnavailable }
        return try await snapshot(
            connectionID: connectionID,
            sessionID: request.request.securityContext?.principal.runID
        )
    }

    func snapshot(connectionID: UUID, sessionID: UUID? = nil) async throws -> Snapshot {
        let registration = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        return try await snapshot(identity: handle.context, sessionID: sessionID)
    }

    func snapshot(identity: DomainContextIdentity, sessionID: UUID? = nil) async throws -> Snapshot {
        guard let workspace = await runtime.contextStore.workspaceSnapshot(identity.workspaceID) else {
            throw Error.workspaceUnavailable
        }
        guard let context = workspace.contexts.first(where: { $0.metadata.identity == identity }) else {
            throw Error.contextUnavailable
        }
        let canonicalRoots = try workspace.document.metadata.repoPaths.map { raw -> URL in
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(raw)
            }
            return url
        }
        let rootMappings = try await resolveRootMappings(
            canonicalRoots: canonicalRoots,
            sessionID: sessionID
        )
        let roots = try rootMappings.map { mapping -> URL in
            let physical = mapping.physicalRoot.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: physical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(physical.path)
            }
            return physical
        }
        let contextObject = try Self.contextObject(from: workspace, contextID: identity.contextID)
        let prompt = contextObject["prompt"] as? String ?? ""
        let selection = contextObject["selectedPaths"] as? [String]
            ?? contextObject["selection"] as? [String]
            ?? []
        return Snapshot(
            identity: identity,
            workspace: workspace,
            context: context,
            canonicalRoots: canonicalRoots,
            rootMappings: rootMappings,
            roots: roots,
            prompt: prompt,
            selection: selection
        )
    }

    func prepareSessionRootMappings(
        sessionID: UUID,
        sourceSessionID: UUID?,
        arguments: [String: Value],
        connectionID: UUID
    ) async throws -> SessionRootMappingPreparation {
        let current = try await snapshot(connectionID: connectionID)
        let inherits = arguments["inherit_worktree"]?.boolValue ?? true
        let selectorIntent = try DirectHeadlessWorktreeRouting.parseSessionSelector(arguments: arguments)
        let inheritedMappings = inherits && !selectorIntent.isExplicit
            ? sourceSessionID.flatMap { sessionRootMappings[$0] }
            : nil
        let baseMappings = inheritedMappings ?? current.rootMappings
        let resolved = try await DirectHeadlessWorktreeRouting.resolveSessionMappings(
            arguments: arguments,
            selectorIntent: selectorIntent,
            canonicalRoots: current.canonicalRoots,
            baseMappings: baseMappings
        )
        let previousMappings = sessionRootMappings.updateValue(resolved, forKey: sessionID)
        let bindings = resolved.compactMap {
            DirectHeadlessWorktreeRouting.binding(
                mapping: $0,
                source: inheritedMappings == nil ? "direct-headless-session-overlay" : "direct-headless-inherited-overlay"
            )
        }
        return SessionRootMappingPreparation(
            sessionID: sessionID,
            resolvedMappings: resolved,
            previousMappings: previousMappings,
            bindings: bindings
        )
    }

    func rollbackSessionRootMappings(_ preparation: SessionRootMappingPreparation) {
        guard sessionRootMappings[preparation.sessionID] == preparation.resolvedMappings else { return }
        if let previousMappings = preparation.previousMappings {
            sessionRootMappings[preparation.sessionID] = previousMappings
        } else {
            sessionRootMappings.removeValue(forKey: preparation.sessionID)
        }
    }

    func validateBinding(_ identity: DomainContextIdentity) async throws {
        _ = try await snapshot(identity: identity)
    }

    func validateWorkspaceRoots(_ rawRoots: [String]) async throws {
        let canonicalRoots = try rawRoots.map { raw -> URL in
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(raw)
            }
            return url
        }
        _ = try await resolveRootMappings(canonicalRoots: canonicalRoots, sessionID: nil)
    }

    private func resolveRootMappings(
        canonicalRoots: [URL],
        sessionID: UUID?
    ) async throws -> [DirectHeadlessRootMapping] {
        let preferredMappings = sessionID.flatMap { sessionRootMappings[$0] } ?? processRootMappings
        let rootMappings: [DirectHeadlessRootMapping]
        if preferredMappings.isEmpty {
            rootMappings = canonicalRoots.map {
                DirectHeadlessRootMapping(
                    canonicalRoot: $0,
                    physicalRoot: $0,
                    worktree: nil,
                    visualLabel: nil,
                    visualColorHex: nil
                )
            }
        } else {
            guard preferredMappings.count == canonicalRoots.count else { throw Error.rootMappingUnavailable }
            var physicalPaths: Set<String> = []
            rootMappings = try canonicalRoots.map { canonicalRoot in
                let matches = preferredMappings.filter {
                    $0.canonicalRoot.standardizedFileURL.resolvingSymlinksInPath().path == canonicalRoot.path
                }
                guard matches.count == 1, let match = matches.first,
                      physicalPaths.insert(match.physicalRoot.path).inserted
                else { throw Error.rootMappingUnavailable }
                return match
            }
        }
        try await DirectHeadlessWorktreeRouting.verifyMappingsAtUse(rootMappings)
        return rootMappings
    }

    func mutate(
        request: DomainPhysicalToolRequest,
        mutation: ContextMutation
    ) async throws -> Snapshot {
        let current = try await snapshot(for: request)
        guard var document = try JSONSerialization.jsonObject(
            with: current.workspace.document.documentBytes
        ) as? [String: Any],
            var contexts = document["composeTabs"] as? [[String: Any]],
            let index = contexts.firstIndex(where: { ($0["id"] as? String) == current.identity.contextID.uuidString })
        else {
            throw Error.invalidWorkspaceDocument
        }
        switch mutation {
        case let .setPrompt(prompt):
            contexts[index]["prompt"] = prompt
        case let .setSelection(paths):
            contexts[index]["selectedPaths"] = paths
        }
        document["composeTabs"] = contexts
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: current.workspace.document.fileURL
        )
        try await MCPDomainMutationCommitContext.willCommit()
        let operationID = request.securityContext?.invocationID ?? UUID()
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: current.workspace.revisions.workingRevision,
            expectedContextRevision: current.context.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        guard outcome.disposition == .applied
            || outcome.disposition == .unchanged
            || outcome.disposition == .deduplicated
        else {
            throw Error.stateConflict(outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue)
        }
        return try await snapshot(
            identity: current.identity,
            sessionID: request.securityContext?.principal.runID
        )
    }

    nonisolated static func resolvePath(_ rawPath: String, roots: [URL], allowMissingLeaf: Bool = false) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("path must not be empty")
        }
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else if roots.count == 1, let root = roots.first {
            candidate = root.appendingPathComponent(rawPath)
        } else {
            let matches = roots.map { $0.appendingPathComponent(rawPath) }.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard matches.count == 1, let match = matches.first else {
                throw MCPError.invalidParams("Relative path is ambiguous across workspace roots")
            }
            candidate = match
        }
        let standardized = candidate.standardizedFileURL
        let checked = allowMissingLeaf
            ? standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
            : standardized.resolvingSymlinksInPath()
        guard roots.contains(where: { root in
            checked.path == root.path || checked.path.hasPrefix(root.path + "/")
        }) else {
            throw Error.pathOutsideWorkspace(rawPath)
        }
        return checked
    }

    nonisolated func resolvePath(_ rawPath: String, roots: [URL], allowMissingLeaf: Bool = false) throws -> URL {
        try Self.resolvePath(rawPath, roots: roots, allowMissingLeaf: allowMissingLeaf)
    }

    private static func contextObject(
        from workspace: DomainWorkspaceSnapshot,
        contextID: UUID
    ) throws -> [String: Any] {
        guard let document = try JSONSerialization.jsonObject(
            with: workspace.document.documentBytes
        ) as? [String: Any],
            let contexts = document["composeTabs"] as? [[String: Any]],
            let context = contexts.first(where: { ($0["id"] as? String) == contextID.uuidString })
        else {
            throw Error.invalidWorkspaceDocument
        }
        return context
    }
}
