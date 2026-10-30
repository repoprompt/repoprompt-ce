import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptHTTPProviders

extension AzureOpenAIConfiguration {
    func revokingHTTPConsent() -> AzureOpenAIConfiguration {
        AzureOpenAIConfiguration(baseURL: baseURL, apiKey: apiKey, apiVersion: apiVersion, extraHeaders: extraHeaders, models: models, defaultModelID: defaultModelID, httpCredentialConsentEndpoint: nil)
    }

    static func inferredEndpoint(for modelID: String, baseModelID: String? = nil) -> ModelDescriptor.EndpointKind {
        let candidates = [baseModelID, modelID].compactMap(\.self)
        for name in candidates {
            if let equivalent = AIModel.fromModelName(name), equivalent.usesResponsesAPI {
                return .responses
            }
            let lowered = name.lowercased()
            if lowered.hasPrefix("gpt-5") || lowered == "o3" || lowered.hasPrefix("o3-") {
                return .responses
            }
        }
        return .chatCompletions
    }

    static func inferredSupportsStreaming(for modelID: String, baseModelID: String? = nil) -> Bool {
        if let baseModelID, let equivalent = AIModel.fromModelName(baseModelID) {
            return equivalent.canStream
        }
        if let equivalent = AIModel.fromModelName(modelID) {
            return equivalent.canStream
        }
        return !modelID.lowercased().contains("no-stream")
    }
}

extension AzureOpenAIProvider {
    static let defaultModelDescriptors: [AzureOpenAIConfiguration.ModelDescriptor] = {
        let openAIModels = AIModel.modelsForProvider(.openAI)
            .filter { $0.openAIReasoningMode == nil }
            .sorted { lhs, rhs in lhs.displayName.lowercased() < rhs.displayName.lowercased() }

        let descriptors = openAIModels.map { model in
            let rawID = model.rawValue
            let display = AIModel.azureCustom(name: rawID).displayName
            let usesResponses = model.usesResponsesAPI
            let streams = model.canStream

            return AzureOpenAIConfiguration.ModelDescriptor(
                id: rawID,
                displayName: display,
                endpoint: usesResponses ? .responses : .chatCompletions,
                supportsStreaming: streams,
                baseModelID: rawID,
                supportsChatCompletions: usesResponses ? false : true,
                supportsResponses: usesResponses ? true : false
            )
        }

        return descriptors
            .map { normalizedDescriptor($0) }
    }()

