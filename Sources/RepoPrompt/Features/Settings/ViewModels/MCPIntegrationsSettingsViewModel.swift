import AppKit
import Combine
import Foundation

enum FigmaMCPSettingsCardContentMode: Equatable {
    case disconnected
    case connected
}

enum FigmaMCPSettingsPresentationState: Equatable, Hashable, CaseIterable {
    case fresh
    case inspecting
    case canonicalImportFound
    case connecting
    case awaitingBrowserAuthorization
    case authorizationRequired
    case connected
    case testing
    case expired
    case serverUnavailable
    case error
    case signingOut
    case cancellationFinalizing
    case busy
    case codexUnavailable
    case credentialRevocationRequired
}

enum FigmaMCPSettingsAuthorizationHandoffOutcome: Equatable {
    case awaitingBrowserAuthorization
    case browserOpenFailed
}

enum FigmaMCPSettingsOperationKind: Equatable {
    case refresh
    case test
    case connect
    case useExistingConnection
    case reauthenticate
    case verifyAuthentication
    case awaitAuthorizationCompletion
    case signOut
}

enum FigmaMCPSettingsPrimaryAction: Equatable {
    case connect
    case operationInProgress
    case useExistingConnection
    case checkConnection
    case testConnection
    case reauthenticate
    case retryConnection
    case openCLIProviders
}

/// The presentation-only, status-safe connected summary for the Figma card.
struct FigmaMCPSettingsConnectionSummary: Equatable {
    enum Row: Equatable {
        case connection(String)
        case authentication(String)
        case credentialOwner(String)
    }

    let rows: [Row]
}

enum FigmaMCPProviderRowStatus: Equatable, Hashable {
    case connected
    case notVerified
    case needsLogin
    case authorizing
    case connecting
    case checking
    case liveTestPending
    case unavailable
    case error
    case unsupported
    case currentlyUnsupported
    case comingSoon

    var label: String {
        switch self {
        case .connected: "Connected"
        case .notVerified, .needsLogin, .unavailable, .error: "Needs login"
        case .authorizing: "Authorizing"
        case .connecting: "Connecting…"
        case .checking, .liveTestPending: "Checking"
        case .unsupported, .currentlyUnsupported: "Currently unsupported"
        case .comingSoon: "Coming Soon"
        }
    }

    var capsuleStatus: SettingsConnectionStatus {
        switch self {
        case .connected: .connected
        case .notVerified, .needsLogin, .unavailable, .error, .unsupported, .currentlyUnsupported, .comingSoon:
            .notConnected
        case .authorizing, .connecting, .checking, .liveTestPending:
            .connecting
        }
    }
}

enum FigmaMCPProviderRowAction: Equatable, Hashable {
    case connect
    case cancelLogin
    case disconnect
    case testConnection
}

struct FigmaMCPProviderRowActionPresentation: Equatable, Identifiable {
    let id: FigmaMCPProviderRowAction
    let title: String
    let systemImage: String
    let isLoading: Bool
    let isDisabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
}

enum FigmaMCPProviderRowTimestampPresentation: Equatable {
    case lastVerified
    case observed(validUntil: Date?)

    func labels(for timestamp: Date) -> (display: String, accessibility: String) {
        switch self {
        case .lastVerified:
            return (
                "Last verified \(timestamp.formatted(date: .abbreviated, time: .shortened))",
                "Last verified \(timestamp.formatted(date: .long, time: .shortened))"
            )
        case let .observed(validUntil):
            let displaySuffix = validUntil.map {
                " • Valid until \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? ""
            let accessibilitySuffix = validUntil.map {
                ", valid until \($0.formatted(date: .long, time: .shortened))"
            } ?? ""
            return (
                "Observed \(timestamp.formatted(date: .abbreviated, time: .shortened))\(displaySuffix)",
                "Observed \(timestamp.formatted(date: .long, time: .shortened))\(accessibilitySuffix)"
            )
        }
    }
}

struct FigmaMCPProviderRowPresentation: Equatable, Identifiable {
    let id: ExternalMCPRuntimeProvider
    let displayName: String
    let status: FigmaMCPProviderRowStatus
    let message: String
    let verifiedAt: Date?
    let timestampPresentation: FigmaMCPProviderRowTimestampPresentation
    let connectionSummary: FigmaMCPSettingsConnectionSummary?
    let actions: [FigmaMCPProviderRowActionPresentation]
    let isTestingConnection: Bool
    let isError: Bool
    let isCLIAvailable: Bool
    let canExpand: Bool

    init(
        id: ExternalMCPRuntimeProvider,
        displayName: String,
        status: FigmaMCPProviderRowStatus,
        message: String,
        verifiedAt: Date?,
        timestampPresentation: FigmaMCPProviderRowTimestampPresentation = .lastVerified,
        connectionSummary: FigmaMCPSettingsConnectionSummary? = nil,
        actions: [FigmaMCPProviderRowActionPresentation],
        isTestingConnection: Bool = false,
        isError: Bool,
        isCLIAvailable: Bool = false,
        canExpand: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.message = message
        self.verifiedAt = verifiedAt
        self.timestampPresentation = timestampPresentation
        self.connectionSummary = connectionSummary
        self.actions = actions
        self.isTestingConnection = isTestingConnection
        self.isError = isError
        self.isCLIAvailable = isCLIAvailable
        self.canExpand = canExpand
    }

    var cliPrerequisitePrefix: String {
        "Connect \(displayName) to RepoPrompt CE first, before connecting to Figma MCP.\nGo to Settings → Agent Mode → "
    }

    var cliPrerequisiteAccessibilityMessage: String {
        cliPrerequisitePrefix.replacingOccurrences(of: "\n", with: " ") + "CLI Providers"
    }
}

struct FigmaMCPProviderRowGroups {
    let connected: [FigmaMCPProviderRowPresentation]
    let notConnected: [FigmaMCPProviderRowPresentation]
    let unsupported: [FigmaMCPProviderRowPresentation]
}

/// The complete user-facing action matrix for the one app-wide Figma connection.
struct FigmaMCPSettingsPresentationSpec: Equatable {
    let status: SettingsConnectionStatus
    let contentMode: FigmaMCPSettingsCardContentMode
    let primaryAction: FigmaMCPSettingsPrimaryAction?
    let showsSignOutAction: Bool
    let signOutIsDisabled: Bool

