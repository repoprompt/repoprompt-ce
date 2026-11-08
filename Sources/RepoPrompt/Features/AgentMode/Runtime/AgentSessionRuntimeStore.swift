import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

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

    /// Admission is distinct from the originating writer capability: final IO must keep its
    /// exact writer while retirement refuses a successor, even with no presentation or registry row.
    func hasRetiringWriter(sessionID: UUID) -> Bool {
        scopes.values.contains { reference in
            guard let scope = reference.value else { return false }
            return scope.isRetiring && !scope.liveSessionTabIDs(for: sessionID).isEmpty
        }
    }

    /// Includes window-free owners and pending operations that keep a scope alive. Neither a
    /// selected window nor writer election may make live files eligible for garbage collection.
    func attachmentSweepProtection() -> (sessionIDs: Set<UUID>, temporaryPaths: Set<String>) {
        var sessionIDs: Set<UUID> = []
        var paths: Set<String> = []
        for scope in scopes.values.compactMap(\.value) {
            let pending = scope.attachments.sweepProtection
            sessionIDs.formUnion(pending.sessionIDs)
            paths.formUnion(pending.temporaryPaths)
            for session in scope.sessions.values {
                if let sessionID = session.activeAgentSessionID { sessionIDs.insert(sessionID) }
                var attachments = session.pendingFileAttachments + session.attachmentsPendingProviderConsumptionCleanup
                switch session.attachmentTurnState {
                case .idle: break
                case let .reserved(_, turnAttachments), let .consumed(_, turnAttachments):
                    attachments.append(contentsOf: turnAttachments)
                }
                paths.formUnion(attachments.compactMap(AgentImageAttachmentAvailabilityResolver.path(for:)))
            }
        }
        return (sessionIDs, paths)
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
        let usage = AgentSessionUsageRuntime()
        lazy var turnTiming = AgentSessionTurnTimingRuntime(presentation: presentation)
        private var interactionRuntime: AgentSessionInteractionRuntime?

        func interactions(routeID: Int, approvalStore: ApplyEditsApprovalStore) -> AgentSessionInteractionRuntime {
            if let interactionRuntime {
                precondition(interactionRuntime.routeID == routeID && interactionRuntime.approvalStore === approvalStore)
                return interactionRuntime
            }
            let runtime = AgentSessionInteractionRuntime(scope: self, routeID: routeID, approvalStore: approvalStore)
            interactionRuntime = runtime
            return runtime
        }

        private(set) var linkExecution: AgentSessionLinkExecutionRuntime?

        func makeLinkExecution(
            commands: AgentSessionLinkExecutionRuntime.Commands,
            diagnostics: any AgentSessionLinkCatalogEventSink
        ) -> AgentSessionLinkExecutionRuntime {
            // Host composition installs once. Presentation attachment must use `linkExecution`,
            // never replace its command authority or reset pending claims/tasks.
            precondition(linkExecution == nil, "Link execution is installed once by its runtime host.")
            let runtime = AgentSessionLinkExecutionRuntime(scope: self, commands: commands, diagnostics: diagnostics)
            linkExecution = runtime
            return runtime
        }

        private var providerInputRuntime: AgentSessionProviderInputRuntime?

        /// Install once from host composition. The legacy VM has an immutable private scope,
        /// catalog and recorder; presentation attachment must reuse this service, not reconfigure it.
        func providerInput(skillCatalog: AgentSkillCatalog, perfRecorder: any AgentModePerfRecording) -> AgentSessionProviderInputRuntime {
            if let providerInputRuntime {
                precondition(providerInputRuntime.skillCatalog === skillCatalog)
                return providerInputRuntime
            }
            let runtime = AgentSessionProviderInputRuntime(skillCatalog: skillCatalog, perfRecorder: perfRecorder)
            providerInputRuntime = runtime
            return runtime
        }

        lazy var observation = AgentSessionObservationRuntime(scope: self)

        /// Construct the actual observed runtime object; UI defaults and saved hydration are
        /// applied by composition before admitting it into this scope's binding index.
        func makeSession(tabID: UUID, perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()) -> AgentTabSession {
            let session = AgentTabSession(tabID: tabID, perfRecorder: perfRecorder)
            observation.install(on: session)
            return session
        }

        lazy var stream = AgentSessionStreamRuntime(scope: self)
        lazy var mcp = AgentSessionMCPRuntime(scope: self)
        lazy var persistence = AgentSessionPersistenceRuntime(scope: self)
        lazy var attachments = AgentSessionAttachmentRuntime(scope: self)
        lazy var handoff = AgentSessionHandoffRuntime(scope: self)
        lazy var drafts = AgentSessionDraftRuntime(scope: self)
        var saveQueue: AgentSessionSaveQueue {
            persistence.queue
        }

        private(set) var isRetiring = false
        private(set) var hasReleasedWriterClaims = false

        /// Called before yielding to teardown. This does not invalidate originating IO tokens.
        func beginRetirement() {
            isRetiring = true
        }

        /// The host has joined provider, interaction and attachment effects and acknowledged
        /// its final save. Release claims explicitly; a retained presentation cannot keep them live.
        @discardableResult
        func releaseWriterClaimsAfterDrain() -> Bool {
            guard isRetiring, saveQueue.inFlightSessionIDs.isEmpty, !attachments.hasPendingRetention,
                  linkExecution?.pendingSendEffects.isEmpty != false,
                  sessions.values.allSatisfy({ session in
                      !session.runState.isActive && session.activeComposerSubmitAttempt == nil
                          && !session.terminalCommitInProgress && (!session.isDirty || session.activeAgentSessionID.map {
                              AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: $0)
                          } == true)
                  }) else { return false }
            replaceSessions([:])
            hasReleasedWriterClaims = true
            return true
        }

        private(set) var sessions: [UUID: AgentTabSession] = [:]
        private var liveClaimByTabID: [UUID: UUID] = [:]
        private var liveTabIDsBySessionID: [UUID: Set<UUID>] = [:]

        fileprivate init(store: AgentSessionRuntimeStore) {
            self.store = store
        }

        func replaceSessions(_ replacement: [UUID: AgentTabSession]) {
            guard !hasReleasedWriterClaims || replacement.isEmpty else { return }
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

        func permitsBinding(_ sessionID: UUID, on session: AgentTabSession) -> Bool {
            if sessions[session.tabID] === session, session.activeAgentSessionID == sessionID {
                return !hasReleasedWriterClaims
            }
            return !isRetiring && !store.hasRetiringWriter(sessionID: sessionID)
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
