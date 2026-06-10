import CryptoKit
import Foundation
import IOKit
import Security

struct ClassicRepoPromptImportSectionResult: Equatable {
    var importedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var messages: [String]
    var failureMessages: [String]

    init(
        importedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        messages: [String] = [],
        failureMessages: [String] = []
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.messages = messages
        self.failureMessages = failureMessages
    }

    var didImport: Bool {
        importedCount > 0
    }

    mutating func importItems(_ count: Int, message: String? = nil) {
        guard count > 0 else { return }
        importedCount += count
        if let message {
            messages.append(message)
        }
    }

    mutating func skipItems(_ count: Int = 1, message: String? = nil) {
        skippedCount += count
        if let message {
            messages.append(message)
        }
    }

    mutating func failItems(_ count: Int = 1, message: String) {
        failedCount += count
        messages.append(message)
        failureMessages.append(message)
    }
}

struct ClassicRepoPromptImportResult {
    struct SkippedWorkspace: Equatable {
        let name: String
        let id: UUID?
        let reason: String
    }

    struct FailedWorkspace: Equatable {
        let name: String
        let id: UUID?
        let message: String
    }

    let sourceRoot: URL
    let targetRoot: URL
    var imported: [WorkspaceIndexEntry]
    var skipped: [SkippedWorkspace]
    var failed: [FailedWorkspace]
    var settings: ClassicRepoPromptImportSectionResult
    var workflowPresets: ClassicRepoPromptImportSectionResult
    var modelPresets: ClassicRepoPromptImportSectionResult
    var savedPrompts: ClassicRepoPromptImportSectionResult
    var contextBuilderPrompts: ClassicRepoPromptImportSectionResult
    var workflows: ClassicRepoPromptImportSectionResult
    var preferences: ClassicRepoPromptImportSectionResult
    var secureAccounts: ClassicRepoPromptImportSectionResult

    init(
        sourceRoot: URL,
        targetRoot: URL,
        imported: [WorkspaceIndexEntry] = [],
        skipped: [SkippedWorkspace] = [],
        failed: [FailedWorkspace] = [],
        settings: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        workflowPresets: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        modelPresets: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        savedPrompts: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        contextBuilderPrompts: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        workflows: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        preferences: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult(),
        secureAccounts: ClassicRepoPromptImportSectionResult = ClassicRepoPromptImportSectionResult()
    ) {
        self.sourceRoot = sourceRoot
        self.targetRoot = targetRoot
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.settings = settings
        self.workflowPresets = workflowPresets
        self.modelPresets = modelPresets
        self.savedPrompts = savedPrompts
        self.contextBuilderPrompts = contextBuilderPrompts
        self.workflows = workflows
        self.preferences = preferences
        self.secureAccounts = secureAccounts
    }

    var importedCount: Int {
        imported.count
    }

    var skippedCount: Int {
        skipped.count
    }

    var failedCount: Int {
        failed.count
    }

    var totalImportedCount: Int {
        importedCount +
            settings.importedCount +
            workflowPresets.importedCount +
            modelPresets.importedCount +
            savedPrompts.importedCount +
            contextBuilderPrompts.importedCount +
            workflows.importedCount +
            preferences.importedCount +
            secureAccounts.importedCount
    }

    var totalSkippedCount: Int {
        skippedCount +
            settings.skippedCount +
            workflowPresets.skippedCount +
            modelPresets.skippedCount +
            savedPrompts.skippedCount +
            contextBuilderPrompts.skippedCount +
            workflows.skippedCount +
            preferences.skippedCount +
            secureAccounts.skippedCount
    }

    var totalFailedCount: Int {
        failedCount +
            settings.failedCount +
            workflowPresets.failedCount +
            modelPresets.failedCount +
            savedPrompts.failedCount +
            contextBuilderPrompts.failedCount +
            workflows.failedCount +
            preferences.failedCount +
            secureAccounts.failedCount
    }

    var didImportPersistentData: Bool {
        totalImportedCount > 0
    }

    func userFacingSummary() -> String {
        if totalImportedCount == 0, totalFailedCount == 0 {
            if totalSkippedCount > 0 {
                return "No new Classic RepoPrompt data was imported. The available Classic data is already present in RepoPrompt CE or uses shared storage."
            }
            return "No Classic RepoPrompt data was found to import."
        }

        var parts: [String] = []
        if importedCount > 0 {
            parts.append("Imported \(importedCount) \(importedCount == 1 ? "workspace" : "workspaces").")
        }
        appendSectionSummary("settings item", result: settings, to: &parts)
        appendSectionSummary("workflow preset item", result: workflowPresets, to: &parts)
        appendSectionSummary("model preset", result: modelPresets, to: &parts)
        appendSectionSummary("saved prompt", result: savedPrompts, to: &parts)
        appendSectionSummary("context builder prompt", result: contextBuilderPrompts, to: &parts)
        appendSectionSummary("workflow", result: workflows, to: &parts)
        appendSectionSummary("preference", result: preferences, to: &parts)
        appendSectionSummary("secure account", result: secureAccounts, to: &parts)

        if skippedCount > 0 {
            parts.append("Skipped \(skippedCount) already-present or incomplete \(skippedCount == 1 ? "workspace" : "workspaces").")
        }
        if totalFailedCount > 0 {
            let firstFailure = failed.first?.message
                ?? firstSectionFailureMessage()
                ?? "Unknown error"
            parts.append("Failed \(totalFailedCount) \(totalFailedCount == 1 ? "item" : "items"): \(firstFailure)")
        }

        return parts.joined(separator: "\n")
    }

