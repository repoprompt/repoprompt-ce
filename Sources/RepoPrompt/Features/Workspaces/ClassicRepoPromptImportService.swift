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

    static func failed(message: String) -> ClassicRepoPromptImportSectionResult {
        .init(failedCount: 1, messages: [message], failureMessages: [message])
    }
}

private extension Set<UUID> {
    func containsVisibilityKey(_ key: String) -> Bool {
        guard let id = UUID(uuidString: key) else { return false }
        return contains(id)
    }
}

private struct ClassicWorkspaceIndexEntry: Decodable {
    let id: UUID
    let name: String
    let customStoragePath: URL?
    let isSystemWorkspace: Bool
    let isHiddenInMenus: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case customStoragePath
        case isSystemWorkspace
        case isHiddenInMenus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        customStoragePath = try container.decodeIfPresent(URL.self, forKey: .customStoragePath)
        isSystemWorkspace = try container.decodeIfPresent(Bool.self, forKey: .isSystemWorkspace) ?? false
        isHiddenInMenus = try container.decodeIfPresent(Bool.self, forKey: .isHiddenInMenus) ?? false
    }

    var workspaceIndexEntry: WorkspaceIndexEntry {
        WorkspaceIndexEntry(
            id: id,
            name: name,
            customStoragePath: customStoragePath,
            isSystemWorkspace: isSystemWorkspace,
            isHiddenInMenus: isHiddenInMenus
        )
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

protocol ClassicRepoPromptSecureValueReading: Sendable {
    func get(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws -> String
}

protocol ClassicRepoPromptSecureValueWriting: Sendable {
    func getPlainValue(
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode
    ) throws -> String?

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode
    ) throws
}

extension SecureKeysService: ClassicRepoPromptSecureValueWriting {}

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
        "ClaudeCodeCompatibleBackendConfigs",
        "ClaudeCodeCompatibleBackendConfigured.glmZAI",
        "ClaudeCodeCompatibleBackendConfigured.kimi",
        "ClaudeCodeCompatibleBackendConfigured.custom",
        "ClaudeCodeGLMZAIConfigured",
        "CustomProviderConfig",
        "CustomProviderSettings",
        "openrouter_configuration",
        "provider_config_anthropic",
        "provider_config_openAI",
        "provider_config_ollama",
        "provider_config_azure",
        "provider_config_openRouter",
        "provider_config_gemini",
        "provider_config_deepseek",
        "provider_config_customProvider",
        "provider_config_fireworks",
        "provider_config_grok",
        "provider_config_groq",
        "provider_config_zAI",
        "provider_config_claudeCode",
        "provider_config_codex",
        "provider_config_openCode",
        "provider_config_cursor",
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

    func importFromDefaultClassicInstallation(
        targetWorkspacesRoot: URL,
        targetWorkspacesRootIsGlobalCustomStorage: Bool = false
    ) async throws -> ClassicRepoPromptImportResult {
        try await importClassicRepoPromptData(
            sourceAppSupportRoot: Self.defaultClassicAppSupportRoot,
            targetAppSupportRoot: Self.defaultCEAppSupportRoot,
            sourcePromptSupportRoot: Self.defaultSharedPromptSupportRoot,
            targetPromptSupportRoot: Self.defaultSharedPromptSupportRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            targetWorkspacesRootIsGlobalCustomStorage: targetWorkspacesRootIsGlobalCustomStorage,
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
        targetWorkspacesRootIsGlobalCustomStorage: Bool = false,
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading? = nil,
        targetSecureStore: ClassicRepoPromptSecureValueWriting? = nil,
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
                targetWorkspacesRootIsGlobalCustomStorage: targetWorkspacesRootIsGlobalCustomStorage,
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

    func defaultClassicSourceExists() -> Bool {
        sourceExists(
            at: Self.defaultClassicAppSupportRoot,
            preferences: UserDefaults(suiteName: Self.classicDefaultsSuiteName).map(UserDefaultsClassicRepoPromptPreferences.init(defaults:))
        )
    }

    func sourceExists(
        at appSupportRoot: URL = Self.defaultClassicAppSupportRoot,
        preferences: ClassicRepoPromptPreferences? = nil
    ) -> Bool {
        let sourceWorkspacesRoot = sourceWorkspacesRoot(appSupportRoot: appSupportRoot, preferences: preferences)
        return fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.classicSettingsRelativePath).path) ||
            fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.workflowPresetsRelativePath).path) ||
            fileManager.fileExists(atPath: appSupportRoot.appendingPathComponent(Self.modelPresetsRelativePath).path) ||
            classicWorkflowFilesExist(at: appSupportRoot.appendingPathComponent(Self.workflowsDirectoryName, isDirectory: true)) ||
            fileManager.fileExists(atPath: sourceWorkspacesRoot.appendingPathComponent("workspacesIndex.json").path) ||
            preferencesContainImportableValues(preferences)
    }

    private func classicWorkflowFilesExist(at directory: URL) -> Bool {
        guard let files = try? markdownFiles(in: directory) else { return false }
        return !files.isEmpty
    }

    private func sourceWorkspacesRoot(
        appSupportRoot: URL,
        preferences: ClassicRepoPromptPreferences?
    ) -> URL {
        let defaultRoot = appSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        guard let customRoot = classicGlobalCustomStorageURL(from: preferences) else {
            return defaultRoot
        }

        // Classic writes the workspace index under GlobalCustomStorageURL when set.
        let customIndexURL = customRoot.appendingPathComponent("workspacesIndex.json")
        guard fileManager.fileExists(atPath: customIndexURL.path) else {
            return defaultRoot
        }
        return customRoot
    }

    private func classicGlobalCustomStorageURL(from preferences: ClassicRepoPromptPreferences?) -> URL? {
        guard let rawValue = preferences?.object(forKey: "GlobalCustomStorageURL") else { return nil }
        if let url = rawValue as? URL {
            return url
        }
        guard let path = rawValue as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func importClassicRepoPromptDataSynchronously(
        sourceAppSupportRoot: URL,
        targetAppSupportRoot: URL,
        sourcePromptSupportRoot: URL,
        targetPromptSupportRoot: URL,
        targetWorkspacesRoot: URL,
        targetWorkspacesRootIsGlobalCustomStorage: Bool,
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading?,
        targetSecureStore: ClassicRepoPromptSecureValueWriting?,
        sourcePreferences: ClassicRepoPromptPreferences?,
        targetPreferences: ClassicRepoPromptPreferences?
    ) throws -> ClassicRepoPromptImportResult {
        guard sourceExists(at: sourceAppSupportRoot, preferences: sourcePreferences) else {
            throw ImportError.sourceMissing(sourceAppSupportRoot)
        }

        let sourceWorkspacesRoot = sourceWorkspacesRoot(
            appSupportRoot: sourceAppSupportRoot,
            preferences: sourcePreferences
        )
        var result: ClassicRepoPromptImportResult
        do {
            result = try importWorkspacesSynchronously(
                sourceRoot: sourceWorkspacesRoot,
                targetRoot: targetWorkspacesRoot,
                missingSourceIsSkip: true,
                targetRootIsGlobalCustomStorage: targetWorkspacesRootIsGlobalCustomStorage
            )
        } catch {
            result = ClassicRepoPromptImportResult(
                sourceRoot: sourceWorkspacesRoot,
                targetRoot: targetWorkspacesRoot,
                failed: [.init(name: "Classic RepoPrompt workspaces", id: nil, message: error.localizedDescription)]
            )
        }

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
        missingSourceIsSkip: Bool = false,
        targetRootIsGlobalCustomStorage _: Bool = false
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

        let sourceEntries = try loadIndex(from: sourceIndexURL)
        let targetIndexURL = targetRoot.appendingPathComponent("workspacesIndex.json")
        var targetEntries = try loadIndex(from: targetIndexURL)
        var existingIDs = Set(targetEntries.map(\.id))
        var result = ClassicRepoPromptImportResult(
            sourceRoot: sourceRoot,
            targetRoot: targetRoot
        )
        let sourceAndTargetRootsMatch = sourceRoot.standardizedFileURL == targetRoot.standardizedFileURL

        for entry in sourceEntries {
            guard !existingIDs.contains(entry.id) || sourceAndTargetRootsMatch else {
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
                let importedCustomStoragePath = importedCustomStoragePath(
                    targetDirectory: targetDirectory,
                    workspace: workspace
                )
                workspace.customStoragePath = importedCustomStoragePath
                if fileManager.fileExists(atPath: targetDirectory.path) {
                    let repairedEntry = try recoverWorkspaceIndexEntry(
                        fromExistingTargetDirectory: targetDirectory,
                        expectedWorkspaceID: workspace.id,
                        fallbackName: workspace.name,
                        customStoragePath: importedCustomStoragePath
                    )
                    try copyMissingWorkspaceSidecars(from: sourceFileURL.deletingLastPathComponent(), to: targetDirectory)
                    upsertWorkspaceIndexEntry(repairedEntry, into: &targetEntries)
                    existingIDs.insert(repairedEntry.id)
                    result.imported.append(repairedEntry)
                    continue
                }

                try copyWorkspaceDirectory(from: sourceFileURL.deletingLastPathComponent(), to: targetDirectory, workspace: workspace)

                let importedEntry = WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: workspace.customStoragePath,
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
            try writeMergedWorkspaceIndex(
                importedEntries: result.imported,
                fallbackEntries: targetEntries,
                to: targetIndexURL
            )
        }

        return result
    }

    private func writeMergedWorkspaceIndex(
        importedEntries: [WorkspaceIndexEntry],
        fallbackEntries: [WorkspaceIndexEntry],
        to targetIndexURL: URL
    ) throws {
        var latestEntries = (try? loadIndex(from: targetIndexURL)) ?? fallbackEntries
        for importedEntry in importedEntries {
            upsertWorkspaceIndexEntry(importedEntry, into: &latestEntries)
        }
        let data = try encoder.encode(latestEntries)
        try data.write(to: targetIndexURL, options: .atomic)
    }

    private func upsertWorkspaceIndexEntry(_ entry: WorkspaceIndexEntry, into entries: inout [WorkspaceIndexEntry]) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func recoverWorkspaceIndexEntry(
        fromExistingTargetDirectory targetDirectory: URL,
        expectedWorkspaceID: UUID,
        fallbackName: String,
        customStoragePath: URL?
    ) throws -> WorkspaceIndexEntry {
        let workspaceURL = targetDirectory.appendingPathComponent("workspace.json")
        guard fileManager.fileExists(atPath: workspaceURL.path) else {
            throw ImportRecoveryError.existingTargetMissingWorkspace(targetDirectory.path)
        }
        var workspace = try loadWorkspace(from: workspaceURL)
        guard workspace.id == expectedWorkspaceID else {
            throw ImportRecoveryError.existingTargetWorkspaceMismatch(
                expected: expectedWorkspaceID,
                actual: workspace.id
            )
        }
        var recoveredWorkspace = normalizedImportedWorkspace(workspace)
        recoveredWorkspace.customStoragePath = customStoragePath
        if recoveredWorkspace != workspace {
            workspace = recoveredWorkspace
            try encoder.encode(workspace).write(to: workspaceURL, options: .atomic)
        }
        return WorkspaceIndexEntry(
            id: workspace.id,
            name: fallbackName,
            customStoragePath: customStoragePath,
            isSystemWorkspace: false,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
    }

    private enum ImportRecoveryError: LocalizedError {
        case existingTargetMissingWorkspace(String)
        case existingTargetWorkspaceMismatch(expected: UUID, actual: UUID)

        var errorDescription: String? {
            switch self {
            case let .existingTargetMissingWorkspace(path):
                "Target folder already exists without workspace.json: \(path)"
            case let .existingTargetWorkspaceMismatch(expected, actual):
                "Target folder contains workspace \(actual.uuidString), expected \(expected.uuidString)."
            }
        }
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
            return .failed(message: "Settings import failed: \(error.localizedDescription)")
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

            // Metadata is only valid for presets that survived ID/name de-dupe into CE.
            let copyPresetIDs = Set(targetDocument.copyUserPresets.map(\.id))
            let chatPresetIDs = Set(targetDocument.chatUserPresets.map(\.id))
            importedCount += appendMissingCopyOverrides(sourceDocument.copyOverrides, to: &targetDocument.copyOverrides, allowedPresetIDs: copyPresetIDs)
            importedCount += appendMissingChatOverrides(sourceDocument.chatOverrides, to: &targetDocument.chatOverrides, allowedPresetIDs: chatPresetIDs)
            importedCount += mergeMissingVisibility(sourceDocument.copyVisibilityByPresetID, into: &targetDocument.copyVisibilityByPresetID, allowedPresetIDs: copyPresetIDs)
            importedCount += mergeMissingVisibility(sourceDocument.chatVisibilityByPresetID, into: &targetDocument.chatVisibilityByPresetID, allowedPresetIDs: chatPresetIDs)

            guard importedCount > 0 else {
                return .init(skippedCount: 1, messages: ["Classic workflow presets were already present."])
            }

            try targetStore.saveWorkflowPresetsThrowing(targetDocument)
            return .init(importedCount: importedCount)
        } catch {
            return .failed(message: "Workflow preset import failed: \(error.localizedDescription)")
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

            try targetStore.saveModelPresetsThrowing(targetDocument)
            return .init(importedCount: importedCount)
        } catch {
            return .failed(message: "Model preset import failed: \(error.localizedDescription)")
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
            return .failed(message: "Saved prompt import failed: \(error.localizedDescription)")
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
            return .failed(message: "Context builder prompt import failed: \(error.localizedDescription)")
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
            return .failed(message: "Workflow import failed: \(error.localizedDescription)")
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
            guard let rawSourceValue = sourcePreferences.object(forKey: key) else {
                result.skipItems()
                continue
            }
            let sourceValue = normalizedPreferenceValue(key: key, value: rawSourceValue)
            if let rawTargetValue = targetPreferences.object(forKey: key) {
                let targetValue = normalizedPreferenceValue(key: key, value: rawTargetValue)
                if let mergedValue = mergedCompositePreferenceValue(
                    key: key,
                    sourceValue: sourceValue,
                    targetValue: targetValue
                ) {
                    targetPreferences.setObject(mergedValue, forKey: key)
                    result.importItems(1)
                    continue
                }
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

    private func normalizedPreferenceValue(key: String, value: Any) -> Any {
        switch key {
        case "openrouter_configuration":
            normalizedOpenRouterConfigurationData(from: value) ?? value
        case "CustomProviderConfig":
            normalizedCustomProviderConfigurationData(from: value) ?? value
        case "ClaudeCodeCompatibleBackendConfigs":
            normalizedCompatibleBackendConfigsData(from: value) ?? value
        default:
            value
        }
    }

    private func normalizedOpenRouterConfigurationData(from value: Any) -> Data? {
        guard let data = value as? Data else { return nil }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        if let config = try? decoder.decode(OpenRouterConfiguration.self, from: data) {
            return try? encoder.encode(config)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let baseConfig = object["baseConfig"] as? [String: Any]
        let temperature = (object["temperature"] as? NSNumber)?.doubleValue
            ?? (baseConfig?["temperature"] as? NSNumber)?.doubleValue
        let maxTokens = (object["maxTokens"] as? NSNumber)?.intValue
            ?? (baseConfig?["maxTokens"] as? NSNumber)?.intValue
        let customHeaders = object["customHeaders"] as? [String: String]
            ?? object["headers"] as? [String: String]
            ?? [:]
        let useCustomSettings = (object["useCustomSettings"] as? Bool) ?? true
        return try? encoder.encode(
            OpenRouterConfiguration(
                temperature: temperature,
                maxTokens: maxTokens,
                customHeaders: customHeaders,
                useCustomSettings: useCustomSettings
            )
        )
    }

    private func normalizedCustomProviderConfigurationData(from value: Any) -> Data? {
        guard let data = value as? Data else { return nil }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        if let config = try? decoder.decode(CustomProviderConfiguration.self, from: data) {
            return try? encoder.encode(config)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              let defaultModel = object["defaultModel"] as? String
        else {
            return nil
        }
        let headers = object["headers"] as? [String: String] ?? [:]
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledModels = Set((object["enabledModels"] as? [String]) ?? [defaultModel])
        let maxTokens = (object["maxTokens"] as? NSNumber)?.intValue
        let userPreferredModel = object["userPreferredModel"] as? String
        let includeContentTypeHeader = (object["includeContentTypeHeader"] as? Bool) ?? false
        let apiVersion = object["apiVersion"] as? String
        guard let config = try? CustomProviderConfiguration(
            url: url,
            defaultModel: defaultModel,
            headers: headers,
            name: name?.isEmpty == false ? name! : "Classic Custom Provider",
            enabledModels: enabledModels,
            maxTokens: maxTokens,
            userPreferredModel: userPreferredModel,
            includeContentTypeHeader: includeContentTypeHeader,
            apiVersion: apiVersion
        ) else {
            return nil
        }
        return try? encoder.encode(config)
    }

    private func normalizedCompatibleBackendConfigsData(from value: Any) -> Data? {
        guard let data = value as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        if let configs = try? decoder.decode([String: ClaudeCodeCompatibleBackendConfig].self, from: data) {
            return try? encoder.encode(configs.mapValues(\.normalized))
        }

        var normalizedConfigs: [String: ClaudeCodeCompatibleBackendConfig] = [:]
        for (rawID, rawConfig) in object {
            guard let id = ClaudeCodeCompatibleBackendID(rawValue: rawID),
                  let configObject = rawConfig as? [String: Any]
            else {
                continue
            }

            if JSONSerialization.isValidJSONObject(configObject),
               let configData = try? JSONSerialization.data(withJSONObject: configObject),
               let decodedConfig = try? decoder.decode(ClaudeCodeCompatibleBackendConfig.self, from: configData)
            {
                normalizedConfigs[rawID] = decodedConfig.normalized
                continue
            }

            var config = id.defaultPreset
            if let isEnabled = configObject["isEnabled"] as? Bool {
                config.isEnabled = isEnabled
            }
            if let displayName = configObject["displayName"] as? String {
                config.displayName = displayName
            }
            if let baseURL = configObject["baseURL"] as? String {
                config.baseURL = baseURL
            }
            normalizedConfigs[rawID] = config.normalized
        }

        guard !normalizedConfigs.isEmpty else { return nil }
        return try? encoder.encode(normalizedConfigs)
    }

    private func mergedCompositePreferenceValue(
        key: String,
        sourceValue: Any,
        targetValue: Any
    ) -> Any? {
        // Preserve existing CE composite entries while filling gaps from Classic.
        if key == "openrouter_configuration",
           let openRouterValue = importedOpenRouterPreferenceValue(sourceValue: sourceValue, targetValue: targetValue)
        {
            return openRouterValue
        }

        if let mergedData = mergedJSONDictionaryPreferenceValue(sourceValue: sourceValue, targetValue: targetValue) {
            return mergedData
        }

        if let mergedStringArray = mergedMissingStrings(
            sourceValue: sourceValue,
            targetValue: targetValue,
            preferSourceOrder: key == "AgentWorkflowStore.featuredWorkflowIDs"
        ) {
            return mergedStringArray
        }

        if let mergedDictionary = mergedMissingDictionaryValues(sourceValue: sourceValue, targetValue: targetValue) {
            return mergedDictionary
        }

        return nil
    }

    private func importedOpenRouterPreferenceValue(sourceValue: Any, targetValue: Any) -> Data? {
        guard let sourceData = sourceValue as? Data,
              let targetData = targetValue as? Data,
              sourceData != targetData,
              let targetObject = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any],
              isGeneratedDefaultOpenRouterConfiguration(targetObject)
        else {
            return nil
        }
        return sourceData
    }

    private func isGeneratedDefaultOpenRouterConfiguration(_ object: [String: Any]) -> Bool {
        let allowedKeys: Set = ["baseConfig", "customHeaders", "useCustomSettings"]
        guard Set(object.keys).isSubset(of: allowedKeys) else { return false }
        guard (object["useCustomSettings"] as? Bool) ?? true else { return false }

        if let baseConfig = object["baseConfig"] as? [String: Any],
           baseConfig.contains(where: { !($0.value is NSNull) })
        {
            return false
        }
        if let customHeaders = object["customHeaders"] as? [String: Any],
           !customHeaders.isEmpty
        {
            return false
        }
        return true
    }

    private func mergedJSONDictionaryPreferenceValue(sourceValue: Any, targetValue: Any) -> Data? {
        guard let sourceData = sourceValue as? Data,
              let sourceObject = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              !sourceObject.isEmpty
        else {
            return nil
        }

        let targetObject: [String: Any]
        if let targetData = targetValue as? Data,
           let decodedTarget = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        {
            targetObject = decodedTarget
        } else {
            return nil
        }

        guard let mergedObject = mergeMissingJSONFields(target: targetObject, source: sourceObject) as? [String: Any] else {
            return nil
        }

        guard !NSDictionary(dictionary: mergedObject).isEqual(to: targetObject),
              JSONSerialization.isValidJSONObject(mergedObject)
        else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: mergedObject, options: [.sortedKeys])
    }

    private func mergedMissingStrings(sourceValue: Any, targetValue: Any, preferSourceOrder: Bool = false) -> [String]? {
        guard let sourceArray = stringArray(from: sourceValue),
              let targetArray = stringArray(from: targetValue),
              !sourceArray.isEmpty
        else {
            return nil
        }

        let orderedValues = preferSourceOrder ? sourceArray + targetArray : targetArray + sourceArray
        var existing: Set<String> = []
        var merged: [String] = []
        for value in orderedValues where existing.insert(value).inserted {
            merged.append(value)
        }
        return merged == targetArray ? nil : merged
    }

    private func stringArray(from value: Any) -> [String]? {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }.count == array.count ? array.compactMap { $0 as? String } : nil
        }
        return nil
    }

    private func mergedMissingDictionaryValues(sourceValue: Any, targetValue: Any) -> [String: Any]? {
        guard let sourceDictionary = sourceValue as? [String: Any],
              let targetDictionary = targetValue as? [String: Any],
              !sourceDictionary.isEmpty
        else {
            return nil
        }

        let mergedDictionary = mergeMissingJSONFields(target: targetDictionary, source: sourceDictionary)
        guard let typedMergedDictionary = mergedDictionary as? [String: Any],
              !NSDictionary(dictionary: typedMergedDictionary).isEqual(to: targetDictionary)
        else {
            return nil
        }
        return typedMergedDictionary
    }

    private func preferencesContainImportableValues(_ preferences: ClassicRepoPromptPreferences?) -> Bool {
        guard let preferences else { return false }
        return Self.preferenceKeysToImport.contains { preferences.object(forKey: $0) != nil }
    }

    private func importSecureAccounts(
        sourceSecureValueReader: ClassicRepoPromptSecureValueReading?,
        targetSecureStore: ClassicRepoPromptSecureValueWriting?
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
                if let existingValue = try targetSecureStore.getPlainValue(for: account, accessMode: accessMode) {
                    if existingValue == sourceValue {
                        result.skipItems()
                    } else {
                        result.skipItems(message: "\(account.displayName) already has a different RepoPrompt CE value.")
                    }
                    continue
                }
            } catch {
                result.failItems(message: "\(account.displayName): \(error.localizedDescription)")
                continue
            }

            do {
                try targetSecureStore.savePlainValue(sourceValue, for: account, accessMode: accessMode)
                let verifiedValue = try targetSecureStore.getPlainValue(for: account, accessMode: accessMode)
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

    private func loadIndex(from url: URL) throws -> [WorkspaceIndexEntry] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        // Classic indexes can predate CE-only fields; normalize them at the import boundary.
        return try decoder.decode([ClassicWorkspaceIndexEntry].self, from: Data(contentsOf: url))
            .map(\.workspaceIndexEntry)
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

    private func copyMissingWorkspaceSidecars(from sourceDirectory: URL, to targetDirectory: URL) throws {
        // Recovery keeps the verified CE workspace.json, then fills in missing Classic sidecars.
        try removeIfPresent(targetDirectory.appendingPathComponent("AgentSessions/AgentSessionIndex.json"))
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        let sourceRootPath = sourceDirectory.standardizedFileURL.path
        for case let sourceURL as URL in enumerator {
            let sourcePath = sourceURL.standardizedFileURL.path
            guard sourcePath.hasPrefix(sourceRootPath + "/") else { continue }
            let relativePath = String(sourcePath.dropFirst(sourceRootPath.count + 1))
            guard relativePath != "workspace.json",
                  relativePath != "AgentSessions/AgentSessionIndex.json"
            else {
                continue
            }

            let targetURL = targetDirectory.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: targetURL.path) {
                continue
            }

            let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: targetURL)
            }
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

    private func importedCustomStoragePath(
        targetDirectory: URL,
        workspace: WorkspaceModel
    ) -> URL? {
        // Some legacy names cannot be reloaded through WorkspaceIndexEntry's raw
        // `Workspace-\(name)-\(id)` lookup, so pin those imports to their copied folder.
        let rawIndexDirectoryName = "Workspace-\(workspace.name)-\(workspace.id.uuidString)"
        return directoryName(for: workspace) == rawIndexDirectoryName ? nil : targetDirectory
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

    private func appendMissingCopyOverrides(
        _ source: [CopyPresetOverrides],
        to target: inout [CopyPresetOverrides],
        allowedPresetIDs: Set<UUID>
    ) -> Int {
        var existingIDs = Set(target.map(\.presetID))
        var importedCount = 0

        for item in source where allowedPresetIDs.contains(item.presetID) && !existingIDs.contains(item.presetID) {
            target.append(item)
            existingIDs.insert(item.presetID)
            importedCount += 1
        }
        return importedCount
    }

    private func appendMissingChatOverrides(
        _ source: [ChatPresetOverrides],
        to target: inout [ChatPresetOverrides],
        allowedPresetIDs: Set<UUID>
    ) -> Int {
        var existingIDs = Set(target.map(\.presetID))
        var importedCount = 0

        for item in source where allowedPresetIDs.contains(item.presetID) && !existingIDs.contains(item.presetID) {
            target.append(item)
            existingIDs.insert(item.presetID)
            importedCount += 1
        }
        return importedCount
    }

    private func mergeMissingVisibility(
        _ source: [String: Bool],
        into target: inout [String: Bool],
        allowedPresetIDs: Set<UUID>
    ) -> Int {
        var importedCount = 0
        for (key, value) in source where target[key] == nil && allowedPresetIDs.containsVisibilityKey(key) {
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
        let targetRootIsGlobalCustomStorage = globalCustomStorageURL != nil
        do {
            let result = try await ClassicRepoPromptImportService()
                .importFromDefaultClassicInstallation(
                    targetWorkspacesRoot: targetRoot,
                    targetWorkspacesRootIsGlobalCustomStorage: targetRootIsGlobalCustomStorage
                )
            if result.importedCount > 0 {
                reloadWorkspacesFromDisk()
                notifyWorkspaceListDidChange()
            }
            if result.savedPrompts.didImport {
                promptViewModel.loadStoredPrompts()
            }
            if result.contextBuilderPrompts.didImport {
                ContextBuilderPromptStorage.shared.loadPrompts()
            }
            applyClassicRepoPromptImportSideEffects(result)
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

@MainActor
func applyClassicRepoPromptImportSideEffects(_ result: ClassicRepoPromptImportResult) {
    if result.settings.didImport {
        _ = GlobalSettingsStore.shared.reloadFromDisk()
    }
    if result.preferences.didImport {
        AgentWorkflowStore.shared.reloadPreferencesFromDefaults(acceptImportedFeaturedIDs: true)
    }
    if result.workflows.didImport || result.preferences.didImport {
        AgentWorkflowStore.shared.refresh()
    }
    if result.workflowPresets.didImport {
        CopyPresetManager.shared.load()
        ChatPresetManager.shared.load()
    }
    if result.modelPresets.didImport {
        ModelPresetsManager.shared.reloadFromDisk()
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
