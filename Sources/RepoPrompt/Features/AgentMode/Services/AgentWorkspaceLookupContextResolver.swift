import Foundation
import RepoPromptWorkspaceCore

enum AgentSessionWorktreeBindingState: Equatable {
    case notApplicable
    case hydrated([AgentSessionWorktreeBinding])
    case unhydrated
    case unavailable

    var bindings: [AgentSessionWorktreeBinding]? {
        guard case let .hydrated(bindings) = self else { return nil }
        return bindings
    }
}

struct AgentWorkspaceLookupContextSource: Equatable {
    let activeAgentSessionID: UUID?
    let worktreeBindingState: AgentSessionWorktreeBindingState

    init(
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingState = worktreeBindingState
    }

    init(
        activeAgentSessionID: UUID?,
        worktreeBindings: [AgentSessionWorktreeBinding]
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings)
        )
    }

    var worktreeBindings: [AgentSessionWorktreeBinding] {
        worktreeBindingState.bindings ?? []
    }

    var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindingState)
        )
    }

    /// Canonical routed contexts have authority without an Agent binding identity.
    var authorityIdentity: AgentWorkspaceLookupContextIdentity? {
        activeAgentSessionID == nil ? nil : identity
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        WorkspaceSessionBindingFingerprint.make(bindings)
    }

    static func worktreeBindingFingerprint(_ state: AgentSessionWorktreeBindingState) -> String {
        switch state {
        case .notApplicable:
            "not-applicable"
        case .unhydrated:
            "unhydrated"
        case .unavailable:
            "unavailable"
        case let .hydrated(bindings):
            WorkspaceSessionBindingFingerprint.make(bindings)
        }
    }
}

struct AgentWorkspaceLookupContextIdentity: Hashable {
    let activeAgentSessionID: UUID?
    let worktreeBindingFingerprint: String
}

enum AgentWorkspaceLookupContextResolver {
    private struct CacheKey: Hashable {
        let storeID: ObjectIdentifier
        let identity: AgentWorkspaceLookupContextIdentity
    }

    private final class ProjectionCache {
        private let limit = 16
        private let lock = NSLock()
        private var contexts: [CacheKey: WorkspaceLookupContext] = [:]
        private var order: [CacheKey] = []

        func context(for key: CacheKey) -> WorkspaceLookupContext? {
            lock.lock()
            defer { lock.unlock() }
            guard let context = contexts[key] else { return nil }
            touch(key)
            return context
        }

        func store(_ context: WorkspaceLookupContext, for key: CacheKey) {
            lock.lock()
            contexts[key] = context
            touch(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                contexts.removeValue(forKey: oldest)
            }
            lock.unlock()
        }

        func removeValue(for key: CacheKey) {
            lock.lock()
            contexts.removeValue(forKey: key)
            order.removeAll { $0 == key }
            lock.unlock()
        }

        private func touch(_ key: CacheKey) {
            order.removeAll { $0 == key }
            order.append(key)
        }
    }

    private static let projectionCache = ProjectionCache()

