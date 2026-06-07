import ApplicationServices
import CoreGraphics
import Foundation

struct CodexComputerUsePermissionClient {
    var screenRecordingStatus: () -> CodexComputerUsePermissionStatus
    var accessibilityStatus: () -> CodexComputerUsePermissionStatus
    var requestScreenRecording: () -> CodexComputerUsePermissionRequestResult
    var requestAccessibility: () -> CodexComputerUsePermissionRequestResult

    static let production = CodexComputerUsePermissionClient(
        screenRecordingStatus: {
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        },
        accessibilityStatus: {
            AXIsProcessTrusted() ? .granted : .notGranted
        },
        requestScreenRecording: {
            CGRequestScreenCaptureAccess() ? .granted : .promptShownRefreshRequired
        },
        requestAccessibility: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .promptShownRefreshRequired
        }
    )
}

struct CodexComputerUseStatusService {
    struct Dependencies {
        var configProbe: () -> CodexComputerUsePluginConfigurationStatus
        var permissionClient: CodexComputerUsePermissionClient
        var liveAvailabilityProbe: () -> CodexComputerUseLiveAvailability
        var now: () -> Date

        static let production = Dependencies(
            configProbe: CodexComputerUseStatusService.productionConfigProbe,
            permissionClient: .production,
            liveAvailabilityProbe: {
                .unsupported(reason: CodexComputerUseStatus.defaultLiveAvailabilityUnsupportedReason)
            },
            now: Date.init
        )
    }

    static var shared = CodexComputerUseStatusService()

    private var dependencies: Dependencies

    init(dependencies: Dependencies = .production) {
        self.dependencies = dependencies
    }

    func currentStatus(optInEnabled: Bool, includeTimestamp: Bool = true) -> CodexComputerUseStatus {
        CodexComputerUseStatus(
            optInEnabled: optInEnabled,
            prerequisites: prerequisiteSnapshot(),
            lastRefreshedAt: includeTimestamp ? dependencies.now() : nil
        )
    }

    func prerequisiteSnapshot() -> CodexComputerUsePrerequisiteSnapshot {
        #if DEBUG
            if let snapshot = Self.testingPrerequisiteSnapshot {
                return snapshot
            }
        #endif

        return CodexComputerUsePrerequisiteSnapshot(
            pluginConfiguration: dependencies.configProbe(),
            liveAvailability: dependencies.liveAvailabilityProbe(),
            screenRecording: dependencies.permissionClient.screenRecordingStatus(),
            accessibility: dependencies.permissionClient.accessibilityStatus()
        )
    }

    func requestScreenRecordingAccess() -> CodexComputerUsePermissionRequestResult {
        dependencies.permissionClient.requestScreenRecording()
    }

    func requestAccessibilityAccess() -> CodexComputerUsePermissionRequestResult {
        dependencies.permissionClient.requestAccessibility()
    }

    static func productionConfigProbe() -> CodexComputerUsePluginConfigurationStatus {
        configProbe(
            configURL: CodexIntegrationConfiguration.configURL(),
            codexDirectoryURL: CodexIntegrationConfiguration.configDirectoryURL()
        )
    }

    static func configProbe(
        configURL: URL,
        codexDirectoryURL: URL
    ) -> CodexComputerUsePluginConfigurationStatus {
        switch CodexComputerUseRuntimeConfiguration.resolve(
            configURL: configURL,
            codexDirectoryURL: codexDirectoryURL
        ) {
        case let .resolved(configuration):
            switch configuration.source {
            case .explicitMCPServer:
                .configured(serverName: configuration.serverName)
            case let .appManagedBundledPlugin(mcpConfigPath, _, version):
                .appManagedPluginInstalled(path: mcpConfigPath, version: version)
            }
        case let .incomplete(incomplete):
            .incomplete(path: incomplete.path, message: incomplete.message)
        case let .missingConfigFile(path):
            .missingConfigFile(path: path)
        case let .serverEntryMissing(path):
            .serverEntryMissing(path: path)
        case let .unreadable(path, message):
            .unreadable(path: path, message: message)
        }
    }
}

#if DEBUG
    extension CodexComputerUseStatusService {
        private static let testingPrerequisiteLock = NSLock()
        private static var testingPrerequisiteSnapshotStorage: CodexComputerUsePrerequisiteSnapshot?

        private static var testingPrerequisiteSnapshot: CodexComputerUsePrerequisiteSnapshot? {
            testingPrerequisiteLock.lock()
            defer { testingPrerequisiteLock.unlock() }
            return testingPrerequisiteSnapshotStorage
        }

        static func setPrerequisiteSnapshotForTesting(_ snapshot: CodexComputerUsePrerequisiteSnapshot?) {
            testingPrerequisiteLock.lock()
            testingPrerequisiteSnapshotStorage = snapshot
            testingPrerequisiteLock.unlock()
        }

        static func test_configDeclaresComputerUsePlugin(_ content: String) -> Bool {
            CodexComputerUseRuntimeConfiguration.configDeclaresAppManagedPlugin(content)
        }

        static func testing(
            configProbe: @escaping () -> CodexComputerUsePluginConfigurationStatus = { .configured(serverName: CodexComputerUseConstants.mcpServerName) },
            permissionClient: CodexComputerUsePermissionClient = .init(
                screenRecordingStatus: { .granted },
                accessibilityStatus: { .granted },
                requestScreenRecording: { .granted },
                requestAccessibility: { .granted }
            ),
            liveAvailabilityProbe: @escaping () -> CodexComputerUseLiveAvailability = { .unsupported(reason: CodexComputerUseStatus.defaultLiveAvailabilityUnsupportedReason) },
            now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) }
        ) -> CodexComputerUseStatusService {
            CodexComputerUseStatusService(
                dependencies: .init(
                    configProbe: configProbe,
                    permissionClient: permissionClient,
                    liveAvailabilityProbe: liveAvailabilityProbe,
                    now: now
                )
            )
        }
    }
#endif
