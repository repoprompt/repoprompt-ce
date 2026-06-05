import Foundation

struct RepoPromptSessionID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct MCPRoutingSessionID: Hashable {
    let rawValue: Int
}

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
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let workspaceSessionController: WorkspaceSessionController
    let selectionCoordinator: WorkspaceSelectionCoordinator
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
        workspaceAccessPolicy: any WorkspaceAccessPolicy,
        platformDependencies: RepoPromptCorePlatformDependencies
    ) {
        self.sessionID = sessionID
        self.routingSessionID = routingSessionID
        self.workspaceRepository = workspaceRepository
        self.workspaceAccessPolicy = workspaceAccessPolicy
        workspaceFileContextStore = WorkspaceFileContextStore(
            fileSystemWatcherFactory: platformDependencies.fileSystemWatcherFactory
        )
        workspaceSearchService = WorkspaceSearchService()
        workspaceSessionController = WorkspaceSessionController(accessPolicy: workspaceAccessPolicy)
        selectionCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: workspaceSessionController,
            store: workspaceFileContextStore
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
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let runtimeSessionRegistry: MCPRuntimeSessionRegistry
    let platformDependencies: RepoPromptCorePlatformDependencies
    private var createdSessions: [RepoPromptSessionID: WeakSession] = [:]
    private var activeSessions: [RepoPromptSessionID: RepoPromptCoreSession] = [:]

    init(
        workspaceRepository: WorkspaceRepository,
        workspaceAccessPolicy: any WorkspaceAccessPolicy,
        runtimeSessionRegistry: MCPRuntimeSessionRegistry,
        platformDependencies: RepoPromptCorePlatformDependencies
    ) {
        self.workspaceRepository = workspaceRepository
        self.workspaceAccessPolicy = workspaceAccessPolicy
        self.runtimeSessionRegistry = runtimeSessionRegistry
        self.platformDependencies = platformDependencies
    }

    func makeEmbeddedSession(routingSessionID: MCPRoutingSessionID) -> RepoPromptCoreSessionHandle {
        let session = RepoPromptCoreSession(
            routingSessionID: routingSessionID,
            workspaceRepository: workspaceRepository,
            workspaceAccessPolicy: workspaceAccessPolicy,
            platformDependencies: platformDependencies
        )
        createdSessions[session.sessionID] = WeakSession(session)
        return RepoPromptCoreSessionHandle(session: session)
    }

    func activate(_ handle: RepoPromptCoreSessionHandle) {
        let session = handle.session
        guard session.lifecycle == .created else { return }
        session.lifecycle = .active
        activeSessions[session.sessionID] = session
        runtimeSessionRegistry.register(session: session)
    }

    func beginDraining(_ handle: RepoPromptCoreSessionHandle) {
        let session = handle.session
        guard session.lifecycle == .active else { return }
        session.lifecycle = .draining
        runtimeSessionRegistry.beginDraining(windowID: session.routingSessionID.rawValue)
    }

    func remove(_ handle: RepoPromptCoreSessionHandle) {
        let session = handle.session
        guard session.lifecycle != .removed else { return }
        runtimeSessionRegistry.remove(windowID: session.routingSessionID.rawValue)
        activeSessions.removeValue(forKey: session.sessionID)
        createdSessions.removeValue(forKey: session.sessionID)
        session.workspaceSessionController.detach()
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
