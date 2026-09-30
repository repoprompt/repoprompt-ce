import Foundation

protocol CodexExternalMCPAppServer: Sendable {
    func startIfNeeded() async throws
    func request(method: String, params: [String: Any]?, timeout: TimeInterval?) async throws -> [String: Any]
    func requestWithSettlementDeadline(method: String, params: [String: Any]?, deadline: TimeInterval) async throws -> [String: Any]
}

private struct CodexExternalMCPAppServerAdapter: CodexExternalMCPAppServer {
    let client: CodexAppServerClient
    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    func startIfNeeded() async throws {
        try await client.startIfNeeded()
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval?) async throws -> [String: Any] {
        try await client.request(method: method, params: params, timeout: timeout)
    }

    func requestWithSettlementDeadline(method: String, params: [String: Any]?, deadline: TimeInterval) async throws -> [String: Any] {
        try await client.requestWithSettlementDeadline(method: method, params: params, deadline: deadline)
    }
}

struct FigmaMCPToolCatalogEntry: Equatable, Hashable { let name: String }
enum FigmaMCPAuthenticationState: Equatable { case unknown, notLoggedIn, expired, authenticated, unsupported }
enum FigmaMCPIntegrationState: Equatable { case notConfigured, connecting, reconnecting, authorizationRequired, expired, connected, serverUnavailable, failed }
struct FigmaMCPIntegrationSnapshot: Equatable {
    let state: FigmaMCPIntegrationState
    let authentication: FigmaMCPAuthenticationState
    let tools: [FigmaMCPToolCatalogEntry]
    let lastSuccessfulCheck: Date?
    let failureMessage: String?
    static let notConfigured = Self(state: .notConfigured, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
}

/// The URL stays only in this immediate handoff; callers must not persist or log it.
/// The opaque ID lets the browser handoff settle the matching callback listener without
/// exposing OAuth state or accidentally releasing a newer authorization attempt.
struct FigmaMCPAuthorizationRequest: Equatable {
    let id: UUID
    let url: URL
}

enum FigmaMCPAuthorizationHandoffDisposition: Equatable {
    case opened
    case abandoned
}

enum FigmaMCPOAuthAuthorizationURL {
    enum ValidationFailure: String, Equatable, Error {
        case invalidOrigin
        case invalidQuery
        case duplicateQueryItem
        case missingRequiredQueryItem
        case invalidClientID
        case invalidResponseType
        case invalidResource
        case invalidRedirectURI
        case invalidState
        case invalidCodeChallenge
        case invalidCodeChallengeMethod
        case invalidScope
    }

    private static let canonicalResource = CodexIntegrationConfiguration.settingsManagedFigmaURL
    private static let permittedQueryNames: Set<String> = [
        "client_id", "redirect_uri", "scope", "state", "response_type",
        "code_challenge", "code_challenge_method", "resource"
    ]
    private static let requiredQueryNames: Set<String> = [
        "client_id", "redirect_uri", "state", "response_type", "code_challenge",
        "code_challenge_method", "resource"
    ]
    private static let uriSafeASCII = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let base64URLAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Returns the original URL only for immediate browser handoff. Callers must not retain
    /// the URL or include it in snapshots, diagnostics, or error descriptions.
    static func validate(_ url: URL) -> Result<URL, ValidationFailure> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "www.figma.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "/oauth/mcp",
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else { return .failure(.invalidOrigin) }

        let grouped = Dictionary(grouping: queryItems, by: \.name)
        guard Set(grouped.keys).isSubset(of: permittedQueryNames) else {
            return .failure(.invalidQuery)
        }
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            return .failure(.duplicateQueryItem)
        }
        guard requiredQueryNames.allSatisfy({ grouped[$0]?.first?.value?.isEmpty == false }) else {
            return .failure(.missingRequiredQueryItem)
        }

        guard let clientID = grouped["client_id"]?.first?.value,
              isASCIIWithoutControls(clientID),
              clientID.utf8.count <= 256
        else { return .failure(.invalidClientID) }
        guard grouped["response_type"]?.first?.value == "code" else {
            return .failure(.invalidResponseType)
        }
        guard grouped["resource"]?.first?.value == canonicalResource else {
            return .failure(.invalidResource)
        }
        guard let redirectURI = grouped["redirect_uri"]?.first?.value,
              isCodexLoopbackRedirectURI(redirectURI)
        else { return .failure(.invalidRedirectURI) }
        guard let state = grouped["state"]?.first?.value,
              state.utf8.count >= 16,
              state.utf8.count <= 512,
              state.unicodeScalars.allSatisfy({ uriSafeASCII.contains($0) })
        else { return .failure(.invalidState) }
        guard let challenge = grouped["code_challenge"]?.first?.value,
              challenge.utf8.count >= 43,
              challenge.utf8.count <= 128,
              challenge.unicodeScalars.allSatisfy({ base64URLAlphabet.contains($0) }),
              challenge.count == challenge.utf8.count
        else { return .failure(.invalidCodeChallenge) }
        guard grouped["code_challenge_method"]?.first?.value == "S256" else {
            return .failure(.invalidCodeChallengeMethod)
        }
        if let scope = grouped["scope"]?.first?.value,
           !isASCIIWithoutControls(scope)
        {
            return .failure(.invalidScope)
        }
        return .success(url)
    }

    static func isValid(_ url: URL) -> Bool {
        if case .success = validate(url) { return true }
        return false
    }

    private static func isASCIIWithoutControls(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value < 128 && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func isCodexLoopbackRedirectURI(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme == "http",
              let host = components.host,
              ["localhost", "127.0.0.1", "::1"].contains(host),
              let port = components.port,
              (1 ... 65535).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.isEmpty,
              components.path.hasPrefix("/")
        else { return false }
        return true
    }
}

