import Foundation
import RepoPromptDomainRuntime

struct OraclePromptConfiguration {
    let chatPreset: ChatPreset
    let mode: OracleMode
    let promptContext: PromptContextResolved
    let systemPrompt: String
    let metaInstructions: [MetaInstruction]

    var chatPresetID: UUID {
        chatPreset.id
    }
}

enum OracleStartChoice: Equatable {
    case automatic
    case oracleSend(String)
    case contextBuilderPreset(String)
}

enum OracleSelectionOrigin: Equatable {
    case mcp
    case contextBuilderUI
}

struct OracleSelectionSnapshot {
    let origin: OracleSelectionOrigin
    let agentModelsProfile: AgentModelsSettingsProfile
    let modelPresets: [ModelPreset]
    let modelPresetsExposed: Bool
    let modelPresetsTemporarilyDisabled: Bool
    let chatPresets: [ChatPreset]
    let defaultChatPresets: [ChatPresetMode: ChatPreset]
    let contextBuilderUIModelStrings: [String]?
    let contextBuilderUIChatPreset: ChatPreset?

    init(
        origin: OracleSelectionOrigin,
        agentModelsProfile: AgentModelsSettingsProfile,
        modelPresets: [ModelPreset],
        modelPresetsExposed: Bool,
        modelPresetsTemporarilyDisabled: Bool,
        chatPresets: [ChatPreset],
        defaultChatPresets: [ChatPresetMode: ChatPreset],
        contextBuilderUIModelStrings: [String]? = nil,
        contextBuilderUIChatPreset: ChatPreset? = nil
    ) {
        self.origin = origin
        self.agentModelsProfile = agentModelsProfile
        self.modelPresets = modelPresets
        self.modelPresetsExposed = modelPresetsExposed
        self.modelPresetsTemporarilyDisabled = modelPresetsTemporarilyDisabled
        self.chatPresets = chatPresets
        self.defaultChatPresets = defaultChatPresets
        self.contextBuilderUIModelStrings = contextBuilderUIModelStrings
        self.contextBuilderUIChatPreset = contextBuilderUIChatPreset
    }
}

extension OracleSelectionSnapshot {
    @MainActor
    static func mcp(profile: AgentModelsSettingsProfile) -> Self {
        let chatPresetManager = ChatPresetManager.shared
        return Self(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: ModelPresetsManager.shared.allPresets(),
            modelPresetsExposed: GlobalSettingsStore.shared.mcpShowModelPresets(),
            modelPresetsTemporarilyDisabled: GlobalSettingsStore.shared.mcpTemporarilyDisablePresets(),
            chatPresets: chatPresetManager.allPresets,
            defaultChatPresets: [
                .chat: chatPresetManager.defaultPreset(for: .chat) ?? ChatPreset.BuiltIn.chat,
                .plan: chatPresetManager.defaultPreset(for: .plan) ?? ChatPreset.BuiltIn.plan,
                .review: chatPresetManager.defaultPreset(for: .review) ?? ChatPreset.BuiltIn.review
            ]
        )
    }
}

enum OracleExecutionSelection: Equatable {
    case explicitPreset(id: UUID, name: String)
    case automaticPreset(id: UUID, name: String)
    case agentModels
    case rawPrimaryOverride(String)
    case conversation
    case contextBuilderUI
}

struct ResolvedOracleExecution {
    let mode: OracleMode
    let roster: OracleRoster
    let models: [AIModel]
    let promptConfiguration: OraclePromptConfiguration
    let selection: OracleExecutionSelection

    fileprivate init(
        mode: OracleMode,
        roster: OracleRoster,
        models: [AIModel],
        promptConfiguration: OraclePromptConfiguration,
        selection: OracleExecutionSelection
    ) {
        self.mode = mode
        self.roster = roster
        self.models = models
        self.promptConfiguration = promptConfiguration
        self.selection = selection
    }

    var primaryModel: AIModel {
        models[0]
    }

    var presetName: String? {
        switch selection {
        case let .explicitPreset(_, name), let .automaticPreset(_, name):
            name
        case .agentModels, .rawPrimaryOverride, .conversation, .contextBuilderUI:
            nil
        }
    }

    func validateAvailability(using isModelAvailable: (AIModel) -> Bool) throws {
        for (laneIndex, model) in models.enumerated() where !isModelAvailable(model) {
            throw OracleExecutionResolutionError.unavailableModel(
                presetName: presetName,
                laneIndex: laneIndex,
                model: model
            )
        }
    }
}