    static let failClosedLookupContext = WorkspaceLookupContext(
        rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []),
        bindingProjection: nil
    )

    static func requiredLookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceLookupContext {
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        return try await requiredLookupContext(
            source: source,
            visibleRoots: visibleRoots,
            store: store
        )
    }

    static func requiredLookupContext(
        source: AgentWorkspaceLookupContextSource,
        visibleRoots: [WorkspaceRootRef],
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceLookupContext {
        let capturedCanonicalRoots = Set(visibleRoots)
        guard await Set(store.rootRefs(scope: .visibleWorkspace)) == capturedCanonicalRoots else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
        guard let sessionID = source.activeAgentSessionID else {
            return WorkspaceLookupContext(
                rootScope: .validatedSessionBoundWorkspace(
                    canonicalRoots: capturedCanonicalRoots,
                    physicalRoots: []
                ),
                bindingProjection: nil
            )
        }
        guard case let .hydrated(bindings) = source.worktreeBindingState else {
            throw AgentWorkspaceLookupContextResolutionError.unknownBindingState
        }
        guard !bindings.isEmpty else {
            return WorkspaceLookupContext(
                rootScope: .validatedSessionBoundWorkspace(
                    canonicalRoots: capturedCanonicalRoots,
                    physicalRoots: []
                ),
                bindingProjection: nil
            )
        }

        for root in visibleRoots {
            guard let currentRoot = await store.exactRootRef(
                path: root.standardizedFullPath,
                kind: .primaryWorkspace
            ), currentRoot == root else {
                throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
            }
        }
        let visibleRootPaths = Set(visibleRoots.map(\.standardizedFullPath))
        let logicalRootPaths = Set(bindings.compactMap {
            AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0.logicalRootPath)
        })
        let bindingsMapDistinctLogicalRootsToWorktrees = bindings.allSatisfy { binding in
            guard let logicalRootPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(
                binding.logicalRootPath
            ), let worktreeRootPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(
                binding.worktreeRootPath
            ) else { return false }
            return logicalRootPath != worktreeRootPath
        }
        guard logicalRootPaths.count == bindings.count,
              logicalRootPaths.isSubset(of: visibleRootPaths),
              bindingsMapDistinctLogicalRootsToWorktrees
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
        let cacheKey = CacheKey(storeID: ObjectIdentifier(store), identity: source.identity)
        if let cached = projectionCache.context(for: cacheKey) {
            if await canReuseAuthoritativeLookupContext(
                cached,
                source: source,
                visibleRoots: visibleRoots,
                store: store
            ) {
                return cached
            }
            projectionCache.removeValue(for: cacheKey)
        }

        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: bindings,
            visibleRoots: visibleRoots
        ),
            !projection.isEmpty,
            projection.isFullyMaterialized
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        switch await store.rootScopeAvailability(projection.lookupRootScope) {
        case .available:
            let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            projectionCache.store(context, for: cacheKey)
            return context
        case .sessionWorktreeUnavailable:
            projectionCache.removeValue(for: cacheKey)
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
    }

    static func canReuseAuthoritativeLookupContext(
        _ lookupContext: WorkspaceLookupContext,
        source: AgentWorkspaceLookupContextSource,
        visibleRoots suppliedVisibleRoots: [WorkspaceRootRef]? = nil,
        store: WorkspaceFileContextStore
    ) async -> Bool {
        guard !Task.isCancelled,
              let sessionID = source.activeAgentSessionID,
              case let .hydrated(bindings) = source.worktreeBindingState,
              !bindings.isEmpty,
              let projection = lookupContext.bindingProjection,
              projection.sessionID == sessionID,
              projection.isFullyMaterialized,
              lookupContext.rootScope == projection.lookupRootScope,
              AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings)
              == AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(
                  projection.boundRootsForMetadata.map(\.binding)
              )
        else { return false }

        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch {
            return false
        }

        let visibleRoots = if let suppliedVisibleRoots {
            suppliedVisibleRoots
        } else {
            await store.rootRefs(scope: .visibleWorkspace)
        }
        guard !Task.isCancelled else { return false }
        let visibleRootIDsByPath = Dictionary(
            visibleRoots.map { ($0.standardizedFullPath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        guard Set(projection.visibleLogicalRootRefs) == Set(visibleRoots) else {
            return false
        }
        guard projection.logicalRootRefs.allSatisfy({ visibleRootIDsByPath[$0.standardizedFullPath] == $0.id }) else {
            return false
        }

        let sessionRootSnapshot = await store.sessionBoundRootScopeValidationSnapshot(
            projection.lookupRootScope,
            expectedPhysicalRoots: projection.physicalRootRefs
        )
        guard !Task.isCancelled, let sessionRootSnapshot else { return false }
        return sessionRootSnapshot.isGenerationCurrent()
    }

    static func authoritativeLookupContextOrFailClosed(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        do {
            return try await requiredLookupContext(source: source, store: store)
        } catch {
            return failClosedLookupContext
        }
    }

    /// Permissive resolution is reserved for non-authoritative UI consumers.
    static func lookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        let startMS = AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        var fields: [String: String] = [
            "activeAgentSessionID": AgentSelectedFilesDiagnostics.shortID(source.activeAgentSessionID),
            "bindingState": String(describing: source.worktreeBindingState),
            "bindingCount": String(source.worktreeBindings.count),
            "bindingFingerprint": String(source.identity.worktreeBindingFingerprint.prefix(16))
        ]
        AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).event("lookupResolver.lookupContext.start", fields: fields)
        guard let sessionID = source.activeAgentSessionID,
              case let .hydrated(bindings) = source.worktreeBindingState,
              !bindings.isEmpty
        else {
            fields["result"] = "visibleWorkspace"
            AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
            return WorkspaceLookupContext.visibleWorkspace
        }

        let cacheKey = CacheKey(storeID: ObjectIdentifier(store), identity: source.identity)
        if let cached = projectionCache.context(for: cacheKey) {
            if await canReuseAuthoritativeLookupContext(cached, source: source, store: store) {
                fields["result"] = "cachedProjection"
                fields["physicalRoots"] = String(cached.bindingProjection?.physicalRootRefs.count ?? 0)
                fields["fullyMaterialized"] = String(cached.bindingProjection?.isFullyMaterialized ?? false)
                AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
                return cached
            }
            projectionCache.removeValue(for: cacheKey)
        }

        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: bindings
        ),
            !projection.isEmpty
        else {
            fields["result"] = "visibleWorkspace"
            AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
            return WorkspaceLookupContext.visibleWorkspace
        }
        fields["result"] = "projection"
        fields["physicalRoots"] = String(projection.physicalRootRefs.count)
        fields["fullyMaterialized"] = String(projection.isFullyMaterialized)
        AgentSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent("lookupResolver.lookupContext", startMS: startMS, fields: fields)
        let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        projectionCache.store(context, for: cacheKey)
        return context
    }
}

typealias AgentWorkspaceLookupContextResolutionError = WorkspaceLookupContextResolutionError