    static func resolve(
        _ state: FigmaMCPSettingsPresentationState,
        hasDefinition: Bool = false
    ) -> Self {
        switch state {
        case .fresh:
            .init(status: .notConnected, contentMode: .disconnected, primaryAction: .connect, showsSignOutAction: false, signOutIsDisabled: false)
        case .inspecting:
            .init(status: .connecting, contentMode: .disconnected, primaryAction: .operationInProgress, showsSignOutAction: false, signOutIsDisabled: false)
        case .canonicalImportFound:
            .init(status: .notConnected, contentMode: .disconnected, primaryAction: .useExistingConnection, showsSignOutAction: false, signOutIsDisabled: false)
        case .connecting:
            .init(status: .connecting, contentMode: .disconnected, primaryAction: .operationInProgress, showsSignOutAction: false, signOutIsDisabled: false)
        case .awaitingBrowserAuthorization:
            .init(status: .notConnected, contentMode: .disconnected, primaryAction: .checkConnection, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .authorizationRequired:
            .init(status: .notConnected, contentMode: .disconnected, primaryAction: .reauthenticate, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .connected:
            .init(status: .connected, contentMode: .connected, primaryAction: .testConnection, showsSignOutAction: true, signOutIsDisabled: false)
        case .testing:
            .init(status: .connected, contentMode: .connected, primaryAction: .operationInProgress, showsSignOutAction: true, signOutIsDisabled: true)
        case .expired:
            .init(status: .notConnected, contentMode: .disconnected, primaryAction: .reauthenticate, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .serverUnavailable:
            .init(status: .unavailable, contentMode: .disconnected, primaryAction: .retryConnection, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .error:
            .init(status: .error, contentMode: .disconnected, primaryAction: .retryConnection, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .signingOut:
            .init(status: .connecting, contentMode: .disconnected, primaryAction: nil, showsSignOutAction: hasDefinition, signOutIsDisabled: true)
        case .cancellationFinalizing:
            .init(status: .connecting, contentMode: .disconnected, primaryAction: nil, showsSignOutAction: false, signOutIsDisabled: true)
        case .busy:
            .init(status: .connecting, contentMode: .disconnected, primaryAction: nil, showsSignOutAction: false, signOutIsDisabled: true)
        case .codexUnavailable:
            .init(status: .unavailable, contentMode: .disconnected, primaryAction: .openCLIProviders, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        case .credentialRevocationRequired:
            .init(status: .error, contentMode: .disconnected, primaryAction: nil, showsSignOutAction: hasDefinition, signOutIsDisabled: false)
        }
    }
}

enum FigmaMCPSettingsModalButtonRole: Equatable {
    case destructive
    case cancel
    case normal
}

struct FigmaMCPSignOutConfirmation: Equatable {
    static let title = "Stop Figma MCP Sessions and Sign Out?"
    static let message = "Active Figma MCP work in all RepoPrompt CE windows will stop. Conversations and unsent drafts will be preserved."
    static let confirmTitle = "Stop Sessions & Sign Out"
    static let cancelTitle = "Cancel"
    static let confirmRole: FigmaMCPSettingsModalButtonRole = .destructive
    static let cancelRole: FigmaMCPSettingsModalButtonRole = .cancel
}

/// One provider-scoped destructive confirmation contract shared by every provider row.
/// Cursor deliberately uses Disconnect because disabling its MCP entry preserves configuration and
/// OAuth credentials; provider-owned Sign Out flows clear only that provider's credentials.
struct FigmaMCPProviderDisconnectConfirmation: Equatable, Identifiable {
    let provider: ExternalMCPRuntimeProvider

    var id: ExternalMCPRuntimeProvider {
        provider
    }

    var title: String {
        switch provider {
        case .codex: "Sign Out of Figma in Codex CLI?"
        case .claudeCode: "Sign Out of Figma in Claude Code?"
        case .openCode: "Sign Out of Figma in OpenCode CLI?"
        case .cursor: "Disconnect Figma in Cursor CLI?"
        case .devin: "Sign Out of Figma in Devin CLI?"
        case .antigravity: "Disconnect Figma?"
        case .grokBuild: "Disconnect Figma?"
        }
    }

    var message: String {
        switch provider {
        case .codex:
            "RepoPrompt CE will stop active Figma MCP sessions, then Codex CLI will clear its Figma OAuth credentials. Other providers are not affected."
        case .claudeCode:
            "Claude Code will clear its own Figma MCP OAuth credentials. Codex and other providers are not affected."
        case .openCode:
            "OpenCode CLI will clear its own Figma MCP OAuth credentials. Codex and other providers are not affected."
        case .cursor:
            "Cursor CLI will disable its Figma MCP integration. Its configuration and OAuth credentials will be kept. Codex and other providers are not affected."
        case .devin:
            "Devin CLI will clear only its provider-owned Figma credentials. Other providers are not affected."
        case .antigravity:
            "Google Antigravity ACP does not support this remote Figma MCP endpoint."
        case .grokBuild:
            "This provider does not currently support Figma MCP."
        }
    }

    var confirmTitle: String {
        provider == .cursor ? "Disconnect" : "Sign Out"
    }

    let cancelTitle = "Cancel"
    let confirmRole: FigmaMCPSettingsModalButtonRole = .destructive
    let cancelRole: FigmaMCPSettingsModalButtonRole = .cancel
}

struct FigmaMCPSettingsAcknowledgementSpec: Equatable {
    enum Kind: Equatable {
        case loginCompleted
        case signOutCompleted
    }

    let kind: Kind

    var title: String {
        "Figma MCP Management"
    }

    var message: String {
        switch kind {
        case .loginCompleted: "Figma login completed."
        case .signOutCompleted: "Signed out from Figma."
        }
    }

    var dismissTitle: String {
        "OK"
    }

    var dismissRole: FigmaMCPSettingsModalButtonRole {
        .normal
    }
}

struct FigmaMCPSettingsPresentationEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case loginCompleted
        case signOutCompleted
    }

    let id: UUID
    let requestID: UUID
    let ownerID: UUID
    let windowID: Int
    let coordinatorGeneration: UInt64
    let kind: Kind
}

struct FigmaMCPSettingsModalPresentation: Equatable {
    enum ModalState: Identifiable, Equatable {
        case signOutConfirmation
        case acknowledgement(FigmaMCPSettingsPresentationEvent)

        var id: String {
            switch self {
            case .signOutConfirmation: "signOutConfirmation"
            case let .acknowledgement(event): "acknowledgement-\(event.id.uuidString)"
            }
        }
    }

    private(set) var active: ModalState?
    private(set) var queuedAcknowledgement: FigmaMCPSettingsPresentationEvent?
    private(set) var consumedEventIDs = Set<UUID>()

    @discardableResult
    mutating func requestSignOutConfirmation() -> Bool {
        guard active == nil else { return false }
        active = .signOutConfirmation
        return true
    }

    /// Dismissing the confirmation is intentionally a no-op with respect to the destructive action.
    mutating func cancelSignOutConfirmation() -> Bool {
        guard active == .signOutConfirmation else { return false }
        active = nil
        return true
    }

    /// Dispatches the destructive action at most once for the currently presented confirmation.
    @discardableResult
    mutating func confirmSignOut(dispatch: () -> Void) -> Bool {
        guard active == .signOutConfirmation else { return false }
        active = nil
        dispatch()
        return true
    }

    @discardableResult
    mutating func receive(
        _ event: FigmaMCPSettingsPresentationEvent,
        generationIsCurrent: Bool = true
    ) -> Bool {
        guard generationIsCurrent, consumedEventIDs.insert(event.id).inserted else { return false }
        if active != nil {
            if queuedAcknowledgement == nil { queuedAcknowledgement = event }
        } else {
            active = .acknowledgement(event)
        }
        return true
    }

    mutating func setActiveModal(_ modal: ModalState?) {
        active = modal
    }

    mutating func clearActiveModal() {
        active = nil
    }

    mutating func advanceAfterDismissal() {
        guard active == nil, let queuedAcknowledgement else { return }
        active = .acknowledgement(queuedAcknowledgement)
        self.queuedAcknowledgement = nil
    }

    mutating func reset() {
        active = nil
        queuedAcknowledgement = nil
        consumedEventIDs.removeAll()
    }
}

@MainActor
final class MCPIntegrationsSettingsViewModel: ObservableObject {
    typealias AuthorizationURLOpener = @MainActor (URL) -> Bool

    private enum CursorFigmaObservationPresentationPhase {
        case routineCheck
        case postAuthorizationVerification
    }

    @Published private(set) var definition: ExternalMCPIntegrationDefinition?
    @Published private(set) var snapshot: FigmaMCPIntegrationSnapshot = .notConfigured
    @Published private(set) var isPerformingOperation = false
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published private(set) var currentOperationKind: FigmaMCPSettingsOperationKind?
    @Published private(set) var pendingPresentationEvent: FigmaMCPSettingsPresentationEvent?
    @Published private(set) var cliAvailability: AgentModelCatalog.AvailabilityContext

    var isCodexConnected: Bool {
        cliAvailability.codexAvailable
    }

    @Published private(set) var cursorFigmaToolSurfaceObservation: CursorFigmaMCPToolSurfaceProbeOutcome?
    @Published private(set) var isObservingCursorFigmaToolSurface = false
    @Published private(set) var isAuthorizingCursorFigma = false
    @Published private(set) var isDisconnectingCursorFigma = false
    @Published private(set) var cursorFigmaDisableErrorMessage: String?
    @Published private(set) var cursorFigmaLoginPreflight: CursorFigmaMCPLoginPreflight?

    let figmaMCPCoordinator: FigmaMCPIntegrationCoordinator
    let figmaProviderConnectionCoordinator: FigmaMCPProviderConnectionCoordinator
    private let terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController
    private let openAuthorizationURL: AuthorizationURLOpener
    private let openCLIProviders: @MainActor () -> Void
    private let cursorFigmaToolSurfaceObserver: (any CursorFigmaMCPToolSurfaceObserving)?
    private let cursorFigmaLoginComponents: CursorFigmaMCPLoginComponents?
    private let cursorFigmaLoginDriver: FigmaMCPProviderSubprocessLoginDriver?
    private let cursorFigmaDisableExecutor: (any CursorFigmaMCPDisableExecuting)?
    private let ownerID = UUID()
    private let windowID: Int
    private(set) var activeRequestID: UUID?
    private var isActive = false
    private var operationTask: Task<Void, Never>?
    private var cursorFigmaPreflightTask: Task<Void, Never>?
    private var cursorFigmaObservationTask: Task<Void, Never>?
    private var cursorFigmaObservationExpiryTask: Task<Void, Never>?
    private var cursorFigmaObservationGeneration: UInt64 = 0
    private var cursorFigmaLoginTask: Task<Void, Never>?
    private var cursorFigmaLoginTimeoutTask: Task<Void, Never>?
    private var cursorFigmaDisableTask: Task<Void, Never>?
    private var cursorFigmaLoginAttemptID: UUID?
    private var cursorFigmaObservationLaunch: FigmaMCPProviderResolvedLoginLaunch?
    private var cursorFigmaObservationPresentationPhase: CursorFigmaObservationPresentationPhase?
    private var latestPresentationResult: FigmaMCPSettingsActionResult?
    private var latestPresentationRevision: UInt64?
    private var lastAcceptedCoordinatorRevision: UInt64
    private var latestAuthorizationHandoff: FigmaMCPSettingsAuthorizationHandoffOutcome?
    private var pendingAutomaticAuthorizationSourceRequestID: UUID?
    private var availabilityWaiterID: UUID?
    private var waitingForCoordinator = false
    /// Presentation-only snapshots retained while a connected provider performs Test Connection.
    /// They never participate in authentication or connection authority decisions.
    private var providerConnectionTestBaselines: [ExternalMCPRuntimeProvider: FigmaMCPProviderRowPresentation] = [:]
    private var lastProviderConnectionStates: [ExternalMCPRuntimeProvider: FigmaMCPProviderConnectionState] = [:]
    private var cancellables = Set<AnyCancellable>()
    #if DEBUG
        private var test_beforeApplyingResponse: (@MainActor () async -> Void)?
    #endif

    private static let providerRowOrder: [ExternalMCPRuntimeProvider] = [
        .codex, .claudeCode, .openCode, .cursor, .grokBuild, .antigravity, .devin
    ]
    private static let cursorFigmaLoginMaximumTimeout: TimeInterval = 5 * 60

    init(
        externalMCPComposition: AppExternalMCPComposition,
        cliAvailability: AgentModelCatalog.AvailabilityContext,
        settingsStore: GlobalSettingsStore? = nil,
        windowID: Int = 0,
        service: (any FigmaMCPIntegrationManaging)? = nil,
        runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority? = nil,
        coordinator: FigmaMCPIntegrationCoordinator? = nil,
        providerConnectionCoordinator: FigmaMCPProviderConnectionCoordinator? = nil,
        providerStatusService: (any FigmaMCPProviderStatusChecking)? = nil,
        cursorFigmaToolSurfaceObserver: (any CursorFigmaMCPToolSurfaceObserving)? = nil,
        cursorFigmaLoginComponents: CursorFigmaMCPLoginComponents? = nil,
        cursorFigmaLoginDriver: FigmaMCPProviderSubprocessLoginDriver? = nil,
        cursorFigmaDisableExecutor: (any CursorFigmaMCPDisableExecuting)? = nil,
        openCLIProviders: @escaping @MainActor () -> Void = {},
        openAuthorizationURL: @escaping AuthorizationURLOpener = { NSWorkspace.shared.open($0) }
    ) {
        self.windowID = windowID
        terminalSessionController = externalMCPComposition.terminalSessionController
        self.cliAvailability = cliAvailability
        self.openCLIProviders = openCLIProviders
        self.cursorFigmaToolSurfaceObserver = cursorFigmaToolSurfaceObserver
        self.cursorFigmaLoginComponents = cursorFigmaLoginComponents
        self.cursorFigmaLoginDriver = cursorFigmaLoginDriver
        self.cursorFigmaDisableExecutor = cursorFigmaDisableExecutor
        figmaMCPCoordinator = coordinator ?? MCPIntegrationsRuntime.coordinator(
            externalMCPComposition: externalMCPComposition,
            settingsStore: settingsStore,
            service: service,
            runtimeAvailability: runtimeAvailability
        )
        figmaProviderConnectionCoordinator = providerConnectionCoordinator
            ?? externalMCPComposition.figmaProviderConnectionCoordinator
        lastProviderConnectionStates = figmaProviderConnectionCoordinator.states
        // Kept as a source-compatible initializer label. Provider status is owned exclusively by
        // the app-lifetime coordinator; this legacy injection is intentionally ignored.
        _ = providerStatusService
        self.openAuthorizationURL = openAuthorizationURL
        definition = figmaMCPCoordinator.currentDefinition
        snapshot = figmaMCPCoordinator.state.connection
        lastAcceptedCoordinatorRevision = figmaMCPCoordinator.state.revision

        figmaMCPCoordinator.$state
            .sink { [weak self] state in
                guard let self, isActive,
                      state.revision >= lastAcceptedCoordinatorRevision
                else { return }
                lastAcceptedCoordinatorRevision = max(lastAcceptedCoordinatorRevision, state.revision)
                if state.operation == .test,
                   providerConnectionTestBaselines[.codex] == nil,
                   snapshot.state == .connected,
                   snapshot.authentication == .authenticated
                {
                    providerConnectionTestBaselines[.codex] = codexConnectedTestBaseline(from: snapshot)
                } else if state.operation != .test {
                    providerConnectionTestBaselines.removeValue(forKey: .codex)
                }
                definition = state.definition
                if !isPerformingOperation {
                    if latestPresentationResult != nil,
                       latestPresentationRevision == state.revision
                    {
                        return
                    }
                    let isNewerThanLocalPresentation = state.revision > (latestPresentationRevision ?? 0)
                    latestPresentationResult = nil
                    latestPresentationRevision = nil
                    latestAuthorizationHandoff = nil
                    snapshot = sanitizedSnapshot(state.connection)
                    if figmaMCPCoordinator.hasInteractiveSettingsOperation {
                        notice = FigmaMCPSettingsActionResult.busy.notice
                        noticeIsError = false
                    } else if isNewerThanLocalPresentation {
                        // A newer app-wide revision supersedes this window's local result.
                        notice = nil
                        noticeIsError = false
                    }
                }
                if state.isCancelling, isPerformingOperation {
                    notice = cancellationNotice
                    noticeIsError = false
                }
            }
            .store(in: &cancellables)

        figmaProviderConnectionCoordinator.$states
            .sink { [weak self] states in
                guard let self else { return }
                let previousStates = lastProviderConnectionStates
                lastProviderConnectionStates = states
                for provider in [ExternalMCPRuntimeProvider.claudeCode, .openCode, .devin] {
                    if states[provider] == .checking,
                       figmaProviderConnectionCoordinator.statusRecheckPurpose(for: provider) == .testConnection,
                       providerConnectionTestBaselines[provider] == nil,
                       case let .connected(proof)? = previousStates[provider]
                    {
                        providerConnectionTestBaselines[provider] = connectedProviderTestBaseline(
                            provider: provider,
                            proof: proof
                        )
                    } else if states[provider] != .checking {
                        providerConnectionTestBaselines.removeValue(forKey: provider)
                    }
                }
                guard isActive else { return }
                objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var presentationState: FigmaMCPSettingsPresentationState {
        if waitingForCoordinator { return .cancellationFinalizing }
        if !isPerformingOperation, figmaMCPCoordinator.hasInteractiveSettingsOperation {
            return .busy
        }
        if let latestPresentationResult, !isPerformingOperation {
            if latestPresentationResult.foundCanonicalImport { return .canonicalImportFound }
            if latestPresentationResult.snapshot.state == .authorizationRequired,
               latestAuthorizationHandoff == .awaitingBrowserAuthorization
            {
                return .awaitingBrowserAuthorization
            }
        }
        if isPerformingOperation {
            if figmaMCPCoordinator.state.isCancelling { return .cancellationFinalizing }
            return switch currentOperationKind {
            case .refresh: .inspecting
            case .test: .testing
            case .connect, .useExistingConnection, .reauthenticate, .verifyAuthentication, .awaitAuthorizationCompletion: .connecting
            case .signOut: .signingOut
            case nil: .connecting
            }
        }
        if figmaMCPCoordinator.credentialRevocationRequired { return .credentialRevocationRequired }
        if !isCodexConnected { return .codexUnavailable }
        guard definition != nil else { return .fresh }
        return switch snapshot.state {
        case .connected where snapshot.authentication == .authenticated
            && figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime: .connected
        case .authorizationRequired: .authorizationRequired
        case .expired: .expired
        case .serverUnavailable: .serverUnavailable
        case .failed: .error
        case .notConfigured: .error
        case .connecting, .reconnecting: .inspecting
        case .connected: .error
        }
    }

    private var presentation: FigmaMCPSettingsPresentationSpec {
        .resolve(presentationState, hasDefinition: definition != nil)
    }

    var connectionStatus: SettingsConnectionStatus {
        presentation.status
    }

    /// Figma provider routes use the fixed product order and remain presentation-only.
    var providerRows: [FigmaMCPProviderRowPresentation] {
        Self.providerRowOrder.map { decoratedProviderRow(providerRow(for: $0)) }
    }

    var providerRowGroups: FigmaMCPProviderRowGroups {
        let rows = providerRows
        func sorted(_ rows: [FigmaMCPProviderRowPresentation]) -> [FigmaMCPProviderRowPresentation] {
            rows.sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.id.rawValue < $1.id.rawValue : comparison == .orderedAscending
            }
        }
        let unsupported = rows.filter { Self.isUnsupported($0.status) }
        let supported = rows.filter { !Self.isUnsupported($0.status) }
        func isConnectedGroupMember(_ row: FigmaMCPProviderRowPresentation) -> Bool {
            row.isCLIAvailable && (row.status == .connected || row.isTestingConnection)
        }
        return .init(
            connected: sorted(supported.filter(isConnectedGroupMember)),
            notConnected: sorted(supported.filter { !isConnectedGroupMember($0) }),
            unsupported: sorted(unsupported)
        )
    }

    private static func isUnsupported(_ status: FigmaMCPProviderRowStatus) -> Bool {
        status == .unsupported || status == .currentlyUnsupported || status == .comingSoon
    }

    private func isCLIAvailable(for provider: ExternalMCPRuntimeProvider) -> Bool {
        AgentProviderKind.allCases.contains {
            $0.externalMCPRuntimeProvider == provider
                && AgentModelCatalog.isAgentAvailable($0, availability: cliAvailability)
        }
    }

    private func decoratedProviderRow(_ row: FigmaMCPProviderRowPresentation) -> FigmaMCPProviderRowPresentation {
        let supported = !Self.isUnsupported(row.status)
        let available = isCLIAvailable(for: row.id)
        let canExpand = supported && available
        let actions = row.actions.map { action in
            FigmaMCPProviderRowActionPresentation(
                id: action.id,
                title: action.title,
                systemImage: action.systemImage,
                isLoading: action.isLoading,
                isDisabled: action.isDisabled || !supported || (!available && action.id != .cancelLogin),
                accessibilityLabel: action.accessibilityLabel,
                accessibilityHint: action.accessibilityHint
            )
        }
        return .init(
            id: row.id,
            displayName: row.displayName,
            status: row.status,
            message: row.message,
            verifiedAt: row.verifiedAt,
            timestampPresentation: row.timestampPresentation,
            connectionSummary: row.connectionSummary,
            actions: actions,
            isTestingConnection: row.isTestingConnection,
            isError: row.isError,
            isCLIAvailable: available,
            canExpand: canExpand
        )
    }

    func canPerformProviderAction(provider: ExternalMCPRuntimeProvider, action: FigmaMCPProviderRowAction) -> Bool {
        providerRows.first(where: { $0.id == provider })?.actions.contains {
            $0.id == action && !$0.isDisabled
        } == true
    }

    func openCLIProviderSettings() {
        openCLIProviders()
    }

    /// Settings-only aggregate for the Figma accordion. Provider rows retain their independent
    /// connection authority; this projection only chooses the top tag and includes Cursor's current
    /// UI observation without promoting it to runtime proof.
    var integrationCardStatus: SettingsConnectionStatus {
        switch integrationCardProviderStatus {
        case .authorizing, .connecting, .checking:
            .connecting
        case .connected:
            .connected
        case .needsLogin:
            .notConnected
        default:
            .notConnected
        }
    }

    var integrationCardStatusLabelOverride: String? {
        switch integrationCardProviderStatus {
        case .authorizing: "Authorizing"
        case .connecting: "Connecting…"
        case .checking: "Checking"
        case .connected: "Connected"
        default: "Needs Login"
        }
    }

    private var integrationCardProviderStatus: FigmaMCPProviderRowStatus {
        let rows = providerRows.filter { $0.id != .grokBuild && $0.id != .antigravity }
        if rows.contains(where: { $0.status == .authorizing }) { return .authorizing }
        if rows.contains(where: { $0.status == .connecting }) { return .connecting }
        if rows.contains(where: { $0.status == .checking }) { return .checking }
        if rows.contains(where: { $0.status == .connected }) { return .connected }
        return .needsLogin
    }

    var contentMode: FigmaMCPSettingsCardContentMode {
        presentation.contentMode
    }

    func performProviderRowAction(
        provider: ExternalMCPRuntimeProvider,
        action: FigmaMCPProviderRowAction
    ) {
        guard isActive,
              let row = providerRows.first(where: { $0.id == provider }),
              let actionPresentation = row.actions.first(where: { $0.id == action }),
              !actionPresentation.isDisabled
        else { return }

        // Production Devin has no credential capabilities or row actions. Only an injected
        // verified registration may use the generic coordinator action path below.
        if provider == .devin {
            guard let registration = figmaProviderConnectionCoordinator.registry.registration(for: .devin),
                  case .verified = registration.figmaCapabilities.loginSupport,
                  registration.targetResolver != nil,
                  registration.loginDriver != nil
            else { return }
        }

        if action == .testConnection {
            retainConnectionTestBaseline(provider: provider, row: row)
        }

        switch (provider, action) {
        case (.codex, .disconnect):
            // The view normally presents the existing destructive confirmation before calling
            // `signOut`; retain this direct seam for tests and other Settings callers.
            signOut()
        case (.codex, .connect):
            // A cancelled or timed-out Codex handoff leaves the managed registration in place,
            // but the next Connect must start a new authorization operation rather than merely
            // polling the stale state.
            if definition?.repoPromptActivation == .enabled, !isAuthenticatedConnection {
                run(.reauthenticate)
            } else {
                performPrimaryAction()
            }
        case (.codex, .testConnection):
            performPrimaryAction()
        case (.codex, .cancelLogin):
            cancelCurrentOperation()
        case (.claudeCode, .connect), (.openCode, .connect), (.devin, .connect):
            startProviderLogin(provider: provider)
        case (.claudeCode, .cancelLogin), (.openCode, .cancelLogin), (.devin, .cancelLogin):
            cancelProviderLogin(provider: provider)
        case (.openCode, .testConnection), (.claudeCode, .testConnection), (.devin, .testConnection):
            testProviderConnection(provider: provider)
        case (.claudeCode, .disconnect):
            _ = figmaProviderConnectionCoordinator.signOut(provider: provider)
        case (.openCode, .disconnect), (.devin, .disconnect):
            _ = figmaProviderConnectionCoordinator.signOut(provider: provider)
        case (.cursor, .connect):
            startCursorFigmaLogin()
        case (.cursor, .cancelLogin):
            cancelCursorFigmaLogin()
        case (.cursor, .testConnection):
            testCursorFigmaConnection()
        case (.cursor, .disconnect):
            disconnectCursorFigma()
        case (.grokBuild, _), (.antigravity, _):
            break
        }
    }

    /// Starts Claude Code's provider-owned Figma login through the shared app-lifetime coordinator.
    /// Its single coordinator-owned subprocess opens Terminal and visibly runs the real Claude command.
    func startClaudeCodeFigmaAuthorization() {
        startProviderLogin(provider: .claudeCode)
    }

    /// Rechecks provider-owned Figma status after an external authentication flow returns control
    /// to RepoPrompt. Connected still requires the coordinator's current structured proof.
    @discardableResult
    func recheckProviderStatus(provider: ExternalMCPRuntimeProvider) -> Bool {
        guard isActive, provider != .cursor, isCLIAvailable(for: provider) else { return false }
        return figmaProviderConnectionCoordinator.recheckStatus(provider: provider)
    }

    private func providerRow(
        for provider: ExternalMCPRuntimeProvider
    ) -> FigmaMCPProviderRowPresentation {
        switch provider {
        case .codex:
            codexProviderRow()
        case .openCode, .devin:
            cliProviderRow(provider)
        case .cursor:
            cursorFigmaObservationRow()
        case .antigravity:
            FigmaMCPProviderRowPresentation(
                id: provider,
                displayName: "Google Antigravity ACP",
                status: .currentlyUnsupported,
                message: unsupportedProviderMessage(providerName: "Google Antigravity ACP"),
                verifiedAt: nil,
                actions: [],
                isError: false
            )
        case .grokBuild:
            FigmaMCPProviderRowPresentation(
                id: provider,
                displayName: "Grok Build CLI",
                status: .currentlyUnsupported,
                message: unsupportedProviderMessage(providerName: "Grok Build CLI"),
                verifiedAt: nil,
                actions: [],
                isError: false
            )
        case .claudeCode:
            claudeCodeProviderRow()
        }
    }

    private func claudeCodeProviderRow() -> FigmaMCPProviderRowPresentation {
        let state = providerConnectionState(for: .claudeCode)
        let displayName = providerDisplayName(for: .claudeCode)
        let testingBaseline = providerConnectionTestBaselines[.claudeCode]
        let status: FigmaMCPProviderRowStatus
        let verifiedAt: Date?
        let actions: [FigmaMCPProviderRowActionPresentation]
        let message: String
        var isError = false
        switch state {
        case let .connected(proof):
            status = .connected
            verifiedAt = proof.sanitizedSnapshot.verifiedAt
            message = "Figma is connected."
            actions = connectedProviderActions(provider: .claudeCode, providerName: displayName)
        case let .notVerified(_, notice):
            status = .needsLogin
            verifiedAt = nil
            message = providerNotice(notice, providerName: displayName)
            actions = switch notice {
            case .credentialLogoutUnverified:
                providerSignOutAction(for: .claudeCode, providerName: displayName)
            case .cancelledAuthenticationStateUnknown:
                retryConnectionAction(for: .claudeCode, providerName: displayName)
            default:
                loginAction(for: .claudeCode, providerName: displayName)
            }
        case .needsLogin:
            status = .needsLogin
            verifiedAt = nil
            message = "Claude Code reports that Figma authentication is required."
            actions = loginAction(for: .claudeCode, providerName: displayName)
        case .authorizing:
            status = .authorizing
            verifiedAt = nil
            message = "Claude Code is handling Figma authentication in its provider-owned login flow."
            actions = [cancelLoginAction(for: .claudeCode, providerName: displayName, isLoading: true)]
        case .verifyingAfterAuthorization:
            status = .connecting
            verifiedAt = nil
            message = "Verifying Figma access through Claude Code."
            actions = [cancelLoginAction(for: .claudeCode, providerName: displayName, isLoading: true)]
        case let .unavailable(reason):
            status = .needsLogin
            verifiedAt = nil
            message = reason
            actions = isProviderLoginLaunchFailure(reason)
                ? loginAction(for: .claudeCode, providerName: displayName)
                : []
        case .unsupported:
            status = .currentlyUnsupported
            verifiedAt = nil
            message = unsupportedProviderMessage(providerName: displayName)
            actions = []
        case .checking:
            status = .checking
            verifiedAt = testingBaseline?.verifiedAt
            message = testingBaseline == nil
                ? "Checking provider-reported Figma status through Claude Code."
                : "Testing Figma connection…"
            actions = testingBaseline.map(connectionTestActions) ?? []
        case .failed(.launchFailed):
            status = .needsLogin
            verifiedAt = nil
            message = "The \(displayName) Figma login could not be launched."
            actions = loginAction(for: .claudeCode, providerName: displayName)
        case .failed:
            status = .needsLogin
            verifiedAt = nil
            message = "Claude Code Figma status could not be verified."
            actions = loginAction(for: .claudeCode, providerName: displayName)
            isError = true
        }

        let isTestingConnection = status == .checking && testingBaseline != nil
        return .init(
            id: .claudeCode,
            displayName: displayName,
            status: status,
            message: message,
            verifiedAt: verifiedAt,
            timestampPresentation: testingBaseline?.timestampPresentation ?? .lastVerified,
            connectionSummary: status == .connected
                ? verifiedConnectionSummary(providerName: displayName)
                : isTestingConnection ? checkingConnectionSummary(providerName: displayName) : nil,
            actions: actions,
            isTestingConnection: isTestingConnection,
            isError: isError
        )
    }

    private func codexProviderRow() -> FigmaMCPProviderRowPresentation {
        let testingBaseline = providerConnectionTestBaselines[.codex]
        let status: FigmaMCPProviderRowStatus = if currentOperationKind == .awaitAuthorizationCompletion {
            .authorizing
        } else if isAwaitingBrowserAuthorization {
            .authorizing
        } else if isPerformingOperation {
            switch currentOperationKind {
            case .connect, .reauthenticate:
                .authorizing
            case .refresh, .test, .useExistingConnection, .verifyAuthentication:
                .checking
            case .awaitAuthorizationCompletion:
                .authorizing
            case .signOut, nil:
                isAuthenticatedConnection ? .connected : .needsLogin
            }
        } else if waitingForCoordinator || figmaMCPCoordinator.hasInteractiveSettingsOperation {
            .checking
        } else if isAuthenticatedConnection {
            .connected
        } else {
            .needsLogin
        }

        let isTestingConnection = status == .checking && testingBaseline != nil
        var actions: [FigmaMCPProviderRowActionPresentation] = []
        if status == .authorizing || status == .connecting {
            actions = [cancelLoginAction(for: .codex, providerName: "Codex CLI")]
        } else if isTestingConnection, let testingBaseline {
            actions = connectionTestActions(from: testingBaseline)
        } else if status != .checking {
            if let primaryAction = presentation.primaryAction {
                let action: FigmaMCPProviderRowAction = switch primaryAction {
                case .testConnection: .testConnection
                default: .connect
                }
                actions.append(.init(
                    id: action,
                    title: primaryActionTitle,
                    systemImage: primaryActionSymbol,
                    isLoading: false,
                    isDisabled: primaryActionIsDisabled,
                    accessibilityLabel: primaryActionAccessibilityLabel,
                    accessibilityHint: primaryActionAccessibilityHint
                ))
            }
            if showsSignOutAction {
                actions.append(.init(
                    id: .disconnect,
                    title: "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isLoading: isSigningOut,
                    isDisabled: signOutActionIsDisabled,
                    accessibilityLabel: isSigningOut ? "Signing out of Figma" : "Sign Out",
                    accessibilityHint: signOutActionAccessibilityHint
                ))
            }
        }

        return .init(
            id: .codex,
            displayName: "Codex CLI",
            status: status,
            message: connectionMessage ?? "Figma authentication is managed by Codex CLI.",
            verifiedAt: isTestingConnection ? testingBaseline?.verifiedAt : lastSuccessfulCheck,
            timestampPresentation: testingBaseline?.timestampPresentation ?? .lastVerified,
            connectionSummary: connectionSummary,
            actions: actions,
            isTestingConnection: isTestingConnection,
            isError: connectionMessageIsError
        )
    }

    private func cliProviderRow(
        _ provider: ExternalMCPRuntimeProvider
    ) -> FigmaMCPProviderRowPresentation {
        let state = providerConnectionState(for: provider)
        let displayName = providerDisplayName(for: provider)
        let testingBaseline = providerConnectionTestBaselines[provider]
        let status: FigmaMCPProviderRowStatus
        let verifiedAt: Date?
        let actions: [FigmaMCPProviderRowActionPresentation]
        let message: String
        var isError = false
        switch state {
        case let .connected(proof):
            status = .connected
            verifiedAt = proof.sanitizedSnapshot.verifiedAt
            message = "Figma is connected."
            actions = connectedProviderActions(provider: provider, providerName: displayName)
        case let .notVerified(_, notice):
            status = .needsLogin
            verifiedAt = nil
            message = providerNotice(notice, providerName: displayName)
            actions = loginAction(for: provider, providerName: displayName)
        case .needsLogin:
            status = .needsLogin
            verifiedAt = nil
            message = "\(displayName) reports that Figma authentication is required."
            actions = loginAction(for: provider, providerName: displayName)
        case .authorizing:
            status = .authorizing
            verifiedAt = nil
            message = "\(displayName) is handling Figma authentication in its provider-owned login flow."
            actions = [cancelLoginAction(for: provider, providerName: displayName, isLoading: true)]
        case .verifyingAfterAuthorization:
            status = .connecting
            verifiedAt = nil
            message = "Verifying Figma access through \(displayName)."
            actions = [cancelLoginAction(for: provider, providerName: displayName, isLoading: true)]
        case let .unavailable(reason):
            status = .needsLogin
            verifiedAt = nil
            message = reason
            actions = isProviderLoginLaunchFailure(reason)
                ? loginAction(for: provider, providerName: displayName)
                : []
        case .unsupported:
            status = .currentlyUnsupported
            verifiedAt = nil
            message = unsupportedProviderMessage(providerName: displayName)
            actions = []
        case .checking:
            status = .checking
            verifiedAt = testingBaseline?.verifiedAt
            message = "Checking provider-owned Figma status through \(displayName)."
            actions = testingBaseline.map(connectionTestActions) ?? []
        case .failed(.launchFailed):
            status = .needsLogin
            verifiedAt = nil
            message = "The \(displayName) Figma login could not be launched."
            actions = loginAction(for: provider, providerName: displayName)
        case .failed:
            status = .needsLogin
            verifiedAt = nil
            message = "Figma status through \(displayName) could not be verified."
            actions = loginAction(for: provider, providerName: displayName)
            isError = true
        }

        let isTestingConnection = status == .checking && testingBaseline != nil
        return .init(
            id: provider,
            displayName: displayName,
            status: status,
            message: message,
            verifiedAt: verifiedAt,
            timestampPresentation: testingBaseline?.timestampPresentation ?? .lastVerified,
            connectionSummary: status == .connected
                ? verifiedConnectionSummary(providerName: displayName)
                : isTestingConnection ? checkingConnectionSummary(providerName: displayName) : nil,
            actions: actions,
            isTestingConnection: isTestingConnection,
            isError: isError
        )
    }

    private func isProviderLoginLaunchFailure(_ message: String) -> Bool {
        message == "The provider Figma login could not be launched."
    }

    private func providerDisplayName(
        for provider: ExternalMCPRuntimeProvider
    ) -> String {
        switch provider {
        case .claudeCode: "Claude Code CLI"
        case .openCode: "OpenCode CLI"
        case .devin: "Devin CLI"
        default: provider.rawValue
        }
    }

    private func connectedProviderActions(
        provider: ExternalMCPRuntimeProvider,
        providerName: String
    ) -> [FigmaMCPProviderRowActionPresentation] {
        let testAction = if provider == .claudeCode {
            providerAction(
                action: .testConnection,
                title: "Test Connection",
                symbol: "antenna.radiowaves.left.and.right",
                accessibilityLabel: "Test Figma status for Claude Code",
                accessibilityHint: "Checks provider-reported Figma status through Claude Code without changing its configuration."
            )
        } else {
            providerAction(
                action: .testConnection,
                title: "Test Connection",
                symbol: "antenna.radiowaves.left.and.right",
                accessibilityLabel: "Test Figma connection through \(providerName)",
                accessibilityHint: "Checks the current provider-owned Figma MCP status without changing CLI configuration."
            )
        }
        return [testAction] + providerSignOutAction(for: provider, providerName: providerName)
    }

    private func connectedProviderTestBaseline(
        provider: ExternalMCPRuntimeProvider,
        proof: FigmaMCPVerifiedProviderStatus
    ) -> FigmaMCPProviderRowPresentation {
        let displayName = providerDisplayName(for: provider)
        return .init(
            id: provider,
            displayName: displayName,
            status: .connected,
            message: "Figma is connected.",
            verifiedAt: proof.sanitizedSnapshot.verifiedAt,
            connectionSummary: verifiedConnectionSummary(providerName: displayName),
            actions: connectedProviderActions(provider: provider, providerName: displayName),
            isError: false
        )
    }

    private func codexConnectedTestBaseline(
        from snapshot: FigmaMCPIntegrationSnapshot
    ) -> FigmaMCPProviderRowPresentation {
        .init(
            id: .codex,
            displayName: "Codex CLI",
            status: .connected,
            message: "Figma is connected.",
            verifiedAt: snapshot.lastSuccessfulCheck,
            connectionSummary: verifiedConnectionSummary(providerName: "Codex"),
            actions: [
                providerAction(
                    action: .testConnection,
                    title: "Test Connection",
                    symbol: "antenna.radiowaves.left.and.right",
                    accessibilityLabel: "Test Connection",
                    accessibilityHint: "Checks the current Figma connection."
                ),
                providerAction(
                    action: .disconnect,
                    title: "Sign Out",
                    symbol: "rectangle.portrait.and.arrow.right",
                    accessibilityLabel: "Sign Out",
                    accessibilityHint: signOutActionAccessibilityHint
                )
            ],
            isError: false
        )
    }

    private func cursorFigmaObservationRow() -> FigmaMCPProviderRowPresentation {
        let displayName = "Cursor CLI"
        let testingBaseline = providerConnectionTestBaselines[.cursor]
        guard isActive else {
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .needsLogin,
                message: "Cursor Figma connection has not been checked.",
                verifiedAt: nil,
                actions: [],
                isError: false
            )
        }
        if isAuthorizingCursorFigma {
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .authorizing,
                message: "Cursor CLI is authorizing Figma in its browser login flow.",
                verifiedAt: nil,
                actions: [cancelLoginAction(for: .cursor, providerName: displayName)],
                isError: false
            )
        }
        guard let cursorFigmaLoginPreflight else {
            let isChecking = cursorFigmaPreflightTask != nil
            return .init(
                id: .cursor,
                displayName: displayName,
                status: isChecking ? .checking : .needsLogin,
                message: isChecking
                    ? "Checking Cursor's reviewed Figma login capability."
                    : "Cursor Figma connection has not been verified.",
                verifiedAt: nil,
                actions: [],
                isError: false
            )
        }
        guard cursorFigmaLoginPreflight.permitsLogin else {
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .needsLogin,
                message: cursorLoginAvailabilityMessage(cursorFigmaLoginPreflight.availability),
                verifiedAt: nil,
                actions: [],
                isError: false
            )
        }
        if isDisconnectingCursorFigma,
           case let .candidate(candidate) = cursorFigmaToolSurfaceObservation,
           candidate.expiresAt > Date()
        {
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .connected,
                message: "Cursor CLI is disabling its Figma MCP integration.",
                verifiedAt: candidate.observedAt,
                timestampPresentation: .observed(validUntil: candidate.expiresAt),
                connectionSummary: cursorObservedConnectionSummary,
                actions: cursorFigmaConnectedActions(for: displayName, isDisconnecting: true),
                isError: false
            )
        }
        if isObservingCursorFigmaToolSurface {
            let isTestingConnection = testingBaseline != nil
            let isVerifyingAfterAuthorization = !isTestingConnection
                && cursorFigmaObservationPresentationPhase == .postAuthorizationVerification
            return .init(
                id: .cursor,
                displayName: displayName,
                status: isVerifyingAfterAuthorization ? .connecting : .checking,
                message: isVerifyingAfterAuthorization
                    ? "Verifying Figma access through Cursor CLI."
                    : "Checking Cursor's documented Figma MCP tool surface.",
                verifiedAt: testingBaseline?.verifiedAt,
                timestampPresentation: testingBaseline?.timestampPresentation ?? .lastVerified,
                connectionSummary: isTestingConnection
                    ? cursorCheckingConnectionSummary
                    : nil,
                actions: testingBaseline.map(connectionTestActions) ?? [],
                isTestingConnection: isTestingConnection,
                isError: false
            )
        }
        switch cursorFigmaToolSurfaceObservation {
        case let .candidate(candidate) where candidate.expiresAt > Date():
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .connected,
                message: cursorFigmaDisableErrorMessage
                    ?? "Figma is connected.",
                verifiedAt: candidate.observedAt,
                timestampPresentation: .observed(validUntil: candidate.expiresAt),
                connectionSummary: cursorObservedConnectionSummary,
                actions: cursorFigmaConnectedActions(for: displayName),
                isError: cursorFigmaDisableErrorMessage != nil
            )
        case let .unavailable(diagnostic):
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .needsLogin,
                message: diagnostic.message,
                verifiedAt: nil,
                actions: cursorFigmaConnectAction(for: displayName),
                isError: false
            )
        case .candidate(_), nil:
            return .init(
                id: .cursor,
                displayName: displayName,
                status: .needsLogin,
                message: "Cursor Figma tool-surface observation is unavailable.",
                verifiedAt: nil,
                actions: cursorFigmaConnectAction(for: displayName),
                isError: false
            )
        }
    }

