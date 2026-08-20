import Foundation
import MCP

public enum DomainReadContextRequirement: Equatable, Sendable {
    case workspaceIndependent
    case workspaceOptional
    case workspaceRequired
}

/// The shared provider may execute historically unscoped reads (history, graceful tree/Git
/// fallbacks) without manufacturing a domain identity. Scoped reads carry the exact authority
/// handle and connection consumed by the backend.
public struct DomainReadInvocationContext: Sendable {
    public let invocationID: UUID
    public var handle: DomainReadContextHandle?
    public let connectionID: UUID?
    public let refreshesDomainRouting: Bool

    public init(
        invocationID: UUID = UUID(),
        handle: DomainReadContextHandle?,
        connectionID: UUID?,
        refreshesDomainRouting: Bool = true
    ) {
        self.invocationID = invocationID
        self.handle = handle
        self.connectionID = connectionID
        self.refreshesDomainRouting = refreshesDomainRouting
    }
}

public struct MCPDomainReadSideEffectEmitter: Sendable {
    private let submitOperation: @Sendable (
        _ effectClass: DomainReadSideEffectClass,
        _ operationID: UUID,
        _ fingerprint: String,
        _ waitForCommit: Bool,
        _ operation: @Sendable @escaping () async throws -> Void
    ) async throws -> Void

    public init(
        submit: @Sendable @escaping (
            _ effectClass: DomainReadSideEffectClass,
            _ operationID: UUID,
            _ fingerprint: String,
            _ waitForCommit: Bool,
            _ operation: @Sendable @escaping () async throws -> Void
        ) async throws -> Void
    ) {
        submitOperation = submit
    }

    public func submit(
        effectClass: DomainReadSideEffectClass = .selection,
        operationID: UUID = UUID(),
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) async throws {
        try await submitOperation(effectClass, operationID, fingerprint, false, operation)
    }

    public func submitAndWait(
        effectClass: DomainReadSideEffectClass = .selection,
        operationID: UUID = UUID(),
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) async throws {
        try await submitOperation(effectClass, operationID, fingerprint, true, operation)
    }
}

public struct MCPDomainReadToolBackend: Sendable {
    public typealias Execute = @Sendable (
        _ toolName: String,
        _ context: DomainReadInvocationContext,
        _ arguments: [String: Value],
        _ sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value

    public let execute: Execute

    public init(execute: @escaping Execute) {
        self.execute = execute
    }
}

/// Sole provider/schema implementation for M3 read/discovery families.
///
/// Concrete app and standalone compositions inject physical backends, but both execute the same
/// definitions, cancellation boundaries, scoped authority refresh, and effect revision semantics.
public struct MCPDomainReadToolProvider: Sendable {
    public typealias ResolveContext = @Sendable (
        _ toolName: String,
        _ requirement: DomainReadContextRequirement
    ) async throws -> DomainReadInvocationContext
    public typealias RefreshContext = @Sendable (
        _ handle: DomainReadContextHandle
    ) async throws -> DomainReadContextHandle
    public typealias ReleaseContext = @Sendable (
        _ context: DomainReadInvocationContext
    ) async -> Void

    private let resolveContext: ResolveContext
    private let refreshContext: RefreshContext
    private let releaseContext: ReleaseContext
    private let backend: MCPDomainReadToolBackend
    private let sideEffects: DomainReadSideEffectCoordinator

    public init(
        resolveContext: @escaping ResolveContext,
        refreshContext: @escaping RefreshContext = { $0 },
        releaseContext: @escaping ReleaseContext = { _ in },
        backend: MCPDomainReadToolBackend,
        sideEffects: DomainReadSideEffectCoordinator
    ) {
        self.resolveContext = resolveContext
        self.refreshContext = refreshContext
        self.releaseContext = releaseContext
        self.backend = backend
        self.sideEffects = sideEffects
    }

    public var bindings: [MCPDomainToolBinding] {
        MCPDomainReadToolDefinitions.definitions.map { definition in
            MCPDomainToolBinding(definition: definition) { arguments in
                try await execute(
                    toolName: definition.name,
                    arguments: arguments
                )
            }
        }
    }

    public func binding(named name: String) -> MCPDomainToolBinding? {
        bindings.first { $0.definition.name == name }
    }

