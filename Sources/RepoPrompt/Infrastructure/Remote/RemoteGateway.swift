import AppKit
import Foundation
import OSLog
import RepoPromptRemoteProtocol

/// Opt-in Iroh gateway for the Remote control surface. The gateway is
/// intentionally independent from the Unix-socket MCP server and talks to
/// typed application services through the snapshot and command boundaries.
@MainActor
final class RemoteGatewayController: NSObject, ObservableObject {
    private static let unpairLogger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "RemoteUnpair")

    @Published private(set) var isRunning = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var irohDiagnostics = RemoteIrohGatewayDiagnostics()
    @Published private(set) var lastError: String?
    @Published private(set) var lastRequestAt: Date?
    @Published private(set) var lastSuccessfulRequestAt: Date?
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var isPaired = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "RepoPrompt.remote.gatewayEnabled"
    private static let defaultAuthorityKey = "RepoPrompt.remote.defaultAuthority"

    private weak var windowStatesManager: WindowStatesManager?
    private var controlService: (any RemoteAgentControlService)?
    private let pairingManager = RemotePairingManager()
    private let irohIdentityStore = RemoteIrohIdentityStore()
    let availabilityController = RemoteAvailabilityController()
    private let replayBuffer = RemoteEventReplayBuffer(capacity: 512)
    private let transcriptRevisionTracker = RemoteTranscriptRevisionTracker()
    /// Changes only when the CE process restarts. Gateway stop/start preserves it.
    private let transcriptRevisionEpoch = UUID()

    private var irohGeneration: UInt64 = 0
    private var commandGeneration: UInt64 = 0
    private var isStarting = false
    private var eventPollTask: Task<Void, Never>?
    private var lastPublishedSnapshot: RemoteSnapshot?

    private lazy var requestRouter = RemoteGatewayRequestRouter(services: makeRoutingServices())
    private lazy var irohAdapter = RemoteIrohGatewayAdapter(
        router: requestRouter,
        stateChanged: { [weak self] diagnostics in
            self?.irohDiagnostics = diagnostics
        },
        requestReceived: { [weak self] in
            self?.lastRequestAt = Date()
        },
        successfulResponseSent: { [weak self] in
            self?.lastSuccessfulRequestAt = Date()
        }
    )
    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isPaired = pairingManager.isPaired
        super.init()
    }

    func configure(windowStatesManager: WindowStatesManager) {
        self.windowStatesManager = windowStatesManager
        controlService = WindowRemoteAgentControlService(windowStatesManager: windowStatesManager)
        if isEnabled, !isRunning {
            Task { [weak self] in
                try? await self?.start()
            }
        }
    }

    private static func makePairingCode(for advertisement: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(advertisement) else { return nil }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "rpremote://pair?payload=\(payload)"
    }

    var pairedDeviceName: String? {
        pairingManager.pairedDeviceName
    }

    func refreshPairingAdvertisement() {
        guard isEnabled, isRunning, !pairingManager.isPaired,
              let server = irohAdapter.currentAddress else { return }
        do {
            let advertisement = try pairingManager.issueAdvertisement(server: server)
            pairingCode = Self.makePairingCode(for: advertisement)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    var defaultAuthority: RemoteAuthorityLevel {
        get {
            RemoteAuthorityLevel(
                rawValue: UserDefaults.standard.integer(forKey: Self.defaultAuthorityKey)
            ) ?? .observe
        }
        set {
            if newValue < defaultAuthority {
                commandGeneration &+= 1
            }
            if !RemoteAuthorizationState(defaultLevel: newValue).allows(.control) {
                controlService?.clearAttachmentUploads()
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultAuthorityKey)
        }
    }

    var authorizationState: RemoteAuthorizationState {
        RemoteAuthorizationState(defaultLevel: defaultAuthority)
    }

    func start() async throws {
        guard isEnabled, !isRunning, !isStarting else { return }
        guard windowStatesManager != nil else { throw RemoteGatewayError.configurationUnavailable }

        isStarting = true
        irohGeneration &+= 1
        let generation = irohGeneration
        defer { if irohGeneration == generation { isStarting = false } }
        do {
            let identity = try irohIdentityStore.loadOrCreate()
            if identity.origin != .loaded, pairingManager.isPaired {
                try pairingManager.revokeDevice()
                isPaired = false
            }
            _ = try await irohAdapter.start(
                secret: identity.secret,
                desktopInstanceID: pairingManager.desktopInstanceID,
                generation: generation
            )
            guard irohGeneration == generation, isEnabled else { return }
            isRunning = true
            startEventPolling()
        } catch {
            guard irohGeneration == generation else { return }
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        commandGeneration &+= 1
        controlService?.clearAttachmentUploads()
        eventPollTask?.cancel()
        eventPollTask = nil
        lastPublishedSnapshot = nil
        irohGeneration &+= 1
        isStarting = false
        irohAdapter.stop()
        pairingManager.invalidateAdvertisement()
        pairingCode = nil
        isRunning = false
        availabilityController.releaseSleepAssertion()
    }

    func diagnostics() async -> RemoteDiagnostics {
        await RemoteDiagnostics(
            gatewayState: isRunning ? "running" : "stopped",
            lastRequestAt: lastRequestAt,
            lastSuccessfulRequestAt: lastSuccessfulRequestAt,
            lastSnapshotAt: lastSnapshotAt,
            lastEventCursor: replayBuffer.latestCursor(),
            pairedDevice: pairingManager.isPaired,
            notificationRegistration: false,
            irohState: irohDiagnostics.state,
            irohEndpointID: irohDiagnostics.endpointID,
            irohPath: irohDiagnostics.path,
            irohActivePeerCount: irohDiagnostics.activePeerCount,
            irohLastTransitionAt: irohDiagnostics.lastTransitionAt,
            irohLastError: irohDiagnostics.lastError
        )
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            do { try await start() } catch { lastError = error.localizedDescription }
        } else {
            stop()
        }
    }

    func revokePairedDevice() {
        do {
            try pairingManager.revokeDevice()
            commandGeneration &+= 1
            controlService?.clearAttachmentUploads()
            irohAdapter.revokePeerSessions()
            isPaired = false
            lastError = nil
            pairingCode = nil
        } catch {
            isPaired = pairingManager.isPaired
            lastError = error.localizedDescription
        }
    }

    func publish(_ event: RemoteEvent) async -> RemoteEvent {
        await replayBuffer.append(event)
    }

    private func makeRoutingServices() -> RemoteGatewayRoutingServices {
        RemoteGatewayRoutingServices(
            authorize: { [unowned self] context in
                isEnabled && isRunning && pairingManager.isAuthorizedIroh(
                    authorizationHeader: context.authorizationHeader,
                    deviceID: context.deviceID,
                    authenticatedPeerEndpointID: context.endpointID
                )
            },
            unpair: { [unowned self] in
                Self.unpairLogger.info("Authenticated remote Unpair request received")
                do {
                    // Delete the durable credential first. Only then invalidate
                    // Iroh sessions and publish the unpaired UI state.
                    try pairingManager.revokeDevice()
                    commandGeneration &+= 1
                    controlService?.clearAttachmentUploads()
                    irohAdapter.revokePeerSessions()
                    isPaired = false
                    lastError = nil
                    pairingCode = nil
                    Self.unpairLogger.info("Durable credential revocation succeeded; Iroh sessions invalidated")
                    return .success
                } catch {
                    isPaired = pairingManager.isPaired
                    lastError = error.localizedDescription
                    Self.unpairLogger.error("Durable credential revocation failed: \(error.localizedDescription, privacy: .public)")
                    return .failed
                }
            },
            snapshot: { [unowned self] in
                await snapshot()
            },
            diagnostics: { [unowned self] in
                await diagnostics()
            },
            history: { [unowned self] request in
                guard let readService = makeReadService() else { return nil }
                return try await readService.history(request)
            },
            transcript: { [unowned self] request in
                guard let readService = makeReadService() else { return .unavailable }
                do {
                    let page = try await readService.transcript(
                        sessionID: request.sessionID,
                        paging: request.paging,
                        limit: request.limit,
                        includeDetails: request.includeDetails
                    )
                    return await .success(RemoteTranscriptPage(
                        sessionID: page.sessionID,
                        items: page.items,
                        nextSequenceIndex: page.nextSequenceIndex,
                        hasMore: page.hasMore,
                        eventCursor: replayBuffer.latestCursor(),
                        pagingMode: page.pagingMode,
                        olderCursor: page.olderCursor,
                        hasOlder: page.hasOlder,
                        transcriptRevision: page.transcriptRevision,
                        transcriptRevisionEpoch: transcriptRevisionEpoch,
                        chatConfiguration: page.chatConfiguration
                    ))
                } catch let error as RemoteReadServiceError {
                    switch error {
                    case .workspaceNotFound:
                        return .failed
                    case .sessionNotFound:
                        return .sessionNotFound(error.localizedDescription)
                    case .transcriptItemNotFound:
                        return .itemNotFound(error.localizedDescription)
                    case .invalidCursor:
                        return .invalidCursor(error.localizedDescription)
                    }
                } catch {
                    return .failed
                }
            },
            replay: { [unowned self] cursor in
                await replayBuffer.replay(
                    after: cursor,
                    desktopInstanceID: pairingManager.desktopInstanceID
                )
            },
            authorizationState: { [unowned self] in
                authorizationState
            },
            commandGeneration: { [unowned self] in commandGeneration },
            execute: { [unowned self] command, authorizeDispatch in
                guard let controlService else { return .unavailable }
                do {
                    return try await .success(controlService.execute(command, authorizeDispatch: authorizeDispatch))
                } catch let error as RemoteAgentControlServiceError {
                    return .rejected(error.localizedDescription)
                } catch {
                    return .failed
                }
            },
            eventCursor: { [unowned self] in
                await replayBuffer.latestCursor()
            },
            imageAttachment: { [unowned self] request in
                guard let readService = makeReadService() else { return nil }
                return try await readService.imageAttachment(request)
            },
            pairIroh: { [unowned self] request, peerEndpointID in
                guard isEnabled, isRunning, !pairingManager.isPaired else {
                    return .failure(RemoteGatewayError.pairingUnavailable)
                }
                do {
                    let response = try pairingManager.pairIroh(
                        request: request,
                        authenticatedPeerEndpointID: peerEndpointID,
                        serverEndpointID: irohAdapter.currentAddress?.endpointID ?? "",
                        desktop: desktopSummary
                    )
                    commandGeneration &+= 1
                    controlService?.clearAttachmentUploads()
                    isPaired = true
                    pairingCode = nil
                    return .success(response)
                } catch {
                    return .failure(error)
                }
            }
        )
    }

    private func startEventPolling() {
        eventPollTask?.cancel()
        eventPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await publishLiveStateChanges()
            }
        }
    }

    /// The gateway publishes bounded, sanitized coarse events from the same
    /// authoritative snapshot used by GET /snapshot. This keeps the gateway
    /// independent of individual Agent Mode runners while still making live
    /// state changes observable to a reconnecting phone.
    private func publishLiveStateChanges() async {
        guard isRunning else { return }
        let generation = irohGeneration
        let current = await snapshot()
        guard generation == irohGeneration, !Task.isCancelled else { return }
        availabilityController.update(snapshot: current)
        guard let previous = lastPublishedSnapshot else {
            lastPublishedSnapshot = current
            return
        }

        var pendingEvents: [RemoteEvent] = []

        if previous.authorization != current.authorization {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .authorizationChanged,
                payload: .authorization(current.authorization)
            ))
        }

        if previous.workflowCatalog != current.workflowCatalog
            || previous.agentCatalog != current.agentCatalog
            || previous.agentCatalogMetadata != current.agentCatalogMetadata
        {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .catalogChanged,
                payload: .catalog(
                    RemoteCatalogPayload(
                        workflows: current.workflowCatalog,
                        agents: current.agentCatalog,
                        metadata: current.agentCatalogMetadata
                    )
                )
            ))
        }

        let oldWorkspaces = Dictionary(uniqueKeysWithValues: previous.workspaces.map { ($0.workspaceID, $0) })
        for workspace in current.workspaces where oldWorkspaces[workspace.workspaceID] != workspace {
            let type: RemoteEventType = workspace.isOpen ? .workspaceReady : .workspaceOpening
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: type,
                workspaceID: workspace.workspaceID,
                payload: .workspace(workspace)
            ))
        }

        let oldSessions = Dictionary(uniqueKeysWithValues: previous.sessions.map { ($0.sessionID, $0) })
        for session in current.sessions {
            guard let old = oldSessions[session.sessionID] else {
                pendingEvents.append(RemoteEvent(
                    desktopInstanceID: pairingManager.desktopInstanceID,
                    type: .sessionCreated,
                    workspaceID: session.workspaceID,
                    sessionID: session.sessionID,
                    payload: .session(session)
                ))
                continue
            }
            guard old != session else { continue }
            if let event = Self.transcriptRevisionEvent(
                old: old,
                current: session,
                desktopInstanceID: pairingManager.desktopInstanceID
            ) {
                pendingEvents.append(event)
            }
            guard Self.hasSessionChangeExcludingTranscriptRevision(old: old, current: session) else {
                continue
            }
            let type: RemoteEventType = if old.runState != session.runState {
                switch session.runState {
                case .working: .runStarted
                case .waitingForInput: .runWaitingForInput
                case .completed: .runCompleted
                case .failed: .runFailed
                case .cancelled: .runCancelled
                default: .sessionUpdated
                }
            } else if old.latestMeaningfulActivity != session.latestMeaningfulActivity {
                .runProgressed
            } else if old.pendingInteraction == nil, session.pendingInteraction != nil {
                .interactionCreated
            } else if old.pendingInteraction != nil, session.pendingInteraction == nil {
                .interactionResolved
            } else {
                .sessionUpdated
            }
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: type,
                workspaceID: session.workspaceID,
                sessionID: session.sessionID,
                payload: .session(session)
            ))
        }

        let oldAttention = Dictionary(uniqueKeysWithValues: previous.attentionItems.map { ($0.id, $0) })
        let currentAttention = Dictionary(uniqueKeysWithValues: current.attentionItems.map { ($0.id, $0) })
        for item in current.attentionItems where oldAttention[item.id] != item {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .interactionCreated,
                sessionID: item.sessionID,
                payload: .attention(item)
            ))
        }
        for id in oldAttention.keys where currentAttention[id] == nil {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .interactionResolved,
                payload: .attentionRemoved(id)
            ))
        }

        for event in RemoteEventCoalescer.coalesce(pendingEvents) {
            guard generation == irohGeneration, !Task.isCancelled else { return }
            _ = await publish(event)
        }

        guard generation == irohGeneration, !Task.isCancelled else { return }
        lastPublishedSnapshot = current
    }

    static func transcriptRevisionEvent(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary,
        desktopInstanceID: String
    ) -> RemoteEvent? {
        guard old.transcriptRevision != current.transcriptRevision,
              let revision = current.transcriptRevision
        else { return nil }
        return RemoteEvent(
            desktopInstanceID: desktopInstanceID,
            type: .transcriptItemsAppended,
            workspaceID: current.workspaceID,
            sessionID: current.sessionID,
            payload: .text(String(revision))
        )
    }

    static func hasSessionChangeExcludingTranscriptRevision(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary
    ) -> Bool {
        old.sessionID != current.sessionID
            || old.workspaceID != current.workspaceID
            || old.composeTabID != current.composeTabID
            || old.parentSessionID != current.parentSessionID
            || old.sessionName != current.sessionName
            || old.workflow != current.workflow
            || old.workflowID != current.workflowID
            || old.runStartedAt != current.runStartedAt
            || old.agent != current.agent
            || old.model != current.model
            || old.reasoningEffort != current.reasoningEffort
            || old.configurationControls != current.configurationControls
            || old.runState != current.runState
            || old.lifecycleStage != current.lifecycleStage
            || old.latestMeaningfulActivity != current.latestMeaningfulActivity
            || old.pendingInteraction != current.pendingInteraction
            || old.childSessionIDs != current.childSessionIDs
            || old.worktreeSummary != current.worktreeSummary
            || old.mergeAttention != current.mergeAttention
            || old.failureSummary != current.failureSummary
            || old.lastUpdatedAt != current.lastUpdatedAt
            || old.isLive != current.isLive
    }

    private static func notificationCategory(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary
    ) -> RemoteNotificationCategory? {
        if old.pendingInteraction == nil, let interaction = current.pendingInteraction {
            return interaction.kind == .approval ? .approvalRequired : .agentNeedsInput
        }
        guard old.runState != current.runState else { return nil }
        switch current.runState {
        case .completed: return .completed
        case .failed: return .failed
        default: return nil
        }
    }

    private func makeReadService() -> WindowRemoteReadService? {
        guard let windowStatesManager else { return nil }
        let contexts = windowStatesManager.allWindows
            .filter { !$0.isClosing }
            .map { (agentMode: $0.agentModeViewModel, workspaceManager: $0.workspaceManager) }
        return WindowRemoteReadService(
            contexts: contexts,
            revisionTracker: transcriptRevisionTracker
        )
    }

    private var desktopSummary: RemoteDesktopSummary {
        RemoteDesktopSummary(
            instanceID: pairingManager.desktopInstanceID,
            displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "RepoPrompt CE",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            isAvailable: true,
            lastSeenAt: Date()
        )
    }

    private func snapshot() async -> RemoteSnapshot {
        lastSnapshotAt = Date()
        let authorization = authorizationState
        guard let window = windowStatesManager?.allWindows.first else {
            return await RemoteSnapshot(
                desktop: desktopSummary,
                connection: .init(state: .connected, transport: "iroh"),
                authorization: authorization,
                eventCursor: replayBuffer.latestCursor(),
                transcriptRevisionEpoch: transcriptRevisionEpoch
            )
        }
        let windows = windowStatesManager?.allWindows ?? [window]
        let contexts = windows.map {
            (agentMode: $0.agentModeViewModel, workspaceManager: $0.workspaceManager)
        }
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: WorkspaceManagerRemoteCatalogService(
                managers: windows.map(\.workspaceManager)
            ),
            sessionQuery: AgentModeRemoteSessionQueryService(
                contexts: contexts,
                revisionTracker: transcriptRevisionTracker
            ),
            workflowCatalog: DesktopRemoteCatalogService(agentModes: contexts.map(\.agentMode))
        )
        return await builder.build(
            desktop: desktopSummary,
            connection: .init(state: .connected, transport: "iroh", lastConnectedAt: Date()),
            authorization: authorization,
            eventCursor: replayBuffer.latestCursor(),
            transcriptRevisionEpoch: transcriptRevisionEpoch
        )
    }
}

enum RemoteGatewayError: LocalizedError {
    case configurationUnavailable
    case pairingUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: "Remote gateway configuration is unavailable."
        case .pairingUnavailable: "Enable Remote and generate a pairing code on your Mac."
        }
    }
}
