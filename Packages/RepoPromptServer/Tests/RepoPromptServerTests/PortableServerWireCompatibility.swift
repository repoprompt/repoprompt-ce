import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import RepoPromptServiceProtocol
@testable import RepoPromptServerHost

extension ProviderTurnConfigurationInput {
    init(
        providerID: ProviderSettingsID,
        model: ProviderModelDescriptor,
        effortID: String? = nil,
        permissionID: String? = nil,
        toolValues: [String: AgentControlValue] = [:],
        scopedResources: Set<OwnedResourceReference> = [],
        workflowID: String? = nil
    ) {
        self.init(
            providerID: providerID,
            model: model,
            effortID: effortID,
            permissionID: permissionID,
            settings: ProviderTurnConfigurationAdapters.defaultSettings(for: providerID),
            toolValues: toolValues,
            scopedResources: scopedResources,
            workflowID: workflowID
        )
    }
}
extension CompiledProviderTurnConfiguration {
    init(
        runtimeKind: ProviderKind,
        providerRawModelValue: String,
        executionPolicy: ProviderExecutionPolicy,
        supportsNativeImages: Bool,
        normalizedToolValues: [String: AgentControlValue]
    ) {
        self.init(
            runtimeKind: runtimeKind,
            providerRawModelValue: providerRawModelValue,
            effortID: nil,
            permissions: .workspaceWrite(),
            executionPolicy: executionPolicy,
            supportsNativeImages: supportsNativeImages,
            normalizedToolValues: normalizedToolValues
        )
    }
}