enum FigmaMCPConfigurationEffect: Equatable {
    case none
    case verifiedPresent
    case verifiedAbsent
    case commitUncertain
}

enum FigmaMCPAppServerSettlement: Equatable {
    case notRequested
    case requested
    case settled
    case unknown
}

struct FigmaMCPAppServerEffect: Equatable {
    var reload: FigmaMCPAppServerSettlement
    var oauthListener: FigmaMCPAppServerSettlement

    static let none = Self(reload: .notRequested, oauthListener: .notRequested)
}

struct FigmaMCPCredentialLogoutEffect: Equatable {
    var settlement: FigmaMCPCredentialLogoutSettlement
    var outcome: FigmaMCPCredentialLogoutOutcome?

    static let none = Self(settlement: .notRequested, outcome: nil)
}

enum FigmaMCPCredentialLogoutSettlement: Equatable {
    case notRequested
    case requested
    case settled
    case unknown
}

struct FigmaMCPServiceEffects: Equatable {
    var configuration: FigmaMCPConfigurationEffect
    var appServer: FigmaMCPAppServerEffect
    var credentialLogout: FigmaMCPCredentialLogoutEffect

    init(
        configuration: FigmaMCPConfigurationEffect,
        appServer: FigmaMCPAppServerEffect,
        credentialLogout: FigmaMCPCredentialLogoutEffect = .none
    ) {
        self.configuration = configuration
        self.appServer = appServer
        self.credentialLogout = credentialLogout
    }

    static let none = Self(configuration: .none, appServer: .none)
}

struct FigmaMCPConnectServiceResult: Equatable {
    let result: FigmaMCPConnectResult
    let authorizationRequest: FigmaMCPAuthorizationRequest?
    let effects: FigmaMCPServiceEffects

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result == rhs.result && lhs.authorizationRequest?.url == rhs.authorizationRequest?.url && lhs.effects == rhs.effects
    }
}

enum FigmaMCPConnectResult: Equatable { case authorizationRequired, connected(FigmaMCPIntegrationSnapshot), failed, cancelled }
enum FigmaMCPDisconnectResult: Equatable { case disconnected, failed, cancelled }

struct FigmaMCPDisconnectServiceResult: Equatable {
    let result: FigmaMCPDisconnectResult
    let effects: FigmaMCPServiceEffects
}

/// Transient authority for whether Figma may be bound into a newly started or resumed agent
/// runtime. Durable Settings express user intent; only a successful authenticated status result
/// makes that intent available at runtime. The authority intentionally starts fail-closed on every
/// app launch and never persists OAuth or account state.
@MainActor
final class FigmaMCPRuntimeRevocationBarrier {
    struct Participant: Hashable {
        fileprivate let revision: UInt64
        fileprivate let id: UUID
    }

    private var participantsByRevision: [UInt64: Set<Participant>] = [:]

    func begin(revision: UInt64) {
        participantsByRevision[revision] = []
    }

    func registerParticipant(for revision: UInt64) -> Participant {
        let participant = Participant(revision: revision, id: UUID())
        participantsByRevision[revision, default: []].insert(participant)
        return participant
    }

    func complete(_ participant: Participant) {
        participantsByRevision[participant.revision]?.remove(participant)
    }

    func awaitCompletion(for revision: UInt64) async {
        while !(participantsByRevision[revision]?.isEmpty ?? true) {
            await Task.yield()
        }
        participantsByRevision[revision] = nil
    }
}

@MainActor
final class FigmaMCPRuntimeAvailabilityAuthority {
    struct RefreshTicket: Equatable {
        let generation: UInt64
        let expectedDefinition: ExternalMCPIntegrationDefinition?
        let operation: FigmaMCPIntegrationOperationKind
    }

    static let explicitRevocationNotification = Notification.Name(
        "com.pvncher.repoprompt.ce.figma-mcp-explicit-revocation"
    )

    let explicitRevocationBarrier = FigmaMCPRuntimeRevocationBarrier()

    private(set) var hasAuthenticatedRuntime = false
    private(set) var revision: UInt64 = 0
    private var lastExplicitRevocationID: UUID?
    private var lastExplicitRevocationRevision: UInt64?
    private var explicitRevocationRevisions: [UUID: UInt64] = [:]