    private func firstSectionFailureMessage() -> String? {
        [
            settings,
            workflowPresets,
            modelPresets,
            savedPrompts,
            contextBuilderPrompts,
            workflows,
            preferences,
            secureAccounts
        ]
        .first { $0.failedCount > 0 }?
        .failureMessages
        .first
    }

    private func appendSectionSummary(
        _ singularName: String,
        result: ClassicRepoPromptImportSectionResult,
        to parts: inout [String]
    ) {
        guard result.importedCount > 0 else { return }
        parts.append("Imported \(result.importedCount) \(singularName)\(result.importedCount == 1 ? "" : "s").")
    }
}

protocol ClassicRepoPromptSecureValueReading {
    func get(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws -> String
}

protocol ClassicRepoPromptPreferences: Sendable {
    func object(forKey key: String) -> Any?
    func setObject(_ value: Any, forKey key: String)
}

private struct UserDefaultsClassicRepoPromptPreferences: ClassicRepoPromptPreferences, @unchecked Sendable {
    let defaults: UserDefaults

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func setObject(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

extension SecureKeyValueStorageBackend {
    func classicValueReader() -> ClassicRepoPromptSecureValueReading {
        SecureStorageClassicValueReaderAdapter(store: self)
    }
}

private struct SecureStorageClassicValueReaderAdapter: ClassicRepoPromptSecureValueReading {
    let store: SecureKeyValueStorageBackend

    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        try store.get(for: key, accessMode: accessMode)
    }
}

struct ClassicRepoPromptImportService {
    enum ImportError: LocalizedError {
        case sourceMissing(URL)

        var errorDescription: String? {
            switch self {
            case let .sourceMissing(url):
                "Classic RepoPrompt data was not found at \(url.path)."
            }
        }
    }

    static let defaultClassicAppSupportRoot: URL = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RepoPrompt", isDirectory: true)
    }()

    static let defaultSourceRoot: URL = defaultClassicAppSupportRoot
        .appendingPathComponent("Workspaces", isDirectory: true)

    static let defaultCEAppSupportRoot: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDirectory.appendingPathComponent("RepoPrompt CE", isDirectory: true)
    }()