    private func cursorFigmaConnectedActions(
        for providerName: String,
        isDisconnecting: Bool = false
    ) -> [FigmaMCPProviderRowActionPresentation] {
        guard cursorFigmaObservationLaunch != nil else { return [] }
        var actions = [providerAction(
            action: .testConnection,
            title: "Test Connection",
            symbol: "antenna.radiowaves.left.and.right",
            isDisabled: isDisconnecting,
            accessibilityLabel: "Test Figma connection through \(providerName)",
            accessibilityHint: "Checks Cursor's current Figma MCP tool surface without changing its configuration."
        )]
        if cursorFigmaDisableExecutor != nil {
            actions.append(providerAction(
                action: .disconnect,
                title: "Disconnect",
                symbol: "rectangle.portrait.and.arrow.right",
                isLoading: isDisconnecting,
                isDisabled: isDisconnecting,
                accessibilityLabel: isDisconnecting ? "Disconnecting Figma in \(providerName)" : "Disconnect Figma in \(providerName)",
                accessibilityHint: "Disables Cursor's Figma MCP integration while keeping its configuration and OAuth credentials."
            ))
        }
        return actions
    }

    private func cursorFigmaConnectAction(
        for providerName: String
    ) -> [FigmaMCPProviderRowActionPresentation] {
        guard cursorFigmaLoginComponents != nil,
              cursorFigmaLoginDriver != nil,
              cursorFigmaLoginPreflight?.permitsLogin == true
        else { return [] }
        return [providerAction(
            action: .connect,
            title: "Connect",
            symbol: "link",
            accessibilityLabel: "Connect Figma for \(providerName)",
            accessibilityHint: "Runs cursor-agent mcp login figma. Cursor opens and manages the Figma browser sign-in."
        )]
    }