enum OracleExecutionResolutionError: LocalizedError, Equatable {
    case invalidMode(String)
    case presetsUnavailable(String)
    case presetNotFound(String)
    case presetModeUnsupported(name: String, mode: String)
    case invalidRoster(String)
    case invalidModel(presetName: String?, laneIndex: Int, modelID: String)
    case unavailableModel(presetName: String?, laneIndex: Int, model: AIModel)
    case missingMappedChatPreset(presetName: String, mappingID: UUID)
    case missingConversationChatPreset(UUID)
    case missingDefaultChatPreset(String)
    case noUsablePreset(mode: String, details: String)
    case missingContextBuilderUISelection

    var errorDescription: String? {
        switch self {
        case let .invalidMode(mode):
            "Invalid mode: \(mode). Valid modes: chat, plan, review"
        case let .presetsUnavailable(choice):
            "Model preset '\(choice)' is unavailable because Model Presets are not exposed to MCP."
        case let .presetNotFound(choice):
            "Model preset '\(choice)' was not found."
        case let .presetModeUnsupported(name, mode):
            "Model preset '\(name)' does not support \(mode.capitalized) mode."
        case let .invalidRoster(message):
            message
        case let .invalidModel(presetName, laneIndex, modelID):
            "\(laneDescription(presetName: presetName, laneIndex: laneIndex)) uses unknown model '\(modelID)'."
        case let .unavailableModel(presetName, laneIndex, model):
            "\(laneDescription(presetName: presetName, laneIndex: laneIndex)) uses unavailable model '\(model.displayName)'."
        case let .missingMappedChatPreset(presetName, mappingID):
            "Model preset '\(presetName)' maps to missing Chat Preset \(mappingID.uuidString)."
        case let .missingConversationChatPreset(id):
            "Oracle conversation refers to missing Chat Preset \(id.uuidString)."
        case let .missingDefaultChatPreset(mode):
            "No default Chat Preset is available for \(mode.capitalized) mode."
        case let .noUsablePreset(mode, details):
            "No usable Model Preset supports \(mode.capitalized) mode. \(details)"
        case .missingContextBuilderUISelection:
            "Context Builder UI selection is incomplete."
        }
    }

    private func laneDescription(presetName: String?, laneIndex: Int) -> String {
        if let presetName {
            return "Model preset '\(presetName)' lane \(laneIndex + 1)"
        }
        return "Oracle lane \(laneIndex + 1)"
    }
}

@MainActor
struct OracleExecutionResolver {
    typealias PromptConfigurationCapture = (ChatPreset, OracleMode) throws -> OraclePromptConfiguration

    let resolveModel: (String) -> AIModel?
    let isModelAvailable: (AIModel) -> Bool
    let capturePromptConfiguration: PromptConfigurationCapture

    init(
        resolveModel: @escaping (String) -> AIModel?,
        isModelAvailable: @escaping (AIModel) -> Bool,
        capturePromptConfiguration: @escaping PromptConfigurationCapture
    ) {
        self.resolveModel = resolveModel
        self.isModelAvailable = isModelAvailable
        self.capturePromptConfiguration = capturePromptConfiguration
    }

    init(promptViewModel: PromptViewModel) {
        self.init(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: { promptViewModel.mcpOracleIsProviderConfigured(for: $0) },
            capturePromptConfiguration: { chatPreset, mode in
                try promptViewModel.captureOraclePromptConfiguration(chatPreset: chatPreset, mode: mode)
            }
        )
    }

    func resolve(
        choice: OracleStartChoice,
        mode rawMode: String,
        snapshot: OracleSelectionSnapshot
    ) throws -> ResolvedOracleExecution {
        let mode = try normalizedMode(rawMode)
        if snapshot.origin == .contextBuilderUI {
            return try resolveContextBuilderUI(mode: mode, snapshot: snapshot)
        }

        let presetsExposed = snapshot.modelPresetsExposed && !snapshot.modelPresetsTemporarilyDisabled
        switch choice {
        case .automatic:
            return try resolveAutomatic(mode: mode, snapshot: snapshot, presetsExposed: presetsExposed)
        case let .contextBuilderPreset(identifier):
            guard presetsExposed else {
                throw OracleExecutionResolutionError.presetsUnavailable(identifier)
            }
            guard let preset = matchingPreset(identifier, in: snapshot.modelPresets) else {
                throw OracleExecutionResolutionError.presetNotFound(identifier)
            }
            return try resolvePreset(preset, mode: mode, snapshot: snapshot, automatic: false)
        case let .oracleSend(identifier):
            return try resolveOracleSendChoice(
                identifier,
                mode: mode,
                snapshot: snapshot,
                presetsExposed: presetsExposed
            )
        }
    }

