import AppKit
import Foundation
import OSLog
import RepoPromptRemoteProtocol

/// Opt-in LAN gateway for the Remote control surface. The gateway is
/// intentionally independent from the Unix-socket MCP server and talks to
/// typed application services through the snapshot and command boundaries.
@MainActor
final class RemoteGatewayController: NSObject, ObservableObject {
    private static let unpairLogger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "RemoteUnpair")

    @Published private(set) var isRunning = false
    @Published private(set) var pairingAdvertisement: RemotePairingAdvertisement?
    @Published private(set) var irohPairingAdvertisement: RemoteIrohPairingAdvertisement?
    @Published private(set) var pairingCode: String?
    @Published private(set) var legacyPairingCode: String?
    @Published private(set) var irohPairingCode: String?
    @Published private(set) var irohDiagnostics = RemoteIrohGatewayDiagnostics()
    @Published private(set) var lastError: String?
    @Published private(set) var lastRequestAt: Date?
    @Published private(set) var lastSuccessfulRequestAt: Date?
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var isPaired = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var isIrohEnabled: Bool {
        didSet { UserDefaults.standard.set(isIrohEnabled, forKey: Self.irohEnabledKey) }
    }

    private static let enabledKey = "RepoPrompt.remote.gatewayEnabled"
    private static let irohEnabledKey = "RepoPrompt.remote.irohEnabled"
    private static let defaultAuthorityKey = "RepoPrompt.remote.defaultAuthority"

    private weak var windowStatesManager: WindowStatesManager?
    private var controlService: (any RemoteAgentControlService)?
    private let pairingManager = RemotePairingManager()
    private lazy var notificationRelay = RemoteNotificationRelay(pairingManager: pairingManager)
    private let tlsIdentityStore = RemoteTLSIdentityStore()
    private let irohIdentityStore = RemoteIrohIdentityStore()
    let availabilityController = RemoteAvailabilityController()
    private let replayBuffer = RemoteEventReplayBuffer(capacity: 512)
    private let transcriptRevisionTracker = RemoteTranscriptRevisionTracker()
    /// Changes only when the CE process restarts. Gateway stop/start preserves it.
    private let transcriptRevisionEpoch = UUID()

    private var tlsIdentity: RemoteTLSIdentity?
    private var irohGeneration: UInt64 = 0
    private var eventPollTask: Task<Void, Never>?
    private var lastPublishedSnapshot: RemoteSnapshot?
    private(set) var activePort: UInt16?

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
    private lazy var legacyAdapter = RemoteLegacyHTTPSGatewayAdapter(
        router: requestRouter,
        requestReceived: { [weak self] in
            self?.lastRequestAt = Date()
        },
        successfulResponseSent: { [weak self] in
            self?.lastSuccessfulRequestAt = Date()
        }
    )

    var notificationRelayConfigured: Bool {
        notificationRelay.isConfigured
    }

    var notificationRegistrationAvailable: Bool {
        pairingManager.registeredNotification != nil
    }

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isIrohEnabled = UserDefaults.standard.object(forKey: Self.irohEnabledKey) as? Bool ?? false
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
        guard let activePort else { return }
        do {
            if let server = irohAdapter.currentAddress, isIrohEnabled {
                let issued = try pairingManager.issuePairingAdvertisements(
                    port: activePort,
                    serviceName: bonjourName,
                    host: RemoteLocalAddress.preferredIPv4Address(),
                    server: server
                )
                setPairingAdvertisements(legacy: issued.legacy, iroh: issued.iroh)
            } else {
                try setPairingAdvertisements(
                    legacy: pairingManager.issueAdvertisement(
                        port: activePort,
                        serviceName: bonjourName,
                        host: RemoteLocalAddress.preferredIPv4Address()
                    ),
                    iroh: nil
                )
            }
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
        guard !isRunning else { return }
        guard windowStatesManager != nil else {
            throw RemoteGatewayError.configurationUnavailable
        }

        do {
            let identity = try tlsIdentityStore.loadOrCreate()
            tlsIdentity = identity
            if identity.wasCreated {
                // A new TLS identity invalidates the certificate pin held by
                // existing phones, so do not leave an unusable device paired.
                try pairingManager.revokeDevice()
                controlService?.clearAttachmentUploads()
                isPaired = false
            }
            pairingManager.setCertificateSHA256(identity.certificateSHA256)

            let port = try await legacyAdapter.start(
                identity: identity,
                serviceName: bonjourName,
                desktopInstanceID: pairingManager.desktopInstanceID
            )
            activePort = port
            if isIrohEnabled {
                do {
                    let identity = try irohIdentityStore.loadOrCreate()
                    if identity.origin == .replacedCorruptValue {
                        try pairingManager.clearIrohPeerBinding()
                    }
                    irohGeneration &+= 1
                    _ = try await irohAdapter.start(
                        secret: identity.secret,
                        desktopInstanceID: pairingManager.desktopInstanceID,
                        generation: irohGeneration
                    )
                } catch {
                    irohDiagnostics.lastError = error.localizedDescription
                }
            }
            refreshPairingAdvertisement()
            isRunning = true
            lastError = nil
            startEventPolling()
        } catch {
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        controlService?.clearAttachmentUploads()
        eventPollTask?.cancel()
        eventPollTask = nil
        lastPublishedSnapshot = nil
        legacyAdapter.stop()
        irohAdapter.stop()
        setPairingAdvertisements(legacy: nil, iroh: nil)
        activePort = nil
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
            notificationRegistration: notificationRegistrationAvailable,
            notificationRelayConfigured: notificationRelayConfigured,
            notificationLastAttemptAt: notificationRelay.lastAttemptAt,
            notificationLastError: notificationRelay.lastError,
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

    func setIrohEnabled(_ enabled: Bool) async {
        isIrohEnabled = enabled
        guard isRunning else { return }
        if enabled {
            do {
                let identity = try irohIdentityStore.loadOrCreate()
                irohGeneration &+= 1
                _ = try await irohAdapter.start(
                    secret: identity.secret,
                    desktopInstanceID: pairingManager.desktopInstanceID,
                    generation: irohGeneration
                )
            } catch {
                irohDiagnostics.lastError = error.localizedDescription
            }
        } else {
            irohAdapter.stop()
        }
        refreshPairingAdvertisement()
    }

    private func setPairingAdvertisements(
        legacy: RemotePairingAdvertisement?,
        iroh: RemoteIrohPairingAdvertisement?
    ) {
        pairingAdvertisement = legacy
        irohPairingAdvertisement = iroh
        legacyPairingCode = legacy.flatMap(Self.makePairingCode(for:))
        irohPairingCode = iroh.flatMap { Self.makePairingCode(for: RemotePairingCode.iroh($0)) }
        pairingCode = legacyPairingCode ?? irohPairingCode
    }

    func revokePairedDevice() {
        do {
            try pairingManager.revokeDevice()
            controlService?.clearAttachmentUploads()
            irohAdapter.revokePeerSessions()
            isPaired = false
            lastError = nil
            refreshPairingAdvertisement()
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
                switch context.transport {
                case .legacyHTTPS:
                    pairingManager.isAuthorized(context.authorizationHeader)
                case let .authenticatedPeer(endpointID, deviceID):
                    pairingManager.isAuthorizedIroh(
                        authorizationHeader: context.authorizationHeader,
                        deviceID: deviceID,
                        authenticatedPeerEndpointID: endpointID
                    )
                }
            },
            pair: { [unowned self] request in
                do {
                    let response = try pairingManager.pair(request: request, desktop: desktopSummary)
                    isPaired = true
                    return .success(response)
                } catch let error as RemoteGatewaySecurityError {
                    return .forbidden(error.localizedDescription)
                } catch {
                    return .failed
                }
            },
            unpair: { [unowned self] in
                Self.unpairLogger.info("Authenticated remote Unpair request received")
                do {
                    // Delete the durable credential first. Only then invalidate
                    // Iroh sessions and publish the unpaired UI state.
                    try pairingManager.revokeDevice()
                    controlService?.clearAttachmentUploads()
                    irohAdapter.revokePeerSessions()
                    isPaired = false
                    lastError = nil
                    refreshPairingAdvertisement()
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
            registerNotifications: { [unowned self] registration in
                do {
                    try pairingManager.registerNotifications(registration)
                    return .success
                } catch {
                    return .failed
                }
            },
            authorizationState: { [unowned self] in
                authorizationState
            },
            execute: { [unowned self] command in
                guard let controlService else { return .unavailable }
                do {
                    return try await .success(controlService.execute(command))
                } catch let error as RemoteAgentControlServiceError {
                    return .rejected(error.localizedDescription)
                } catch {
                    return .failed
                }
            },
            eventCursor: { [unowned self] in
                await replayBuffer.latestCursor()
            },
            pairIroh: { [unowned self] request, peerEndpointID in
                do {
                    let response = try pairingManager.pairIroh(
                        request: request,
                        authenticatedPeerEndpointID: peerEndpointID,
                        serverEndpointID: irohAdapter.currentAddress?.endpointID ?? "",
                        desktop: desktopSummary
                    )
                    isPaired = true
                    return .success(response)
                } catch {
                    return .failure(error)
                }
            },
            transportBootstrap: { [unowned self] in
                guard let server = irohAdapter.currentAddress, isIrohEnabled else { return nil }
                return RemoteTransportBootstrapResponse(
                    desktopInstanceID: pairingManager.desktopInstanceID,
                    server: server
                )
            },
            bindIrohEndpoint: { [unowned self] request, authorizationHeader in
                do {
                    return try .success(pairingManager.bindIrohEndpoint(
                        request: request,
                        authorizationHeader: authorizationHeader,
                        serverEndpointID: irohAdapter.currentAddress?.endpointID ?? ""
                    ))
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
        let current = await snapshot()
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
            if let category = Self.notificationCategory(old: old, current: session) {
                _ = await notificationRelay.deliver(category: category, sessionID: session.sessionID)
            }
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
            _ = await publish(event)
        }

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

    private var bonjourName: String {
        "RepoPrompt-\(pairingManager.desktopInstanceID.prefix(8))"
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
            let snapshot = await RemoteSnapshot(
                desktop: desktopSummary,
                connection: .init(state: .connected, transport: "lan_https"),
                authorization: authorization,
                eventCursor: replayBuffer.latestCursor(),
                transcriptRevisionEpoch: transcriptRevisionEpoch
            )
            availabilityController.update(snapshot: snapshot)
            return snapshot
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
        let snapshot = await builder.build(
            desktop: desktopSummary,
            connection: .init(state: .connected, transport: "lan_https", lastConnectedAt: Date()),
            authorization: authorization,
            eventCursor: replayBuffer.latestCursor(),
            transcriptRevisionEpoch: transcriptRevisionEpoch
        )
        availabilityController.update(snapshot: snapshot)
        return snapshot
    }
}

enum RemoteGatewayError: LocalizedError {
    case configurationUnavailable
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: "Remote gateway configuration is unavailable."
        case .listenerUnavailable: "The Remote gateway listener could not start."
        }
    }
}