    private func cursorLoginAvailabilityMessage(
        _ availability: FigmaMCPProviderLoginAvailability
    ) -> String {
        switch availability {
        case .available:
            "Cursor Figma login is available."
        case .missingTarget:
            "Cursor's standard user profile does not contain one canonical Figma MCP target."
        case .ambiguousTarget:
            "Cursor's standard user profile contains multiple Figma MCP targets."
        case .untrustedCredentialContext:
            "Cursor Figma login is unavailable for a custom credential context."
        case let .unavailable(message):
            message
        }
    }

    private func providerSignOutAction(
        for provider: ExternalMCPRuntimeProvider,
        providerName: String
    ) -> [FigmaMCPProviderRowActionPresentation] {
        guard figmaProviderConnectionCoordinator.canSignOut(provider: provider) else { return [] }
        return [providerAction(
            action: .disconnect,
            title: "Sign Out",
            symbol: "rectangle.portrait.and.arrow.right",
            accessibilityLabel: "Sign Out of Figma in \(providerName)",
            accessibilityHint: "Asks \(providerName) to clear its provider-owned Figma MCP OAuth credentials."
        )]
    }

    private func providerAction(
        action: FigmaMCPProviderRowAction,
        title: String,
        symbol: String,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        accessibilityLabel: String,
        accessibilityHint: String
    ) -> FigmaMCPProviderRowActionPresentation {
        .init(
            id: action,
            title: title,
            systemImage: symbol,
            isLoading: isLoading,
            isDisabled: isDisabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: accessibilityHint
        )
    }