    @discardableResult
    func beginAuthoritativeRefresh(
        expectedDefinition: ExternalMCPIntegrationDefinition? = nil,
        operation: FigmaMCPIntegrationOperationKind = .settingsRefresh
    ) -> RefreshTicket {
        revision &+= 1
        hasAuthenticatedRuntime = false
        return RefreshTicket(generation: revision, expectedDefinition: expectedDefinition, operation: operation)
    }

    /// Compatibility publication for phase-1 callers. New lifecycle code must use the
    /// revisioned overload below.
    func publish(
        snapshot: FigmaMCPIntegrationSnapshot,
        definition: ExternalMCPIntegrationDefinition?
    ) {
        publish(ticketGeneration: revision, snapshot: snapshot, definition: definition)
    }

    @discardableResult
    func publish(
        ticketGeneration: UInt64,
        snapshot: FigmaMCPIntegrationSnapshot,
        definition: ExternalMCPIntegrationDefinition?
    ) -> Bool {
        guard ticketGeneration == revision else { return false }
        hasAuthenticatedRuntime = definition?.repoPromptActivation == .enabled
            && snapshot.state == .connected
            && snapshot.authentication == .authenticated
        return hasAuthenticatedRuntime
    }

    func clearForRevision(_ generation: UInt64) {
        guard generation == revision else { return }
        hasAuthenticatedRuntime = false
    }

    func clearAvailability() {
        hasAuthenticatedRuntime = false
    }

    func authoritativeRuntimeAvailability(
        configuredAvailability: ExternalMCPRuntimeAvailability
    ) -> ExternalMCPRuntimeAvailability {
        guard hasAuthenticatedRuntime else { return .unavailable }
        return configuredAvailability
    }

    func resolvedAgentAccess(
        settingsStore: GlobalSettingsStore,
        configuredAvailability: ExternalMCPRuntimeAvailability
    ) -> ExternalMCPAgentAccessResolution {
        settingsStore.resolvedFigmaMCPAgentAccess(
            runtimeAvailability: authoritativeRuntimeAvailability(
                configuredAvailability: configuredAvailability
            )
        )
    }

    /// Explicit Sign Out is stronger than a failed/passive status refresh: it also tells every
    /// currently bound Agent Mode runtime to terminate or retire its Figma-capable binding now.
    @discardableResult
    func revokeForExplicitDisconnect(
        revocationID: UUID = UUID(),
        notificationCenter: NotificationCenter = .default
    ) -> UInt64 {
        if let existingRevision = explicitRevocationRevisions[revocationID] {
            return existingRevision
        }
        revision &+= 1
        explicitRevocationRevisions[revocationID] = revision
        lastExplicitRevocationID = revocationID
        lastExplicitRevocationRevision = revision
        hasAuthenticatedRuntime = false
        explicitRevocationBarrier.begin(revision: revision)
        notificationCenter.post(
            name: Self.explicitRevocationNotification,
            object: nil,
            userInfo: ["revision": revision]
        )
        return revision
    }

    func awaitExplicitRevocationSettlement() async {
        await explicitRevocationBarrier.awaitCompletion(for: revision)
    }
}

/// Result of a read-only check for an existing Figma block which Settings does not own.
/// The UI must obtain explicit adoption before it persists policy for this identity.
enum FigmaMCPImportDiscovery: Equatable {
    case absent
    case available(FigmaMCPIntegrationSnapshot)
    case unavailable
    case cancelled
}

private enum ExternalMCPOperationKind: Equatable {
    case interactive
    case statusRefresh
}

private struct ExternalMCPOperation {
    let kind: ExternalMCPOperationKind
    let generation: UInt64
    let cancellationFallback: FigmaMCPIntegrationSnapshot
    let retainsPreviousDetails: Bool
}

private enum ExternalMCPProvisioningOutcome {
    case satisfied
    case cancelled
    case failed
}

private final class ExternalMCPOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64 = 0
    func activate(_ generation: UInt64) {
        lock.lock()
        activeGeneration = generation
        lock.unlock()
    }

    func isStale(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration != generation
    }
}