    private func execute(
        toolName: String,
        arguments: [String: Value]
    ) async throws -> Value {
        try Task.checkCancellation()
        // Historical parameter failures must win over unrelated routing/workspace failures.
        try validateTopLevelArguments(toolName: toolName, arguments: arguments)
        let requirement = contextRequirement(toolName)
        let context = try await resolveContext(toolName, requirement)
        do {
            try Task.checkCancellation()
            if requirement == .workspaceRequired, context.handle == nil {
                throw MCPError.internalError("Required domain authority is unavailable for \(toolName)")
            }

            let value = try await executeResolved(
                toolName: toolName,
                arguments: arguments,
                context: context
            )
            await releaseContext(context)
            return value
        } catch {
            await releaseContext(context)
            throw error
        }
    }

    private func executeResolved(
        toolName: String,
        arguments: [String: Value],
        context initialContext: DomainReadInvocationContext
    ) async throws -> Value {
        var context = initialContext
        if let handle = context.handle,
           requiresSelectionSideEffectDrain(toolName: toolName, arguments: arguments)
        {
            let revision = try await sideEffects.highWaterRevision(
                for: handle,
                effectClass: .selection
            )
            try await sideEffects.drain(
                handle: handle,
                effectClass: .selection,
                through: revision
            )
        }

        // Refresh solely through the domain actor. This verifies the consumed connection/entity
        // binding and adopts its latest revisions without a second heavyweight MainActor capture.
        if let handle = context.handle,
           context.refreshesDomainRouting
        {
            context.handle = try await refreshContext(handle)
        }
        try Task.checkCancellation()

        let resolvedContext = context
        let emitter = MCPDomainReadSideEffectEmitter { effectClass, operationID, fingerprint, waitForCommit, operation in
            guard let handle = resolvedContext.handle else {
                // Historical unscoped/test execution has no synthetic identity. Commit inline.
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                return
            }
            let receipt: DomainReadSideEffectReceipt
            do {
                receipt = try await sideEffects.submit(
                    handle: handle,
                    effectClass: effectClass,
                    operationID: operationID,
                    fingerprint: fingerprint,
                    operation: operation
                )
            } catch DomainReadSideEffectError.stopped {
                // Runtime shutdown is the cancellation boundary for an in-flight read.
                throw CancellationError()
            }
            if waitForCommit {
                try await sideEffects.wait(handle: handle, receipt: receipt)
            }
        }
        let value = try await backend.execute(toolName, resolvedContext, arguments, emitter)
        try Task.checkCancellation()
        return value
    }

    private func contextRequirement(_ toolName: String) -> DomainReadContextRequirement {
        switch toolName {
        case "history", "oracle_chat_log":
            .workspaceIndependent
        case "get_file_tree", "git":
            .workspaceOptional
        default:
            .workspaceRequired
        }
    }

    private func validateTopLevelArguments(
        toolName: String,
        arguments: [String: Value]
    ) throws {
        switch toolName {
        case "get_code_structure":
            let allowedKeys: Set = ["paths", "expand", "depth", "signatures", "size"]
            guard Set(arguments.keys).isSubset(of: allowedKeys) else {
                throw MCPError.invalidParams("unknown get_code_structure parameter")
            }
        case "read_file":
            guard arguments["path"]?.stringValue != nil else {
                throw MCPError.invalidParams("missing path")
            }
        case "file_search":
            let pattern = arguments["pattern"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pattern.isEmpty else {
                throw MCPError.invalidParams("pattern cannot be empty; provide a non-empty search term. If you intend to enumerate files, use get_file_tree or specify a path mode with a wildcard like '*.swift'.")
            }
        default:
            break
        }
    }

    private func requiresSelectionSideEffectDrain(
        toolName: String,
        arguments: [String: Value]
    ) -> Bool {
        switch toolName {
        case "get_code_structure":
            arguments["paths"] == nil
        case "get_file_tree":
            arguments["mode"]?.stringValue?.lowercased() == "selected"
        case "workspace_context":
            (arguments["op"]?.stringValue ?? "snapshot").lowercased() == "snapshot"
        case "prompt":
            arguments["op"]?.stringValue?.lowercased() == "export"
        case "git":
            arguments["op"]?.stringValue?.lowercased() == "diff"
                && arguments["artifacts"]?.boolValue == true
                && arguments["scope"]?.stringValue?.lowercased() == "selected"
        default:
            false
        }
    }
}