    func resolveConversation(
        modelString: String,
        persistedChatPresetID: UUID?,
        mode rawMode: String,
        snapshot: OracleSelectionSnapshot
    ) throws -> ResolvedOracleExecution {
        let mode = try normalizedMode(rawMode)
        let chatPreset: ChatPreset
        if let persistedChatPresetID {
            guard let persisted = snapshot.chatPresets.first(where: { $0.id == persistedChatPresetID }) else {
                throw OracleExecutionResolutionError.missingConversationChatPreset(persistedChatPresetID)
            }
            chatPreset = persisted.mode == chatPresetMode(for: mode)
                ? persisted
                : try defaultChatPreset(mode: mode, snapshot: snapshot)
        } else {
            chatPreset = try defaultChatPreset(mode: mode, snapshot: snapshot)
        }
        return try makeExecution(
            modelStrings: [modelString],
            presetName: nil,
            chatPreset: chatPreset,
            mode: mode,
            selection: .conversation
        )
    }

    private func resolveOracleSendChoice(
        _ identifier: String,
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot,
        presetsExposed: Bool
    ) throws -> ResolvedOracleExecution {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if presetsExposed, let preset = exactMatchingPreset(normalized, in: snapshot.modelPresets) {
            return try resolvePreset(preset, mode: mode, snapshot: snapshot, automatic: false)
        }
        if normalized.caseInsensitiveCompare("current_chat_model") == .orderedSame {
            return try resolveAgentModels(mode: mode, snapshot: snapshot)
        }
        if resolveModel(normalized) != nil {
            let roster = [normalized] + snapshot.agentModelsProfile.additionalOracleModelRaws
            return try makeExecution(
                modelStrings: roster,
                presetName: nil,
                chatPreset: defaultChatPreset(mode: mode, snapshot: snapshot),
                mode: mode,
                selection: .rawPrimaryOverride(normalized)
            )
        }
        if presetsExposed, let preset = fuzzyMatchingPreset(normalized, in: snapshot.modelPresets) {
            return try resolvePreset(preset, mode: mode, snapshot: snapshot, automatic: false)
        }
        if !presetsExposed, matchingPreset(normalized, in: snapshot.modelPresets) != nil {
            throw OracleExecutionResolutionError.presetsUnavailable(identifier)
        }
        throw OracleExecutionResolutionError.presetNotFound(identifier)
    }