/// Codex owns OAuth and credential storage. RepoPrompt persists only a fixed URL-only definition.
actor CodexExternalMCPIntegrationService {
    typealias Factory = @Sendable () -> any CodexExternalMCPAppServer
    typealias Provisioner = @Sendable (ExternalMCPIntegrationDefinition?, @escaping @Sendable () -> Bool) -> CodexIntegrationConfiguration.SettingsManagedMCPUpdateResult
    typealias ImportInspector = @Sendable (@escaping @Sendable () -> Bool) -> CodexIntegrationConfiguration.ExistingFigmaServerInspection
    private let factory: Factory
    private let provisioner: Provisioner
    private let importInspector: ImportInspector
    private let credentialLogoutExecutor: any CodexFigmaMCPCredentialLogoutExecuting
    private var generation: UInt64 = 0
    private let cancellation = ExternalMCPOperationCancellation()
    private var current = FigmaMCPIntegrationSnapshot.notConfigured
    private var lastSettled = FigmaMCPIntegrationSnapshot.notConfigured
    private var activeOperation: ExternalMCPOperation?
    private var activeOrigin: ExternalMCPIntegrationOrigin?
    private var lastSettledEffects = FigmaMCPServiceEffects.none
    private var cancelledGenerations = Set<UInt64>()
    private var pendingAuthorizationListener: PendingAuthorizationListener?

    /// Keeps alive only the app-server process that owns an issued OAuth callback listener.
    /// The service operation generation is no longer current after the URL handoff, so the
    /// separate request ID fences later browser-open settlement from newer login attempts.
    private struct PendingAuthorizationListener {
        let requestID: UUID
        let generation: UInt64
        let client: any CodexExternalMCPAppServer
    }

    init(
        factory: @escaping Factory = { CodexExternalMCPAppServerAdapter() },
        provisioner: @escaping Provisioner = { definition, cancelled in
            let live = CodexIntegrationConfiguration.ProvisioningDependencies.live()
            return CodexIntegrationConfiguration.reconcileSettingsManagedFigmaConnection(definition: definition, dependencies: .init(sourceReader: .init { _ in nil }, managedStore: live.managedStore, diagnostics: live.diagnostics, cancellation: .init(isCancelled: cancelled)))
        },
        importInspector: @escaping ImportInspector = { cancelled in
            let live = CodexIntegrationConfiguration.ProvisioningDependencies.live()
            return CodexIntegrationConfiguration.inspectExistingFigmaServer(
                dependencies: .init(sourceReader: .init { _ in nil }, managedStore: live.managedStore, diagnostics: live.diagnostics, cancellation: .init(isCancelled: cancelled))
            )
        },
        credentialLogoutExecutor: any CodexFigmaMCPCredentialLogoutExecuting = CodexFigmaMCPCredentialLogoutExecutor()
    ) {
        self.factory = factory
        self.provisioner = provisioner
        self.importInspector = importInspector
        self.credentialLogoutExecutor = credentialLogoutExecutor
    }

    func snapshot() -> FigmaMCPIntegrationSnapshot {
        current
    }

    func serviceEffects() -> FigmaMCPServiceEffects {
        lastSettledEffects
    }

    func settleAuthorizationHandoff(
        id: UUID,
        disposition: FigmaMCPAuthorizationHandoffDisposition
    ) {
        guard let pendingAuthorizationListener,
              pendingAuthorizationListener.requestID == id
        else { return }
        switch disposition {
        case .opened:
            withExtendedLifetime(pendingAuthorizationListener.client) {}
        case .abandoned:
            self.pendingAuthorizationListener = nil
        }
    }

    func connectWithEffects(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPConnectServiceResult {
        let outcome = await connectWithEffectsInternal(definition: definition)
        var effects = outcome.effects
        if outcome.result == .cancelled {
            markPendingAppServerEffectsUnknown(&effects)
        }
        return .init(result: outcome.result, authorizationRequest: outcome.authorizationRequest, effects: effects)
    }

    func connect(
        definition: ExternalMCPIntegrationDefinition
    ) async -> (FigmaMCPConnectResult, FigmaMCPAuthorizationRequest?) {
        let outcome = await connectWithEffectsInternal(definition: definition)
        return (outcome.result, outcome.authorizationRequest)
    }

    func disconnectWithEffects(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectServiceResult {
        let outcome = await disconnectWithEffectsInternal(definition: definition)
        var effects = outcome.effects
        if outcome.result == .cancelled {
            markPendingAppServerEffectsUnknown(&effects)
        }
        return .init(result: outcome.result, effects: effects)
    }

    func disconnect(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectResult {
        await (disconnectWithEffectsInternal(definition: definition)).result
    }

    func removeManagedConfiguration(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectServiceResult {
        let outcome = await removeManagedConfigurationWithEffectsInternal(definition: definition)
        var effects = outcome.effects
        if outcome.result == .cancelled {
            markPendingAppServerEffectsUnknown(&effects)
        }
        return .init(result: outcome.result, effects: effects)
    }

    func cancelCurrentOperation() {
        pendingAuthorizationListener = nil
        guard let activeOperation else {
            return
        }
        cancelledGenerations.insert(activeOperation.generation)
        if cancelledGenerations.count > 32 { cancelledGenerations.removeFirst() }
        advanceGeneration()
        current = activeOperation.cancellationFallback
        lastSettled = activeOperation.cancellationFallback
        self.activeOperation = nil
        activeOrigin = nil
    }

    /// Sleep/wake uses this narrower cancellation path so it can stop only a background
    /// status refresh without interrupting an explicit user connect, authorization, or
    /// disconnect operation in Settings.
    func cancelStatusRefresh() {
        guard let activeOperation, activeOperation.kind == .statusRefresh else { return }
        cancelledGenerations.insert(activeOperation.generation)
        if cancelledGenerations.count > 32 { cancelledGenerations.removeFirst() }
        advanceGeneration()
        current = lastSettled
        self.activeOperation = nil
        activeOrigin = nil
    }

    /// Clears only the actor's sanitized presentation cache. It deliberately does not
    /// provision configuration, start Codex, reload servers, or touch OAuth credentials.
    func invalidatePresentationSnapshot() {
        advanceGeneration()
        pendingAuthorizationListener = nil
        current = .notConfigured
        lastSettled = .notConfigured
        activeOperation = nil
        activeOrigin = nil
    }

    /// Read-only discovery protects user/imported blocks from being overwritten by the
    /// normal Settings-managed connection path. The caller must explicitly persist adoption.
    func discoverExistingImport() async -> FigmaMCPImportDiscovery {
        let token = begin(
            .connecting,
            kind: .interactive,
            cancellationFallback: .notConfigured,
            retainsPreviousDetails: false,
            origin: nil
        )
        switch importInspector({ [cancellation] in cancellation.isStale(token) }) {
        case .absent, .settingsManaged:
            guard token == generation else { return .cancelled }
            settle(.notConfigured, token: token)
            return .absent
        case .unsafe, .canonicalExplicitlyDisabled, .conflictingAlias:
            guard token == generation else { return .cancelled }
            settle(failedSnapshot(), token: token)
            return .unavailable
        case .imported, .canonicalImported:
            let outcome = await refreshCatalog(token: token)
            guard token == generation else { return .cancelled }
            let snapshot = outcome.snapshot
            return snapshot.state == .failed ? .unavailable : .available(snapshot)
        }
    }

    private func connectWithEffectsInternal(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPConnectServiceResult {
        var effects = FigmaMCPServiceEffects.none
        // Any new login attempt supersedes a callback listener from an earlier URL, even if
        // the incoming definition turns out to be invalid or disabled.
        pendingAuthorizationListener = nil
        guard definition.isSupportedDefinition else {
            settleWithoutOperation(failedSnapshot())
            return .init(result: .failed, authorizationRequest: nil, effects: effects)
        }
        guard definition.repoPromptActivation == .enabled else {
            invalidatePresentationSnapshot()
            return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
        }

        let fallback = lastSettled
        let state: FigmaMCPIntegrationState = fallback.state == .notConfigured ? .connecting : .reconnecting
        let token = begin(
            state,
            kind: .interactive,
            cancellationFallback: fallback,
            retainsPreviousDetails: true,
            origin: definition.origin
        )
        if definition.origin != .adoptedImport {
            switch provision(definition, token: token, expected: true, effects: &effects) {
            case .satisfied:
                break
            case .cancelled:
                settleCancellation(token: token)
                return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
            case .failed:
                settle(failedSnapshot(), token: token)
                return .init(result: .failed, authorizationRequest: nil, effects: effects)
            }
        }

        do {
            let client = factory()
            try await client.startIfNeeded()
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
            }
            effects.appServer.reload = .requested
            _ = try await client.requestWithSettlementDeadline(
                method: "config/mcpServer/reload",
                params: nil,
                deadline: 30
            )
            effects.appServer.reload = .settled
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
            }
            effects.appServer.oauthListener = .requested
            let result = try await client.request(
                method: "mcpServer/oauth/login",
                params: ["name": CodexIntegrationConfiguration.settingsManagedFigmaServerName],
                timeout: 30
            )
            effects.appServer.oauthListener = .settled
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
            }
            guard let value = result["authorizationUrl"] as? String,
                  let url = URL(string: value),
                  FigmaMCPOAuthAuthorizationURL.isValid(url)
            else {
                settle(failedSnapshot(), token: token)
                lastSettledEffects = effects
                return .init(result: .failed, authorizationRequest: nil, effects: effects)
            }
            let authorizationRequest = FigmaMCPAuthorizationRequest(id: UUID(), url: url)
            pendingAuthorizationListener = .init(
                requestID: authorizationRequest.id,
                generation: token,
                client: client
            )
            let snapshot = FigmaMCPIntegrationSnapshot(
                state: .authorizationRequired,
                authentication: .notLoggedIn,
                tools: [],
                lastSuccessfulCheck: nil,
                failureMessage: nil
            )
            settle(snapshot, token: token)
            lastSettledEffects = effects
            return .init(result: .authorizationRequired, authorizationRequest: authorizationRequest, effects: effects)
        } catch is CancellationError {
            markPendingAppServerEffectsUnknown(&effects)
            settleCancellation(token: token)
            return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
        } catch {
            markPendingAppServerEffectsUnknown(&effects)
            guard token == generation else {
                return .init(result: .cancelled, authorizationRequest: nil, effects: effects)
            }
            settle(failedSnapshot(), token: token)
            lastSettledEffects = effects
            return .init(result: .failed, authorizationRequest: nil, effects: effects)
        }
    }

    private func removeManagedConfigurationWithEffectsInternal(
        definition: ExternalMCPIntegrationDefinition
    ) async -> FigmaMCPDisconnectServiceResult {
        var effects = FigmaMCPServiceEffects.none
        pendingAuthorizationListener = nil
        guard definition.isSupportedDefinition,
              definition.origin == .settingsManaged
        else {
            invalidatePresentationSnapshot()
            return .init(result: .failed, effects: effects)
        }

        let token = begin(
            .connecting,
            kind: .interactive,
            cancellationFallback: .notConfigured,
            retainsPreviousDetails: false,
            origin: definition.origin
        )
        switch provision(nil, token: token, expected: false, effects: &effects) {
        case .satisfied:
            guard effects.configuration == .verifiedAbsent else {
                settle(.notConfigured, token: token)
                lastSettledEffects = effects
                return .init(result: .failed, effects: effects)
            }
        case .cancelled:
            settleCancellation(token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        case .failed:
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .failed, effects: effects)
        }

        do {
            let client = factory()
            try await client.startIfNeeded()
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, effects: effects)
            }
            effects.appServer.reload = .requested
            _ = try await client.requestWithSettlementDeadline(
                method: "config/mcpServer/reload",
                params: nil,
                deadline: 30
            )
            effects.appServer.reload = .settled
            guard token == generation, !cancelledGenerations.contains(token) else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, effects: effects)
            }
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .disconnected, effects: effects)
        } catch is CancellationError {
            markPendingAppServerEffectsUnknown(&effects)
            settleCancellation(token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        } catch {
            markPendingAppServerEffectsUnknown(&effects)
            guard token == generation else { return .init(result: .cancelled, effects: effects) }
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .failed, effects: effects)
        }
    }

    /// Dynamic catalog is inspect-only: Codex 0.149 has server-level enablement, not a portable client per-tool policy.
    func refreshWithReceipt(
        definition: ExternalMCPIntegrationDefinition?
    ) async -> FigmaMCPIntegrationRefreshReceipt {
        var effects = FigmaMCPServiceEffects.none
        guard let definition, definition.isSupportedDefinition else {
            invalidatePresentationSnapshot()
            return .init(snapshot: current, generation: generation, isAuthoritative: true)
        }
        guard definition.repoPromptActivation == .enabled else {
            invalidatePresentationSnapshot()
            return .init(snapshot: current, generation: generation, isAuthoritative: true)
        }

        let fallback = lastSettled
        let token = begin(
            .connecting,
            kind: .statusRefresh,
            cancellationFallback: fallback,
            retainsPreviousDetails: true,
            origin: definition.origin
        )
        if definition.origin != .adoptedImport {
            switch provision(definition, token: token, expected: true, effects: &effects) {
            case .satisfied:
                break
            case .cancelled:
                settleCancellation(token: token)
                return .init(snapshot: current, generation: token, isAuthoritative: false)
            case .failed:
                settle(failedSnapshot(), token: token)
                releaseAuthorizationListenerAfterAuthoritativeRefresh(current, token: token)
                lastSettledEffects = effects
                return .init(snapshot: current, generation: token, isAuthoritative: token == generation)
            }
        }
        let outcome = await refreshCatalog(token: token, effects: effects)
        let authoritative = outcome.generation == generation
        if authoritative { lastSettledEffects = outcome.effects }
        return .init(snapshot: outcome.snapshot, generation: outcome.generation, isAuthoritative: authoritative)
    }

    func refresh(definition: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationSnapshot {
        await refreshWithReceipt(definition: definition).snapshot
    }

    /// Revokes Codex's Figma credential first, then reconciles the managed config and reloads
    /// the app server. Adopted imports remain detach-only and never invoke the credential executor.
    private func disconnectWithEffectsInternal(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult {
        var effects = FigmaMCPServiceEffects.none
        pendingAuthorizationListener = nil
        guard definition.isSupportedDefinition else {
            invalidatePresentationSnapshot()
            return .init(result: .failed, effects: effects)
        }

        let token = begin(
            .connecting,
            kind: .interactive,
            cancellationFallback: .notConfigured,
            retainsPreviousDetails: false,
            origin: definition.origin
        )
        if definition.origin == .adoptedImport {
            guard token == generation else { return .init(result: .cancelled, effects: effects) }
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .disconnected, effects: effects)
        }

        effects.credentialLogout.settlement = .requested
        let logoutOutcome = await credentialLogoutExecutor.logoutFigmaCredential()
        effects.credentialLogout.outcome = logoutOutcome
        switch logoutOutcome {
        case .credentialAbsent:
            effects.credentialLogout.settlement = .settled
        case .failed:
            effects.credentialLogout.settlement = .settled
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .failed, effects: effects)
        case .cancelledBeforeLaunch:
            // No child was started, so a repeat is safe and the requested effect remains visible.
            settleCancellation(token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        case .indeterminate:
            effects.credentialLogout.settlement = .unknown
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        }

        // A stale executor result must not authorize follow-on mutation. A confirmed absence is
        // retained in the returned effects, but this operation cannot continue its lease.
        guard token == generation, !cancelledGenerations.contains(token) else {
            return .init(result: .cancelled, effects: effects)
        }

        switch provision(nil, token: token, expected: false, effects: &effects) {
        case .satisfied:
            guard effects.configuration == .verifiedAbsent else {
                settle(.notConfigured, token: token)
                lastSettledEffects = effects
                return .init(result: .failed, effects: effects)
            }
        case .cancelled:
            settleCancellation(token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        case .failed:
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .failed, effects: effects)
        }

        do {
            let client = factory()
            try await client.startIfNeeded()
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, effects: effects)
            }
            effects.appServer.reload = .requested
            _ = try await client.requestWithSettlementDeadline(
                method: "config/mcpServer/reload",
                params: nil,
                deadline: 30
            )
            effects.appServer.reload = .settled
            guard token == generation, !cancelledGenerations.contains(token) else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(result: .cancelled, effects: effects)
            }
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .disconnected, effects: effects)
        } catch is CancellationError {
            markPendingAppServerEffectsUnknown(&effects)
            settleCancellation(token: token)
            lastSettledEffects = effects
            return .init(result: .cancelled, effects: effects)
        } catch {
            markPendingAppServerEffectsUnknown(&effects)
            guard token == generation else { return .init(result: .cancelled, effects: effects) }
            settle(.notConfigured, token: token)
            lastSettledEffects = effects
            return .init(result: .failed, effects: effects)
        }
    }

    private struct RefreshOutcome {
        let snapshot: FigmaMCPIntegrationSnapshot
        let effects: FigmaMCPServiceEffects
        let generation: UInt64
    }

    private func begin(
        _ state: FigmaMCPIntegrationState,
        kind: ExternalMCPOperationKind,
        cancellationFallback: FigmaMCPIntegrationSnapshot,
        retainsPreviousDetails: Bool,
        origin: ExternalMCPIntegrationOrigin?
    ) -> UInt64 {
        advanceGeneration()
        let operation = ExternalMCPOperation(
            kind: kind,
            generation: generation,
            cancellationFallback: cancellationFallback,
            retainsPreviousDetails: retainsPreviousDetails
        )
        activeOperation = operation
        activeOrigin = origin
        let detailSource = operation.retainsPreviousDetails ? lastSettled : .notConfigured
        current = .init(
            state: state,
            authentication: detailSource.authentication,
            tools: detailSource.tools,
            lastSuccessfulCheck: detailSource.lastSuccessfulCheck,
            failureMessage: nil
        )
        return generation
    }

    private func advanceGeneration() {
        generation &+= 1
        cancellation.activate(generation)
    }

    private func settle(_ snapshot: FigmaMCPIntegrationSnapshot, token: UInt64) {
        guard token == generation,
              activeOperation?.generation == token
        else { return }
        current = snapshot
        lastSettled = snapshot
        activeOperation = nil
        activeOrigin = nil
    }

    private func settleWithoutOperation(_ snapshot: FigmaMCPIntegrationSnapshot) {
        advanceGeneration()
        current = snapshot
        lastSettled = snapshot
        activeOperation = nil
        activeOrigin = nil
    }

    private func settleCancellation(token: UInt64) {
        guard token == generation,
              let activeOperation,
              activeOperation.generation == token
        else { return }
        settle(activeOperation.cancellationFallback, token: token)
    }

    private func provision(
        _ definition: ExternalMCPIntegrationDefinition?,
        token: UInt64,
        expected: Bool,
        effects: inout FigmaMCPServiceEffects
    ) -> ExternalMCPProvisioningOutcome {
        let result = provisioner(definition) { [cancellation] in cancellation.isStale(token) }
        guard token == generation else { return .cancelled }
        recordConfigurationEffect(result, expected: expected, effects: &effects)
        switch result.status {
        case .updated, .unchanged:
            let isSatisfied: Bool = if definition?.origin == .adoptedImport {
                expected && !result.hasSettingsManagedFigma
            } else {
                result.hasSettingsManagedFigma == expected
            }
            return isSatisfied ? .satisfied : .failed
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }

    private func refreshStatusPages(
        client: any CodexExternalMCPAppServer,
        token: UInt64
    ) async throws -> FigmaMCPIntegrationSnapshot {
        var cursor: String?
        var seenCursors = Set<String>()
        var rows: [[String: Any]] = []
        let maxPages = 32
        let maxRows = 4096

        for _ in 0 ..< maxPages {
            guard token == generation else { return current }
            var params: [String: Any] = ["detail": "toolsAndAuthOnly"]
            if let cursor { params["cursor"] = cursor }
            let page = try await client.request(method: "mcpServerStatus/list", params: params, timeout: 30)
            guard let pageRows = page["data"] as? [[String: Any]], rows.count + pageRows.count <= maxRows else {
                return unavailableSnapshot(message: "Figma MCP status was incomplete.")
            }
            rows.append(contentsOf: pageRows)
            guard let next = page["nextCursor"] else {
                return project(rows: rows)
            }
            if next is NSNull {
                return project(rows: rows)
            }
            guard let nextCursor = next as? String, !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted,
                  nextCursor != cursor
            else {
                return unavailableSnapshot(message: "Figma MCP status pagination was invalid.")
            }
            cursor = nextCursor
        }
        return unavailableSnapshot(message: "Figma MCP status was incomplete.")
    }

    private func refreshCatalog(
        token: UInt64,
        effects initialEffects: FigmaMCPServiceEffects = .none
    ) async -> RefreshOutcome {
        var effects = initialEffects
        do {
            let client = factory()
            try await client.startIfNeeded()
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(snapshot: current, effects: effects, generation: token)
            }
            effects.appServer.reload = .requested
            _ = try await client.requestWithSettlementDeadline(
                method: "config/mcpServer/reload",
                params: nil,
                deadline: 30
            )
            effects.appServer.reload = .settled
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(snapshot: current, effects: effects, generation: token)
            }
            let snapshot = try await refreshStatusPages(client: client, token: token)
            guard token == generation else {
                markPendingAppServerEffectsUnknown(&effects)
                return .init(snapshot: current, effects: effects, generation: token)
            }
            settle(snapshot, token: token)
            releaseAuthorizationListenerAfterAuthoritativeRefresh(snapshot, token: token)
            return .init(snapshot: current, effects: effects, generation: token)
        } catch is CancellationError {
            markPendingAppServerEffectsUnknown(&effects)
            settleCancellation(token: token)
            return .init(snapshot: current, effects: effects, generation: token)
        } catch {
            markPendingAppServerEffectsUnknown(&effects)
            guard token == generation else {
                return .init(snapshot: current, effects: effects, generation: token)
            }
            settle(failedSnapshot(), token: token)
            releaseAuthorizationListenerAfterAuthoritativeRefresh(current, token: token)
            return .init(snapshot: current, effects: effects, generation: token)
        }
    }

    private func releaseAuthorizationListenerAfterAuthoritativeRefresh(
        _ snapshot: FigmaMCPIntegrationSnapshot,
        token: UInt64
    ) {
        guard token == generation,
              let pendingAuthorizationListener,
              pendingAuthorizationListener.generation <= token
        else { return }
        if snapshot.state != .authorizationRequired || snapshot.authentication != .notLoggedIn {
            self.pendingAuthorizationListener = nil
        }
    }

    private func recordConfigurationEffect(
        _ result: CodexIntegrationConfiguration.SettingsManagedMCPUpdateResult,
        expected: Bool,
        effects: inout FigmaMCPServiceEffects
    ) {
        switch result.status {
        case .updated, .unchanged:
            effects.configuration = expected ? .verifiedPresent : .verifiedAbsent
        case .cancelled, .failed:
            effects.configuration = result.recovery == .replacementMayHaveCommitted
                ? .commitUncertain
                : .none
        }
    }

    private func markPendingAppServerEffectsUnknown(_ effects: inout FigmaMCPServiceEffects) {
        if effects.appServer.reload == .requested || effects.appServer.reload == .settled {
            effects.appServer.reload = .unknown
        }
        if effects.appServer.oauthListener == .requested || effects.appServer.oauthListener == .settled {
            effects.appServer.oauthListener = .unknown
        }
    }

    private func project(rows: [[String: Any]]) -> FigmaMCPIntegrationSnapshot {
        guard let figma = rows.first(where: { $0["name"] as? String == CodexIntegrationConfiguration.settingsManagedFigmaServerName }) else {
            return unavailableSnapshot(message: "Figma MCP server was not reported by Codex.")
        }
        let rawAuthStatus = (figma["authStatus"] as? String)?.lowercased()
        let auth: FigmaMCPAuthenticationState = switch rawAuthStatus {
        case "oauth", "bearertoken": .authenticated
        case "notloggedin", "authenticationrequired", "authorizationrequired": .notLoggedIn
        case "expired", "oauthexpired", "oauth_expired", "authenticationexpired", "authorizationexpired": .expired
        case "unsupported": .unsupported
        default: .unknown
        }
        let state: FigmaMCPIntegrationState = switch auth {
        case .authenticated: .connected
        case .notLoggedIn: .authorizationRequired
        case .expired: .expired
        case .unknown, .unsupported: .failed
        }
        let tools = (figma["tools"] as? [String: Any] ?? [:]).keys.sorted().map(FigmaMCPToolCatalogEntry.init(name:))
        let failureMessage: String? = switch auth {
        case .expired: "Figma MCP authorization has expired."
        case .unknown, .unsupported: "Figma MCP reported an unrecognized authentication state."
        default: nil
        }
        return .init(state: state, authentication: auth, tools: tools, lastSuccessfulCheck: Date(), failureMessage: failureMessage)
    }

    private func unavailableSnapshot(message: String) -> FigmaMCPIntegrationSnapshot {
        .init(state: .serverUnavailable, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: message)
    }

    private func failedSnapshot() -> FigmaMCPIntegrationSnapshot {
        FigmaMCPIntegrationSnapshot(
            state: .failed,
            authentication: .unknown,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: "RepoPrompt could not complete the Figma MCP operation."
        )
    }
}
