import Foundation
import MCP

public struct DomainProtectedMutationOperation: Hashable, Sendable {
    public let toolName: String
    public let action: String
}

public enum DomainProtectedMutationError: Error, Equatable, LocalizedError, Sendable {
    case partialSuccessAfterCommit(operationID: String)

    public var errorDescription: String? {
        switch self {
        case let .partialSuccessAfterCommit(operationID):
            "Protected mutation crossed its durable commit boundary but reply settlement was interrupted. Inspect state before retrying operation ID \(operationID)."
        }
    }
}

public struct MCPDomainProtectedMutationToolProvider: Sendable {
    private let policyStore: DomainMutationPolicyStore
    private let journal: DomainMutationJournal

    public init(
        policyStore: DomainMutationPolicyStore,
        journal: DomainMutationJournal
    ) {
        self.policyStore = policyStore
        self.journal = journal
    }

    public func protectedBinding(
        _ binding: MCPDomainToolBinding
    ) -> MCPDomainToolBinding {
        guard Self.isProtectedFamily(binding.definition.name) else {
            return binding
        }
        let definition = binding.definition
        let policyStore = policyStore
        let journal = journal
        return MCPDomainToolBinding(definition: definition) { arguments in
            guard let operation = Self.operation(
                toolName: definition.name,
                arguments: arguments
            ) else {
                return try await binding(arguments)
            }
            guard let securityContext = MCPDomainInvocationSecurityContext.current else {
                throw DomainMutationPolicyError.principalMissing
            }

            if Self.isDurableMutationFamily(operation.toolName) {
                return try await Self.executeDurableMutation(
                    operation: operation,
                    arguments: arguments,
                    securityContext: securityContext,
                    binding: binding,
                    policyStore: policyStore,
                    journal: journal
                )
            }

            let authorization = try await policyStore.authorize(
                context: securityContext,
                toolName: operation.toolName,
                action: operation.action,
                workspaceID: securityContext.workspaceID,
                canonicalRoots: Self.canonicalRoots(
                    operation: operation,
                    arguments: arguments,
                    securityContext: securityContext
                )
            )
            try Task.checkCancellation()
            try await policyStore.revalidate(authorization)
            return try await binding(arguments)
        }
    }

    public static func isProtectedFamily(_ toolName: String) -> Bool {
        [
            "manage_selection", "prompt", "workspace_context", "bind_context", "manage_workspaces",
            "file_actions", "apply_edits", "manage_worktree",
        ].contains(toolName)
    }

    public static func operation(
        toolName: String,
        arguments: [String: Value]
    ) -> DomainProtectedMutationOperation? {
        guard isProtectedFamily(toolName) else { return nil }
        switch toolName {
        case "manage_selection":
            let action = arguments["op"]?.stringValue ?? "get"
            return ["add", "remove", "set", "clear", "promote", "demote"].contains(action)
                ? .init(toolName: toolName, action: action)
                : nil
        case "prompt":
            let action = arguments["op"]?.stringValue ?? "get"
            if ["set", "append", "clear", "select_preset"].contains(action) {
                return .init(toolName: toolName, action: action)
            }
            if action == "export" {
                return .init(toolName: toolName, action: action)
            }
            return nil
        case "workspace_context":
            let action = arguments["op"]?.stringValue ?? "snapshot"
            if action == "select_preset" || action == "export" {
                return .init(toolName: toolName, action: action)
            }
            return nil
        case "bind_context":
            let action = arguments["op"]?.stringValue ?? "list"
            return action == "bind" ? .init(toolName: toolName, action: action) : nil
        case "manage_workspaces":
            let action = arguments["action"]?.stringValue ?? "list"
            return [
                "switch", "create", "hide", "unhide", "delete", "add_folder", "remove_folder",
                "select_tab", "create_tab", "close_tab",
            ].contains(action) ? .init(toolName: toolName, action: action) : nil
        case "file_actions":
            let action = arguments["action"]?.stringValue ?? ""
            return action.isEmpty ? nil : .init(toolName: toolName, action: action)
        case "apply_edits":
            let action: String = if arguments["rewrite"] != nil {
                "rewrite"
            } else if arguments["edits"] != nil {
                "batch"
            } else {
                "replace"
            }
            return .init(toolName: toolName, action: action)
        case "manage_worktree":
            let action = arguments["op"]?.stringValue ?? "list"
            let mutating = ["create", "bind", "select", "unbind", "apply", "continue", "abort"].contains(action)
            let persistsVisuals = ["list", "show"].contains(action)
                && arguments["persist_visuals"]?.boolValue == true
            return mutating || persistsVisuals ? .init(toolName: toolName, action: action) : nil
        default:
            return nil
        }
    }

