import Foundation

protocol AgentTaskRouterBackend: Sendable {
    var id: AgentTaskRouterBackendID { get }
    var displayName: String { get }
    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness
    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome
}

struct AgentTaskRouterBackendSettingsPresentation: Equatable {
    struct Link: Equatable, Identifiable {
        let title: String
        let url: URL
        var id: URL {
            url
        }
    }

    let title: String
    let configurationDetail: String
    let secretFieldLabel: String?
    let links: [Link]
}

enum AgentTaskRouterBackendSettingsAction {
    case validateAndSaveSecret(String)
    case revalidateStoredSecret
    case removeStoredSecret
}

enum AgentTaskRouterBackendSettingsActionResult: Equatable {
    case succeeded(String)
    case missingSecret(String)
    case superseded(String)
    case failed(String)
}

/// Backend-owned credential/configuration authority exposed through a redacted,
/// backend-neutral Settings seam. Generic UI never receives stored secrets.
protocol AgentTaskRouterBackendSettingsController: Sendable {
    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness
    func readinessUpdates() async -> AsyncStream<AgentTaskRouterBackendReadiness>
    func perform(_ action: AgentTaskRouterBackendSettingsAction) async -> AgentTaskRouterBackendSettingsActionResult
    func bootstrapStoredConfigurationIfNeeded() async
    func cancelAndAdvanceGeneration() async
}

struct AgentTaskRouterBackendSettingsRegistration {
    let presentation: AgentTaskRouterBackendSettingsPresentation
    let controller: any AgentTaskRouterBackendSettingsController
}

struct AgentTaskRouterBackendRegistration {
    let id: AgentTaskRouterBackendID
    let displayName: String
    let backend: any AgentTaskRouterBackend
    let settings: AgentTaskRouterBackendSettingsRegistration?

    init(
        backend: any AgentTaskRouterBackend,
        settings: AgentTaskRouterBackendSettingsRegistration? = nil
    ) {
        id = backend.id
        displayName = backend.displayName
        self.backend = backend
        self.settings = settings
    }
}

enum AgentTaskRouterRegistryError: Error, Equatable {
    case invalidBackendID
    case duplicateBackendID(AgentTaskRouterBackendID)
}
