import AppKit
import Darwin
import Foundation
import Logging
import Sparkle
import SwiftUI

struct RepoPromptFileLogHandler: LogHandler {
    private let stream: FileHandle
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    init(label: String) {
        stream = FileHandle.standardError
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel else { return }
        let text = renderMessage(message, metadata: explicitMetadata)
        if let data = (text + "\n").data(using: .utf8) {
            try? stream.write(contentsOf: data)
        }
    }

    private func renderMessage(_ message: Logger.Message, metadata explicitMetadata: Logger.Metadata?) -> String {
        var parts = [message.description]
        let merged = mergedMetadata(explicitMetadata)
        if !merged.isEmpty {
            parts.append(merged)
        }
        return parts.joined(separator: " ")
    }

    private func mergedMetadata(_ explicit: Logger.Metadata?) -> String {
        let combined = metadata.merging(explicit ?? [:]) { _, new in new }
        guard !combined.isEmpty else { return "" }
        return combined
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
    }
}

@main
struct RepoPromptApp: App {
    init() {
        LoggingSystem.bootstrap { label in
            var handler = RepoPromptFileLogHandler(label: label)
            #if DEBUG
                handler.logLevel = .debug
            #else
                handler.logLevel = .notice
            #endif
            return handler
        }
        // Avoid process-killing SIGPIPE when the child closes stdin while we're still writing.
        signal(SIGPIPE, SIG_IGN)

        ProcessDebugLogging.log(
            prefix: "MCPStartup",
            "RepoPromptApp.init scheduling ServerNetworkManager.start",
            flushStdout: true
        )
        Task.detached {
            ProcessDebugLogging.log(
                prefix: "MCPStartup",
                "RepoPromptApp.init start task running",
                flushStdout: true
            )
            await ServerController.shared.startServer()
        }

        if !AppLaunchConfiguration.current.suppressesWindowRestore {
            WindowStatesManager.shared.loadWindowRestoreSessionIfNeeded()
        }
    }

    /// Make sure we define AppDelegate first, so it's available in init
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Global version manager for the entire app
    @StateObject private var versionManager = VersionManager()

    /// Tracks all WindowState objects across multiple windows (singleton)
    @StateObject private var windowStatesManager = WindowStatesManager.shared

    /// Root font scaling source so inherited SwiftUI text updates when the preset changes.
    @StateObject private var fontScale = FontScaleManager.shared

    // MARK: - Body

    var body: some Scene {
        WindowGroup(id: "main") {
            // IMPORTANT: Each time a new SwiftUI window/scene is created,
            // we instantiate a fresh WindowContentView (and thus a new WindowState)
            WindowContentView()
                .environmentObject(versionManager)
                .environmentObject(appDelegate.sparkleManager)
                .environmentObject(windowStatesManager)
                .environmentObject(fontScale)
                .toolbarRole(.automatic)
                .frame(minWidth: 948, idealWidth: 1080, minHeight: 600)
                // Override environment font
                .environment(\.font, fontScale.preset.font)
                .environment(\.repoPromptFontScalePreset, fontScale.preset)
                // Advertise URL handling on existing windows so SwiftUI does not create
                // an extra scene before the global deep-link router can choose the target.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { incomingURL in
                    Task { @MainActor in
                        await AppDeepLinkRouter.shared.route(url: incomingURL)
                    }
                }
        }
        // .windowStyle(.hiddenTitleBar)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            UpdateMenu(sparkleManager: appDelegate.sparkleManager)

            // macOS standard "Settings…" (⌘,) menu item
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    // Identify the currently focused window (or fall back to latest)
                    if let target = windowStatesManager
                        .allWindows.first(where: { $0.isCurrentlyFocused })
                        ?? windowStatesManager.latestWindowState
                    {
                        SettingsWindowCoordinator.shared.open(windowState: target)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // ➜ New File-menu commands (Save Workspace / Exit Workspace)
            WorkspaceCommands(windowStatesManager: windowStatesManager)

            CommandGroup(before: .saveItem) {
                Button("Close Window") {
                    NSApplication.shared.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                HelpMenu()
                    .environmentObject(versionManager)
            }
        }
    }
}