    static let defaultSharedPromptSupportRoot: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDirectory.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
    }()

    private static let classicSettingsRelativePath = "Settings/globalSettings.json"
    private static let workflowPresetsRelativePath = "Presets/workflowPresets.json"
    private static let modelPresetsRelativePath = "Presets/modelPresets.json"
    private static let savedPromptsFilename = "SavedPrompts.json"
    private static let contextBuilderPromptsFilename = "ContextBuilderPrompts.json"
    private static let workflowsDirectoryName = "Workflows"
    private static let classicDefaultsSuiteName = "com.pvncher.repoprompt"

    private static let preferenceKeysToImport: [String] = [
        "ClaudeCodeConnected",
        "CodexCLIConnected",
        "OpenCodeCLIConnected",
        "CursorCLIConnected",
        "customModelOpenAI",
        "customModelAnthropic",
        "customModelGemini",
        "customModelDeepSeek",
        "customModelFireworks",
        "customModelGrok",
        "customModelGroq",
        "customModelZAI",
        "customModelAzure",
        "customProviderUserModel",
        "customBaseURLOpenAI",
        "customOpenAIVersionOverride",
        "openAIServiceTier",
        "openAIShowServiceTierVariants",
        "includeDefaultOpenRouterModels",
        "CustomOpenRouterModels",
        "OllamaLocalModels",
        "ollamaModel",
        "contextBuilderModel",
        "agentMode.lastUsedAgent",
        "agentMode.lastUsedModelsByAgent",
        "AgentWorkflowStore.hiddenBuiltInIDs",
        "AgentWorkflowStore.featuredWorkflowIDs",
        "AgentWorkflowStore.featuredDefaultsVersion",
        "codexAgentTools.bash.enabled",
        "codexAgentTools.search.enabled",
        "codexAgentTools.bash.approvalPolicy",
        "codexAgentTools.bash.sandboxMode",
        "codexAgentTools.approvalsReviewer",
        "codexAgentTools.mcpServerToggles",
        "codexAgent.reasoning.lastUsedEffort",
        "agentMode.codex.lastUsedReasoningEffort",
        "codexAgent.reasoning.lastUsedEffortByModelSlug",
        "claudeCodeAllowNativeBashTool",
        "claudeCodePermissionMode",
        "claudeCodeMCPStrictModeEnabled",
        "claudeCodeToolSearchEnabled",
        "claudeCodeEffortLevel",
        "claudeCodeEffortLevelsByModelSlug",
        "claudeCodeAgentModePromptDelivery",
        "claudeCodeNullBuiltInSystemPromptEnabled",
        "openCodeACPSessionMode",
        "cursorACPToolPermissionLevel"
    ]

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let documentDecoder: JSONDecoder
    private let documentEncoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documentDecoder = JSONDecoder()
        documentDecoder.dateDecodingStrategy = .iso8601
        self.documentDecoder = documentDecoder

        let documentEncoder = JSONEncoder()
        documentEncoder.dateEncodingStrategy = .iso8601
        documentEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.documentEncoder = documentEncoder
    }

    func importFromDefaultClassicInstallation(targetWorkspacesRoot: URL) async throws -> ClassicRepoPromptImportResult {
        try await importClassicRepoPromptData(
            sourceAppSupportRoot: Self.defaultClassicAppSupportRoot,
            targetAppSupportRoot: Self.defaultCEAppSupportRoot,
            sourcePromptSupportRoot: Self.defaultSharedPromptSupportRoot,
            targetPromptSupportRoot: Self.defaultSharedPromptSupportRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            // Classic Keychain ACLs can prompt once per saved secret, even when the
            // user has already approved one item. The default import is intentionally
            // no-prompt and migrates durable non-secret configuration instead.
            sourceSecureValueReader: nil,
            targetSecureStore: nil,
            sourcePreferences: UserDefaults(suiteName: Self.classicDefaultsSuiteName).map(UserDefaultsClassicRepoPromptPreferences.init(defaults:)),
            targetPreferences: UserDefaultsClassicRepoPromptPreferences(defaults: .standard)
        )
    }

    func importClassicRepoPromptData(
        sourceAppSupportRoot: URL,
        targetAppSupportRoot: URL,
        sourcePromptSupportRoot: URL,
        targetPromptSupportRoot: URL,
        targetWorkspacesRoot: URL,
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading? = nil,
        targetSecureStore: SecureKeyValueStorageBackend? = nil,
        sourcePreferences: ClassicRepoPromptPreferences? = nil,
        targetPreferences: ClassicRepoPromptPreferences? = nil
    ) async throws -> ClassicRepoPromptImportResult {
        try await Task.detached(priority: .utility) {
            try importClassicRepoPromptDataSynchronously(
                sourceAppSupportRoot: sourceAppSupportRoot,
                targetAppSupportRoot: targetAppSupportRoot,
                sourcePromptSupportRoot: sourcePromptSupportRoot,
                targetPromptSupportRoot: targetPromptSupportRoot,
                targetWorkspacesRoot: targetWorkspacesRoot,
                sourceSecureValueReader: sourceSecureValueReader,
                targetSecureStore: targetSecureStore,
                sourcePreferences: sourcePreferences,
                targetPreferences: targetPreferences
            )
        }.value
    }

    func importWorkspaces(sourceRoot: URL, targetRoot: URL) async throws -> ClassicRepoPromptImportResult {
        try await Task.detached(priority: .utility) {
            try importWorkspacesSynchronously(sourceRoot: sourceRoot, targetRoot: targetRoot)
        }.value
    }

    func sourceExists(at appSupportRoot: URL = Self.defaultClassicAppSupportRoot) -> Bool {
        fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.classicSettingsRelativePath).path) ||
            fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.workflowPresetsRelativePath).path) ||
            fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.modelPresetsRelativePath).path) ||
            classicWorkflowFilesExist(at: appSupportRoot.appendingPathComponent(Self.workflowsDirectoryName, isDirectory: true)) ||
            fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent("Workspaces/workspacesIndex.json").path)
    }

    private func classicWorkflowFilesExist(at directory: URL) -> Bool {
        guard let files = try? markdownFiles(in: directory) else { return false }
        return !files.isEmpty
    }

    private func importClassicRepoPromptDataSynchronously(
        sourceAppSupportRoot: URL,
        targetAppSupportRoot: URL,
        sourcePromptSupportRoot: URL,
        targetPromptSupportRoot: URL,
        targetWorkspacesRoot: URL,
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading?,
        targetSecureStore: SecureKeyValueStorageBackend?,
        sourcePreferences: ClassicRepoPromptPreferences?,
        targetPreferences: ClassicRepoPromptPreferences?
    ) throws -> ClassicRepoPromptImportResult {
        guard sourceExists(at: sourceAppSupportRoot) else {
            throw ImportError.sourceMissing(sourceAppSupportRoot)
        }

        let sourceWorkspacesRoot = sourceAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        var result = try importWorkspacesSynchronously(
            sourceRoot: sourceWorkspacesRoot,
            targetRoot: targetWorkspacesRoot,
            missingSourceIsSkip: true
        )

        result.settings = importSettings(
            sourceURL: sourceAppSupportRoot.appendingPathComponent(Self.classicSettingsRelativePath),
            targetURL: targetAppSupportRoot.appendingPathComponent(Self.classicSettingsRelativePath)
        )
        result.workflowPresets = importWorkflowPresets(
            sourceURL: sourceAppSupportRoot.appendingPathComponent(Self.workflowPresetsRelativePath),
            targetURL: targetAppSupportRoot.appendingPathComponent(Self.workflowPresetsRelativePath)
        )
        result.modelPresets = importModelPresets(
            sourceURL: sourceAppSupportRoot.appendingPathComponent(Self.modelPresetsRelativePath),
            targetURL: targetAppSupportRoot.appendingPathComponent(Self.modelPresetsRelativePath)
        )
        result.savedPrompts = importSavedPrompts(
            sourceURL: sourcePromptSupportRoot.appendingPathComponent(Self.savedPromptsFilename),
            targetURL: targetPromptSupportRoot.appendingPathComponent(Self.savedPromptsFilename)
        )
        result.contextBuilderPrompts = importContextBuilderPrompts(
            sourceURL: sourcePromptSupportRoot.appendingPathComponent(Self.contextBuilderPromptsFilename),
            targetURL: targetPromptSupportRoot.appendingPathComponent(Self.contextBuilderPromptsFilename)
        )
        result.workflows = importWorkflows(
            sourceDirectory: sourceAppSupportRoot.appendingPathComponent(Self.workflowsDirectoryName, isDirectory: true),
            targetDirectory: targetAppSupportRoot.appendingPathComponent(Self.workflowsDirectoryName, isDirectory: true)
        )
        result.preferences = importPreferences(
            sourcePreferences: sourcePreferences,
            targetPreferences: targetPreferences
        )
        result.secureAccounts = importSecureAccounts(
            sourceSecureValueReader: sourceSecureValueReader,
            targetSecureStore: targetSecureStore
        )

        return result
    }

    private func importWorkspacesSynchronously(
        sourceRoot: URL,
        targetRoot: URL,
        missingSourceIsSkip: Bool = false
    ) throws -> ClassicRepoPromptImportResult {
        let sourceIndexURL = sourceRoot.appendingPathComponent("workspacesIndex.json")
        guard fileManager.fileExists(atPath: sourceIndexURL.path) else {
            if missingSourceIsSkip {
                return ClassicRepoPromptImportResult(
                    sourceRoot: sourceRoot,
                    targetRoot: targetRoot,
                    skipped: [.init(name: "Classic RepoPrompt workspaces", id: nil, reason: "No workspace index found")]
                )
            }
            throw ImportError.sourceMissing(sourceRoot)
        }

        try fileManager.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let sourceEntries = loadIndex(from: sourceIndexURL)
        let targetIndexURL = targetRoot.appendingPathComponent("workspacesIndex.json")
        var targetEntries = loadIndex(from: targetIndexURL)
        var existingIDs = Set(targetEntries.map(\.id))
        var result = ClassicRepoPromptImportResult(
            sourceRoot: sourceRoot,
            targetRoot: targetRoot
        )

        for entry in sourceEntries {
            guard !existingIDs.contains(entry.id) else {
                result.skipped.append(.init(name: entry.name, id: entry.id, reason: "Already exists in RepoPrompt CE"))
                continue
            }

            do {
                guard let sourceFileURL = workspaceFileURL(for: entry, sourceRoot: sourceRoot) else {
                    result.skipped.append(.init(name: entry.name, id: entry.id, reason: "workspace.json not found"))
                    continue
                }

                var workspace = try loadWorkspace(from: sourceFileURL)
                workspace = normalizedImportedWorkspace(workspace)
                let targetDirectory = targetRoot.appendingPathComponent(directoryName(for: workspace), isDirectory: true)
                guard !fileManager.fileExists(atPath: targetDirectory.path) else {
                    result.skipped.append(.init(name: workspace.name, id: workspace.id, reason: "Target folder already exists"))
                    continue
                }

                try copyWorkspaceDirectory(from: sourceFileURL.deletingLastPathComponent(), to: targetDirectory, workspace: workspace)

                let importedEntry = WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: workspace.isHiddenInMenus
                )
                targetEntries.append(importedEntry)
                existingIDs.insert(workspace.id)
                result.imported.append(importedEntry)
            } catch {
                result.failed.append(.init(name: entry.name, id: entry.id, message: error.localizedDescription))
            }
        }

        if !result.imported.isEmpty {
            let data = try encoder.encode(targetEntries)
            try data.write(to: targetIndexURL, options: .atomic)
        }

        return result
    }

    private func importSettings(sourceURL: URL, targetURL: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .init(skippedCount: 1, messages: ["Classic settings were not found."])
        }

        do {
            let sourceDocument = try documentDecoder.decode(GlobalSettingsDocument.self, from: Data(contentsOf: sourceURL))
            let targetStore = GlobalSettingsFileStore(fileURL: targetURL, fileManager: fileManager)
            let targetDocument = targetStore.loadOrCreateDefault()

            var mergedCopySettings = targetDocument.copySettings
            var mergedChatSettings = targetDocument.chatSettings
            var importedCount = 0

            for (id, value) in sourceDocument.copySettings where mergedCopySettings[id] == nil {
                mergedCopySettings[id] = value
                importedCount += 1
            }
            for (id, value) in sourceDocument.chatSettings where mergedChatSettings[id] == nil {
                mergedChatSettings[id] = value
                importedCount += 1
            }

            let mergedDefaults = try mergeMissingFields(target: targetDocument.globalDefaults, source: sourceDocument.globalDefaults)
            let mergedScalarPreferences = try mergeOptionalMissingFields(target: targetDocument.scalarPreferences, source: sourceDocument.scalarPreferences)
            let globalDefaultsChanged = try !encodedJSONMatches(targetDocument.globalDefaults, mergedDefaults)
            let scalarPreferencesChanged = try !encodedJSONMatches(targetDocument.scalarPreferences, mergedScalarPreferences)
            if globalDefaultsChanged {
                importedCount += 1
            }
            if scalarPreferencesChanged {
                importedCount += 1
            }

            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic settings were already present."])
            }

            let mergedDocument = targetDocument.replacing(
                copySettings: mergedCopySettings,
                chatSettings: mergedChatSettings,
                globalDefaults: mergedDefaults,
                scalarPreferences: mergedScalarPreferences
            )
            try targetStore.save(mergedDocument)
            return .init(importedCount: importedCount)
        } catch {
            return .init(failedCount: 1, messages: ["Settings import failed: \(error.localizedDescription)"])
        }
    }

    private func importWorkflowPresets(sourceURL: URL, targetURL: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .init(skippedCount: 1, messages: ["Classic workflow presets were not found."])
        }

        do {
            let sourceDocument = try documentDecoder.decode(PresetFileStore.WorkflowPresetDocument.self, from: Data(contentsOf: sourceURL))
            let targetStore = PresetFileStore(workflowFileURL: targetURL, fileManager: fileManager)
            var targetDocument = targetStore.loadWorkflowPresets()
            var importedCount = 0

            importedCount += appendMissingCopyPresets(sourceDocument.copyUserPresets, to: &targetDocument.copyUserPresets)
            importedCount += appendMissingChatPresets(sourceDocument.chatUserPresets, to: &targetDocument.chatUserPresets)
            importedCount += appendMissingCopyOverrides(sourceDocument.copyOverrides, to: &targetDocument.copyOverrides)
            importedCount += appendMissingChatOverrides(sourceDocument.chatOverrides, to: &targetDocument.chatOverrides)
            importedCount += mergeMissingVisibility(sourceDocument.copyVisibilityByPresetID, into: &targetDocument.copyVisibilityByPresetID)
            importedCount += mergeMissingVisibility(sourceDocument.chatVisibilityByPresetID, into: &targetDocument.chatVisibilityByPresetID)

            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic workflow presets were already present."])
            }

            targetStore.saveWorkflowPresets(targetDocument)
            return .init(importedCount: importedCount)
        } catch {
            return .init(failedCount: 1, messages: ["Workflow preset import failed: \(error.localizedDescription)"])
        }
    }

    private func importModelPresets(sourceURL: URL, targetURL: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .init(skippedCount: 1, messages: ["Classic model presets were not found."])
        }

        do {
            let sourceDocument = try documentDecoder.decode(PresetFileStore.ModelPresetDocument.self, from: Data(contentsOf: sourceURL))
            let targetStore = PresetFileStore(modelFileURL: targetURL, fileManager: fileManager)
            var targetDocument = targetStore.loadModelPresets()
            let importedCount = appendMissingModelPresets(sourceDocument.modelPresets, to: &targetDocument.modelPresets)

            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic model presets were already present."])
            }

            targetStore.saveModelPresets(targetDocument)
            return .init(importedCount: importedCount)
        } catch {
            return .init(failedCount: 1, messages: ["Model preset import failed: \(error.localizedDescription)"])
        }
    }

    private func importSavedPrompts(sourceURL: URL, targetURL: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .init(skippedCount: 1, messages: ["Classic saved prompts were not found."])
        }
        guard sourceURL.standardizedFileURL.path != targetURL.standardizedFileURL.path else {
            return .init(skippedCount: 1, messages: ["Saved prompts already use shared Classic/CE storage."])
        }

        do {
            let sourcePrompts = try decoder.decode([PromptViewModel.StoredPrompt].self, from: Data(contentsOf: sourceURL))
            var targetPrompts = try loadJSONIfPresent([PromptViewModel.StoredPrompt].self, from: targetURL) ?? []
            let importedCount = appendMissingPrompts(sourcePrompts, to: &targetPrompts)
            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic saved prompts were already present."])
            }
            try writeJSON(targetPrompts, to: targetURL, encoder: encoder)
            return .init(importedCount: importedCount)
        } catch {
            return .init(failedCount: 1, messages: ["Saved prompt import failed: \(error.localizedDescription)"])
        }
    }

    private func importContextBuilderPrompts(sourceURL: URL, targetURL: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .init(skippedCount: 1, messages: ["Classic context builder prompts were not found."])
        }
        guard sourceURL.standardizedFileURL.path != targetURL.standardizedFileURL.path else {
            return .init(skippedCount: 1, messages: ["Context builder prompts already use shared Classic/CE storage."])
        }

        do {
            let sourcePrompts = try decoder.decode([ContextBuilderPrompt].self, from: Data(contentsOf: sourceURL))
            var targetPrompts = try loadJSONIfPresent([ContextBuilderPrompt].self, from: targetURL) ?? []
            let importedCount = appendMissingContextBuilderPrompts(sourcePrompts, to: &targetPrompts)
            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic context builder prompts were already present."])
            }
            try writeJSON(targetPrompts, to: targetURL, encoder: encoder)
            return .init(importedCount: importedCount)
        } catch {
            return .init(failedCount: 1, messages: ["Context builder prompt import failed: \(error.localizedDescription)"])
        }
    }

    private func importWorkflows(sourceDirectory: URL, targetDirectory: URL) -> ClassicRepoPromptImportSectionResult {
        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            return .init(skippedCount: 1, messages: ["Classic custom workflows were not found."])
        }

        do {
            let sourceFiles = try markdownFiles(in: sourceDirectory)
            guard !sourceFiles.isEmpty else {
                return .init(skippedCount: 1, messages: ["Classic custom workflows were not found."])
            }

            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let targetFiles = (try? markdownFiles(in: targetDirectory)) ?? []
            var existingIdentities = Set(targetFiles.map(workflowIdentity))
            var result = ClassicRepoPromptImportSectionResult()

            for sourceFile in sourceFiles {
                let identity = workflowIdentity(for: sourceFile)
                guard !existingIdentities.contains(identity) else {
                    result.skipItems()
                    continue
                }

                let targetFile = uniqueWorkflowTargetURL(for: sourceFile, in: targetDirectory)
                do {
                    try fileManager.copyItem(at: sourceFile, to: targetFile)
                    existingIdentities.insert(identity)
                    result.importItems(1)
                } catch {
                    result.failItems(message: "\(sourceFile.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if result.importedCount == 0, result.failedCount == 0, result.messages.isEmpty {
                result.messages.append("Classic custom workflows were already present.")
            }
            return result
        } catch {
            return .init(failedCount: 1, messages: ["Workflow import failed: \(error.localizedDescription)"])
        }
    }

    private func importPreferences(
        sourcePreferences: ClassicRepoPromptPreferences?,
        targetPreferences: ClassicRepoPromptPreferences?
    ) -> ClassicRepoPromptImportSectionResult {
        guard let sourcePreferences, let targetPreferences else {
            return .init(skippedCount: 1, messages: ["Classic preferences import is unavailable in this runtime."])
        }

        var result = ClassicRepoPromptImportSectionResult()
        for key in Self.preferenceKeysToImport {
            guard let sourceValue = sourcePreferences.object(forKey: key) else {
                result.skipItems()
                continue
            }
            guard targetPreferences.object(forKey: key) == nil else {
                result.skipItems()
                continue
            }
            targetPreferences.setObject(sourceValue, forKey: key)
            result.importItems(1)
        }

        if result.importedCount == 0, result.failedCount == 0, result.messages.isEmpty {
            result.messages.append("Classic preferences were already present or not set.")
        }
        return result
    }

    private func importSecureAccounts(
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading?,
        targetSecureStore: SecureKeyValueStorageBackend?
    ) -> ClassicRepoPromptImportSectionResult {
        guard let sourceSecureValueReader, let targetSecureStore else {
            return .init(skippedCount: 1, messages: ["Classic secure account import is unavailable in this runtime."])
        }

        var result = ClassicRepoPromptImportSectionResult()
        let accessMode = KeychainAccessMode.nonInteractive(reason: .bulkSettingsLoad)
        for account in SecureStorageAccountCatalog.allAccounts {
            let sourceValue: String
            do {
                sourceValue = try sourceSecureValueReader.get(for: account.identifier, accessMode: accessMode)
            } catch KeychainService.KeychainError.itemNotFound {
                result.skipItems()
                continue
            } catch KeychainService.KeychainError.interactionNotAllowed {
                result.failItems(message: "\(account.displayName): Keychain access requires user interaction.")
                continue
            } catch {
                result.failItems(message: "\(account.displayName): \(error.localizedDescription)")
                continue
            }

            do {
                let existingValue = try targetSecureStore.get(for: account.identifier, accessMode: accessMode)
                if existingValue == sourceValue {
                    result.skipItems()
                } else {
                    result.skipItems(message: "\(account.displayName) already has a different RepoPrompt CE value.")
                }
                continue
            } catch KeychainService.KeychainError.itemNotFound {
                // Save below.
            } catch {
                result.failItems(message: "\(account.displayName): \(error.localizedDescription)")
                continue
            }

            do {
                try targetSecureStore.save(sourceValue, for: account.identifier, accessMode: accessMode)
                let verifiedValue = try targetSecureStore.get(for: account.identifier, accessMode: accessMode)
                if verifiedValue == sourceValue {
                    result.importItems(1)
                } else {
                    result.failItems(message: "\(account.displayName): imported value could not be verified.")
                }
            } catch {
                result.failItems(message: "\(account.displayName): \(error.localizedDescription)")
            }
        }

        if result.importedCount == 0, result.failedCount == 0, result.messages.isEmpty {
            result.messages.append("No new Classic secure accounts were importable.")
        }
        return result
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension.lowercased() == "md" else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func workflowIdentity(for fileURL: URL) -> String {
        if let id = workflowID(in: fileURL) {
            return "id:\(id.uuidString.lowercased())"
        }
        return "file:\(fileURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func workflowID(in fileURL: URL) -> UUID? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        if stem.hasPrefix("workflow-"), let parsed = UUID(uuidString: String(stem.dropFirst("workflow-".count))) {
            return parsed
        }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              content.hasPrefix("---")
        else {
            return nil
        }
        let searchRange = content.index(content.startIndex, offsetBy: 3) ..< content.endIndex
        guard let closingRange = content.range(of: "\n---", range: searchRange) else { return nil }
        let frontmatter = content[content.index(content.startIndex, offsetBy: 3) ..< closingRange.lowerBound]
        for line in frontmatter.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("id:") else { continue }
            var value = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if let parsed = UUID(uuidString: String(value)) {
                return parsed
            }
        }
        return nil
    }

    private func uniqueWorkflowTargetURL(for sourceFile: URL, in targetDirectory: URL) -> URL {
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let pathExtension = sourceFile.pathExtension
        var candidate = targetDirectory.appendingPathComponent(sourceFile.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var suffix = 2
        repeat {
            candidate = targetDirectory.appendingPathComponent("\(baseName)-classic-\(suffix).\(pathExtension)")
            suffix += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    private func loadIndex(from url: URL) -> [WorkspaceIndexEntry] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([WorkspaceIndexEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    private func workspaceFileURL(for entry: WorkspaceIndexEntry, sourceRoot: URL) -> URL? {
        let candidates: [URL] = [
            entry.customStoragePath?.appendingPathComponent("workspace.json"),
            sourceRoot
                .appendingPathComponent(directoryName(name: entry.name, id: entry.id), isDirectory: true)
                .appendingPathComponent("workspace.json"),
            fallbackWorkspaceDirectory(for: entry.id, sourceRoot: sourceRoot)?
                .appendingPathComponent("workspace.json")
        ].compactMap(\.self)

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func fallbackWorkspaceDirectory(for id: UUID, sourceRoot: URL) -> URL? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let idSuffix = "-\(id.uuidString.lowercased())"
        return children.first { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            return url.lastPathComponent.lowercased().hasSuffix(idSuffix)
        }
    }

    private func loadWorkspace(from fileURL: URL) throws -> WorkspaceModel {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try decoder.decode(WorkspaceModel.self, from: data)
    }

    private func normalizedImportedWorkspace(_ source: WorkspaceModel) -> WorkspaceModel {
        var workspace = source
        workspace.customStoragePath = nil
        workspace.isSystemWorkspace = false
        workspace.ephemeralFlag = false
        workspace.schemaVersion = max(workspace.schemaVersion, 1)
        if source.isSystemWorkspace, workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" {
            workspace.name = "Default (Classic)"
        }
        workspace.normalizeComposeTabInvariants()
        workspace.normalizationRequiresSave = false
        return workspace
    }

    private func copyWorkspaceDirectory(from sourceDirectory: URL, to targetDirectory: URL, workspace: WorkspaceModel) throws {
        let tempDirectory = targetDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".classic-import-\(workspace.id.uuidString)-\(UUID().uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: tempDirectory.path) {
            try fileManager.removeItem(at: tempDirectory)
        }

        do {
            try fileManager.copyItem(at: sourceDirectory, to: tempDirectory)
            try removeIfPresent(tempDirectory.appendingPathComponent("workspace.json"))
            try removeIfPresent(tempDirectory.appendingPathComponent("AgentSessions/AgentSessionIndex.json"))
            let workspaceData = try encoder.encode(workspace)
            try workspaceData.write(to: tempDirectory.appendingPathComponent("workspace.json"), options: .atomic)
            try fileManager.moveItem(at: tempDirectory, to: targetDirectory)
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func directoryName(for workspace: WorkspaceModel) -> String {
        directoryName(name: workspace.name, id: workspace.id)
    }

    private func directoryName(name: String, id: UUID) -> String {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(id.uuidString)"
    }

    @inline(never)
    private func mergeOptionalMissingFields<T: Codable>(target: T?, source: T?) throws -> T? {
        guard let source else { return target }
        guard let target else { return source }
        return try mergeMissingFields(target: target, source: source)
    }

    @inline(never)
    private func mergeMissingFields<T: Codable>(target: T, source: T) throws -> T {
        let targetObject = try jsonObject(from: target)
        let sourceObject = try jsonObject(from: source)
        let mergedObject = mergeMissingJSONFields(target: targetObject, source: sourceObject)
        let mergedData = try JSONSerialization.data(withJSONObject: mergedObject)
        return try documentDecoder.decode(T.self, from: mergedData)
    }

    private func encodedJSONMatches<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        try documentEncoder.encode(lhs) == documentEncoder.encode(rhs)
    }

    private func jsonObject(from value: some Encodable) throws -> Any {
        let data = try documentEncoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func mergeMissingJSONFields(target: Any, source: Any) -> Any {
        if target is NSNull {
            return source
        }
        guard let targetDictionary = target as? [String: Any],
              let sourceDictionary = source as? [String: Any]
        else {
            return target
        }

        var merged = targetDictionary
        for (key, sourceValue) in sourceDictionary {
            if let targetValue = merged[key] {
                merged[key] = mergeMissingJSONFields(target: targetValue, source: sourceValue)
            } else {
                merged[key] = sourceValue
            }
        }
        return merged
    }

    private func appendMissingCopyPresets(_ source: [CopyPreset], to target: inout [CopyPreset]) -> Int {
        var existingIDs = Set(target.map(\.id))
        var existingNames = Set(target.map { normalizedName($0.name) })
        var importedCount = 0

        for preset in source {
            let presetName = normalizedName(preset.name)
            guard !existingIDs.contains(preset.id), !existingNames.contains(presetName) else {
                continue
            }
            target.append(preset)
            existingIDs.insert(preset.id)
            existingNames.insert(presetName)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingChatPresets(_ source: [ChatPreset], to target: inout [ChatPreset]) -> Int {
        var existingIDs = Set(target.map(\.id))
        var existingNames = Set(target.map { normalizedName($0.name) })
        var importedCount = 0

        for preset in source {
            let presetName = normalizedName(preset.name)
            guard !existingIDs.contains(preset.id), !existingNames.contains(presetName) else {
                continue
            }
            target.append(preset)
            existingIDs.insert(preset.id)
            existingNames.insert(presetName)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingModelPresets(_ source: [ModelPreset], to target: inout [ModelPreset]) -> Int {
        var existingIDs = Set(target.map(\.id))
        var existingNames = Set(target.map { normalizedName($0.name) })
        var importedCount = 0

        for preset in source {
            let presetName = normalizedName(preset.name)
            guard !existingIDs.contains(preset.id), !existingNames.contains(presetName) else {
                continue
            }
            target.append(preset)
            existingIDs.insert(preset.id)
            existingNames.insert(presetName)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingCopyOverrides(_ source: [CopyPresetOverrides], to target: inout [CopyPresetOverrides]) -> Int {
        var existingIDs = Set(target.map(\.presetID))
        var importedCount = 0

        for item in source where !existingIDs.contains(item.presetID) {
            target.append(item)
            existingIDs.insert(item.presetID)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingChatOverrides(_ source: [ChatPresetOverrides], to target: inout [ChatPresetOverrides]) -> Int {
        var existingIDs = Set(target.map(\.presetID))
        var importedCount = 0

        for item in source where !existingIDs.contains(item.presetID) {
            target.append(item)
            existingIDs.insert(item.presetID)
            importedCount += 1
        }
        return importedCount
    }

    private func mergeMissingVisibility(_ source: [String: Bool], into target: inout [String: Bool]) -> Int {
        var importedCount = 0
        for (key, value) in source where target[key] == nil {
            target[key] = value
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingPrompts(
        _ source: [PromptViewModel.StoredPrompt],
        to target: inout [PromptViewModel.StoredPrompt]
    ) -> Int {
        var existingIDs = Set(target.map(\.id))
        var existingContentKeys = Set(target.map { promptIdentity(title: $0.title, content: $0.content) })
        var importedCount = 0

        for prompt in source {
            let contentKey = promptIdentity(title: prompt.title, content: prompt.content)
            guard !existingIDs.contains(prompt.id), !existingContentKeys.contains(contentKey) else {
                continue
            }
            target.append(prompt)
            existingIDs.insert(prompt.id)
            existingContentKeys.insert(contentKey)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingContextBuilderPrompts(
        _ source: [ContextBuilderPrompt],
        to target: inout [ContextBuilderPrompt]
    ) -> Int {
        var existingIDs = Set(target.map(\.id))
        var existingContentKeys = Set(target.map { promptIdentity(title: $0.title, content: $0.content) })
        var importedCount = 0

        for prompt in source {
            let contentKey = promptIdentity(title: prompt.title, content: prompt.content)
            guard !existingIDs.contains(prompt.id), !existingContentKeys.contains(contentKey) else {
                continue
            }
            target.append(prompt)
            existingIDs.insert(prompt.id)
            existingContentKeys.insert(contentKey)
            importedCount += 1
        }
        return importedCount
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func promptIdentity(title: String, content: String) -> String {
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{1F}\(content.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func loadJSONIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func writeJSON(_ value: some Encodable, to url: URL, encoder: JSONEncoder) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension WorkspaceManagerViewModel {
    @MainActor
    func importClassicRepoPromptData() async -> ClassicRepoPromptImportResult {
        let targetRoot = globalCustomStorageURL ?? WorkspaceStoragePaths.defaultRoot
        do {
            let result = try await ClassicRepoPromptImportService()
                .importFromDefaultClassicInstallation(targetWorkspacesRoot: targetRoot)
            if result.importedCount > 0 {
                reloadWorkspacesFromDisk()
                notifyWorkspaceListDidChange()
            }
            if result.settings.didImport {
                _ = GlobalSettingsStore.shared.reloadFromDisk()
            }
            if result.workflows.didImport {
                AgentWorkflowStore.shared.refresh()
            }
            if result.preferences.didImport {
                NotificationCenter.default.post(name: .claudeCodeConnectionChanged, object: nil)
                NotificationCenter.default.post(name: .codexConnectionChanged, object: nil)
                NotificationCenter.default.post(name: .openCodeConnectionChanged, object: nil)
                NotificationCenter.default.post(name: .cursorConnectionChanged, object: nil)
            }
            if result.secureAccounts.didImport {
                for domain in AgentPermissionSecureDomain.allCases {
                    NotificationCenter.default.post(
                        name: .agentPermissionSecureStoreDidChange,
                        object: nil,
                        userInfo: [
                            AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue,
                            AgentPermissionSecureStoreNotificationKey.writeSucceeded: true
                        ]
                    )
                }
            }
            return result
        } catch {
            return ClassicRepoPromptImportResult(
                sourceRoot: ClassicRepoPromptImportService.defaultClassicAppSupportRoot,
                targetRoot: targetRoot,
                failed: [.init(name: "Classic RepoPrompt", id: nil, message: error.localizedDescription)]
            )
        }
    }
}

final class ClassicRepoPromptKeychainValueReader: ClassicRepoPromptSecureValueReading, @unchecked Sendable {
    private let serviceName: String
    private let secItemClient: SecItemClient

    private let integrityInstallSecretAccount = SecurityObfuscation.decode([
        40, 42, 5, 51, 52, 46, 63, 61, 40, 51, 46, 35, 5, 51, 52,
        41, 46, 59, 54, 54, 5, 41, 63, 57, 40, 63, 46, 5, 44, 107
    ])
    private let integrityKeyDerivationSalt = SecurityObfuscation.decode([
        8, 63, 42, 53, 10, 40, 53, 55, 42, 46, 9, 63, 57, 47, 40, 51,
        46, 35, 9, 59, 54, 46, 119, 44, 104
    ])

    init(
        serviceName: String = "com.pvncher.repoprompt.keychain",
        secItemClient: SecItemClient = SystemSecItemClient()
    ) {
        self.serviceName = serviceName
        self.secItemClient = secItemClient
    }

    func get(for key: String, accessMode: KeychainAccessMode = .interactive) throws -> String {
        let data = try rawData(for: key, accessMode: accessMode)
        return try verifyAndExtract(from: data, accessMode: accessMode)
    }

    private func rawData(for key: String, accessMode: KeychainAccessMode) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if accessMode.isNonInteractive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = secItemClient.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw keychainError(for: status)
        }
        guard let data = result as? Data else {
            throw KeychainService.KeychainError.invalidData
        }
        return data
    }

    private func loadInstallSecret(accessMode: KeychainAccessMode) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: integrityInstallSecretAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if accessMode.isNonInteractive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = secItemClient.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(for: status)
        }
        guard let data = result as? Data, !data.isEmpty else {
            throw KeychainService.KeychainError.invalidData
        }
        return data
    }

    private func verifyAndExtract(from data: Data, accessMode: KeychainAccessMode) throws -> String {
        guard data.count > 32 else {
            throw KeychainService.KeychainError.invalidData
        }

        let storedHMAC = data.prefix(32)
        let originalData = data.suffix(from: 32)
        let hmac = try HMAC<SHA256>.authenticationCode(for: originalData, using: deviceSpecificKey(accessMode: accessMode))
        guard storedHMAC == Data(hmac) else {
            throw KeychainService.KeychainError.invalidData
        }

        guard let value = String(data: originalData, encoding: .utf8) else {
            throw KeychainService.KeychainError.invalidData
        }
        return value
    }

    private func deviceSpecificKey(accessMode: KeychainAccessMode) throws -> SymmetricKey {
        let installSecret = try loadInstallSecret(accessMode: accessMode)
        let hardwareUUID = hardwareUUID()
        let salt = integrityKeyDerivationSalt

        if let installSecret, !installSecret.isEmpty {
            var material = Data()
            material.append(installSecret)
            if let hardwareUUID, let uuidData = hardwareUUID.data(using: .utf8) {
                material.append(uuidData)
            }
            if let saltData = salt.data(using: .utf8) {
                material.append(saltData)
            }
            return SymmetricKey(data: Data(SHA256.hash(data: material)))
        }

        if let hardwareUUID, let data = (hardwareUUID + salt).data(using: .utf8) {
            return SymmetricKey(data: Data(SHA256.hash(data: data)))
        }

        return SymmetricKey(data: Data(SHA256.hash(data: Data(salt.utf8))))
    }

    private func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let property = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  kIOPlatformUUIDKey as CFString,
                  kCFAllocatorDefault,
                  0
              )
        else {
            return nil
        }
        return property.takeRetainedValue() as? String
    }

    private func keychainError(for status: OSStatus) -> KeychainService.KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecDuplicateItem:
            .duplicateItem
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecUserCanceled:
            .userInteractionCancelled
        case errSecAuthFailed:
            .authenticationFailed
        default:
            .unexpectedStatus(status)
        }
    }
}