    static func mergedWithDefaultDescriptors(_ descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> [AzureOpenAIConfiguration.ModelDescriptor] {
        var merged: [String: AzureOpenAIConfiguration.ModelDescriptor] = [:]

        for descriptor in descriptors {
            let key = normalizedModelName(from: descriptor.id).lowercased()
            merged[key] = descriptor
        }

        for descriptor in defaultModelDescriptors {
            let key = normalizedModelName(from: descriptor.id).lowercased()
            if merged[key] == nil {
                merged[key] = descriptor
            }
        }

        return merged.values
            .map { normalizedDescriptor($0) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    private static func normalizedDescriptor(_ descriptor: AzureOpenAIConfiguration.ModelDescriptor) -> AzureOpenAIConfiguration.ModelDescriptor {
        let normalizedID = Self.normalizedModelName(from: descriptor.id)
        let openAIModel = AIModel.fromModelName(normalizedID)
        let inferredEndpoint = descriptor.endpoint ?? AzureOpenAIConfiguration.inferredEndpoint(for: descriptor.id, baseModelID: descriptor.baseModelID)
        let usesResponses = descriptor.supportsResponses ?? openAIModel?.usesResponsesAPI ?? (inferredEndpoint == .responses)
        let endpoint: AzureOpenAIConfiguration.ModelDescriptor.EndpointKind = usesResponses ? .responses : .chatCompletions
        let supportsStreaming = descriptor.supportsStreaming ?? openAIModel?.canStream
        let resolvedBaseModelID: String = if let explicitBase = descriptor.baseModelID, !explicitBase.isEmpty {
            explicitBase
        } else if let openAIModel {
            openAIModel.rawValue
        } else {
            normalizedID
        }
        let azureDisplay = AIModel.azureCustom(name: normalizedID).displayName
        let resolvedDisplay = azureDisplay.isEmpty
            ? "azure/\(descriptor.displayName.isEmpty ? descriptor.id : descriptor.displayName)"
            : azureDisplay

        return AzureOpenAIConfiguration.ModelDescriptor(
            id: descriptor.id,
            displayName: resolvedDisplay,
            endpoint: endpoint,
            supportsStreaming: supportsStreaming,
            baseModelID: resolvedBaseModelID,
            supportsChatCompletions: descriptor.supportsChatCompletions ?? !usesResponses,
            supportsResponses: usesResponses
        )
    }

    static func defaultDescriptor(for identifier: String) -> AzureOpenAIConfiguration.ModelDescriptor? {
        let normalized = normalizedModelName(from: identifier).lowercased()
        return defaultModelDescriptors.first {
            normalizedModelName(from: $0.id).lowercased() == normalized
        }
    }

    static func matchedModel(for descriptor: AzureOpenAIConfiguration.ModelDescriptor) -> AIModel? {
        if let baseModelID = descriptor.baseModelID,
           let model = AIModel.fromModelName(baseModelID)
        {
            return model
        }
        return AIModel.fromModelName(Self.normalizedModelName(from: descriptor.id))
    }

    static func prioritizedDeployments(from descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> [AzureOpenAIConfiguration.ModelDescriptor] {
        let openAIModels = Set(AIModel.modelsForProvider(.openAI))
        return descriptors.filter { descriptor in
            guard let model = matchedModel(for: descriptor) else { return false }
            return openAIModels.contains(model)
        }
    }

    static func defaultDeploymentID(for descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> String? {
        descriptors.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }.first?.id
    }

    static func preferredDeploymentID(from descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> String? {
        let priorityOrder = AIModel.wholePriorityModels
        for priority in priorityOrder {
            if let descriptor = descriptors.first(where: { matchedModel(for: $0) == priority }) {
                return descriptor.id
            }
        }
        for descriptor in descriptors {
            if let model = matchedModel(for: descriptor), model.providerType == .openAI {
                return descriptor.id
            }
        }
        return descriptors.first?.id
    }
}

struct AzureOpenAIAppHost: AzureOpenAIHTTPHost {
    func validateEndpoint(_ url: URL, apiKey: String, customHeaders: [String: String], consentEndpoint: String?) throws {
        try ProviderEndpointConsent.validate(url, apiKey: apiKey, customHeaders: customHeaders, consentEndpoint: consentEndpoint)
    }

    func modelFromName(_ name: String) -> AIModel? {
        AIModel.fromModelName(name)
    }

    func modelName(for model: AIModel) -> String {
        model.modelName
    }

    func rawValue(for model: AIModel) -> String {
        model.rawValue
    }

    func displayName(for model: AIModel) -> String {
        model.displayName
    }

    func usesResponsesAPI(for model: AIModel) -> Bool {
        model.usesResponsesAPI
    }

    func canStream(for model: AIModel) -> Bool {
        model.canStream
    }

    func defaultReasoningEffort(for model: AIModel) -> String? {
        model.defaultReasoningEffort
    }

    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double? {
        message.effectiveTemperature(for: model)
    }

    func defaultDescriptor(for identifier: String) -> AzureOpenAIConfiguration.ModelDescriptor? {
        AzureOpenAIProvider.defaultDescriptor(for: identifier)
    }

    func discoveryDescriptor(id: String, baseModelID: String?) -> AzureOpenAIConfiguration.ModelDescriptor {
        let normalizedID = AzureOpenAIProvider.normalizedModelName(from: id)
        let openAIModel = AIModel.fromModelName(normalizedID)
        let inferredEndpoint = AzureOpenAIConfiguration.inferredEndpoint(for: id, baseModelID: baseModelID)
        let usesResponses = openAIModel?.usesResponsesAPI ?? (inferredEndpoint == .responses)
        let endpoint: AzureOpenAIConfiguration.ModelDescriptor.EndpointKind = usesResponses ? .responses : .chatCompletions
        let supportsStreaming = openAIModel?.canStream
        let resolvedBaseModelID = openAIModel?.rawValue ?? baseModelID ?? normalizedID
        let displayName = AIModel.azureCustom(name: normalizedID).displayName

        return AzureOpenAIConfiguration.ModelDescriptor(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            supportsStreaming: supportsStreaming,
            baseModelID: resolvedBaseModelID,
            supportsChatCompletions: usesResponses ? false : true,
            supportsResponses: usesResponses ? true : false
        )
    }
}
