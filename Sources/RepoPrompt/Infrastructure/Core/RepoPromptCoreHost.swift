import Foundation
import RepoPromptCore

// Phase 1 compatibility aliases. Remove when the host/session implementation moves to Core.
typealias RepoPromptSessionID = RepoPromptCore.RepoPromptSessionID
typealias MCPRoutingSessionID = RepoPromptCore.MCPRoutingSessionID

enum RepoPromptCoreSessionLifecycle: String {
    case created
    case active
    case draining
    case removed
}

struct RepoPromptSessionSnapshot {
    let sessionID: RepoPromptSessionID
    let routingSessionID: MCPRoutingSessionID
    let lifecycle: RepoPromptCoreSessionLifecycle
}

@MainActor
final class RepoPromptCoreSessionHandle {
    let session: RepoPromptCoreSession

    var sessionID: RepoPromptSessionID {
        session.sessionID
    }

    var routingSessionID: MCPRoutingSessionID {
        session.routingSessionID
    }

    var snapshot: RepoPromptSessionSnapshot {
        session.snapshot
    }

    fileprivate init(session: RepoPromptCoreSession) {
        self.session = session
    }
}

@MainActor
final class RepoPromptCoreSession {
    let sessionID: RepoPromptSessionID
    let routingSessionID: MCPRoutingSessionID
    let workspaceRepository: WorkspaceRepository
    let workspacePersistenceWriter: WorkspacePersistenceWriter
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let workspaceSessionController: WorkspaceSessionController
    let workspaceSelectionController: WorkspaceSelectionController
    let selectionSliceCoordinator: SelectionSliceCoordinator
    fileprivate(set) var lifecycle: RepoPromptCoreSessionLifecycle = .created

    var snapshot: RepoPromptSessionSnapshot {
        RepoPromptSessionSnapshot(
            sessionID: sessionID,
            routingSessionID: routingSessionID,
            lifecycle: lifecycle
        )
    }

    init(
        sessionID: RepoPromptSessionID = RepoPromptSessionID(),
        routingSessionID: MCPRoutingSessionID,
        workspaceRepository: WorkspaceRepository,
        workspacePersistenceWriter: WorkspacePersistenceWriter,
        workspaceAccessPolicy: any WorkspaceAccessPolicy,
        runtime: RepoPromptEmbeddedWorkspaceRuntime
    ) {
        self.sessionID = sessionID
        self.routingSessionID = routingSessionID
        self.workspaceRepository = workspaceRepository
        self.workspacePersistenceWriter = workspacePersistenceWriter
        self.workspaceAccessPolicy = workspaceAccessPolicy
        workspaceFileContextStore = runtime.workspaceFileContextStore
        workspaceSearchService = runtime.workspaceSearchService
        selectionSliceCoordinator = runtime.selectionSliceCoordinator
        let sessionController = WorkspaceSessionController(
            repository: workspaceRepository,
            persistenceWriter: workspacePersistenceWriter,
            accessPolicy: workspaceAccessPolicy
        )
        workspaceSessionController = sessionController
        workspaceSelectionController = WorkspaceSelectionController(
            sessionController: sessionController,
            mutationService: runtime.selectionMutationService
        )
    }
}

@MainActor
final class RepoPromptCoreHost {
    private final class WeakSession {
        weak var value: RepoPromptCoreSession?

        init(_ value: RepoPromptCoreSession) {
            self.value = value
        }
    }

    let workspaceRepository: WorkspaceRepository
    let workspacePersistenceWriter: WorkspacePersistenceWriter
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let runtimeSessionRegistry: MCPRuntimeSessionRegistry
    let runtimeFactory: RepoPromptEmbeddedWorkspaceRuntimeFactory
    private var createdSessions: [RepoPromptSessionID: WeakSession] = [:]
    private var activeSessions: [RepoPromptSessionID: RepoPromptCoreSession] = [:]

    init(
        workspaceRepository: WorkspaceRepository,
        workspacePersistenceWriter: WorkspacePersistenceWriter,
        workspaceAccessPolicy: any WorkspaceAccessPolicy,
        runtimeSessionRegistry: MCPRuntimeSessionRegistry,
        runtimeFactory: RepoPromptEmbeddedWorkspaceRuntimeFactory
    ) {
        self.workspaceRepository = workspaceRepository
        self.workspacePersistenceWriter = workspacePersistenceWriter
        self.workspaceAccessPolicy = workspaceAccessPolicy
        self.runtimeSessionRegistry = runtimeSessionRegistry
        self.runtimeFactory = runtimeFactory
    }

    func makeEmbeddedSession(routingSessionID: MCPRoutingSessionID) -> RepoPromptCoreSessionHandle {
        let runtime = runtimeFactory.makeRuntime()
        let session = RepoPromptCoreSession(
            routingSessionID: routingSessionID,
            workspaceRepository: workspaceRepository,
            workspacePersistenceWriter: workspacePersistenceWriter,
            workspaceAccessPolicy: workspaceAccessPolicy,
            runtime: runtime
        )
        createdSessions[session.sessionID] = WeakSession(session)
        return RepoPromptCoreSessionHandle(session: session)
    }

    @discardableResult
    func activate(_ handle: RepoPromptCoreSessionHandle) -> Bool {
        let session = handle.session
        guard session.lifecycle == .created else { return session.lifecycle == .active }
        let registration = runtimeSessionRegistry.register(session: session)
        guard registration == .accepted || registration == .alreadyRegistered else {
            return false
        }
        session.lifecycle = .active
        activeSessions[session.sessionID] = session
        return true
    }

    func beginDraining(_ handle: RepoPromptCoreSessionHandle) {
        let session = handle.session
        guard session.lifecycle == .active else { return }
        guard runtimeSessionRegistry.beginDraining(
            windowID: session.routingSessionID.rawValue,
            expectedSessionID: session.sessionID
        ) else {
            return
        }
        session.lifecycle = .draining
    }

    func remove(_ handle: RepoPromptCoreSessionHandle) {
        let session = handle.session
        guard session.lifecycle != .removed else { return }
        _ = runtimeSessionRegistry.remove(
            windowID: session.routingSessionID.rawValue,
            expectedSessionID: session.sessionID
        )
        activeSessions.removeValue(forKey: session.sessionID)
        createdSessions.removeValue(forKey: session.sessionID)
        session.lifecycle = .removed
    }

    func activeSessionHandles() -> [RepoPromptCoreSessionHandle] {
        runtimeSessionRegistry.sessions(includeDraining: true).map(RepoPromptCoreSessionHandle.init(session:))
    }

    func shutdownForAppTermination() {
        let handles = activeSessionHandles()
        for handle in handles {
            beginDraining(handle)
        }
        for handle in handles {
            remove(handle)
        }
    }
}
