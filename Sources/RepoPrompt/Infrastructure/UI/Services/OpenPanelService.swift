import AppKit
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
        if let message {
            panel.message = message
        }
        if let startingDirectory {
            panel.directoryURL = startingDirectory
        }

        // Prefer sheet modal to avoid runModal() blocking the main run loop.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: window) { response in
                    cont.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } else {
            // Fallback: no window available.
            let response = panel.runModal()
            return response == .OK ? panel.url : nil
        }
    }

    /// Picks one or more image files.
    func pickImageFiles(
        title: String = "Choose Images",
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
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"
        panel.title = title
        if let message {
            panel.message = message
        }
        if let startingDirectory {
            panel.directoryURL = startingDirectory
        }

        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: window) { response in
                    cont.resume(returning: response == .OK ? panel.urls : [])
                }
            }
        }

        let response = panel.runModal()
        return response == .OK ? panel.urls : []
    }
}