    private func resolveAutomatic(
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot,
        presetsExposed: Bool
    ) throws -> ResolvedOracleExecution {
        guard presetsExposed, !snapshot.modelPresets.isEmpty else {
            return try resolveAgentModels(mode: mode, snapshot: snapshot)
        }
        let supporting = snapshot.modelPresets.filter { $0.supports(mode: mode.rawValue) }
        guard !supporting.isEmpty else {
            throw OracleExecutionResolutionError.noUsablePreset(
                mode: mode.rawValue,
                details: "The mode is disabled by every configured Model Preset."
            )
        }
        var failures: [String] = []
        for preset in supporting {
            do {
                return try resolvePreset(preset, mode: mode, snapshot: snapshot, automatic: true)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw OracleExecutionResolutionError.noUsablePreset(
            mode: mode.rawValue,
            details: failures.joined(separator: " ")
        )
    }

    private func resolvePreset(
        _ preset: ModelPreset,
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot,
        automatic: Bool
    ) throws -> ResolvedOracleExecution {
        guard preset.supports(mode: mode.rawValue) else {
            throw OracleExecutionResolutionError.presetModeUnsupported(name: preset.name, mode: mode.rawValue)
        }
        let chatPreset: ChatPreset
        if let mappingID = preset.chatPresetMappings?.presetID(for: mode.rawValue) {
            guard let mapped = snapshot.chatPresets.first(where: { $0.id == mappingID }) else {
                throw OracleExecutionResolutionError.missingMappedChatPreset(
                    presetName: preset.name,
                    mappingID: mappingID
                )
            }
            chatPreset = mapped
        } else {
            chatPreset = try defaultChatPreset(mode: mode, snapshot: snapshot)
        }
        return try makeExecution(
            modelStrings: preset.modelStrings,
            presetName: preset.name,
            chatPreset: chatPreset,
            mode: mode,
            selection: automatic
                ? .automaticPreset(id: preset.id, name: preset.name)
                : .explicitPreset(id: preset.id, name: preset.name)
        )
    }

    private func resolveAgentModels(
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot
    ) throws -> ResolvedOracleExecution {
        guard let primary = snapshot.agentModelsProfile.planningModelRaw else {
            throw OracleExecutionResolutionError.invalidRoster("Choose an Oracle model before starting a conversation.")
        }
        return try makeExecution(
            modelStrings: [primary] + snapshot.agentModelsProfile.additionalOracleModelRaws,
            presetName: nil,
            chatPreset: defaultChatPreset(mode: mode, snapshot: snapshot),
            mode: mode,
            selection: .agentModels
        )
    }

    private func resolveContextBuilderUI(
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot
    ) throws -> ResolvedOracleExecution {
        guard let modelStrings = snapshot.contextBuilderUIModelStrings,
              let chatPreset = snapshot.contextBuilderUIChatPreset
        else {
            throw OracleExecutionResolutionError.missingContextBuilderUISelection
        }
        return try makeExecution(
            modelStrings: modelStrings,
            presetName: nil,
            chatPreset: chatPreset,
            mode: mode,
            selection: .contextBuilderUI
        )
    }

    private func makeExecution(
        modelStrings: [String],
        presetName: String?,
        chatPreset: ChatPreset,
        mode: OracleMode,
        selection: OracleExecutionSelection
    ) throws -> ResolvedOracleExecution {
        let roster: OracleRoster
        do {
            guard let primary = modelStrings.first else {
                throw OracleExecutionResolutionError.invalidRoster("Oracle rosters require 1...5 models; received 0.")
            }
            roster = try OracleRoster(primaryModelID: primary, additionalModelIDs: Array(modelStrings.dropFirst()))
        } catch let error as OracleExecutionResolutionError {
            throw error
        } catch {
            throw OracleExecutionResolutionError.invalidRoster(error.localizedDescription)
        }
        let models = try roster.orderedModels.enumerated().map { laneIndex, reference in
            guard let model = resolveModel(reference.modelID) else {
                throw OracleExecutionResolutionError.invalidModel(
                    presetName: presetName,
                    laneIndex: laneIndex,
                    modelID: reference.modelID
                )
            }
            guard isModelAvailable(model) else {
                throw OracleExecutionResolutionError.unavailableModel(
                    presetName: presetName,
                    laneIndex: laneIndex,
                    model: model
                )
            }
            return model
        }
        return try ResolvedOracleExecution(
            mode: mode,
            roster: roster,
            models: models,
            promptConfiguration: capturePromptConfiguration(chatPreset, mode),
            selection: selection
        )
    }

    private func matchingPreset(_ identifier: String, in presets: [ModelPreset]) -> ModelPreset? {
        exactMatchingPreset(identifier, in: presets) ?? fuzzyMatchingPreset(identifier, in: presets)
    }

    private func exactMatchingPreset(_ identifier: String, in presets: [ModelPreset]) -> ModelPreset? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: normalized), let preset = presets.first(where: { $0.id == id }) {
            return preset
        }
        return presets.first(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame })
    }

    private func fuzzyMatchingPreset(_ identifier: String, in presets: [ModelPreset]) -> ModelPreset? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let matchedName = ModelPreset.findBestMatch(normalized, among: presets.map(\.name)) else {
            return nil
        }
        return presets.first(where: { $0.name == matchedName })
    }

    private func normalizedMode(_ rawMode: String) throws -> OracleMode {
        let normalized = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = OracleMode(rawValue: normalized) else {
            throw OracleExecutionResolutionError.invalidMode(normalized)
        }
        return mode
    }

    private func chatPresetMode(for mode: OracleMode) -> ChatPresetMode {
        switch mode {
        case .chat: .chat
        case .plan: .plan
        case .review: .review
        }
    }

    private func defaultChatPreset(
        mode: OracleMode,
        snapshot: OracleSelectionSnapshot
    ) throws -> ChatPreset {
        guard let preset = snapshot.defaultChatPresets[chatPresetMode(for: mode)] else {
            throw OracleExecutionResolutionError.missingDefaultChatPreset(mode.rawValue)
        }
        return preset
    }
}