    /// Production Devin's capability gate takes presentation precedence over an async
    /// coordinator status; this row projection never grants Connected proof or authority.
    private func providerConnectionState(
        for provider: ExternalMCPRuntimeProvider
    ) -> FigmaMCPProviderConnectionState {
        guard let registration = figmaProviderConnectionCoordinator.registry.registration(for: provider) else {
            return .unsupported
        }
        if provider == .devin,
           case .unverified(.liveGatePending) = registration.figmaCapabilities.loginSupport,
           case .unverified(.noStructuredProofContract) = registration.figmaCapabilities.proofSupport
        {
            return .unsupported
        }
        if let state = figmaProviderConnectionCoordinator.state(for: provider) {
            return state
        }
        switch registration.figmaCapabilities.proofSupport {
        case .codexManaged, .unsupported:
            return .unsupported
        case let .unverified(reason):
            if case .verified = registration.figmaCapabilities.loginSupport {
                return .notVerified(loginAvailability: .available, notice: nil)
            }
            if case let .unverified(loginReason) = registration.figmaCapabilities.loginSupport {
                let message = if loginReason == .liveGatePending {
                    "Figma MCP login is currently pending verification for this provider"
                } else {
                    "Provider Figma login is pending its evidence gate (\(loginReason))."
                }
                return .unavailable(message)
            }
            return .unavailable("Provider Figma proof is pending its evidence gate (\(reason)).")
        case .verified:
            switch registration.figmaCapabilities.loginSupport {
            case .codexManaged, .unsupported:
                return .unsupported
            case .verified:
                return .notVerified(loginAvailability: .available, notice: nil)
            case let .unverified(reason):
                let message = if reason == .liveGatePending {
                    "Figma MCP login is currently pending verification for this provider"
                } else {
                    "Provider Figma login is pending its evidence gate (\(reason))."
                }
                return .unavailable(message)
            }
        }
    }

    private func unsupportedProviderMessage(providerName: String) -> String {
        "\(providerName) does currently not support Figma MCP in RepoPrompt CE."
    }

    private func loginAction(
        for provider: ExternalMCPRuntimeProvider,
        providerName: String
    ) -> [FigmaMCPProviderRowActionPresentation] {
        guard provider != .codex,
              let registration = figmaProviderConnectionCoordinator.registry.registration(for: provider),
              case .verified = registration.figmaCapabilities.loginSupport,
              registration.loginDriver != nil,
              registration.targetResolver != nil
        else { return [] }

        if case let .notVerified(availability, _) = providerConnectionState(for: provider),
           availability != .available
        {
            return []
        }

        return [providerAction(
            action: .connect,
            title: "Connect",
            symbol: "link",
            accessibilityLabel: "Connect Figma for \(providerName)",
            accessibilityHint: "Starts the \(providerName) login command. \(providerName) opens and manages the Figma browser sign-in."
        )]
    }

    private func retryConnectionAction(
        for provider: ExternalMCPRuntimeProvider,
        providerName: String
    ) -> [FigmaMCPProviderRowActionPresentation] {
        [providerAction(
            action: .connect,
            title: "Retry Connection",
            symbol: "arrow.clockwise",
            accessibilityLabel: "Retry Figma connection for \(providerName)",
            accessibilityHint: "Starts the \(providerName) Figma login again."
        )]
    }

    private func cancelLoginAction(
        for provider: ExternalMCPRuntimeProvider,
        providerName: String,
        isLoading: Bool = false
    ) -> FigmaMCPProviderRowActionPresentation {
        providerAction(
            action: .cancelLogin,
            title: "Cancel Login",
            symbol: "xmark.circle",
            isLoading: isLoading,
            accessibilityLabel: "Cancel Figma login for \(providerName)",
            accessibilityHint: "Stops only the active \(providerName) provider login process. Provider-side credentials may already have changed."
        )
    }

    private func providerNotice(
        _ notice: FigmaMCPProviderLoginNotice?,
        providerName: String
    ) -> String {
        switch notice {
        case .processCompletedWithoutProof:
            "The \(providerName) Figma login command finished, but RepoPrompt CE cannot verify current Figma access."
        case .providerProcessFailed:
            "The \(providerName) Figma login command failed. RepoPrompt CE could not verify current Figma access."
        case .authorizationSessionClosed:
            "The \(providerName) Figma authorization terminal was closed."
        case .timedOutAuthenticationStateUnknown:
            "The \(providerName) Figma login timed out. Provider-side credentials may already have changed; RepoPrompt CE cannot verify or undo that state."
        case .cancelledAuthenticationStateUnknown:
            "The \(providerName) Figma login was cancelled. Provider-side credentials may already have changed; RepoPrompt CE cannot verify or undo that state."
        case .credentialLogoutUnverified:
            "\(providerName) did not provide conclusive Figma logout status. You can retry Sign Out."
        case .targetUnavailable:
            "The canonical Figma target could not be verified for \(providerName)."
        case nil:
            "\(providerName) Figma login is not verified."
        }
    }

    var connectionSummary: FigmaMCPSettingsConnectionSummary? {
        guard contentMode == .connected else { return nil }
        let authentication = presentationState == .testing
            ? "Checking Figma sign-in through Codex"
            : "Figma sign-in verified through Codex"
        return .init(rows: [
            .connection("Figma MCP"),
            .authentication(authentication),
            .credentialOwner("Managed by Codex")
        ])
    }

    private func verifiedConnectionSummary(
        providerName: String
    ) -> FigmaMCPSettingsConnectionSummary {
        .init(rows: [
            .connection("Figma MCP"),
            .authentication("Figma sign-in verified through \(providerName)"),
            .credentialOwner("Managed by \(providerName)")
        ])
    }

    private func checkingConnectionSummary(
        providerName: String
    ) -> FigmaMCPSettingsConnectionSummary {
        .init(rows: [
            .connection("Figma MCP"),
            .authentication("Checking Figma sign-in through \(providerName)"),
            .credentialOwner("Managed by \(providerName)")
        ])
    }

    private func connectionTestActions(
        from baseline: FigmaMCPProviderRowPresentation
    ) -> [FigmaMCPProviderRowActionPresentation] {
        baseline.actions.map { action in
            .init(
                id: action.id,
                title: action.title,
                systemImage: action.systemImage,
                isLoading: action.id == .testConnection,
                isDisabled: true,
                accessibilityLabel: action.id == .testConnection
                    ? "Testing Figma connection through \(baseline.displayName)"
                    : action.accessibilityLabel,
                accessibilityHint: action.accessibilityHint
            )
        }
    }

    private var cursorCheckingConnectionSummary: FigmaMCPSettingsConnectionSummary {
        .init(rows: [
            .connection("Figma MCP"),
            .authentication("Checking Cursor's documented Figma MCP tool surface"),
            .credentialOwner("Managed by Cursor CLI")
        ])
    }

    private var cursorObservedConnectionSummary: FigmaMCPSettingsConnectionSummary {
        .init(rows: [
            .connection("Figma MCP"),
            .authentication("Figma sign-in not independently verified by RepoPrompt CE"),
            .credentialOwner("Managed by Cursor CLI")
        ])
    }

    var isAuthenticatedConnection: Bool {
        isCodexConnected
            && presentationState == .connected
            && definition?.repoPromptActivation == .enabled
            && snapshot.authentication == .authenticated
            && figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime
    }

    var showsPrimaryAction: Bool {
        presentation.primaryAction != nil
    }

    var showsTestAction: Bool {
        presentation.primaryAction == .testConnection
    }

    var showsSignOutAction: Bool {
        // A managed definition is created before browser authorization completes. It alone is not
        // evidence of Codex credentials, so a cancelled or failed first-time login must not offer
        // Sign Out. Keep the recovery path for credentials we know were authenticated or expired,
        // and for a failed prior sign-out that still requires explicit credential revocation.
        presentation.showsSignOutAction
            && (
                isAuthenticatedConnection
                    || snapshot.authentication == .expired
                    || figmaMCPCoordinator.credentialRevocationRequired
            )
    }

    var signOutActionIsDisabled: Bool {
        presentation.signOutIsDisabled || isPerformingOperation || presentationStateIsCancellationFinalizing
    }

    var isTestingConnection: Bool {
        currentOperationKind == .test
    }

    var isSigningOut: Bool {
        currentOperationKind == .signOut
    }

    var primaryActionIsLoading: Bool {
        presentation.primaryAction == .operationInProgress
    }

    var primaryActionIsDisabled: Bool {
        primaryActionIsLoading || isPerformingOperation
    }

    var isObservedAppWideOperation: Bool {
        !isPerformingOperation && figmaMCPCoordinator.hasInteractiveSettingsOperation
    }

    var authorizationHandoffOutcome: FigmaMCPSettingsAuthorizationHandoffOutcome? {
        latestAuthorizationHandoff
    }

    var presentationStateIsCancellationFinalizing: Bool {
        presentationState == .cancellationFinalizing
    }

    var connectionStatusAccessibilityLabel: String {
        "Figma connection status: \(connectionStatus.accessibilityLabel)"
    }

    var lastSuccessfulCheck: Date? {
        isAuthenticatedConnection ? snapshot.lastSuccessfulCheck : nil
    }

