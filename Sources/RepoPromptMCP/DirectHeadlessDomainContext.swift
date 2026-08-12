import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessDomainContext {
    struct SessionRootOverlayPreparation {
        let sessionID: UUID
        let resolvedOverlay: DirectHeadlessRootOverlay
        let previousOverlay: DirectHeadlessRootOverlay?
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
        let rootOverlay: DirectHeadlessRootOverlay
        let prompt: String
        let selection: [String]

        var canonicalRoots: [URL] {
            rootOverlay.mappings.map(\.canonicalRoot)
        }

        var roots: [URL] {
            rootOverlay.mappings.map(\.physicalRoot)
        }

        var activeRoot: URL? {
            rootOverlay.activeRoot
        }
    }

    let runtime: MCPDomainRuntime
    let scopeID: DomainStandaloneScopeID
    private let processRootOverlay: DirectHeadlessRootOverlay
    private var sessionRootOverlays: [UUID: DirectHeadlessRootOverlay] = [:]

    init(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        processRootOverlay: DirectHeadlessRootOverlay = .init(mappings: [], activeRoot: nil)
    ) {
        self.runtime = runtime
        self.scopeID = scopeID
        self.processRootOverlay = processRootOverlay
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
        let rootOverlay = try await resolveRootOverlay(
            canonicalRoots: canonicalRoots,
            sessionID: sessionID
        )
        for mapping in rootOverlay.mappings {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: mapping.physicalRoot.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(mapping.physicalRoot.path)
            }
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
            rootOverlay: rootOverlay,
            prompt: prompt,
            selection: Self.translateSelectionToPhysical(selection, mappings: rootOverlay.mappings)
        )
    }

    func prepareSessionRootOverlay(
        sessionID: UUID,
        sourceSessionID: UUID?,
        arguments: [String: Value],
        connectionID: UUID
    ) async throws -> SessionRootOverlayPreparation {
        let processSnapshot = try await snapshot(connectionID: connectionID)
        let inherits = try Self.parseOptionalBool(
            arguments["inherit_worktree"],
            name: "inherit_worktree"
        ) ?? true
        let selectorIntent = try DirectHeadlessWorktreeRouting.parseSessionSelector(arguments: arguments)
        let inheritedOverlay = inherits
            ? sourceSessionID.flatMap { sessionRootOverlays[$0] }
            : nil
        let baseOverlay = inheritedOverlay ?? processSnapshot.rootOverlay
        let resolved = try await DirectHeadlessWorktreeRouting.resolveSessionOverlay(
            arguments: arguments,
            selectorIntent: selectorIntent,
            canonicalRoots: processSnapshot.canonicalRoots,
            baseOverlay: baseOverlay
        )
        let previousOverlay = sessionRootOverlays.updateValue(resolved, forKey: sessionID)
        let isUnmodifiedInheritance = inheritedOverlay != nil
            && selectorIntent.selector == nil
            && selectorIntent.worktreeID == nil
            && !selectorIntent.create
        let bindingSource = isUnmodifiedInheritance
            ? "direct-headless-inherited-overlay"
            : "direct-headless-session-overlay"
        let bindings = resolved.mappings.compactMap {
            DirectHeadlessWorktreeRouting.binding(mapping: $0, source: bindingSource)
        }
        return SessionRootOverlayPreparation(
            sessionID: sessionID,
            resolvedOverlay: resolved,
            previousOverlay: previousOverlay,
            bindings: bindings
        )
    }

    func rollbackSessionRootOverlay(_ preparation: SessionRootOverlayPreparation) {
        guard sessionRootOverlays[preparation.sessionID] == preparation.resolvedOverlay else { return }
        if let previousOverlay = preparation.previousOverlay {
            sessionRootOverlays[preparation.sessionID] = previousOverlay
        } else {
            sessionRootOverlays.removeValue(forKey: preparation.sessionID)
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
        _ = try await resolveRootOverlay(canonicalRoots: canonicalRoots, sessionID: nil)
    }

    private func resolveRootOverlay(
        canonicalRoots: [URL],
        sessionID: UUID?
    ) async throws -> DirectHeadlessRootOverlay {
        let preferred = sessionID.flatMap { sessionRootOverlays[$0] } ?? processRootOverlay
        let mappings: [DirectHeadlessRootMapping]
        let activeRoot: URL?
        if preferred.mappings.isEmpty {
            mappings = canonicalRoots.map {
                DirectHeadlessRootMapping(
                    canonicalRoot: $0,
                    physicalRoot: $0,
                    worktree: nil,
                    visualLabel: nil,
                    visualColorHex: nil
                )
            }
            activeRoot = mappings.first?.physicalRoot
        } else {
            guard preferred.mappings.count == canonicalRoots.count else { throw Error.rootMappingUnavailable }
            var physicalPaths: Set<String> = []
            mappings = try canonicalRoots.map { canonicalRoot in
                let matches = preferred.mappings.filter {
                    $0.canonicalRoot.standardizedFileURL.resolvingSymlinksInPath().path == canonicalRoot.path
                }
                guard matches.count == 1, let match = matches.first,
                      physicalPaths.insert(match.physicalRoot.path).inserted
                else { throw Error.rootMappingUnavailable }
                return match
            }
            activeRoot = preferred.activeRoot?.standardizedFileURL.resolvingSymlinksInPath()
            guard activeRoot.map({ physicalPaths.contains($0.path) }) == !mappings.isEmpty else {
                throw Error.rootMappingUnavailable
            }
        }
        try await DirectHeadlessWorktreeRouting.verifyMappingsAtUse(mappings)
        return DirectHeadlessRootOverlay(mappings: mappings, activeRoot: activeRoot)
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
            contexts[index]["selectedPaths"] = try Self.translateSelectionToCanonical(
                paths,
                mappings: current.rootOverlay.mappings
            )
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

    private static func parseOptionalBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case let .bool(boolValue):
            return boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                break
            }
        case let .int(intValue):
            return intValue != 0
        case let .double(doubleValue):
            return doubleValue != 0
        default:
            break
        }
        throw MCPError.invalidParams("\(name) must be a boolean.")
    }

    private nonisolated static func translateSelectionToPhysical(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping]
    ) -> [String] {
        translateAbsolutePaths(paths, mappings: mappings, from: \.canonicalRoot, to: \.physicalRoot)
    }

    private nonisolated static func translateSelectionToCanonical(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping]
    ) throws -> [String] {
        try paths.map { rawPath in
            guard rawPath.hasPrefix("/") else { return rawPath }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if let translated = translateAbsolutePathPreservingSuffix(
                path,
                mappings: mappings,
                from: \.physicalRoot,
                to: \.canonicalRoot
            ) {
                return translated
            }
            guard mappings.contains(where: {
                path == $0.canonicalRoot.path || path.hasPrefix($0.canonicalRoot.path + "/")
            }) else {
                throw Error.pathOutsideWorkspace(rawPath)
            }
            return path
        }
    }

    private nonisolated static func translateAbsolutePaths(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> [String] {
        paths.map { rawPath in
            guard rawPath.hasPrefix("/") else { return rawPath }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return translateAbsolutePathPreservingSuffix(
                path,
                mappings: mappings,
                from: source,
                to: destination
            ) ?? rawPath
        }
    }

    private nonisolated static func translateAbsolutePathPreservingSuffix(
        _ path: String,
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> String? {
        if let translated = translateAbsolutePath(path, mappings: mappings, from: source, to: destination) {
            return translated
        }

        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while true {
            let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
            if let mapping = mappings.first(where: { resolvedAncestor == $0[keyPath: source].path }) {
                var translated = mapping[keyPath: destination]
                for component in suffix.reversed() {
                    translated.appendPathComponent(component)
                }
                return translated.standardizedFileURL.path
            }
            guard ancestor.path != "/" else { return nil }
            suffix.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }
    }

    private nonisolated static func translateAbsolutePath(
        _ path: String,
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> String? {
        guard let mapping = mappings
            .filter({ path == $0[keyPath: source].path || path.hasPrefix($0[keyPath: source].path + "/") })
            .max(by: { $0[keyPath: source].path.count < $1[keyPath: source].path.count })
        else { return nil }
        let sourcePath = mapping[keyPath: source].path
        let suffix = String(path.dropFirst(sourcePath.count))
        return mapping[keyPath: destination].path + suffix
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