    private static func executeDurableMutation(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        binding: MCPDomainToolBinding,
        policyStore: DomainMutationPolicyStore,
        journal: DomainMutationJournal
    ) async throws -> Value {
        let effectiveArguments = arguments
        let suppliedOperationID = arguments["operation_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Public operation_id is correlation-only. Journal ownership is keyed exclusively by
        // the server-created request identity so continue/abort/retry remain recoverable.
        let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 }
            ?? securityContext.invocationID.uuidString

        // Authenticate the operation before invoking the physical backend. Exact root scope is
        // authorized again when that backend has translated and resolved the real target.
        let initialAuthorization = try await policyStore.authorize(
            context: securityContext,
            toolName: operation.toolName,
            action: operation.action,
            workspaceID: securityContext.workspaceID,
            canonicalRoots: Self.canonicalRoots(
                operation: operation,
                arguments: effectiveArguments,
                securityContext: securityContext,
                includeAuthoritativeRoots: false
            )
        )
        try Task.checkCancellation()

        let fingerprint = try mutationFingerprint(
            operation: operation,
            arguments: effectiveArguments,
            workspaceID: securityContext.workspaceID,
            pathFence: nil
        )
        let key = "\(operation.toolName).\(operation.action):request:\(securityContext.mutationRequestKey)"
        let begin = try await journal.begin(
            key: key,
            operationID: operationID,
            toolName: operation.toolName,
            action: operation.action,
            fingerprint: fingerprint,
            ownerInvocationID: securityContext.invocationID,
            workspaceID: securityContext.workspaceID,
            workspaceRevision: securityContext.workspaceRevision,
            pathFence: nil
        )
        switch begin {
        case let .replay(result):
            return result
        case let .execute(ticket):
            let commitState = DomainMutationCommitState()
            let admissionState = DomainMutationPhysicalAdmissionState(
                operation: operation,
                securityContext: securityContext,
                initialAuthorization: initialAuthorization,
                requiresPhysicalAdmission: requiresPhysicalAdmission(operation),
                policyStore: policyStore,
                journal: journal,
                ticket: ticket
            )
            let controller = DomainMutationCommitController(
                admitPhysicalTargets: { paths, mappings in
                    try await admissionState.admit(paths: paths, rootMappings: mappings)
                },
                physicalMutationGuard: {
                    guard await commitState.hasBegunCommit() else { return nil }
                    return try await admissionState.physicalMutationGuard()
                },
                willCommit: {
                    try await commitState.beginIfNeeded {
                        try await admissionState.prepareCommit()
                    }
                }
            )
            do {
                let result = try await MCPDomainMutationCommitContext.$controller.withValue(controller) {
                    try await binding(effectiveArguments)
                }
                let didBeginCommit = await commitState.hasBegunCommit()
                if Task.isCancelled, didBeginCommit {
                    try? await detachedFinishIndeterminate(journal: journal, ticket: ticket)
                    throw DomainProtectedMutationError.partialSuccessAfterCommit(operationID: operationID)
                }
                try await detachedFinishApplied(journal: journal, ticket: ticket, result: result)
                return result
            } catch let error as DomainProtectedMutationError {
                throw error
            } catch {
                let didBeginCommit = await commitState.hasBegunCommit()
                if didBeginCommit {
                    try? await detachedFinishIndeterminate(journal: journal, ticket: ticket)
                    throw DomainProtectedMutationError.partialSuccessAfterCommit(operationID: operationID)
                }
                try? await detachedFinishBeforeCommit(
                    journal: journal,
                    ticket: ticket,
                    cancelled: error is CancellationError
                )
                throw error
            }
        }
    }

    private static func isDurableMutationFamily(_ toolName: String) -> Bool {
        ["file_actions", "apply_edits", "manage_worktree", "prompt", "workspace_context"].contains(toolName)
    }