    var connectionMessage: String? {
        if presentationState == .codexUnavailable {
            return "Connect Codex in CLI Providers before setting up Figma."
        }
        if presentationState == .credentialRevocationRequired {
            return figmaMCPCoordinator.credentialRevocationNotice
                ?? "RepoPrompt CE stopped Figma access, but Codex did not confirm credential removal. Choose Sign Out to try again."
        }
        return notice
    }

    var connectionMessageIsError: Bool {
        if presentationState == .codexUnavailable { return false }
        if presentationState == .credentialRevocationRequired { return true }
        return noticeIsError
    }

    var primaryActionTitle: String {
        switch presentation.primaryAction {
        case .connect: "Connect"
        case .operationInProgress:
            switch currentOperationKind {
            case .connect, .reauthenticate: "Connect"
            case .useExistingConnection: "Use Existing Connection"
            case .test: "Test Connection"
            case .refresh, .verifyAuthentication, .awaitAuthorizationCompletion, .signOut, nil: "Check Connection"
            }
        case .useExistingConnection: "Use Existing Connection"
        case .checkConnection: "Check Connection"
        case .testConnection: "Test Connection"
        case .reauthenticate: "Connect"
        case .retryConnection: "Retry Connection"
        case .openCLIProviders: "Open CLI Providers"
        case nil: ""
        }
    }

    var primaryActionSymbol: String {
        switch presentation.primaryAction {
        case .connect, .useExistingConnection, .reauthenticate: "link"
        case .operationInProgress:
            switch currentOperationKind {
            case .connect, .reauthenticate: "link"
            case .useExistingConnection: "link"
            case .test, .refresh, .verifyAuthentication, .awaitAuthorizationCompletion, .signOut, nil:
                "antenna.radiowaves.left.and.right"
            }
        case .checkConnection, .testConnection: "antenna.radiowaves.left.and.right"
        case .retryConnection: "arrow.clockwise"
        case .openCLIProviders: "terminal"
        case nil: ""
        }
    }

    var primaryActionAccessibilityLabel: String {
        if isSigningOut { return "Signing out of Figma" }
        if isTestingConnection { return "Testing Figma connection" }
        if presentation.primaryAction == .operationInProgress || isPerformingOperation {
            switch currentOperationKind {
            case .connect, .reauthenticate: return "Connecting Figma"
            case .useExistingConnection: return "Using existing Figma connection"
            case .verifyAuthentication: return "Checking Figma login"
            case .awaitAuthorizationCompletion: return "Waiting for Figma sign in to complete"
            case .refresh: return "Checking Figma connection"
            case nil: return "Checking Figma connection"
            case .test: return "Testing Figma connection"
            case .signOut: return "Signing out of Figma"
            }
        }
        return primaryActionTitle
    }

    var primaryActionAccessibilityHint: String {
        switch presentation.primaryAction {
        case .connect: "Checks for an existing Figma connection, then starts validated Figma sign in if needed."
        case .operationInProgress: "Wait for the current Figma operation to finish."
        case .useExistingConnection: "Uses the existing canonical Figma connection without changing its Codex configuration."
        case .checkConnection: "Verifies whether Figma sign in has completed."
        case .testConnection: "Checks the current Figma connection."
        case .reauthenticate: "Starts Figma sign in in your browser."
        case .retryConnection: "Retries the current Figma connection check."
        case .openCLIProviders: "Opens CLI Providers, where you can connect Codex before setting up Figma."
        case nil: ""
        }
    }

    var signOutActionAccessibilityHint: String {
        "Signs out of Figma in RepoPrompt CE and removes its app-wide connection. Codex sign-in remains unchanged."
    }

    private var cancellationNotice: String {
        isSigningOut ? "Finishing Sign Out…" : "Cancelling Figma operation…"
    }

    private var isAwaitingBrowserAuthorization: Bool {
        latestAuthorizationHandoff == .awaitingBrowserAuthorization
    }

    func updateCLIAvailability(_ availability: AgentModelCatalog.AvailabilityContext) {
        guard cliAvailability != availability else { return }
        let wasCodexConnected = isCodexConnected
        cliAvailability = availability
        let connected = isCodexConnected
        guard wasCodexConnected != connected else { return }
        if !connected,
           (isPerformingOperation && currentOperationKind?.requiresCodexConnection == true)
           || isAwaitingBrowserAuthorization
        {
            cancelCurrentOperation()
        }
        pendingPresentationEvent = nil
        latestPresentationResult = nil
        latestPresentationRevision = nil
        latestAuthorizationHandoff = nil
        pendingAutomaticAuthorizationSourceRequestID = nil
        notice = nil
        noticeIsError = false

        if !connected {
            return
        }

        guard isActive,
              !isPerformingOperation,
              !figmaMCPCoordinator.credentialRevocationRequired,
              definition?.repoPromptActivation == .enabled
        else { return }
        run(.refresh)
    }

    func activateAndLoad() {
        guard !isActive else { return }
        isActive = true
        lastAcceptedCoordinatorRevision = max(lastAcceptedCoordinatorRevision, figmaMCPCoordinator.state.revision)
        definition = figmaMCPCoordinator.currentDefinition
        snapshot = sanitizedSnapshot(figmaMCPCoordinator.state.connection)
        figmaProviderConnectionCoordinator.activate(observerID: ownerID.uuidString)
        startCursorFigmaLoginPreflight()
        latestPresentationResult = nil
        latestPresentationRevision = nil
        latestAuthorizationHandoff = nil
        pendingAutomaticAuthorizationSourceRequestID = nil
        pendingPresentationEvent = nil
        activeRequestID = nil
        guard let definition, definition.repoPromptActivation == .enabled else { return }
        guard !figmaMCPCoordinator.credentialRevocationRequired else { return }
        guard isCodexConnected else { return }
        guard !figmaMCPCoordinator.hasInteractiveSettingsOperation else {
            notice = FigmaMCPSettingsActionResult.busy.notice
            noticeIsError = false
            return
        }
        run(.refresh)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        if let availabilityWaiterID {
            figmaMCPCoordinator.cancelAvailabilityNotification(id: availabilityWaiterID)
        }
        availabilityWaiterID = nil
        waitingForCoordinator = false
        operationTask?.cancel()
        operationTask = nil
        cursorFigmaPreflightTask?.cancel()
        cursorFigmaPreflightTask = nil
        cursorFigmaObservationGeneration &+= 1
        cursorFigmaObservationTask?.cancel()
        cursorFigmaObservationTask = nil
        cursorFigmaLoginTask?.cancel()
        cursorFigmaLoginTask = nil
        cursorFigmaLoginTimeoutTask?.cancel()
        cursorFigmaLoginTimeoutTask = nil
        cursorFigmaDisableTask?.cancel()
        cursorFigmaDisableTask = nil
        if let attemptID = cursorFigmaLoginAttemptID,
           let driver = cursorFigmaLoginDriver
        {
            Task { await driver.cancelLogin(provider: .cursor, attemptID: attemptID) }
        }
        cursorFigmaLoginAttemptID = nil
        cursorFigmaObservationLaunch = nil
        cursorFigmaObservationPresentationPhase = nil
        cursorFigmaLoginPreflight = nil
        isAuthorizingCursorFigma = false
        isDisconnectingCursorFigma = false
        cursorFigmaObservationExpiryTask?.cancel()
        cursorFigmaObservationExpiryTask = nil
        cursorFigmaToolSurfaceObservation = nil
        cursorFigmaDisableErrorMessage = nil
        isObservingCursorFigmaToolSurface = false
        providerConnectionTestBaselines.removeAll()
        figmaProviderConnectionCoordinator.deactivate(observerID: ownerID.uuidString)
        activeRequestID = nil
        pendingAutomaticAuthorizationSourceRequestID = nil
        pendingPresentationEvent = nil
        isPerformingOperation = false
        currentOperationKind = nil
        figmaMCPCoordinator.deactivateSettingsOwner(ownerID: ownerID)
    }

    /// Compatibility entry point for Settings callers.
    func load() {
        activateAndLoad()
    }

    func performPrimaryAction() {
        guard isActive, !isPerformingOperation else { return }
        if presentation.primaryAction == .openCLIProviders {
            openCLIProviders()
            return
        }
        guard isCodexConnected else { return }
        switch presentation.primaryAction {
        case .connect: run(.connect)
        case .operationInProgress: break
        case .useExistingConnection: run(.useExistingConnection)
        case .checkConnection: run(.verifyAuthentication)
        case .testConnection:
            retainConnectionTestBaseline(provider: .codex)
            run(.test)
        case .reauthenticate: run(.reauthenticate)
        case .retryConnection:
            run(latestAuthorizationHandoff == .browserOpenFailed ? .reauthenticate : .refresh)
        case .openCLIProviders: openCLIProviders()
        case nil: break
        }
    }

    func connectOrReauthenticate() {
        performPrimaryAction()
    }

    /// Retained as a compatibility seam; discovery is now only initiated by Connect.
    func discoverExistingImport() {
        guard isCodexConnected, presentationState == .fresh else { return }
        run(.connect)
    }

    func testConnection() {
        guard isActive, isCodexConnected else { return }
        if presentationState == .awaitingBrowserAuthorization || presentationState == .authorizationRequired {
            run(.verifyAuthentication)
        } else if isAuthenticatedConnection {
            performPrimaryAction()
        }
    }

    private func retainConnectionTestBaseline(
        provider: ExternalMCPRuntimeProvider,
        row: FigmaMCPProviderRowPresentation? = nil
    ) {
        guard providerConnectionTestBaselines[provider] == nil,
              let row = row ?? providerRows.first(where: { $0.id == provider }),
              row.status == .connected
        else { return }
        providerConnectionTestBaselines[provider] = row
    }

    func signOut() {
        guard isActive, isCodexConnected, showsSignOutAction, !isPerformingOperation else { return }
        run(.signOut)
    }

    #if DEBUG
        func test_setBeforeApplyingResponse(_ hook: (@MainActor () async -> Void)?) {
            test_beforeApplyingResponse = hook
        }
    #endif

    func consumePresentationEvent(id: UUID) {
        guard pendingPresentationEvent?.id == id else { return }
        pendingPresentationEvent = nil
    }

    func isCurrentPresentationEvent(_ event: FigmaMCPSettingsPresentationEvent) -> Bool {
        guard pendingPresentationEvent == event,
              Self.isCurrentPresentationGeneration(
                  event.coordinatorGeneration,
                  currentRevision: figmaMCPCoordinator.state.revision,
                  kind: event.kind,
                  runtimeRevision: figmaMCPCoordinator.runtimeAvailability.revision
              )
        else { return false }

        switch event.kind {
        case .loginCompleted:
            let definition = figmaMCPCoordinator.currentDefinition
            return isCodexConnected
                && definition?.repoPromptActivation == .enabled
                && figmaMCPCoordinator.state.definition == definition
                && figmaMCPCoordinator.state.connection.state == .connected
                && figmaMCPCoordinator.state.connection.authentication == .authenticated
                && figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime
        case .signOutCompleted:
            return figmaMCPCoordinator.currentDefinition == nil
                && figmaMCPCoordinator.state.definition == nil
                && figmaMCPCoordinator.state.connection.state == .notConfigured
                && !figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime
        }
    }

    static func isCurrentPresentationGeneration(
        _ receiptGeneration: UInt64,
        currentRevision: UInt64,
        kind: FigmaMCPSettingsPresentationEvent.Kind,
        runtimeRevision: UInt64
    ) -> Bool {
        switch kind {
        case .loginCompleted:
            receiptGeneration == currentRevision && receiptGeneration == runtimeRevision
        case .signOutCompleted:
            // Explicit revocation advances the runtime revision once after the operation lease.
            currentRevision == receiptGeneration &+ 1 && runtimeRevision == currentRevision
        }
    }

    func cancelCurrentOperation() {
        guard isPerformingOperation || isAwaitingBrowserAuthorization else { return }
        // Retire the browser handoff before asking the coordinator to cancel. This fences a
        // completion that races the X action while the handoff settlement is still in flight.
        pendingAutomaticAuthorizationSourceRequestID = nil
        latestAuthorizationHandoff = nil
        if !isPerformingOperation {
            latestPresentationResult = .cancelled
            latestPresentationRevision = figmaMCPCoordinator.state.revision
            snapshot = .init(
                state: .authorizationRequired,
                authentication: .notLoggedIn,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            )
            notice = FigmaMCPSettingsActionResult.cancelled.notice
            noticeIsError = false
        } else {
            notice = cancellationNotice
            noticeIsError = false
        }
        figmaMCPCoordinator.cancelSettingsOperation(ownerID: ownerID)
    }

