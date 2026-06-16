//
//  WindowContentView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-24.
//

import SwiftUI

/// This view holds exactly one @StateObject WindowState, meaning
/// each new Window/Scene gets its own WindowState.
struct WindowContentView: View {
    @EnvironmentObject var versionManager: VersionManager
    @EnvironmentObject var windowStatesManager: WindowStatesManager
    @EnvironmentObject var sparkleManager: SparkleUpdaterManager
    @Environment(\.openWindow) private var openWindow

    /// The WindowState itself (your big manager of fileManager, promptManager, etc.)
    @StateObject private var windowState = WindowState()

    var body: some View {
        ContentView(windowState: windowState)
            .environmentObject(windowState) // If your subviews need it
            .environmentObject(sparkleManager)
            .environmentObject(versionManager) // Pass versionManager to ContentView
            // Let SwiftUI own the window title. Without this, the scene re-applies the
            // default app-name title over the workspace name whenever it refreshes the
            // window chrome (visible in both window titles and native tab names).
            .navigationTitle(windowState.displayedWindowTitle)
            .background(
                WindowAccessor { newWindow in
                    // IMPORTANT: do not mutate SwiftUI @State here.
                    // Attach is internally guarded and safe even if called multiple times.
                    windowState.attachWindow(newWindow)
                }
            )
            // Once the view appears, register it with WindowStatesManager
            .onAppear {
                windowStatesManager.registerWindowState(windowState)

                // Install the openWindow action into AppWindowOpener for programmatic window creation
                AppWindowOpener.shared.install {
                    openWindow(id: "main")
                }
            }
            // Cleanup if the window goes away
            .onDisappear {
                SettingsWindowCoordinator.shared.closeIfTargeting(windowState)

                // Stop focus/title side-effects early to avoid SwiftUI observation crashes during teardown.
                windowState.beginClose()

                // Save the current workspace state before closing, but avoid extra teardown work
                // or publish-heavy persistence once app termination has begun.
                if !windowStatesManager.isTerminating {
                    windowState.workspaceManager.pollAndSaveState()
                }

                guard !windowStatesManager.isTerminating else {
                    windowState.aiQueriesService.cancelQuery()
                    return
                }

                windowStatesManager.unregisterWindowState(windowState)
                Task { await windowState.tearDown() }
            }
            // Example sheets or popups
            .sheet(isPresented: $versionManager.shouldShowWelcomeView) {
                WelcomeView(isPresented: $versionManager.shouldShowWelcomeView, versionManager: versionManager)
            }
            .sheet(isPresented: $versionManager.shouldShowVersionPopup) {
                VersionPopupView(isPresented: $versionManager.shouldShowVersionPopup)
            }
    }
}
