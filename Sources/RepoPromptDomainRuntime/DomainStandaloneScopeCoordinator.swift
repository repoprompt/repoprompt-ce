import Foundation

package enum DomainStandaloneScopeError: Error, Equatable, Sendable {
    case unavailableOutsideStandaloneRuntime
    case invalidWorkingDirectory(String)
    case duplicateScope(DomainStandaloneScopeID)
    case unknownScope(DomainStandaloneScopeID)
    case contextUnavailable(DomainContextIdentity)
    case staleConnection
}

package struct DomainStandaloneScopeSnapshot: Sendable {
    package let scopeID: DomainStandaloneScopeID
    package let registration: DomainConnectionRegistration
    package let workingDirectories: [URL]
    package let binding: DomainBinding

    package init(
        scopeID: DomainStandaloneScopeID,
        registration: DomainConnectionRegistration,
        workingDirectories: [URL],
        binding: DomainBinding
    ) {
        self.scopeID = scopeID
        self.registration = registration
        self.workingDirectories = workingDirectories
        self.binding = binding
    }
}

package struct DomainStandaloneBindingCASResult: Sendable {
    package let disposition: DomainRoutingDisposition
    package let snapshot: DomainStandaloneScopeSnapshot
    package let diagnostic: String?

    package init(
        disposition: DomainRoutingDisposition,
        snapshot: DomainStandaloneScopeSnapshot,
        diagnostic: String?
    ) {
        self.disposition = disposition
        self.snapshot = snapshot
        self.diagnostic = diagnostic
    }
}

