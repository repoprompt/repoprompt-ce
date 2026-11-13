import AppKit
import RepoPromptFileSystem
import UniformTypeIdentifiers

@MainActor
final class OpenPanelService {
    static let shared = OpenPanelService()
    private var isPresenting = false

    /// Picks a single folder. Uses sheet presentation when possible to avoid blocking the main run loop.
    func pickFolder(
        title: String = "Choose a Folder",
        message: String? = nil,
        startingDirectory: URL? = nil
    ) async -> URL? {
        guard !isPresenting else { return nil }
        isPresenting = true
        defer { isPresenting = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = title
        if let message { panel.message = message }
        if let startingDirectory { panel.directoryURL = startingDirectory }

        let response = await present(panel, attachedTo: nil)
        return response == .OK ? panel.url : nil
    }

    func pickFiles(
        title: String = "Choose Files",
        message: String? = nil,
        startingDirectory: URL? = nil,
        allowsMultipleSelection: Bool = true,
        attachedTo window: NSWindow? = nil
    ) async -> [URL] {
        guard !isPresenting else { return [] }
        isPresenting = true
        defer { isPresenting = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.prompt = "Attach"
        panel.title = title
        if let message { panel.message = message }
        if let startingDirectory { panel.directoryURL = startingDirectory }

        let response = await present(panel, attachedTo: window)
        return response == .OK ? panel.urls : []
    }

    /// Presents the panel without blocking the main actor.
    ///
    /// Never use `runModal()` here: it spins a nested modal run loop inside the current
    /// MainActor job, so the main queue (and every other MainActor task) stalls until the
    /// user dismisses the panel, which the app-hang watchdog reports as a hang.
    private func present(_ panel: NSOpenPanel, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: window) { response in
                    cont.resume(returning: response)
                }
            }
        }

        // No window to attach a sheet to: present the panel as a standalone window
        // asynchronously instead of running a blocking modal loop.
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { cont in
            panel.begin { response in
                cont.resume(returning: response)
            }
        }
    }
}