    private func run(
        _ action: FigmaMCPSettingsOperationKind,
        preservingAuthorizationHandoff: Bool = false
    ) {
        guard isActive,
              !isPerformingOperation,
              !isAwaitingBrowserAuthorization || action == .awaitAuthorizationCompletion
        else { return }
        guard isCodexConnected || !action.requiresCodexConnection else {
            notice = nil
            noticeIsError = false
            return
        }
        if action != .awaitAuthorizationCompletion {
            pendingAutomaticAuthorizationSourceRequestID = nil
        }
        currentOperationKind = action
        isPerformingOperation = true
        latestPresentationResult = nil
        if !preservingAuthorizationHandoff {
            latestAuthorizationHandoff = nil
        }
        notice = initialNotice(for: action)
        noticeIsError = false
        let requestID = UUID()
        activeRequestID = requestID
        operationTask = Task { [weak self] in
            guard let self else { return }
            let response = await figmaMCPCoordinator.performSettingsAction(
                action.coordinatorAction,
                requestID: requestID,
                ownerID: ownerID,
                windowID: windowID
            )
            #if DEBUG
                await test_beforeApplyingResponse?()
            #endif
            let disposition = apply(response, expectedRequestID: requestID, action: action)
            if let authorizationRequest = response.result.authorizationRequest,
               let disposition
            {
                if disposition == .opened {
                    // Start the existing bounded authoritative wait before handoff settlement can
                    // suspend. Otherwise an abandoned browser flow can remain Authorizing without
                    // the coordinator's timeout or manual-cancellation lease being active.
                    startAutomaticAuthorizationCompletion(sourceRequestID: requestID)
                }
                let authorizationRequestID = authorizationRequest.id
                let coordinator = figmaMCPCoordinator
                Task {
                    await coordinator.settleAuthorizationHandoff(
                        id: authorizationRequestID,
                        disposition: disposition
                    )
                }
            }
        }
    }

    private func startAutomaticAuthorizationCompletion(sourceRequestID: UUID) {
        guard isActive,
              isCodexConnected,
              !isPerformingOperation,
              activeRequestID == nil,
              pendingAutomaticAuthorizationSourceRequestID == sourceRequestID,
              latestAuthorizationHandoff == .awaitingBrowserAuthorization,
              let definition,
              definition.repoPromptActivation == .enabled
        else { return }
        pendingAutomaticAuthorizationSourceRequestID = nil
        run(.awaitAuthorizationCompletion, preservingAuthorizationHandoff: true)
    }

    private func apply(
        _ response: FigmaMCPSettingsActionResponse,
        expectedRequestID: UUID,
        action: FigmaMCPSettingsOperationKind
    ) -> FigmaMCPAuthorizationHandoffDisposition? {
        let abandonedHandoff: FigmaMCPAuthorizationHandoffDisposition? =
            response.result.authorizationRequest == nil ? nil : .abandoned
        guard isActive,
              activeRequestID == expectedRequestID,
              response.requestID == expectedRequestID
        else { return abandonedHandoff }

        let currentRevision = figmaMCPCoordinator.state.revision
        guard response.coordinatorRevision == currentRevision,
              response.coordinatorRevision >= lastAcceptedCoordinatorRevision
        else {
            settleStaleResponse()
            return abandonedHandoff
        }
        lastAcceptedCoordinatorRevision = response.coordinatorRevision
        if let receipt = response.receipt {
            guard receipt.requestID == expectedRequestID,
                  receipt.ownerID == ownerID,
                  receipt.windowID == windowID,
                  receipt.action == action.coordinatorAction
            else { return abandonedHandoff }
        }

        var presentationResult = response.result
        var authorizationHandoff: FigmaMCPSettingsAuthorizationHandoffOutcome?
        var handoffDisposition = abandonedHandoff
        if let authorizationRequest = response.result.authorizationRequest {
            let url = authorizationRequest.url
            if !isCodexConnected {
                presentationResult = .cancelled
            } else if !FigmaMCPOAuthAuthorizationURL.isValid(url) {
                presentationResult = .init(
                    snapshot: .init(state: .failed, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
                    notice: "Figma authorization could not be started. Try again.",
                    isError: true,
                    foundCanonicalImport: false,
                    authorizationRequest: nil
                )
            } else if !openAuthorizationURL(url) {
                authorizationHandoff = .browserOpenFailed
                presentationResult = .init(
                    snapshot: .init(state: .failed, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
                    notice: "Figma authorization could not be opened. Choose Retry Connection to try again.",
                    isError: true,
                    foundCanonicalImport: false,
                    authorizationRequest: nil
                )
            } else {
                // The validated URL is a one-shot handoff value; never retain it in presentation state.
                authorizationHandoff = .awaitingBrowserAuthorization
                pendingAutomaticAuthorizationSourceRequestID = expectedRequestID
                handoffDisposition = .opened
                presentationResult = .init(
                    snapshot: response.result.snapshot,
                    notice: response.result.notice,
                    isError: response.result.isError,
                    foundCanonicalImport: response.result.foundCanonicalImport,
                    authorizationRequest: nil
                )
            }
        }
        // The automatic wait is bounded. Once it finishes without verified authentication,
        // return to the ordinary Needs login state rather than inferring anything about the
        // browser tab that received the one-shot handoff.
        latestAuthorizationHandoff = authorizationHandoff
        latestPresentationResult = presentationResult
        latestPresentationRevision = response.coordinatorRevision
        definition = figmaMCPCoordinator.currentDefinition
        snapshot = sanitizedSnapshot(presentationResult.snapshot)
        notice = presentationResult.notice
        noticeIsError = presentationResult.isError
        isPerformingOperation = false
        currentOperationKind = nil
        activeRequestID = nil
        operationTask = nil

        if let receipt = response.receipt,
           let completion = validatedCompletion(for: receipt, response: response, handoff: authorizationHandoff)
        {
            let kind: FigmaMCPSettingsPresentationEvent.Kind = switch completion {
            case .loginCompleted: .loginCompleted
            case .signOutCompleted: .signOutCompleted
            }
            pendingPresentationEvent = .init(
                id: UUID(),
                requestID: receipt.requestID,
                ownerID: receipt.ownerID,
                windowID: receipt.windowID,
                coordinatorGeneration: receipt.generation,
                kind: kind
            )
        }
        if action == .signOut, presentationResult.snapshot.state == .notConfigured {
            snapshot = .notConfigured
        }
        if presentationResult.notice == FigmaMCPSettingsActionResult.busy.notice {
            scheduleAvailabilityRetry()
        }
        return handoffDisposition
    }

    private func settleStaleResponse() {
        latestPresentationResult = nil
        latestPresentationRevision = nil
        latestAuthorizationHandoff = nil
        pendingAutomaticAuthorizationSourceRequestID = nil
        definition = figmaMCPCoordinator.currentDefinition
        snapshot = sanitizedSnapshot(figmaMCPCoordinator.state.connection)
        isPerformingOperation = false
        currentOperationKind = nil
        activeRequestID = nil
        operationTask = nil
    }

    private func validatedCompletion(
        for receipt: FigmaMCPSettingsActionReceipt,
        response: FigmaMCPSettingsActionResponse,
        handoff: FigmaMCPSettingsAuthorizationHandoffOutcome?
    ) -> FigmaMCPSettingsVerifiedCompletion? {
        guard handoff == nil,
              response.result.authorizationRequest == nil,
              let completion = receipt.completion
        else { return nil }

        let state = figmaMCPCoordinator.state
        let eventKind: FigmaMCPSettingsPresentationEvent.Kind = switch completion {
        case .loginCompleted: .loginCompleted
        case .signOutCompleted: .signOutCompleted
        }
        guard Self.isCurrentPresentationGeneration(
            receipt.generation,
            currentRevision: state.revision,
            kind: eventKind,
            runtimeRevision: figmaMCPCoordinator.runtimeAvailability.revision
        ) else { return nil }

        switch completion {
        case .loginCompleted:
            guard isCodexConnected,
                  receipt.action == .connect
                  || receipt.action == .useExistingConnection
                  || receipt.action == .reauthenticate
                  || receipt.action == .verifyAuthentication
                  || receipt.action == .awaitAuthorizationCompletion,
                  let definition = figmaMCPCoordinator.currentDefinition,
                  definition.repoPromptActivation == .enabled,
                  state.definition == definition,
                  state.connection.state == .connected,
                  state.connection.authentication == .authenticated,
                  figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime
            else { return nil }
        case .signOutCompleted:
            guard receipt.action == .signOut,
                  figmaMCPCoordinator.currentDefinition == nil,
                  state.definition == nil,
                  state.connection.state == .notConfigured,
                  !figmaMCPCoordinator.runtimeAvailability.hasAuthenticatedRuntime
            else { return nil }
        }
        return completion
    }

    private func scheduleAvailabilityRetry() {
        guard isActive, availabilityWaiterID == nil, !figmaMCPCoordinator.credentialRevocationRequired else { return }
        waitingForCoordinator = true
        let waiterID = UUID()
        availabilityWaiterID = waiterID
        figmaMCPCoordinator.notifyWhenSettingsOperationAvailable(id: waiterID) { [weak self] in
            guard let self, isActive, availabilityWaiterID == waiterID else { return }
            availabilityWaiterID = nil
            waitingForCoordinator = false
            guard !figmaMCPCoordinator.credentialRevocationRequired, !isPerformingOperation else { return }
            run(.refresh)
        }
    }

    private func startCursorFigmaLoginPreflight() {
        guard isActive,
              let components = cursorFigmaLoginComponents,
              let driver = cursorFigmaLoginDriver
        else { return }
        cursorFigmaPreflightTask?.cancel()
        cursorFigmaLoginPreflight = nil
        cursorFigmaPreflightTask = Task { [weak self] in
            let preflight = await components.evaluatePreflight(using: driver)
            guard !Task.isCancelled,
                  let self,
                  isActive
            else { return }
            cursorFigmaPreflightTask = nil
            cursorFigmaLoginPreflight = preflight
        }
    }

    private func startCursorFigmaToolSurfaceObservation(
        launch: FigmaMCPProviderResolvedLoginLaunch,
        presentationPhase: CursorFigmaObservationPresentationPhase,
        requiresEnable: Bool = false,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy = .allowCachedCandidate,
        terminalSessionAttemptID: UUID? = nil
    ) {
        guard isActive, let cursorFigmaToolSurfaceObserver else { return }
        cursorFigmaObservationGeneration &+= 1
        let generation = cursorFigmaObservationGeneration
        cursorFigmaObservationTask?.cancel()
        cursorFigmaObservationExpiryTask?.cancel()
        cursorFigmaObservationExpiryTask = nil
        cursorFigmaToolSurfaceObservation = nil
        cursorFigmaDisableErrorMessage = nil
        cursorFigmaObservationPresentationPhase = presentationPhase
        isObservingCursorFigmaToolSurface = true

        cursorFigmaObservationTask = Task { [weak self] in
            let outcome = await cursorFigmaToolSurfaceObserver.observe(
                launch: launch,
                requiresEnable: requiresEnable,
                cachePolicy: cachePolicy
            )
            guard !Task.isCancelled,
                  let self,
                  isActive,
                  cursorFigmaObservationGeneration == generation,
                  cursorFigmaObservationLaunch?.executableIdentity == launch.executableIdentity
            else { return }
            providerConnectionTestBaselines.removeValue(forKey: .cursor)
            cursorFigmaObservationTask = nil
            cursorFigmaObservationPresentationPhase = nil
            isObservingCursorFigmaToolSurface = false
            cursorFigmaToolSurfaceObservation = outcome
            if case let .candidate(candidate) = outcome {
                scheduleCursorFigmaObservationExpiry(candidate, launch: launch, generation: generation)
                if let terminalSessionAttemptID {
                    Task {
                        await FigmaMCPProviderTerminalHandoff.closeAfterVerifiedConnection(
                            provider: .cursor,
                            attemptID: terminalSessionAttemptID,
                            sessionController: terminalSessionController
                        )
                    }
                }
            }
        }
    }

    private func scheduleCursorFigmaObservationExpiry(
        _ candidate: CursorFigmaMCPToolSurfaceCandidate,
        launch: FigmaMCPProviderResolvedLoginLaunch,
        generation: UInt64
    ) {
        let secondsUntilExpiry = max(0, candidate.expiresAt.timeIntervalSinceNow)
        cursorFigmaObservationExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(secondsUntilExpiry * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  isActive,
                  cursorFigmaObservationGeneration == generation,
                  cursorFigmaToolSurfaceObservation == .candidate(candidate),
                  cursorFigmaObservationLaunch?.executableIdentity == launch.executableIdentity
            else { return }
            cursorFigmaObservationExpiryTask = nil
            cursorFigmaToolSurfaceObservation = nil
            startCursorFigmaToolSurfaceObservation(
                launch: launch,
                presentationPhase: .routineCheck
            )
        }
    }

    private func startCursorFigmaLogin() {
        guard isActive, isCLIAvailable(for: .cursor),
              !isAuthorizingCursorFigma,
              cursorFigmaLoginPreflight?.permitsLogin == true,
              let components = cursorFigmaLoginComponents,
              let driver = cursorFigmaLoginDriver
        else { return }

        cursorFigmaObservationGeneration &+= 1
        cursorFigmaObservationTask?.cancel()
        cursorFigmaObservationTask = nil
        cursorFigmaObservationExpiryTask?.cancel()
        cursorFigmaObservationExpiryTask = nil
        cursorFigmaObservationLaunch = nil
        cursorFigmaObservationPresentationPhase = nil
        cursorFigmaToolSurfaceObservation = nil
        isObservingCursorFigmaToolSurface = false
        cursorFigmaDisableErrorMessage = nil
        isAuthorizingCursorFigma = true
        let attemptID = UUID()
        cursorFigmaLoginAttemptID = attemptID
        scheduleCursorFigmaLoginTimeout(attemptID: attemptID, driver: driver)

        cursorFigmaLoginTask = Task { [weak self] in
            let reservation = await driver.reserveAttempt(attemptID)
            guard !Task.isCancelled else {
                await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
                return
            }
            switch reservation {
            case .busy:
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .busy)
                return
            case .cancelled:
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
                return
            case .reserved:
                break
            }

            let prepared = await components.prepareAttempt(attemptID, using: driver)
            guard !Task.isCancelled, let prepared else {
                await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
                self?.finishCursorFigmaLogin(
                    attemptID: attemptID,
                    settlement: Task.isCancelled ? .cancelled : .launchFailed
                )
                return
            }
            guard !Task.isCancelled else {
                await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
                return
            }
            self?.cursorFigmaObservationLaunch = prepared.launch
            let context = FigmaMCPProviderLoginAttemptContext(
                provider: .cursor,
                target: .figma,
                providerTargetIdentifier: prepared.providerTargetIdentifier,
                credentialContext: prepared.credentialContext,
                attemptID: attemptID,
                evidenceID: prepared.evidence.evidenceID,
                capabilityRevision: prepared.evidence.capabilityRevision,
                executableIdentity: prepared.launch.executableIdentity.canonicalPath,
                executableVersion: prepared.launch.executableVersion
            )
            guard !Task.isCancelled else {
                await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
                return
            }
            let settlement = await driver.beginLogin(
                provider: .cursor,
                target: .figma,
                attemptContext: context
            )
            guard !Task.isCancelled else {
                await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
                self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
                return
            }
            self?.finishCursorFigmaLogin(attemptID: attemptID, settlement: settlement)
        }
    }

    private func scheduleCursorFigmaLoginTimeout(
        attemptID: UUID,
        driver: FigmaMCPProviderSubprocessLoginDriver
    ) {
        cursorFigmaLoginTimeoutTask?.cancel()
        cursorFigmaLoginTimeoutTask = Task { [weak self] in
            let requestedTimeout = driver.loginTimeout
            guard !Task.isCancelled else { return }
            let timeout = Self.effectiveCursorFigmaLoginTimeout(requestedTimeout)
            let timeoutNanoseconds = Self.clampedSleepNanoseconds(timeout)
            if timeoutNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.timeoutCursorFigmaLogin(attemptID: attemptID)
        }
    }

    private func timeoutCursorFigmaLogin(attemptID: UUID) {
        guard cursorFigmaLoginAttemptID == attemptID,
              let driver = cursorFigmaLoginDriver
        else { return }
        let loginTask = cursorFigmaLoginTask
        finishCursorFigmaLogin(attemptID: attemptID, settlement: .timedOut)
        loginTask?.cancel()
        Task {
            await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
        }
    }

    private static func effectiveCursorFigmaLoginTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite, requested >= 0 else { return cursorFigmaLoginMaximumTimeout }
        return min(requested, cursorFigmaLoginMaximumTimeout)
    }

