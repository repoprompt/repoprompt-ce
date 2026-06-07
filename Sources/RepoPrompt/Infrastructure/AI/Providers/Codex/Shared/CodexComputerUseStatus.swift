import Foundation

enum CodexComputerUseConstants {
    static let mcpServerName = "computer-use"
}

enum CodexComputerUsePluginConfigurationStatus: Equatable {
    case configured(serverName: String)
    case appManagedPluginInstalled(path: String, version: String?)
    case incomplete(path: String, message: String)
    case missingConfigFile(path: String)
    case serverEntryMissing(path: String)
    case unreadable(path: String, message: String)

    var isConfigured: Bool {
        switch self {
        case .configured, .appManagedPluginInstalled:
            true
        case .incomplete, .missingConfigFile, .serverEntryMissing, .unreadable:
            false
        }
    }

    var isAppManagedInstall: Bool {
        if case .appManagedPluginInstalled = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .configured:
            "Configured"
        case .appManagedPluginInstalled:
            "Installed"
        case .incomplete:
            "Incomplete"
        case .missingConfigFile:
            "Config missing"
        case .serverEntryMissing:
            "Not configured"
        case .unreadable:
            "Config unreadable"
        }
    }

    var detail: String {
        switch self {
        case let .configured(serverName):
            "Codex configuration includes \(serverName)."
        case let .appManagedPluginInstalled(path, version):
            "Codex Computer Use is installed by the Codex app at \(path)\(version.map { " (version \($0))" } ?? "")."
        case let .incomplete(path, message):
            "Codex Computer Use setup at \(path) is incomplete: \(message)"
        case let .missingConfigFile(path):
            "RepoPrompt could not find Codex config at \(path). Install or enable Computer Use in Codex, then refresh."
        case let .serverEntryMissing(path):
            "Codex config at \(path) does not contain a Computer Use plugin or MCP server entry."
        case let .unreadable(path, message):
            "RepoPrompt could not read Codex config at \(path): \(message)"
        }
    }
}

enum CodexComputerUseLiveAvailability: Equatable {
    case available(detail: String?)
    case unavailable(reason: String)
    case unknown(reason: String)
    case unsupported(reason: String)

    var blocksReadiness: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        case .unknown:
            "Unknown"
        case .unsupported:
            "Not verifiable"
        }
    }

    var detail: String {
        switch self {
        case let .available(detail):
            detail ?? "Codex reported Computer Use tools are available."
        case let .unavailable(reason), let .unknown(reason), let .unsupported(reason):
            reason
        }
    }
}

enum CodexComputerUsePermissionStatus: Equatable {
    case granted
    case notGranted
    case unknown(reason: String)

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .granted:
            "Granted"
        case .notGranted:
            "Needs access"
        case .unknown:
            "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .granted:
            "Permission is granted."
        case .notGranted:
            "Permission has not been granted yet."
        case let .unknown(reason):
            reason
        }
    }
}

enum CodexComputerUsePermissionRequestResult: Equatable {
    case granted
    case promptShownRefreshRequired
    case deniedOrUnavailable
    case failed(String)

    var userMessage: String {
        switch self {
        case .granted:
            "Permission is already granted."
        case .promptShownRefreshRequired:
            "Permission prompt opened. Complete it, then refresh status. Screen Recording changes may require restarting RepoPrompt or Codex."
        case .deniedOrUnavailable:
            "Permission was not granted. Open System Settings, grant access, then refresh status."
        case let .failed(message):
            "Permission request failed: \(message)"
        }
    }
}

enum CodexComputerUsePrerequisite: String, CaseIterable, Identifiable, Equatable {
    case featureOptIn
    case plugin
    case liveAvailability
    case screenRecording
    case accessibility

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .featureOptIn: "RepoPrompt Computer Use"
        case .plugin: "Computer Use MCP configuration"
        case .liveAvailability: "Computer Use live availability"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    var shortAction: String {
        switch self {
        case .featureOptIn:
            "enable Computer Use in RepoPrompt"
        case .plugin:
            "configure the Computer Use MCP server in Codex"
        case .liveAvailability:
            "confirm Codex Computer Use tools are available"
        case .screenRecording:
            "verify Codex Computer Use Screen Recording permission"
        case .accessibility:
            "verify Codex Computer Use Accessibility permission"
        }
    }
}

struct CodexComputerUsePrerequisiteSnapshot: Equatable {
    var pluginConfiguration: CodexComputerUsePluginConfigurationStatus
    var liveAvailability: CodexComputerUseLiveAvailability
    var screenRecording: CodexComputerUsePermissionStatus
    var accessibility: CodexComputerUsePermissionStatus

