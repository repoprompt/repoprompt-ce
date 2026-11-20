//
//  AppWindowOpener.swift
//  RepoPrompt
//
//  Created by Claude on 2025-01-15.
//
//  Singleton to store the SwiftUI openWindow action, enabling programmatic
//  window creation from non-SwiftUI contexts like WindowStatesManager.
//

import SwiftUI

/// Enables programmatic opening of new windows from non-SwiftUI contexts.
///
/// WindowStatesManager cannot directly access `@Environment(\.openWindow)`,
/// so this singleton stores the action captured from a SwiftUI view.
///
/// Usage:
/// 1. A SwiftUI view calls `install(openMainWindow:)` to register the action
/// 2. Non-SwiftUI code calls `openMainWindow()` to trigger window creation
@MainActor
final class AppWindowOpener: ObservableObject {
    static let shared = AppWindowOpener()
    let commandCenter = CommandCenterWindowOpener()

    private var openMainWindowImpl: (() -> Void)?
    @Published private(set) var pendingDockWindowRequestCount = 0
    private var queuedURLWindowInFlight = false
    @Published private(set) var pendingURLWindowRequest = false

    private init() {}

    /// Installs the openWindow action from a SwiftUI view.
    /// MainWindowCommands supports zero-window startup; WindowContentView also installs on appearance.
    func install(openMainWindow: @escaping () -> Void) {
        openMainWindowImpl = openMainWindow

        let pendingRequestCount = pendingDockWindowRequestCount
        if pendingRequestCount > 0 { pendingDockWindowRequestCount = 0 }
        if pendingURLWindowRequest {
            pendingURLWindowRequest = false
            openMainWindow()
        }
        for _ in 0 ..< pendingRequestCount {
            openMainWindow()
        }
    }

    /// Requests a new main window from the Dock menu.
    /// Queues the request until SwiftUI has installed the window-opening action.
    func requestMainWindowFromDock() {
        guard let openMainWindowImpl else {
            pendingDockWindowRequestCount += 1
            return
        }
        openMainWindowImpl()
    }

    func requestWindowForQueuedURLs(hasLiveWindows: Bool, hasPendingURLs: Bool) {
        guard !hasLiveWindows, hasPendingURLs, !queuedURLWindowInFlight else { return }
        queuedURLWindowInFlight = true
        if let openMainWindowImpl {
            openMainWindowImpl()
        } else {
            pendingURLWindowRequest = true
        }
    }

    func mainWindowRegistered() {
        queuedURLWindowInFlight = false
        if pendingURLWindowRequest { pendingURLWindowRequest = false }
    }

    /// Opens a new main window.
    /// - Throws: `WindowOpenError.openerUnavailable` if no action has been installed.
    func openMainWindow() throws {
        guard let impl = openMainWindowImpl else {
            throw WindowOpenError.openerUnavailable
        }
        impl()
    }

    /// Checks if the opener is ready to create windows.
    var isAvailable: Bool {
        openMainWindowImpl != nil
    }

    #if DEBUG
        func installForTesting(openMainWindow: @escaping () -> Void) {
            openMainWindowImpl = openMainWindow
        }

        func resetForTesting() {
            openMainWindowImpl = nil
            pendingDockWindowRequestCount = 0
            queuedURLWindowInFlight = false
            pendingURLWindowRequest = false
        }
    #endif
}

/// Errors that can occur when opening windows programmatically.
enum WindowOpenError: Error, LocalizedError {
    case openerUnavailable

    var errorDescription: String? {
        switch self {
        case .openerUnavailable:
            "Window opener not available. No SwiftUI view has installed the openWindow action."
        }
    }
}

struct MainWindowCommands: Commands {
    let title: String
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var opener = AppWindowOpener.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(title) {
                opener.requestMainWindowFromDock()
            }
            .onChange(of: opener.pendingURLWindowRequest, initial: true) { _, _ in
                opener.install { openWindow(id: "main") }
            }
            .onChange(of: opener.pendingDockWindowRequestCount, initial: true) { _, _ in
                opener.install { openWindow(id: "main") }
            }
        }
    }
}