/// Owns direct-process scope and connection authority without manufacturing an app window.
/// Working directories are validated physical roots used only for deterministic initial binding;
/// subsequent routing is always expressed as a domain context identity.
package actor DomainStandaloneScopeCoordinator {
    private struct ScopeState: Sendable {
        let scopeID: DomainStandaloneScopeID
        let registration: DomainConnectionRegistration
        let workingDirectories: [URL]
    }

    private let identity: DomainRuntimeIdentity
    private let workspaceStore: DomainWorkspaceStore
    private let contextStore: DomainContextStore
    private let routingCoordinator: DomainRoutingCoordinator
    private var scopes: [DomainStandaloneScopeID: ScopeState] = [:]

    init(
        identity: DomainRuntimeIdentity,
        workspaceStore: DomainWorkspaceStore,
        contextStore: DomainContextStore,
        routingCoordinator: DomainRoutingCoordinator
    ) {
        self.identity = identity
        self.workspaceStore = workspaceStore
        self.contextStore = contextStore
        self.routingCoordinator = routingCoordinator
    }

    package func register(
        scopeID: DomainStandaloneScopeID,
        connectionID: UUID,
        workingDirectories: [URL]
    ) async throws -> DomainStandaloneScopeSnapshot {
        guard identity.mode == .standalone else {
            throw DomainStandaloneScopeError.unavailableOutsideStandaloneRuntime
        }
        guard scopes[scopeID] == nil else {
            throw DomainStandaloneScopeError.duplicateScope(scopeID)
        }
        let roots = try Self.validateWorkingDirectories(workingDirectories)
        _ = await routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let registration = try await routingCoordinator.currentRegistration(connectionID: connectionID)
        let state = ScopeState(
            scopeID: scopeID,
            registration: registration,
            workingDirectories: roots
        )
        scopes[scopeID] = state
        await bindInitialContextIfUnambiguous(state)
        return try await snapshot(scopeID: scopeID)
    }

    package func snapshot(scopeID: DomainStandaloneScopeID) async throws -> DomainStandaloneScopeSnapshot {
        guard let state = scopes[scopeID] else {
            throw DomainStandaloneScopeError.unknownScope(scopeID)
        }
        let routing = await routingCoordinator.snapshot()
        return try snapshot(scopeID: scopeID, state: state, routing: routing)
    }

    package func bind(
        scopeID: DomainStandaloneScopeID,
        context: DomainContextIdentity,
        operationID: UUID = UUID()
    ) async throws -> DomainStandaloneScopeSnapshot {
        guard let state = scopes[scopeID] else {
            throw DomainStandaloneScopeError.unknownScope(scopeID)
        }
        guard await contextStore.snapshot(context) != nil else {
            throw DomainStandaloneScopeError.contextUnavailable(context)
        }
        let outcome = await routingCoordinator.bind(
            connection: state.registration,
            binding: .context(context, explicit: true),
            operationID: operationID
        )
        guard outcome.disposition == .applied || outcome.disposition == .unchanged else {
            throw DomainStandaloneScopeError.staleConnection
        }
        return try await snapshot(scopeID: scopeID)
    }

    package func compareAndSetBinding(
        scopeID: DomainStandaloneScopeID,
        expectedBinding: DomainBinding,
        replacement: DomainBinding,
        operationID: UUID = UUID()
    ) async throws -> DomainStandaloneBindingCASResult {
        guard let state = scopes[scopeID] else {
            throw DomainStandaloneScopeError.unknownScope(scopeID)
        }
        let outcome = await routingCoordinator.bind(
            connection: state.registration,
            binding: replacement,
            operationID: operationID,
            expectedBinding: expectedBinding
        )
        let snapshot = try snapshot(scopeID: scopeID, state: state, routing: outcome.snapshot)
        return DomainStandaloneBindingCASResult(
            disposition: outcome.disposition,
            snapshot: snapshot,
            diagnostic: outcome.diagnostic
        )
    }

    package func unbind(
        scopeID: DomainStandaloneScopeID,
        operationID: UUID = UUID()
    ) async throws -> DomainStandaloneScopeSnapshot {
        guard let state = scopes[scopeID] else {
            throw DomainStandaloneScopeError.unknownScope(scopeID)
        }
        let outcome = await routingCoordinator.bind(
            connection: state.registration,
            binding: .unbound,
            operationID: operationID
        )
        guard outcome.disposition == .applied || outcome.disposition == .unchanged else {
            throw DomainStandaloneScopeError.staleConnection
        }
        return try await snapshot(scopeID: scopeID)
    }

    package func unregister(scopeID: DomainStandaloneScopeID) async {
        guard let state = scopes.removeValue(forKey: scopeID) else { return }
        _ = await routingCoordinator.unregisterConnection(
            state.registration,
            operationID: UUID()
        )
    }

    private func snapshot(
        scopeID: DomainStandaloneScopeID,
        state: ScopeState,
        routing: DomainRoutingSnapshot
    ) throws -> DomainStandaloneScopeSnapshot {
        guard let connection = routing.connections.first(where: {
            $0.registration == state.registration
        }) else {
            throw DomainStandaloneScopeError.staleConnection
        }
        return DomainStandaloneScopeSnapshot(
            scopeID: scopeID,
            registration: state.registration,
            workingDirectories: state.workingDirectories,
            binding: connection.binding
        )
    }

    private func bindInitialContextIfUnambiguous(_ state: ScopeState) async {
        let catalog = await workspaceStore.snapshot()
        let requestedRoots = Set(state.workingDirectories.map(\.standardizedFileURL.path))
        let matches = catalog.workspaces.compactMap { workspace -> DomainContextIdentity? in
            let workspaceRoots = Set(workspace.document.metadata.repoPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
            guard requestedRoots == workspaceRoots else { return nil }
            if let activeContextID = workspace.document.metadata.activeContextID,
               workspace.contexts.contains(where: { $0.metadata.identity.contextID == activeContextID })
            {
                return DomainContextIdentity(
                    workspaceID: workspace.document.workspaceID,
                    contextID: activeContextID
                )
            }
            guard workspace.contexts.count == 1 else { return nil }
            return workspace.contexts[0].metadata.identity
        }
        guard matches.count == 1, let context = matches.first else { return }
        _ = await routingCoordinator.bind(
            connection: state.registration,
            binding: .context(context, explicit: false),
            operationID: UUID()
        )
    }

    private static func validateWorkingDirectories(_ directories: [URL]) throws -> [URL] {
        var seen: Set<String> = []
        return try directories.map { candidate in
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(candidate.path)
            }
            guard seen.insert(url.path).inserted else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(candidate.path)
            }
            return url
        }
    }
}
