import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

package struct ACPDevinThinkingSelection {
    package let advertisedModelRaw: String
    package let configID: String
    package let choiceRaw: String

    package init(advertisedModelRaw: String, configID: String, choiceRaw: String) {
        self.advertisedModelRaw = advertisedModelRaw
        self.configID = configID
        self.choiceRaw = choiceRaw
    }
}

package struct ACPGrokModelDecomposition {
    package let base: AgentModelOption
    package let explicitEffort: CodexReasoningEffort?

    package init(base: AgentModelOption, explicitEffort: CodexReasoningEffort?) {
        self.base = base
        self.explicitEffort = explicitEffort
    }
}

package protocol ACPAgentSessionHost: Sendable {
    var applicationVersion: String { get }
    var repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration { get }
    func preflightInjectedMCPServers(in configuration: ACPSessionConfiguration) throws
    func preflightInjectedMCPServers(in configuration: ACPSessionConfiguration, environment: [String: String]) throws
    var cursorAutoModelRaw: String { get }
    func mcpClientNameHint(for kind: AgentProviderKind) -> String?
    func displayName(for kind: AgentProviderKind) -> String
    func normalizedModelParameterSelections(_ selections: [ACPModelParameterSelection]) -> [ACPModelParameterSelection]
    func canonicalParameterModelRaw(_ raw: String, providerID: ACPProviderID) -> String
    func parameterIdentityMatches(_ selection: ACPModelParameterSelection, providerID: ACPProviderID, baseModelRaw: String, kind: ACPModelParameterKind) -> Bool
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
