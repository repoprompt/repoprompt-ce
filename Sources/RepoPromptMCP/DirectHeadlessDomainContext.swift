import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessDomainContext {
    enum Error: Swift.Error, LocalizedError {
        case routingUnavailable
        case workspaceUnavailable
        case contextUnavailable
        case invalidWorkspaceDocument
        case stateConflict(String)
        case pathOutsideWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .routingUnavailable: "Standalone connection is not bound to a context"
            case .workspaceUnavailable: "Bound workspace is unavailable"
            case .contextUnavailable: "Bound context is unavailable"
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
        let roots: [URL]
        let prompt: String
        let selection: [String]
    }

    let runtime: MCPDomainRuntime
    let scopeID: DomainStandaloneScopeID

    init(runtime: MCPDomainRuntime, scopeID: DomainStandaloneScopeID) {
        self.runtime = runtime
        self.scopeID = scopeID
    }

    func snapshot(for request: DomainPhysicalToolRequest) async throws -> Snapshot {
        guard let securityContext = request.securityContext else { throw Error.routingUnavailable }
        return try await snapshot(connectionID: securityContext.connectionID)
    }

    func snapshot(for request: DomainPhysicalReadRequest) async throws -> Snapshot {
        if let identity = request.context.handle?.context {
            return try await snapshot(identity: identity)
        }
        guard let connectionID = request.context.connectionID else { throw Error.routingUnavailable }
        return try await snapshot(connectionID: connectionID)
    }

    func snapshot(connectionID: UUID) async throws -> Snapshot {
        let registration = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        return try await snapshot(identity: handle.context)
    }

    func snapshot(identity: DomainContextIdentity) async throws -> Snapshot {
        guard let workspace = await runtime.contextStore.workspaceSnapshot(identity.workspaceID) else {
            throw Error.workspaceUnavailable
        }
        guard let context = workspace.contexts.first(where: { $0.metadata.identity == identity }) else {
            throw Error.contextUnavailable
        }
        let roots = try workspace.document.metadata.repoPaths.map { raw -> URL in
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(raw)
            }
            return url
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
            roots: roots,
            prompt: prompt,
            selection: selection
        )
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
        return try await snapshot(identity: current.identity)
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
