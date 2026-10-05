import Foundation

/// Persisted chat mode, independent of the prompt presentation view model.
package enum SettingsPlanActMode: String, CaseIterable, Codable {
    case chat = "Chat"
    case plan = "Plan"
    case edit = "Edit"
    case review = "Review"
}

/// Stable settings identity only; provider discovery and execution remain app policy.
package enum SettingsAgentKind: String, CaseIterable, Hashable {
    case claudeCode
    case codexExec
    case openCode
    case cursor
    case grokBuild
    case antigravity
    case devin
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible

    package var acpProviderID: ACPProviderID? {
        switch self {
        case .openCode: .openCode
        case .cursor: .cursor
        case .grokBuild: .grokBuild
        case .antigravity: .antigravity
        case .devin: .devin
        case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: nil
        }
    }
}

/// Emitted synchronously after the same state/write boundaries as the app adapters.
/// No app notification names or UI objects cross the core boundary.
package enum GlobalSettingsEvent: Equatable {
    case notificationPreferencesChanged
    case agentModelsSettingsChanged(scope: AgentModelsEditingScope)
    case settingsInstalled
    case worktreeLocationLabelsChanged
}

/// Immutable ignore policy input; filesystem compilation and matching are separate owners.
package struct GlobalIgnoreSettingsSnapshot: Equatable {
    package let respectRepoIgnore: Bool
    package let respectCursorignore: Bool
    package let globalIgnoreDefaults: String
    package let enableHierarchicalIgnores: Bool

    package init(
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        globalIgnoreDefaults: String,
        enableHierarchicalIgnores: Bool
    ) {
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.globalIgnoreDefaults = globalIgnoreDefaults
        self.enableHierarchicalIgnores = enableHierarchicalIgnores
    }
}

@MainActor
package protocol GlobalIgnoreSettingsProviding {
    func globalIgnoreSettingsSnapshot() -> GlobalIgnoreSettingsSnapshot
}

extension GlobalSettingsStore: GlobalIgnoreSettingsProviding {
    package func globalIgnoreSettingsSnapshot() -> GlobalIgnoreSettingsSnapshot {
        GlobalIgnoreSettingsSnapshot(
            respectRepoIgnore: respectRepoIgnore(),
            respectCursorignore: respectCursorignore(),
            globalIgnoreDefaults: globalIgnoreDefaults(),
            enableHierarchicalIgnores: enableHierarchicalIgnores()
        )
    }
}

/// Retains the existing DEBUG XCTest isolation without depending on app launch wiring.
enum SettingsProcessEnvironment {
    static var isUnitTestProcess: Bool {
        #if DEBUG
            Bundle.main.bundleURL.pathExtension == "xctest"
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        #else
            false
        #endif
    }
}
