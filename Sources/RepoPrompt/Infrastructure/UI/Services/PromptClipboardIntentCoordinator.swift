import AppKit

@MainActor
final class PromptClipboardIntentCoordinator {
    static let shared = PromptClipboardIntentCoordinator()

    private var generation: UInt = 0

    private init() {}

    func begin() -> UInt {
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        candidate == generation
    }

    func write(
        _ content: String,
        intent: UInt,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard isCurrent(intent) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(content, forType: .string)
    }

    func buildAndWrite(
        intent: UInt,
        to pasteboard: NSPasteboard = .general,
        build: () async -> String?
    ) async -> Bool {
        guard let content = await build() else { return false }
        return write(content, intent: intent, to: pasteboard)
    }
}
