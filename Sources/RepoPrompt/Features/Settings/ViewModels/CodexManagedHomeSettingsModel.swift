import AppKit
import Foundation

struct CodexManagedHomeSettingsSnapshot: Equatable {
    let statePaths: CodexRuntimeAuthority.StatePaths
    let projection: CodexManagedInstructionsProjection.Diagnostic

    var managedHome: URL {
        statePaths.codexHome
    }

    static func load(
        applicationSupportURL: URL? = nil,
        buildChannel: CodexRuntimeAuthority.BuildChannel = .current,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default
    ) -> CodexManagedHomeSettingsSnapshot {
        let statePaths = CodexRuntimeAuthority.statePaths(
            applicationSupportURL: applicationSupportURL,
            buildChannel: buildChannel
        )
        return CodexManagedHomeSettingsSnapshot(
            statePaths: statePaths,
            projection: CodexManagedInstructionsProjection.diagnostic(
                managedHome: statePaths.codexHome,
                ordinaryHome: ordinaryHome,
                fileManager: fileManager
            )
        )
    }
}

struct CodexManagedHomeSettingsActions {
    private let prepareState: (CodexRuntimeAuthority.StatePaths) throws -> Void
    private let copyText: (String) -> Bool
    private let openDirectory: (URL) -> Bool

    init(
        prepareState: @escaping (CodexRuntimeAuthority.StatePaths) throws -> Void,
        copyText: @escaping (String) -> Bool,
        openDirectory: @escaping (URL) -> Bool
    ) {
        self.prepareState = prepareState
        self.copyText = copyText
        self.openDirectory = openDirectory
    }

    func copyFullPath(_ statePaths: CodexRuntimeAuthority.StatePaths) -> Bool {
        copyText(statePaths.codexHome.path)
    }

    func openInFinder(_ statePaths: CodexRuntimeAuthority.StatePaths) throws -> Bool {
        try prepareState(statePaths)
        return openDirectory(statePaths.codexHome)
    }

    static var live: CodexManagedHomeSettingsActions {
        CodexManagedHomeSettingsActions(
            prepareState: { try CodexRuntimeAuthority.prepareManagedState($0) },
            copyText: { value in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(value, forType: .string)
            },
            openDirectory: { NSWorkspace.shared.open($0) }
        )
    }
}
