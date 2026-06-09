import Foundation

/// App-owned weak adapter lookup for compatibility routing sessions.
///
/// MCP route eligibility belongs to `MCPRuntimeSessionRegistry`. This registry is
/// deliberately app-only and resolves UI adapters needed for AppKit activation,
/// approvals, Agent Mode, and transitional MCP tool execution.
@MainActor
final class RepoPromptAppSessionAdapterRegistry {
    nonisolated static let shared = RepoPromptAppSessionAdapterRegistry()

    private enum Lifecycle {
        case active
        case draining
    }

    private final class Entry {
        let windowID: Int
        weak var windowState: WindowState?
        var lifecycle: Lifecycle = .active

        init(windowState: WindowState) {
            windowID = windowState.windowID
            self.windowState = windowState
        }
    }

    private var entriesByID: [Int: Entry] = [:]
    private var orderedIDs: [Int] = []
    private var retiredIDs: Set<Int> = []

    private nonisolated init() {}

    func register(windowState: WindowState) {
        let windowID = windowState.windowID
        guard !retiredIDs.contains(windowID) else { return }
        if let existing = entriesByID[windowID] {
            existing.windowState = windowState
            existing.lifecycle = .active
            return
        }
        entriesByID[windowID] = Entry(windowState: windowState)
        orderedIDs.append(windowID)
    }

    func beginDraining(windowID: Int) {
        guard let entry = entriesByID[windowID] else { return }
        entry.lifecycle = .draining
    }

    func remove(windowID: Int) {
        entriesByID.removeValue(forKey: windowID)
        orderedIDs.removeAll { $0 == windowID }
        retiredIDs.insert(windowID)
    }

    func removeAll() {
        for windowID in orderedIDs {
            retiredIDs.insert(windowID)
        }
        entriesByID.removeAll()
        orderedIDs.removeAll()
    }

    func window(withID windowID: Int, includeDraining: Bool = false) -> WindowState? {
        guard let entry = entriesByID[windowID],
              includeDraining || entry.lifecycle == .active
        else {
            return nil
        }
        return entry.windowState
    }

    func windowStates(includeDraining: Bool = false) -> [WindowState] {
        orderedIDs.compactMap { window(withID: $0, includeDraining: includeDraining) }
    }
}
