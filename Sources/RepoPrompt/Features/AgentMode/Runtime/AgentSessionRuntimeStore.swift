import Foundation
import RepoPromptDomainRuntime

/// Process-owned live-object authority. Scopes retain objects; the store keeps weak scope
/// references so presentation disposal cannot leave phantom claims. A runtime host can retain
/// the same scope independently of its presentation. Neither registration nor run lifecycle
/// is duplicated here: those remain with the domain store and attempt/terminal owners.
@MainActor
final class AgentSessionRuntimeStore {
    static let shared = AgentSessionRuntimeStore()

    enum Unavailable: Equatable {
        case absent, unscopedBinding, bindingTransition
    }

    enum WriterResolution {
        case unavailable(Unavailable)
        case unique(Writer)
        case conflicting
    }

    /// Exact-object capability. Holding one keeps its scope alive across suspension; it does
    /// not grant consent, bypass restoration, or survive replacement/rebinding in the store.
    @MainActor
    struct Writer {
        let scope: Scope
        let session: AgentTabSession
        let binding: AgentPersistentSessionBindingIdentity
        let restoration: AgentSessionRestorationBindingToken

        var isCurrent: Bool {
            guard let workspaceID = binding.workspaceID,
                  case let .unique(current) = scope.store.resolveWriter(workspaceID: workspaceID, sessionID: binding.sessionID)
            else { return false }
            return current.scope === scope && current.session === session
                && current.binding == binding && current.restoration == restoration
        }
    }

    private struct WeakScope {
        weak var value: Scope?
    }

    private var scopes: [UUID: WeakScope] = [:]

    func makeScope() -> Scope {
        scopes = scopes.filter { $0.value.value != nil }
        let scope = Scope(store: self)
        scopes[scope.id] = WeakScope(value: scope)
        return scope
    }

    /// UI replicas never enter this store. Multiple live claims remain conflicts even when
    /// their metadata agrees; a selected tab/window is not a tie breaker.
    func resolveWriter(workspaceID: UUID, sessionID: UUID) -> WriterResolution {
        var match: (Scope, AgentTabSession)?
        for reference in scopes.values {
            guard let scope = reference.value else { continue }
            for tabID in scope.liveSessionTabIDs(for: sessionID) {
                guard let session = scope.sessions[tabID], session.activeAgentSessionID == sessionID else { continue }
                guard match == nil else { return .conflicting }
                match = (scope, session)
            }
        }
        guard let (scope, session) = match, let binding = session.persistentSessionBindingIdentity else {
            return .unavailable(.absent)
        }
        guard let boundWorkspaceID = binding.workspaceID else { return .unavailable(.unscopedBinding) }
        guard boundWorkspaceID == workspaceID else { return .conflicting }
        guard !session.bindingTransitionInProgress, let restoration = session.currentRestorationBindingToken else {
            return .unavailable(.bindingTransition)
        }
        return .unique(Writer(scope: scope, session: session, binding: binding, restoration: restoration))
    }

    private func refreshBindingObservation(for session: AgentTabSession) {
        let owners = scopes.values.compactMap(\.value).filter { $0.sessions[session.tabID] === session }
        guard !owners.isEmpty else {
            session.persistentSessionBindingDidChange = nil
            return
        }
        session.persistentSessionBindingDidChange = { [weak self, weak session] in
            guard let self, let session else { return }
            for reference in scopes.values {
                guard let scope = reference.value, scope.sessions[session.tabID] === session else { continue }
                scope.updateLiveSessionBindingIndex(tabID: session.tabID)
            }
        }
    }

    /// A lifetime scope, not a window. Only this scope stores its live objects and reverse
    /// binding index. Presentation publishes around replacement, not from this authority.
    @MainActor
    final class Scope {
        fileprivate let id = UUID()
        fileprivate let store: AgentSessionRuntimeStore
        let presentation = AgentSessionPresentationRuntime()
        lazy var persistence = AgentSessionPersistenceRuntime(scope: self)
        var saveQueue: AgentSessionSaveQueue {
            persistence.queue
        }

        private(set) var sessions: [UUID: AgentTabSession] = [:]
        private var liveClaimByTabID: [UUID: UUID] = [:]
        private var liveTabIDsBySessionID: [UUID: Set<UUID>] = [:]

        fileprivate init(store: AgentSessionRuntimeStore) {
            self.store = store
        }

        func replaceSessions(_ replacement: [UUID: AgentTabSession]) {
            let previous = sessions
            sessions = replacement
            for (tabID, session) in previous where sessions[tabID] !== session {
                store.refreshBindingObservation(for: session)
                updateLiveSessionBindingIndex(tabID: tabID)
            }
            for (tabID, session) in sessions where previous[tabID] !== session {
                store.refreshBindingObservation(for: session)
                updateLiveSessionBindingIndex(tabID: tabID)
            }
        }

        func resolveWriter(workspaceID: UUID, sessionID: UUID) -> WriterResolution {
            store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID)
        }

        func liveSessionTabIDs(for sessionID: UUID) -> Set<UUID> {
            liveTabIDsBySessionID[sessionID] ?? []
        }

        fileprivate func updateLiveSessionBindingIndex(tabID: UUID) {
            if let previous = liveClaimByTabID.removeValue(forKey: tabID) {
                liveTabIDsBySessionID[previous]?.remove(tabID)
                if liveTabIDsBySessionID[previous]?.isEmpty == true {
                    liveTabIDsBySessionID.removeValue(forKey: previous)
                }
            }
            if let current = sessions[tabID]?.activeAgentSessionID {
                liveClaimByTabID[tabID] = current
                liveTabIDsBySessionID[current, default: []].insert(tabID)
            }
        }
    }
}
