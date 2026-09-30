import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published var selectedTab: SettingsTab

    init(selectedTab: SettingsTab = .appearance) {
        self.selectedTab = selectedTab
    }
}

/// Owns the dedicated Settings `NSWindow`, keeps its title in sync with the
/// active tab, and persists its size/position between launches.
///
/// The window is modeless, resizable, and close-only (no minimize, no zoom
/// button via `.miniaturizable`). Close semantics follow standard macOS: the
/// title-bar close button and Cmd-W dismiss the window; Escape is intentionally
/// not wired to close, so focused controls can keep using Escape as a standard
/// cancel key.
///
/// SEARCH-HELPER: Settings window, Settings NSWindow, Settings window title,
/// Settings window autosave, modeless settings, dedicated settings window.
@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCoordinator()

    /// Key used to persist the window frame between launches via
    /// `setFrameAutosaveName(_:)`.
    private static let frameAutosaveName = "RepoPrompt.SettingsWindow"

    /// Default content size used for first-open (or when no saved frame
    /// exists). Tuned so the sidebar plus a ~560pt readable detail column fit
    /// without horizontal cramping, matching the window polish in
    /// `docs/research/macos-settings-window-ux-best-practices-2026-04-18.md`.
    private static let defaultContentSize = NSSize(width: 960, height: 700)
    private static func defaultContentSize(for preset: FontScalePreset) -> NSSize {
        NSSize(
            width: preset.scaledClamped(defaultContentSize.width, max: 1180),
            height: preset.scaledClamped(defaultContentSize.height, max: 820)
        )
    }

    /// Minimum content size. Large enough that the sidebar search, section
    /// expansion, and Agent Permissions content (including the segmented
    /// scope picker) remain usable without content clipping.
    private static let minContentSize = NSSize(width: 860, height: 620)
    private static func minContentSize(for preset: FontScalePreset) -> NSSize {
        NSSize(
            width: preset.scaledClamped(minContentSize.width, max: 1040),
            height: preset.scaledClamped(minContentSize.height, max: 760)
        )
    }

    private var windowController: NSWindowController?
    private var hostingController: NSHostingController<SettingsWindowRootView>?
    private var model: SettingsWindowModel?
    private weak var targetedWindowState: WindowState?
    private var cancellables: Set<AnyCancellable> = []

    override private init() {}

    func open(windowState: WindowState, selectedTab: SettingsTab? = nil) {
        let model = ensureModel(selectedTab: selectedTab)
        targetedWindowState = windowState

        let rootView = SettingsWindowRootView(
            model: model,
            windowState: windowState
        )

        if let hostingController, let windowController {
            hostingController.rootView = rootView
            // Directly refresh the title — the `$selectedTab` sink will also
            // fire when the tab actually changes, but an explicit retarget
            // might reuse the same tab and we still want the window chrome to
            // match the freshly targeted state.
            if let window = windowController.window {
                updateTitle(for: window, using: model.selectedTab)
            }
            show(windowController: windowController)
            return
        }

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.animationBehavior = .documentWindow
        window.delegate = self

        // Apply a sensible default size before attempting to restore a saved
        // frame; `setFrameAutosaveName(_:)` overwrites this when a frame has
        // been persisted for the autosave key.
        let fontPreset = FontScaleManager.shared.preset
        window.setContentSize(Self.defaultContentSize(for: fontPreset))
        window.contentMinSize = Self.minContentSize(for: fontPreset)
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)

        updateTitle(for: window, using: model.selectedTab)

        let windowController = NSWindowController(window: window)
        self.hostingController = hostingController
        self.windowController = windowController

        // Keep the window title in sync with the active tab, mirroring the
        // macOS Settings / System Settings convention where the chrome
        // reflects the current pane.
        model.$selectedTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] tab in
                guard let self, let window else { return }
                updateTitle(for: window, using: tab)
            }
            .store(in: &cancellables)

        FontScaleManager.shared.$preset
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak window] preset in
                guard let window else { return }
                window.contentMinSize = Self.minContentSize(for: preset)
            }
            .store(in: &cancellables)

        show(windowController: windowController)
    }

    func retarget(windowState: WindowState, selectedTab: SettingsTab) {
        open(windowState: windowState, selectedTab: selectedTab)
    }

    func closeIfTargeting(_ windowState: WindowState) {
        guard targetedWindowState === windowState else { return }
        close()
    }

    func close() {
        windowController?.close()
        clearWindowReferences()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === windowController?.window else { return }
        clearWindowReferences()
    }

    private func ensureModel(selectedTab: SettingsTab?) -> SettingsWindowModel {
        if let model {
            if let selectedTab {
                model.selectedTab = selectedTab
            }
            return model
        }

        let model = SettingsWindowModel(selectedTab: selectedTab ?? .appearance)
        self.model = model
        return model
    }

    private func show(windowController: NSWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func updateTitle(for window: NSWindow, using tab: SettingsTab) {
        window.title = Self.windowTitle(for: tab)
    }

    /// Format the window title from the selected pane's breadcrumbs, falling
    /// back to plain "Settings" if a pane has no nonempty title components.
    static func windowTitle(for tab: SettingsTab) -> String {
        let breadcrumbs = tab.windowTitleBreadcrumbs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (["Settings"] + breadcrumbs).joined(separator: " — ")
    }

    private func clearWindowReferences() {
        windowController?.window?.delegate = nil
        windowController = nil
        hostingController = nil
        model = nil
        targetedWindowState = nil
        cancellables.removeAll()
    }
}