    private static func canonicalRoots(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        includeAuthoritativeRoots: Bool = true
    ) -> Set<String> {
        var roots = includeAuthoritativeRoots ? securityContext.authorizedCanonicalRoots : []
        func insertAbsoluteRoot(_ rawPath: String?) {
            guard let rawPath,
                  let canonical = DomainMutationPathFence.canonicalPath(rawPath)
            else { return }
            roots.insert(canonical)
        }
        if operation.toolName == "manage_workspaces",
           ["add_folder", "create"].contains(operation.action)
        {
            insertAbsoluteRoot(
                arguments["folder_path"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if operation.toolName == "manage_worktree" {
            insertAbsoluteRoot(
                arguments["repo_root"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return roots
    }

    private static func requiresPhysicalAdmission(_ operation: DomainProtectedMutationOperation) -> Bool {
        switch operation.toolName {
        case "file_actions", "apply_edits":
            true
        case "prompt", "workspace_context":
            operation.action == "export"
        case "manage_worktree":
            ["create", "apply", "continue", "abort"].contains(operation.action)
        default:
            false
        }
    }

    private static func mutationFingerprint(
        operation: DomainProtectedMutationOperation,
        arguments: [String: Value],
        workspaceID: UUID?,
        pathFence: DomainMutationPathFenceSnapshot?
    ) throws -> String {
        struct Payload: Encodable {
            let toolName: String
            let action: String
            let arguments: [String: Value]
            let workspaceID: UUID?
            let pathFence: DomainMutationPathFenceSnapshot?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(
            toolName: operation.toolName,
            action: operation.action,
            arguments: arguments,
            workspaceID: workspaceID,
            pathFence: pathFence
        ))
        return DomainContentDigest.sha256(data)
    }

    private static func detachedFinishApplied(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket,
        result: Value
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishApplied(ticket, result: result)
        }.value
    }

    private static func detachedFinishBeforeCommit(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket,
        cancelled: Bool
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishBeforeCommit(ticket, cancelled: cancelled)
        }.value
    }

    private static func detachedFinishIndeterminate(
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await journal.finishIndeterminateAfterCommit(ticket)
        }.value
    }
}

private actor DomainMutationPhysicalAdmissionState {
    private let operation: DomainProtectedMutationOperation
    private let securityContext: DomainToolInvocationSecurityContext
    private let requiresPhysicalAdmission: Bool
    private let policyStore: DomainMutationPolicyStore
    private let journal: DomainMutationJournal
    private let ticket: DomainMutationJournalTicket
    private var authorization: DomainMutationAuthorizationSnapshot
    private var pathFence: DomainMutationPathFenceSnapshot?

    init(
        operation: DomainProtectedMutationOperation,
        securityContext: DomainToolInvocationSecurityContext,
        initialAuthorization: DomainMutationAuthorizationSnapshot,
        requiresPhysicalAdmission: Bool,
        policyStore: DomainMutationPolicyStore,
        journal: DomainMutationJournal,
        ticket: DomainMutationJournalTicket
    ) {
        self.operation = operation
        self.securityContext = securityContext
        self.requiresPhysicalAdmission = requiresPhysicalAdmission
        self.policyStore = policyStore
        self.journal = journal
        self.ticket = ticket
        authorization = initialAuthorization
    }

    func admit(
        paths: [String],
        rootMappings suppliedMappings: [DomainMutationPhysicalRootMapping]
    ) async throws {
        try Task.checkCancellation()
        guard !paths.isEmpty else { throw DomainMutationPathFenceError.scopeUnavailable }
        var mappings = suppliedMappings
        if securityContext.principal.kind == .appProxy,
           securityContext.principal.assurance == .verifiedProcess
        {
            for path in paths where !Self.isCovered(path, by: mappings.map(\.physicalRoot)) {
                if let root = Self.nearestExistingAncestor(of: path) {
                    mappings.append(.init(canonicalRoot: root, physicalRoot: root))
                }
            }
        }
        let matchingMappings = mappings.filter { mapping in
            paths.contains { Self.isContained($0, by: mapping.physicalRoot) }
        }
        guard !matchingMappings.isEmpty else {
            throw DomainMutationPathFenceError.pathOutsideAuthorizedRoots(paths[0])
        }
        let canonicalRoots = Set(matchingMappings.map { Self.standardized($0.canonicalRoot) })
        let physicalRoots = Set(matchingMappings.map { Self.standardized($0.physicalRoot) })
        let authorization = try await policyStore.authorize(
            context: securityContext,
            toolName: operation.toolName,
            action: operation.action,
            workspaceID: securityContext.workspaceID,
            canonicalRoots: canonicalRoots
        )
        let fence = try await DomainMutationPathFence.admit(
            requestedPaths: paths.map(Self.standardized),
            authorizedRoots: physicalRoots
        )
        try await journal.attachPathFence(fence, to: ticket)
        self.authorization = authorization
        pathFence = fence
    }

    func prepareCommit() async throws {
        try Task.checkCancellation()
        if requiresPhysicalAdmission, pathFence == nil {
            throw DomainMutationPathFenceError.scopeUnavailable
        }
        try await policyStore.revalidate(authorization)
        if let pathFence {
            try await DomainMutationPathFence.revalidate(pathFence)
        }
        try await journal.markCommitting(ticket)
    }

    func physicalMutationGuard() throws -> DomainMutationPhysicalCommitGuard? {
        guard let pathFence else {
            if requiresPhysicalAdmission {
                throw DomainMutationPathFenceError.scopeUnavailable
            }
            return nil
        }
        return DomainMutationPhysicalCommitGuard(snapshot: pathFence)
    }

    private static func nearestExistingAncestor(of path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var cursor = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
            guard cursor.path != "/" else { return nil }
            cursor.deleteLastPathComponent()
        }
        return isDirectory.boolValue ? cursor.path : cursor.deletingLastPathComponent().path
    }

    private static func isCovered(_ path: String, by roots: [String]) -> Bool {
        roots.contains { isContained(path, by: $0) }
    }

    private static func isContained(_ path: String, by root: String) -> Bool {
        let path = standardized(path)
        let root = standardized(root)
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
