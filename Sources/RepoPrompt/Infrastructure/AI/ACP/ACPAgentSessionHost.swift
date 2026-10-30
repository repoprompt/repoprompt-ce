import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

struct ACPDevinThinkingSelection {
    let advertisedModelRaw: String
    let configID: String
    let choiceRaw: String
}

struct ACPGrokModelDecomposition {
    let base: AgentModelOption
    let explicitEffort: CodexReasoningEffort?
}

protocol ACPAgentSessionHost: Sendable {
    var applicationVersion: String { get }
    var cursorAutoModelRaw: String { get }
    func mcpClientNameHint(for kind: AgentProviderKind) -> String?
    func displayName(for kind: AgentProviderKind) -> String
    func recognizedDevinPermissionMode(_ mode: String?) -> Bool
    func normalizedDevinPermissionMode(_ mode: String?) -> String?
    func devinThinkingSelection(for model: String) -> ACPDevinThinkingSelection?
    func grokDecomposition(raw: String, options: [AgentModelOption]) -> ACPGrokModelDecomposition?
    func grokCompoundRaw(base: String, effort: CodexReasoningEffort?) -> String
    func resolvedModelSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels?
    func publishDiscoveredModels(_ models: ACPDiscoveredSessionModels, for providerID: ACPProviderID)
    func filterEnvironment(_ environment: [String: String], launchConfiguration: ACPLaunchConfiguration, kind: AgentProviderKind) async -> [String: String]
    func mergingCurrentCarrier(into environment: [String: String]) -> [String: String]
    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID?) async
    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID?) async
    func permissionIsAutoSelectable(optionID: String?, providerID: ACPProviderID) -> Bool
    func permissionOneTimeAllow(options: [(optionID: String, kind: String)], providerID: ACPProviderID) -> String?
    func permissionOneTimeReject(options: [(optionID: String, kind: String)]) -> String?
    #if DEBUG
        func diagnosticErrorKind(_ error: Error) -> String
        func recordRunRoutingEvent(runID: UUID, event: String, fields: [String: String]) async
    #endif
}
