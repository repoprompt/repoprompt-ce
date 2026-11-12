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

    enum BindingRejection: Equatable {
        case conflictingWriter, retiring
    }

    enum WriterResolution {
        case unavailable(Unavailable)
        case unique(Writer)
        case conflicting
    }

    /// Value identity carried by commands, queries and acknowledgements. The scope identifies
    /// the owner; the claim incarnation also fences object replacement and claim reacquisition.
    struct WriterIdentity: Equatable {
        let scopeID: UUID
        let incarnationID: UUID
        let workspaceID: UUID
        let restoration: AgentSessionRestorationBindingToken

        var sessionID: UUID {
            restoration.bindingIdentity.sessionID
        }
    }

    struct Query {
        let identity: WriterIdentity
        let runState: AgentSessionRunState
        let commandRejection: CommandRejection?
    }

    enum CommandRequirement {
        case restored
        case creation(AgentSessionCreationHandle)
    }

    enum CommandRejection: Error, Equatable {
        case staleWriter, retiring, deleted, restorationUnavailable
    }

    /// Admission is not authorization. Callers retain their existing consent, operation and
    /// cancellation fences and must revalidate this capability after every suspension.
    @MainActor
    struct Command {
        let writer: Writer
        let requirement: CommandRequirement
        var identity: WriterIdentity {
            writer.identity
        }

        var isCurrent: Bool {
            writer.commandRejection(requirement) == nil
        }
    }

    /// Persistent tasks remember their admitted writer without retaining the scope through its
    /// session/task graph. This is not new admission and cannot adopt a replacement writer.
    @MainActor
    struct WriterReceipt {
        enum Disposition {
            case current, ownedSuspended, claimLost
        }

        private weak var scope: Scope?
        private let identity: WriterIdentity

        init?(_ command: Command) {
            guard case .restored = command.requirement else { return nil }
            scope = command.writer.scope
            identity = command.identity
        }

        func disposition(for session: AgentTabSession) -> Disposition {
            guard let writer = scope?.originatingWriter(identity: identity, session: session) else {
                return .claimLost
            }
            if case .success = writer.admitCommand(.restored) { return .current }
            return .ownedSuspended
        }
    }

    /// Exact-object capability. Holding one keeps its scope alive across suspension; it does
    /// not grant consent, bypass restoration, or survive replacement/rebinding in the store.
    @MainActor
    struct Writer {
        let scope: Scope
        let session: AgentTabSession
        let binding: AgentPersistentSessionBindingIdentity
        let restoration: AgentSessionRestorationBindingToken
        let identity: WriterIdentity

        func query() -> Query? {
            guard isCurrent else { return nil }
            return Query(identity: identity, runState: session.runState, commandRejection: commandRejection(.restored))
        }

        func admitCommand(_ requirement: CommandRequirement = .restored) -> Result<Command, CommandRejection> {
            if let rejection = commandRejection(requirement) { return .failure(rejection) }
            return .success(Command(writer: self, requirement: requirement))
        }

        fileprivate func commandRejection(_ requirement: CommandRequirement) -> CommandRejection? {
            guard isCurrent else { return .staleWriter }
            guard !scope.isRetiring else { return .retiring }
            guard !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: binding.sessionID),
                  !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: binding.sessionID)
            else { return .deleted }
            guard !scope.isAwaitingWorkspaceAdoption else { return .restorationUnavailable }
            switch requirement {
            case .restored:
                guard session.permitsBoundOperationAndSave else { return .restorationUnavailable }
            case let .creation(handle):
                guard session.creationHandleIsCurrent(handle) else { return .restorationUnavailable }
            }
            return nil
        }

        /// Originating teardown may run while binding preparation has suspended command
        /// admission. It still belongs to this exact, exclusive claim, never a reacquisition.
        /// This is not permission to publish control or start another operation.
        var ownsPersistentClaim: Bool {
            scope.holdsSlot(session: session, incarnationID: identity.incarnationID, binding: binding)
                && !scope.store.hasOtherClaim(sessionID: binding.sessionID, scope: scope, session: session)
        }

        var isCurrent: Bool {
            guard let workspaceID = binding.workspaceID,
                  case let .unique(current) = scope.store.resolveWriter(workspaceID: workspaceID, sessionID: binding.sessionID)
            else { return false }
            return current.scope === scope && current.session === session
                && current.identity == identity
        }
    }

    /// Provenance for binding preparation, including an unbound local draft. This is not a
    /// restored command or permission to save. Keeping it across an await cannot adopt a
    /// remove/re-add of the same object, even when its persistent binding is unchanged.
    /// Reference-free provenance for long-lived projections. This is not command authority.
    struct MembershipIdentity: Equatable {
        fileprivate let scopeID: UUID
        fileprivate let incarnationID: UUID
        fileprivate let binding: AgentPersistentSessionBindingIdentity?
    }

    @MainActor
    struct Membership {
        fileprivate let scope: Scope
        fileprivate let session: AgentTabSession
        fileprivate let incarnationID: UUID
        fileprivate let binding: AgentPersistentSessionBindingIdentity?

        var identity: MembershipIdentity {
            .init(scopeID: scope.id, incarnationID: incarnationID, binding: binding)
        }

        var isCurrent: Bool {
            scope.holdsSlot(session: session, incarnationID: incarnationID, binding: binding)
        }

        /// New binding work needs exclusive ownership; originating transition cleanup may
        /// still use isCurrent while retirement or a conflicting claim blocks new work.
        var permitsBindingPreparation: Bool {
            isCurrent && !scope.isRetiring && !scope.isAwaitingWorkspaceAdoption
                && !scope.store.scopes.values.contains { reference in
                    guard let other = reference.value, other !== scope else { return false }
                    return other.sessions[session.tabID] === session
                }
                && (binding.map { !scope.store.hasOtherClaim(sessionID: $0.sessionID, scope: scope, session: session) } ?? true)
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
        resolveWriter(sessionID: sessionID, expectedWorkspaceID: workspaceID)
    }

    func resolveWriter(sessionID: UUID, expectedWorkspaceID: UUID? = nil) -> WriterResolution {
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
        if let expectedWorkspaceID, boundWorkspaceID != expectedWorkspaceID { return .conflicting }
        guard !session.bindingTransitionInProgress, let restoration = session.currentRestorationBindingToken else {
            return .unavailable(.bindingTransition)
        }
        guard let incarnationID = scope.liveClaimByTabID[session.tabID]?.incarnationID else { return .unavailable(.absent) }
        return .unique(Writer(
            scope: scope, session: session, binding: binding, restoration: restoration,
            identity: WriterIdentity(scopeID: scope.id, incarnationID: incarnationID, workspaceID: boundWorkspaceID, restoration: restoration)
        ))
    }

    private func hasOtherClaim(sessionID: UUID, scope: Scope, session: AgentTabSession) -> Bool {
        scopes.values.contains { reference in
            guard let owner = reference.value else { return false }
            return owner.liveSessionTabIDs(for: sessionID).contains { tabID in
                owner !== scope || owner.sessions[tabID] !== session
            }
        }
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
            session.workspaceAdoptionPending = { false }
            return
        }
        // Read through the actual holders without retaining their session/scope graphs. Multiple
        // claims remain conflicts; none can hide another holder's negative readiness fence.
        let references = owners.map { WeakScope(value: $0) }
        session.workspaceAdoptionPending = {
            references.contains { $0.value?.isAwaitingWorkspaceAdoption == true }
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

        func resolveWriter(sessionID: UUID, expectedWorkspaceID: UUID? = nil) -> WriterResolution {
            store.resolveWriter(sessionID: sessionID, expectedWorkspaceID: expectedWorkspaceID)
        }

        /// Reconstitute an originating receipt from its stored value identity, never from
        /// today's occupant. Binding preparation may drain this claim; admission still uses
        /// Writer.isCurrent and admitCommand. No claim is created by this lookup.
        func originatingWriter(identity: WriterIdentity, session: AgentTabSession) -> Writer? {
            guard identity.scopeID == id,
                  identity.restoration.bindingIdentity == session.persistentSessionBindingIdentity else { return nil }
            let writer = Writer(
                scope: self, session: session, binding: identity.restoration.bindingIdentity,
                restoration: identity.restoration, identity: identity
            )
            return writer.ownsPersistentClaim ? writer : nil
        }

        /// Resource cleanup must recognize the structural installation holder even when raw
        /// conflicting claims make every writer unavailable. This is not command admission.
        /// Copies of a context do not become holders merely by naming the same receipts.
        func hasOtherControlResourceHolder(_ context: AgentMCPControlContext, excluding session: AgentTabSession) -> Bool {
            store.scopes.values.contains { reference in
                guard let owner = reference.value else { return false }
                return owner.sessions.values.contains { candidate in
                    guard owner !== self || candidate !== session,
                          let installed = candidate.mcpControlContext,
                          installed.writerIdentity.scopeID == owner.id,
                          installed.writerIdentity.restoration.bindingIdentity.tabID == candidate.tabID,
                          owner.liveClaimByTabID[candidate.tabID]?.incarnationID == installed.writerIdentity.incarnationID
                    else { return false }
                    return installed.registration == context.registration
                        || (context.autoEditOverride != nil && installed.autoEditOverride == context.autoEditOverride)
                }
            }
        }

        /// Read provenance is not command admission. The installed control receipt remains
        /// readable while its exact claim is suspended or another claim makes writes ambiguous.
        /// A real binding install or release/reacquire rotates the claim and invalidates it.
        func matchesControlReadIdentity(_ identity: WriterIdentity, session: AgentTabSession) -> Bool {
            identity.scopeID == id && !hasReleasedWriterClaims
                && sessions[session.tabID] === session
                && session.persistentSessionBindingIdentity == identity.restoration.bindingIdentity
                && session.persistentSessionBindingIdentity?.workspaceID == identity.workspaceID
                && liveClaimByTabID[session.tabID]?.sessionID == identity.sessionID
                && liveClaimByTabID[session.tabID]?.incarnationID == identity.incarnationID
        }

        let presentation = AgentSessionPresentationRuntime()
        var detachedNotificationCleanup: (@Sendable () -> Void)?

        deinit {
            detachedNotificationCleanup?()
        }

        let usage = AgentSessionUsageRuntime()
        lazy var turnTiming = AgentSessionTurnTimingRuntime(presentation: presentation)
        lazy var submissions = AgentSessionComposerSubmitRuntime(scope: self)
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

        private(set) var execution: AgentModeRunService?

        func installExecution(_ execution: AgentModeRunService) {
            precondition(self.execution == nil, "Execution is installed once by its runtime host.")
            self.execution = execution
        }

        #if DEBUG
            func test_replaceExecution(_ execution: AgentModeRunService) {
                precondition(sessions.values.allSatisfy { $0.activeRunOwnership == nil })
                self.execution = execution
            }
        #endif

        var installedInteractions: AgentSessionInteractionRuntime? {
            interactionRuntime
        }

        private(set) var linkExecution: AgentSessionLinkExecutionRuntime?

        func makeLinkExecution(
            routeID: Int,
            commands: AgentSessionLinkExecutionRuntime.Commands,
            diagnostics: any AgentSessionLinkCatalogEventSink
        ) -> AgentSessionLinkExecutionRuntime {
            // Host composition installs once. Presentation attachment must use `linkExecution`,
            // never replace its command authority or reset pending claims/tasks.
            precondition(linkExecution == nil, "Link execution is installed once by its runtime host.")
            let runtime = AgentSessionLinkExecutionRuntime(scope: self, routeID: routeID, commands: commands, diagnostics: diagnostics)
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
        lazy var startup = AgentSessionRunStartRuntime(scope: self)
        lazy var continuation = AgentSessionRunContinuationRuntime(scope: self)

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
        lazy var administration = AgentSessionAdministrationRuntime(scope: self)
        lazy var worktrees = AgentSessionWorktreeRuntime(scope: self)
        lazy var drafts = AgentSessionDraftRuntime(scope: self)
        var saveQueue: AgentSessionSaveQueue {
            persistence.queue
        }

        /// The host fences readiness synchronously when destructive owner adoption is queued,
        /// and releases it only after that adoption's discard slice (or its own abandoned exit).
        private(set) var isAwaitingWorkspaceAdoption = false

        func setWorkspaceAdoptionPending(_ pending: Bool) {
            isAwaitingWorkspaceAdoption = pending
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
                  worktrees.pendingTransitions == 0,
                  !continuation.hasPendingStarts,
                  linkExecution?.pendingSendEffects.isEmpty != false,
                  linkExecution?.pendingStopEffects.isEmpty != false,
                  sessions.values.allSatisfy({ settlement(for: $0).legacyDrainCanRelease }) else { return false }
            replaceSessions([:])
            hasReleasedWriterClaims = true
            return true
        }

        /// Per-session release under the existing scope retirement fence. The host must first
        /// join provider/domain teardown and acknowledge the final save; timeout is not a receipt.
        /// A sibling's effects never release or block this exact object's claim. This primitive
        /// has no VM caller until host cutover; presentation removal/publication belongs to that host.
        @discardableResult
        func releaseWriterClaim(for session: AgentTabSession) -> Bool {
            guard isRetiring, settlement(for: session).isSettled else { return false }
            var remaining = sessions
            remaining.removeValue(forKey: session.tabID)
            releasedSessionTabIDs.insert(session.tabID)
            replaceSessions(remaining)
            return true
        }

        private(set) var sessions: [UUID: AgentTabSession] = [:]
        private var releasedSessionTabIDs: Set<UUID> = []
        fileprivate struct LiveClaim {
            let sessionID: UUID?
            let incarnationID = UUID()
        }

        fileprivate var liveClaimByTabID: [UUID: LiveClaim] = [:]
        private var liveTabIDsBySessionID: [UUID: Set<UUID>] = [:]

        fileprivate init(store: AgentSessionRuntimeStore) {
            self.store = store
        }

        func replaceSessions(_ replacement: [UUID: AgentTabSession]) {
            guard !hasReleasedWriterClaims || replacement.isEmpty else { return }
            let previous = sessions
            sessions = replacement.filter { !releasedSessionTabIDs.contains($0.key) }
            for (tabID, session) in previous where sessions[tabID] !== session {
                store.refreshBindingObservation(for: session)
                updateLiveSessionBindingIndex(tabID: tabID)
            }
            for (tabID, session) in sessions where previous[tabID] !== session {
                store.refreshBindingObservation(for: session)
                updateLiveSessionBindingIndex(tabID: tabID)
            }
            presentation.refreshDetachedState()
        }

        fileprivate func holdsSlot(session: AgentTabSession, incarnationID: UUID, binding: AgentPersistentSessionBindingIdentity?) -> Bool {
            !hasReleasedWriterClaims && sessions[session.tabID] === session
                && liveClaimByTabID[session.tabID]?.incarnationID == incarnationID
                && session.persistentSessionBindingIdentity == binding
        }

        func holds(_ identity: MembershipIdentity, for session: AgentTabSession) -> Bool {
            identity.scopeID == id && holdsSlot(session: session, incarnationID: identity.incarnationID, binding: identity.binding)
        }

        func membership(of session: AgentTabSession) -> Membership? {
            guard !hasReleasedWriterClaims, sessions[session.tabID] === session,
                  let claim = liveClaimByTabID[session.tabID] else { return nil }
            return Membership(scope: self, session: session, incarnationID: claim.incarnationID, binding: session.persistentSessionBindingIdentity)
        }

        func bindingRejection(_ sessionID: UUID, on session: AgentTabSession) -> BindingRejection? {
            guard !store.hasOtherClaim(sessionID: sessionID, scope: self, session: session) else { return .conflictingWriter }
            if sessions[session.tabID] === session, session.activeAgentSessionID == sessionID {
                return hasReleasedWriterClaims ? .retiring : nil
            }
            return isRetiring || store.hasRetiringWriter(sessionID: sessionID) ? .retiring : nil
        }

        func permitsBinding(_ sessionID: UUID, on session: AgentTabSession) -> Bool {
            bindingRejection(sessionID, on: session) == nil
        }

        func resolveWriter(workspaceID: UUID, sessionID: UUID) -> WriterResolution {
            store.resolveWriter(workspaceID: workspaceID, sessionID: sessionID)
        }

        func liveSessionTabIDs(for sessionID: UUID) -> Set<UUID> {
            liveTabIDsBySessionID[sessionID] ?? []
        }

        fileprivate func updateLiveSessionBindingIndex(tabID: UUID) {
            if let previous = liveClaimByTabID.removeValue(forKey: tabID)?.sessionID {
                liveTabIDsBySessionID[previous]?.remove(tabID)
                if liveTabIDsBySessionID[previous]?.isEmpty == true {
                    liveTabIDsBySessionID.removeValue(forKey: previous)
                }
            }
            if let session = sessions[tabID] {
                // Unbound members need the same ABA fence as persistent writers. They never
                // enter the reverse session-ID index or resolve as a persistent Writer.
                let current = session.activeAgentSessionID
                liveClaimByTabID[tabID] = LiveClaim(sessionID: current)
                if let current { liveTabIDsBySessionID[current, default: []].insert(tabID) }
            }
        }
    }
}