    init(
        pluginConfiguration: CodexComputerUsePluginConfigurationStatus,
        liveAvailability: CodexComputerUseLiveAvailability = .unsupported(reason: CodexComputerUseStatus.defaultLiveAvailabilityUnsupportedReason),
        screenRecording: CodexComputerUsePermissionStatus,
        accessibility: CodexComputerUsePermissionStatus
    ) {
        self.pluginConfiguration = pluginConfiguration
        self.liveAvailability = liveAvailability
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    init(
        pluginInstalled: Bool,
        screenRecordingGranted: Bool,
        accessibilityGranted: Bool,
        liveAvailability: CodexComputerUseLiveAvailability = .unsupported(reason: CodexComputerUseStatus.defaultLiveAvailabilityUnsupportedReason)
    ) {
        self.init(
            pluginConfiguration: pluginInstalled
                ? .configured(serverName: CodexComputerUseConstants.mcpServerName)
                : .serverEntryMissing(path: CodexComputerUseStatus.defaultCodexConfigPath),
            liveAvailability: liveAvailability,
            screenRecording: screenRecordingGranted ? .granted : .notGranted,
            accessibility: accessibilityGranted ? .granted : .notGranted
        )
    }

    var pluginInstalled: Bool {
        pluginConfiguration.isConfigured
    }

    var screenRecordingGranted: Bool {
        screenRecording.isGranted
    }

    var accessibilityGranted: Bool {
        accessibility.isGranted
    }

    static let ready = CodexComputerUsePrerequisiteSnapshot(
        pluginInstalled: true,
        screenRecordingGranted: true,
        accessibilityGranted: true
    )

    static let missingAll = CodexComputerUsePrerequisiteSnapshot(
        pluginInstalled: false,
        screenRecordingGranted: false,
        accessibilityGranted: false
    )
}

struct CodexComputerUseStatus: Equatable {
    static let defaultCodexConfigPath = "~/.codex/config.toml"
    static let defaultLiveAvailabilityUnsupportedReason = "RepoPrompt cannot verify live Codex Computer Use tool availability in this build; static Codex config detection is used."

    let optInEnabled: Bool
    let prerequisites: CodexComputerUsePrerequisiteSnapshot
    let lastRefreshedAt: Date?

    init(
        optInEnabled: Bool,
        prerequisites: CodexComputerUsePrerequisiteSnapshot,
        lastRefreshedAt: Date? = nil
    ) {
        self.optInEnabled = optInEnabled
        self.prerequisites = prerequisites
        self.lastRefreshedAt = lastRefreshedAt
    }

    var pluginConfiguration: CodexComputerUsePluginConfigurationStatus {
        prerequisites.pluginConfiguration
    }

    var liveAvailability: CodexComputerUseLiveAvailability {
        prerequisites.liveAvailability
    }

    var screenRecording: CodexComputerUsePermissionStatus {
        prerequisites.screenRecording
    }

    var accessibility: CodexComputerUsePermissionStatus {
        prerequisites.accessibility
    }

    var usesCodexManagedMacPermissions: Bool {
        pluginConfiguration.isAppManagedInstall
    }

    var screenRecordingSatisfied: Bool {
        usesCodexManagedMacPermissions || screenRecording.isGranted
    }

    var accessibilitySatisfied: Bool {
        usesCodexManagedMacPermissions || accessibility.isGranted
    }

    var isReady: Bool {
        optInEnabled
            && pluginConfiguration.isConfigured
            && !liveAvailability.blocksReadiness
            && screenRecordingSatisfied
            && accessibilitySatisfied
    }

    var missingRequirements: [CodexComputerUsePrerequisite] {
        var values: [CodexComputerUsePrerequisite] = []
        if !optInEnabled { values.append(.featureOptIn) }
        if !pluginConfiguration.isConfigured { values.append(.plugin) }
        if liveAvailability.blocksReadiness { values.append(.liveAvailability) }
        if !screenRecordingSatisfied { values.append(.screenRecording) }
        if !accessibilitySatisfied { values.append(.accessibility) }
        return values
    }

    var primaryUnavailableMessage: String {
        guard !isReady else { return "Codex computer-use is ready." }
        let missing = missingRequirements
        if missing == [.featureOptIn] {
            return "Enable Computer Use in Settings → Agent Mode → Computer Use before starting /computer-use."
        }
        let details = missing.map(\.shortAction).joined(separator: "; ")
        return "Codex computer-use setup is incomplete: \(details). Open Settings → Agent Mode → Computer Use, complete the setup, then refresh status."
    }

    var statusTitle: String {
        if isReady { return "Ready" }
        if !optInEnabled { return "Not enabled" }
        return "Setup incomplete"
    }

    var statusDetail: String {
        if isReady {
            return "RepoPrompt can expose /computer-use for explicit Codex turns. Codex will still ask for app access and sensitive-action approvals."
        }
        return primaryUnavailableMessage
    }
}

struct CodexComputerUseAvailability: Equatable {
    let featureOptIn: Bool
    let prerequisites: CodexComputerUsePrerequisiteSnapshot
    let status: CodexComputerUseStatus

    init(featureOptIn: Bool, prerequisites: CodexComputerUsePrerequisiteSnapshot) {
        self.featureOptIn = featureOptIn
        self.prerequisites = prerequisites
        status = CodexComputerUseStatus(optInEnabled: featureOptIn, prerequisites: prerequisites)
    }

    init(status: CodexComputerUseStatus) {
        featureOptIn = status.optInEnabled
        prerequisites = status.prerequisites
        self.status = status
    }

    var isReady: Bool {
        status.isReady
    }

    var missingPrerequisites: [CodexComputerUsePrerequisite] {
        status.missingRequirements
    }

    var primaryUnavailableMessage: String {
        status.primaryUnavailableMessage
    }

    var statusTitle: String {
        status.statusTitle
    }

    var statusDetail: String {
        status.statusDetail
    }
}
