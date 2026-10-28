#if DEBUG
    import AppKit
    import SwiftUI

    /// Owns the standalone Prompt Experiments Studio `NSWindow` (Window ▸ Prompt Experiments…).
    ///
    /// The in-session tool card only exists inside an Agent Mode transcript, so experiments
    /// created by an external MCP/CLI client (`prompt_experiment create_or_update` +
    /// `request_approval`) need an app-level surface where the user can review and approve
    /// them. The window is modeless, reused across opens, and persists its frame.
    @MainActor
    final class PromptExperimentStudioWindowCoordinator: NSObject, NSWindowDelegate {
        private static let frameAutosaveName = "RepoPrompt.PromptExperimentStudioWindow"
        private static let defaultContentSize = NSSize(width: 1080, height: 760)
        private static let minContentSize = NSSize(width: 920, height: 650)

        private let service: PromptExperimentService
        private var windowController: NSWindowController?
        private var hostingController: NSHostingController<PromptExperimentStudioWindowRootView>?

        init(service: PromptExperimentService) {
            self.service = service
            super.init()
        }

        /// Opens (or brings forward) the Studio window, optionally selecting one experiment.
        func open(selecting experimentID: UUID? = nil) {
            let rootView = PromptExperimentStudioWindowRootView(initialSelection: experimentID, service: service)

            if let hostingController, let windowController {
                if experimentID != nil {
                    hostingController.rootView = rootView
                }
                show(windowController: windowController)
                return
            }

            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Prompt Experiments"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.animationBehavior = .documentWindow
            window.delegate = self
            window.setContentSize(Self.defaultContentSize)
            window.contentMinSize = Self.minContentSize
            window.center()
            window.setFrameAutosaveName(Self.frameAutosaveName)

            let windowController = NSWindowController(window: window)
            self.hostingController = hostingController
            self.windowController = windowController
            show(windowController: windowController)
        }

        func windowWillClose(_ notification: Notification) {
            guard (notification.object as? NSWindow) === windowController?.window else { return }
            windowController?.window?.delegate = nil
            windowController = nil
            hostingController = nil
        }

        private func show(windowController: NSWindowController) {
            NSApp.activate(ignoringOtherApps: true)
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Hosts the Studio with the shared service and the app's font-scale environment.
    struct PromptExperimentStudioWindowRootView: View {
        var initialSelection: UUID?
        @ObservedObject var service: PromptExperimentService
        @ObservedObject private var fontScale = FontScaleManager.shared

        var body: some View {
            PromptExperimentStudioView(service: service, initialSelection: initialSelection, showsCloseButton: false)
                .environment(\.font, fontScale.preset.font)
                .environment(\.repoPromptFontScalePreset, fontScale.preset)
        }
    }
#endif