    private static func clampedSleepNanoseconds(_ interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = interval * 1_000_000_000
        if !scaled.isFinite || scaled >= Double(UInt64.max) { return UInt64.max }
        return UInt64(scaled)
    }

    private func cancelCursorFigmaLogin() {
        guard let attemptID = cursorFigmaLoginAttemptID,
              let driver = cursorFigmaLoginDriver
        else { return }
        let loginTask = cursorFigmaLoginTask
        // Retire this attempt before the asynchronous child cancellation so a late process result
        // cannot restart observation or alter the post-cancel Needs login presentation.
        finishCursorFigmaLogin(attemptID: attemptID, settlement: .cancelled)
        loginTask?.cancel()
        Task {
            await driver.cancelLogin(provider: .cursor, attemptID: attemptID)
        }
    }

    private func testCursorFigmaConnection() {
        guard isActive, isCLIAvailable(for: .cursor),
              !isDisconnectingCursorFigma,
              let launch = cursorFigmaObservationLaunch
        else { return }
        startCursorFigmaToolSurfaceObservation(
            launch: launch,
            presentationPhase: .routineCheck,
            cachePolicy: .requireFreshObservation
        )
    }

    private func disconnectCursorFigma() {
        guard isActive, isCLIAvailable(for: .cursor),
              !isDisconnectingCursorFigma,
              let launch = cursorFigmaObservationLaunch,
              let cursorFigmaDisableExecutor
        else { return }

        isDisconnectingCursorFigma = true
        cursorFigmaDisableErrorMessage = nil
        cursorFigmaObservationExpiryTask?.cancel()
        cursorFigmaObservationExpiryTask = nil
        cursorFigmaDisableTask = Task { [weak self] in
            let outcome = await cursorFigmaDisableExecutor.disable(retainedLaunch: launch)
            guard !Task.isCancelled, let self, isActive else { return }
            finishCursorFigmaDisconnect(outcome)
        }
    }

    private func finishCursorFigmaDisconnect(_ outcome: CursorFigmaMCPDisableOutcome) {
        cursorFigmaDisableTask = nil
        isDisconnectingCursorFigma = false
        switch outcome {
        case .disabled:
            cursorFigmaObservationGeneration &+= 1
            cursorFigmaObservationTask?.cancel()
            cursorFigmaObservationTask = nil
            cursorFigmaObservationExpiryTask?.cancel()
            cursorFigmaObservationExpiryTask = nil
            cursorFigmaObservationLaunch = nil
            cursorFigmaObservationPresentationPhase = nil
            cursorFigmaToolSurfaceObservation = nil
            isObservingCursorFigmaToolSurface = false
            cursorFigmaDisableErrorMessage = nil
        case .timedOut:
            cursorFigmaDisableErrorMessage = "Cursor CLI did not finish disabling its Figma MCP integration."
        case .failed:
            cursorFigmaDisableErrorMessage = "Cursor CLI could not disable its Figma MCP integration."
        case .cancelled:
            break
        }
    }

    private func finishCursorFigmaLogin(
        attemptID: UUID,
        settlement: FigmaMCPProviderLoginSettlement
    ) {
        guard isActive, cursorFigmaLoginAttemptID == attemptID else { return }
        cursorFigmaLoginTask = nil
        cursorFigmaLoginTimeoutTask?.cancel()
        cursorFigmaLoginTimeoutTask = nil
        cursorFigmaLoginAttemptID = nil
        isAuthorizingCursorFigma = false
        if case .exited(status: 0) = settlement,
           let launch = cursorFigmaObservationLaunch
        {
            // Process exit is not browser or authentication proof. Re-enable the configured
            // MCP, then verify the retained-launch tool surface before presenting Connected.
            // Every new login (including reconnect after RepoPrompt Disconnect) requires enable.
            startCursorFigmaToolSurfaceObservation(
                launch: launch,
                presentationPhase: .postAuthorizationVerification,
                requiresEnable: true,
                cachePolicy: .requireFreshObservation,
                terminalSessionAttemptID: attemptID
            )
        } else {
            cursorFigmaObservationLaunch = nil
            let diagnostic: CursorFigmaMCPToolSurfaceProbeDiagnostic = switch settlement {
            case .busy: .loginBusy
            case .cancelled: .cancelled
            case .timedOut: .timedOut
            case .authorizationSessionClosed, .launchFailed, .exited: .processFailed
            }
            cursorFigmaToolSurfaceObservation = .unavailable(diagnostic)
        }
    }

    /// Test asks the shared coordinator to perform the exact provider-bound structured recheck.
    /// Settings does not create a second status request or authority.
    private func testProviderConnection(provider: ExternalMCPRuntimeProvider) {
        guard isActive, provider != .cursor, isCLIAvailable(for: provider) else { return }
        if !figmaProviderConnectionCoordinator.recheckStatus(
            provider: provider,
            purpose: .testConnection
        ) {
            providerConnectionTestBaselines.removeValue(forKey: provider)
        }
    }

    private func startProviderLogin(provider: ExternalMCPRuntimeProvider) {
        guard isActive, isCLIAvailable(for: provider), provider != .codex, provider != .cursor, provider != .grokBuild, provider != .antigravity else { return }
        if provider == .devin {
            guard let registration = figmaProviderConnectionCoordinator.registry.registration(for: .devin),
                  case .verified = registration.figmaCapabilities.loginSupport,
                  registration.targetResolver != nil,
                  registration.loginDriver != nil
            else { return }
        }
        let connectionCoordinator = figmaProviderConnectionCoordinator
        let ownerID = ownerID.uuidString
        Task {
            _ = await connectionCoordinator.beginLogin(provider: provider, ownerID: ownerID)
        }
    }

    private func cancelProviderLogin(provider: ExternalMCPRuntimeProvider) {
        guard isActive, provider != .cursor else { return }
        let attempt: FigmaMCPProviderLoginAttempt
        switch figmaProviderConnectionCoordinator.state(for: provider) {
        case let .authorizing(activeAttempt), let .verifyingAfterAuthorization(activeAttempt):
            attempt = activeAttempt
        default:
            return
        }
        let connectionCoordinator = figmaProviderConnectionCoordinator
        Task {
            await connectionCoordinator.cancelLogin(
                provider: provider,
                attemptID: attempt.attemptID
            )
        }
    }

    private func initialNotice(for action: FigmaMCPSettingsOperationKind) -> String {
        switch action {
        case .refresh: "Checking Figma status…"
        case .test: "Testing Figma connection…"
        case .connect: "Checking for an existing Figma connection…"
        case .useExistingConnection: "Using the existing Figma connection…"
        case .reauthenticate: "Starting Figma sign in…"
        case .verifyAuthentication: "Checking Figma status…"
        case .awaitAuthorizationCompletion: "Waiting for Figma sign in to complete…"
        case .signOut: "Signing out of Figma…"
        }
    }

    private func sanitizedSnapshot(_ candidate: FigmaMCPIntegrationSnapshot) -> FigmaMCPIntegrationSnapshot {
        guard candidate.state == .connected, candidate.authentication == .authenticated else {
            return .init(
                state: candidate.state,
                authentication: candidate.authentication,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            )
        }
        return candidate
    }
}

private extension FigmaMCPSettingsOperationKind {
    var requiresCodexConnection: Bool {
        switch self {
        case .refresh, .test, .connect, .useExistingConnection, .reauthenticate, .verifyAuthentication, .awaitAuthorizationCompletion:
            true
        case .signOut:
            false
        }
    }

    var coordinatorAction: FigmaMCPSettingsAction {
        switch self {
        case .refresh: .refresh
        case .test: .test
        case .connect: .connect
        case .useExistingConnection: .useExistingConnection
        case .reauthenticate: .reauthenticate
        case .verifyAuthentication: .verifyAuthentication
        case .awaitAuthorizationCompletion: .awaitAuthorizationCompletion
        case .signOut: .signOut
        }
    }
}

private extension SettingsConnectionStatus {
    var accessibilityLabel: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not Connected"
        case .connecting: "Connecting"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }
}
