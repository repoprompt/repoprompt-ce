//
//  WindowStateManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-24.
//

import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI

struct WindowSessionSnapshot: Codable {
    var version: Int
    var windows: [WindowSessionEntry]
}

struct WindowSessionEntry: Codable {
    var windowKind: WindowKind
    var workspaceID: UUID?
    var workspaceName: String?
    var isSystemWorkspace: Bool
    var isEphemeral: Bool
    var primaryRepoPath: String?
    var lastFocused: Bool
    /// Sticky instance number for this workspace in this window (for deterministic restore)
    var workspaceInstanceNumber: Int?
}

struct WindowSessionCaptureCandidate {
    let windowID: Int
    let entry: WindowSessionEntry?
}

struct WindowInitialRefreshDeferral: Equatable {
    let id: UUID
    let waiterID: UUID
}

enum WindowSessionSnapshotBuilder {
    static func build(
        version: Int,
        candidates: [WindowSessionCaptureCandidate],
        excludedWindowIDs: Set<Int>
    ) -> WindowSessionSnapshot {
        var entries: [WindowSessionEntry] = []
        for candidate in candidates {
            guard !excludedWindowIDs.contains(candidate.windowID) else { continue }
            guard let entry = candidate.entry else { continue }
            entries.append(entry)
        }
        return WindowSessionSnapshot(version: version, windows: entries)
    }
}

enum WindowSessionStore {
    static func sessionFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("windowSessions.json")
    }
}

actor WindowSessionDiskWriter {
    private let fileURL: URL
    private var pendingTask: Task<Void, Never>?
    private var writeGeneration: UInt64 = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func scheduleWrite(_ snapshot: WindowSessionSnapshot) {
        pendingTask?.cancel()
        writeGeneration += 1
        let generation = writeGeneration
        pendingTask = Task { [self, snapshot, generation] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await performScheduledWrite(snapshot, generation: generation)
        }
    }

    func writeImmediately(_ snapshot: WindowSessionSnapshot) {
        pendingTask?.cancel()
        pendingTask = nil
        writeGeneration += 1
        writeToDisk(snapshot)
    }

    private func performScheduledWrite(_ snapshot: WindowSessionSnapshot, generation: UInt64) {
        guard generation == writeGeneration else { return }
        pendingTask = nil
        writeToDisk(snapshot)
    }

    private func writeToDisk(_ snapshot: WindowSessionSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to write window session snapshot: \(error)")
        }
    }

    func load() -> WindowSessionSnapshot? {
        #if DEBUG
            let startMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(WindowSessionSnapshot.self, from: data)
            #if DEBUG
                if let startMS {
                    WorkspaceRestorePerfLog.log(
                        "restore.sessionDiskLoad status=success entries=\(snapshot.windows.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: startMS)) file=\(fileURL.path)"
                    )
                }
            #endif
            return snapshot
        } catch {
            #if DEBUG
                if let startMS {
                    WorkspaceRestorePerfLog.log(
                        "restore.sessionDiskLoad status=missingOrFailed duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: startMS)) file=\(fileURL.path) error=\(String(describing: error))"
                    )
                }
            #endif
            return nil
        }
    }
}

/// Manages all the open WindowState objects, letting you easily
/// find the "latest" one or broadcast to all windows if needed.
@MainActor
class WindowStatesManager: ObservableObject {
    /// 🚀 Single, shared instance for the entire app
    static let shared = WindowStatesManager()

    /// Flag indicating the app is terminating. When true, observation-triggering
    /// operations should be skipped to prevent EXC_BAD_ACCESS crashes during shutdown.
    /// This is checked by views and view models before triggering updates.
    private(set) var isTerminating = false

    /// Prevent accidental secondary instances
    private init() {
        autoRestoreWorkspacesEnabled = UserDefaults.standard.object(forKey: WindowStatesManager.autoRestoreDefaultsKey) as? Bool ?? false
        GlobalSettingsStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isTerminating else { return }
                updateKeyboardShortcutsState()
            }
            .store(in: &focusCancellables)
        updateKeyboardShortcutsState()
    }

    // ──────────────────────────────────────────────────────────────
    // Existing stored properties follow (unchanged)
    // ──────────────────────────────────────────────────────────────

    /// All active windows in the order they were created
    @Published var allWindows: [WindowState] = []

    /// Any incoming URLs that arrived before a window was ready
    @Published var pendingURLs: [URL] = []
    @Published var autoRestoreWorkspacesEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoRestoreWorkspacesEnabled, forKey: WindowStatesManager.autoRestoreDefaultsKey)
        }
    }

    /// We keep references to the focus-change cancellables (if we needed direct Combine usage),
    /// but in this example we rely on a callback approach from each WindowState.
    private var focusCancellables = Set<AnyCancellable>()

    private static let autoRestoreDefaultsKey = "autoRestoreWorkspacesEnabled_v2"

    /// Promotes the Pro default for auto-restore only when the user has never
    /// explicitly picked a value for this setting.
    static func applyProAutoRestoreDefaultIfUnset() {
        guard UserDefaults.standard.object(forKey: autoRestoreDefaultsKey) == nil else { return }
        shared.autoRestoreWorkspacesEnabled = true
    }

    /// Monotonically-increasing "next instance number" per workspace ID.
    /// This value only ever increases within the app lifetime; we do not reuse numbers.
    private var nextInstanceNumberByWorkspace: [UUID: Int] = [:]

    /// Current assigned instance number per window ID.
    /// Tuple stores the workspace ID and the assigned instance number for that window.
    private var assignedInstanceByWindowID: [Int: (workspaceID: UUID, number: Int)] = [:]

    /// Remembers a window's previously assigned number per workspace
    /// to support reclaiming the same number when it returns.
    private var windowWorkspaceNumberHistory: [Int: [UUID: Int]] = [:]

    /// Restored instance numbers available for each workspace from the last session.
    /// Numbers are consumed as windows for that workspace are restored.
    private var restoredInstanceNumbersByWorkspace: [UUID: [Int]] = [:]

    /// Waiters for programmatic window creation.
    /// Each waiter is waiting for a new window to be registered that wasn't in the excluded set.
    private struct WindowOpenWaiter {
        let id: UUID
        let excludeWindowIDs: Set<Int>
        let expectedInitialRefreshDeferralID: UUID?
        let continuation: CheckedContinuation<WindowState, Error>

        var defersInitialAgentSystemWorkspaceRefresh: Bool {
            expectedInitialRefreshDeferralID != nil
        }
    }

    private var windowOpenWaiters: [WindowOpenWaiter] = []
    private var pendingInitialRefreshDeferrals: [WindowInitialRefreshDeferral] = []

    private let windowSessionWriter = WindowSessionDiskWriter(
        fileURL: WindowSessionStore.sessionFileURL()
    )
    private var explicitlyClosingWindowIDs: Set<Int> = []
    private var restoreQueue: [WindowSessionEntry] = []
    private var hasLoadedRestoreSession = false
    private var isRestoreSessionLoadPending = false

    func claimInitialRefreshDeferralForNewWindow() -> WindowInitialRefreshDeferral? {
        guard !pendingInitialRefreshDeferrals.isEmpty else { return nil }
        return pendingInitialRefreshDeferrals.removeFirst()
    }

    private func clearPendingInitialRefreshDeferral(waiterID: UUID) {
        pendingInitialRefreshDeferrals.removeAll { $0.waiterID == waiterID }
    }

    nonisolated static func initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
        waiterID: UUID,
        expectedDeferralID: UUID?,
        claimedWaiterID: UUID?,
        claimedDeferralID: UUID?
    ) -> Bool {
        guard let expectedDeferralID else { return true }
        return claimedWaiterID == waiterID && claimedDeferralID == expectedDeferralID
    }

    /// Returns the *most recently added* window if it exists
    var latestWindowState: WindowState? {
        allWindows.last
    }

    /// Returns whether multi-window routing should be enforced (multiple windows are open).
    /// Use this for behavior/error messages, not for UI binding.
    var isMultiWindowModeEffectivelyActive: Bool {
        allWindows.count > 1
    }

    /// Finds a window that's showing a specific workspace
    func findWindowState(showing workspaceId: UUID) -> WindowState? {
        allWindows.first { $0.workspaceManager.activeWorkspace?.id == workspaceId }
    }

    /// Counts how many windows are showing a specific workspace
    func countWindowsShowing(workspaceId: UUID) -> Int {
        allWindows.count(where: { $0.workspaceManager.activeWorkspace?.id == workspaceId })
    }

    func loadWindowRestoreSessionIfNeeded() {
        guard !hasLoadedRestoreSession else { return }
        hasLoadedRestoreSession = true
        guard autoRestoreWorkspacesEnabled else {
            #if DEBUG
                WorkspaceRestorePerfLog.log("restore.session skipped reason=autoRestoreDisabled registeredWindows=\(allWindows.count)")
            #endif
            return
        }

        #if DEBUG
            let loadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        isRestoreSessionLoadPending = true
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await windowSessionWriter.load()
            await MainActor.run {
                let entries = snapshot?.windows.filter { !$0.isEphemeral } ?? []
                #if DEBUG
                    if let loadStartMS {
                        WorkspaceRestorePerfLog.log(
                            "restore.session loaded snapshotEntries=\(snapshot?.windows.count ?? 0) restoredEntries=\(entries.count) registeredWindows=\(self.allWindows.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: loadStartMS))"
                        )
                    }
                    let applyStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
                #endif

                // Seed instance-number state from snapshot for deterministic restore
                self.preseedInstanceNumberState(from: snapshot)

                self.restoreQueue = entries
                self.isRestoreSessionLoadPending = false
                if !entries.isEmpty {
                    self.applyRestoreEntriesIfPossible()
                }
                #if DEBUG
                    if let applyStartMS {
                        WorkspaceRestorePerfLog.log(
                            "restore.session applied restoredEntries=\(entries.count) registeredWindows=\(self.allWindows.count) remainingQueue=\(self.restoreQueue.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: applyStartMS))"
                        )
                    }
                #endif
            }
        }
    }

    /// Pre-seeds instance number state from a loaded session snapshot.
    /// This ensures that restored windows get the same instance numbers they had before.
    private func preseedInstanceNumberState(from snapshot: WindowSessionSnapshot?) {
        restoredInstanceNumbersByWorkspace.removeAll()
        nextInstanceNumberByWorkspace.removeAll()
        guard let snapshot else { return }

        var maxByWorkspace: [UUID: Int] = [:]
        for entry in snapshot.windows {
            guard !entry.isEphemeral, let workspaceID = entry.workspaceID else { continue }

            // Only process entries with valid instance numbers
            guard let number = entry.workspaceInstanceNumber, number >= 1 else { continue }

            restoredInstanceNumbersByWorkspace[workspaceID, default: []].append(number)
            maxByWorkspace[workspaceID] = max(maxByWorkspace[workspaceID] ?? number, number)
        }

        // Normalize lists (unique, sorted) for deterministic consumption order
        for (wsID, numbers) in restoredInstanceNumbersByWorkspace {
            let uniqueSorted = Array(Set(numbers)).sorted()
            restoredInstanceNumbersByWorkspace[wsID] = uniqueSorted
        }

        // Set "next" counters just past the highest restored instance
        for (wsID, maxNumber) in maxByWorkspace {
            nextInstanceNumberByWorkspace[wsID] = maxNumber + 1
        }
    }

    /// Finds a window that's showing a workspace containing a specific folder
    func findWindowState(forFolderPath path: String) -> WindowState? {
        allWindows.first { ws in
            guard let activeWS = ws.workspaceManager.activeWorkspace else { return false }
            return activeWS.repoPaths.contains { repoPath in
                let expanded = (repoPath as NSString).expandingTildeInPath
                return expanded == (path as NSString).expandingTildeInPath
            }
        }
    }

    // MARK: - Programmatic Window Creation

    /// Opens a new main window and waits for it to be registered.
    ///
    /// This method uses `AppWindowOpener` to trigger SwiftUI's `openWindow(id: "main")`,
    /// then waits for the new window to appear in `allWindows`.
    ///
    /// - Returns: The newly created `WindowState`
    /// - Throws: `WindowOpenError.openerUnavailable` if no opener is installed
    func openNewMainWindow(deferringInitialAgentSystemWorkspaceRefresh: Bool = false) async throws -> WindowState {
        // Capture existing window IDs to identify the new one
        let excludeWindowIDs = Set(allWindows.map(\.windowID))
        let waiterID = UUID()
        let refreshDeferral = deferringInitialAgentSystemWorkspaceRefresh
            ? WindowInitialRefreshDeferral(id: UUID(), waiterID: waiterID)
            : nil
        if let refreshDeferral {
            pendingInitialRefreshDeferrals.append(refreshDeferral)
        }

        // Wait for the new window to be registered
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Add waiter
                windowOpenWaiters.append(WindowOpenWaiter(
                    id: waiterID,
                    excludeWindowIDs: excludeWindowIDs,
                    expectedInitialRefreshDeferralID: refreshDeferral?.id,
                    continuation: continuation
                ))

                // Trigger window creation via SwiftUI
                do {
                    try AppWindowOpener.shared.openMainWindow()
                } catch {
                    self.cancelWindowOpenWaiter(id: waiterID, error: error)
                    return
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWindowOpenWaiter(id: waiterID, error: CancellationError())
            }
        }
    }

    private func cancelWindowOpenWaiter(id waiterID: UUID, error: Error) {
        guard let index = windowOpenWaiters.firstIndex(where: { $0.id == waiterID }) else {
            // If the waiter is already gone, it may have been fulfilled and resumed; do not clear a
            // routed window's claimed deferral from a late cancellation handler.
            clearPendingInitialRefreshDeferral(waiterID: waiterID)
            return
        }
        let waiter = windowOpenWaiters.remove(at: index)
        if waiter.defersInitialAgentSystemWorkspaceRefresh {
            cleanupInitialRefreshDeferral(waiterID: waiter.id, reason: "waiterCancelled")
        }
        waiter.continuation.resume(throwing: error)
    }

    private func cleanupInitialRefreshDeferral(waiterID: UUID, reason: String) {
        clearPendingInitialRefreshDeferral(waiterID: waiterID)
        let claimedWindows = allWindows.filter { $0.claimedInitialRefreshDeferralWaiterID == waiterID }
        for window in claimedWindows {
            #if DEBUG
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.initialSystemRefreshDeferral cleanup windowID=\(window.windowID) waiterID=\(waiterID.uuidString.prefix(8)) deferralID=\(window.claimedInitialRefreshDeferralID?.uuidString.prefix(8).description ?? "nil") reason=\(reason)"
                )
            #endif
            window.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: true)
        }
    }

    // MARK: - Programmatic Window Close

    func requestCloseWindow(windowID: Int, authorization: WindowCloseAuthorization? = nil) throws {
        guard let state = allWindows.first(where: { $0.windowID == windowID }) else {
            throw NSError(
                domain: "WindowStatesManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown window_id \(windowID)"]
            )
        }
        state.requestClose(authorization: authorization)
    }

    /// Notifies waiters when a new window is registered.
    private func notifyWindowOpenWaiters(newState: WindowState) {
        guard let index = windowOpenWaiterIndex(for: newState) else { return }

        let waiter = windowOpenWaiters.remove(at: index)
        if waiter.defersInitialAgentSystemWorkspaceRefresh {
            verifyInitialRefreshDeferralClaim(waiter: waiter, newState: newState)
        }
        waiter.continuation.resume(returning: newState)
    }

    private func windowOpenWaiterIndex(for newState: WindowState) -> Int? {
        if let claimedWaiterID = newState.claimedInitialRefreshDeferralWaiterID,
           let claimedDeferralID = newState.claimedInitialRefreshDeferralID
        {
            if let claimedWaiterIndex = windowOpenWaiters.firstIndex(where: { waiter in
                waiter.id == claimedWaiterID
                    && waiter.expectedInitialRefreshDeferralID == claimedDeferralID
                    && !waiter.excludeWindowIDs.contains(newState.windowID)
            }) {
                return claimedWaiterIndex
            }

            cleanupClaimedInitialRefreshDeferral(
                for: newState,
                reason: "noMatchingClaimedWindowOpenWaiter"
            )
            return windowOpenWaiters.firstIndex(where: { waiter in
                !waiter.defersInitialAgentSystemWorkspaceRefresh
                    && !waiter.excludeWindowIDs.contains(newState.windowID)
            })
        }

        return windowOpenWaiters.firstIndex(where: { waiter in
            !waiter.defersInitialAgentSystemWorkspaceRefresh
                && !waiter.excludeWindowIDs.contains(newState.windowID)
        })
    }

    private func verifyInitialRefreshDeferralClaim(waiter: WindowOpenWaiter, newState: WindowState) {
        clearPendingInitialRefreshDeferral(waiterID: waiter.id)
        let matches = Self.initialAgentSystemWorkspaceRefreshDeferralClaimMatches(
            waiterID: waiter.id,
            expectedDeferralID: waiter.expectedInitialRefreshDeferralID,
            claimedWaiterID: newState.claimedInitialRefreshDeferralWaiterID,
            claimedDeferralID: newState.claimedInitialRefreshDeferralID
        )
        guard !matches else { return }

        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "agentSessionIndex.initialSystemRefreshDeferral attributionMismatch routedWindowID=\(newState.windowID) waiterID=\(waiter.id.uuidString.prefix(8)) expectedDeferralID=\(waiter.expectedInitialRefreshDeferralID?.uuidString.prefix(8).description ?? "nil") claimedWaiterID=\(newState.claimedInitialRefreshDeferralWaiterID?.uuidString.prefix(8).description ?? "nil") claimedDeferralID=\(newState.claimedInitialRefreshDeferralID?.uuidString.prefix(8).description ?? "nil")"
            )
            assertionFailure("Programmatic new-window Agent refresh deferral was claimed by a different window than the routed waiter.")
        #endif

        for window in allWindows where window !== newState && window.claimedInitialRefreshDeferralWaiterID == waiter.id {
            window.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: true)
        }
    }

    private func cleanupClaimedInitialRefreshDeferral(for state: WindowState, reason: String) {
        guard let waiterID = state.claimedInitialRefreshDeferralWaiterID else { return }
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "agentSessionIndex.initialSystemRefreshDeferral unmatchedClaim windowID=\(state.windowID) waiterID=\(waiterID.uuidString.prefix(8)) deferralID=\(state.claimedInitialRefreshDeferralID?.uuidString.prefix(8).description ?? "nil") reason=\(reason)"
            )
        #endif
        state.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: true)
    }

    private func applyNextRestoreEntryIfAvailable(to state: WindowState) {
        guard !restoreQueue.isEmpty else { return }
        let entry = restoreQueue.removeFirst()
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "restore.entry assign windowID=\(state.windowID) workspaceID=\(WorkspaceRestorePerfLog.shortID(entry.workspaceID)) workspaceName=\(entry.workspaceName ?? "nil") isSystem=\(entry.isSystemWorkspace) remainingQueue=\(restoreQueue.count) registeredWindows=\(allWindows.count)"
            )
        #endif
        state.applyWindowRestoreEntry(entry)
    }

    /// Attempt to apply restore entries to any already-registered windows.
    private func applyRestoreEntriesIfPossible() {
        guard !restoreQueue.isEmpty else { return }
        for state in allWindows where !restoreQueue.isEmpty {
            applyNextRestoreEntryIfAvailable(to: state)
        }
    }

    func registerWindowState(_ state: WindowState) {
        // Prevent duplicate registration
        guard !allWindows.contains(where: { $0 === state }) else { return }

        #if DEBUG
            let registerStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        allWindows.append(state)
        #if DEBUG
            WorkspaceRestorePerfLog.log(
                "restore.window registered windowID=\(state.windowID) registeredWindows=\(allWindows.count) pendingRestoreEntries=\(restoreQueue.count)"
            )
        #endif

        // Notify that window count changed
        NotificationCenter.default.post(name: .windowCountDidChange, object: nil)

        // Notify any waiters for programmatic window creation
        notifyWindowOpenWaiters(newState: state)

        // Listen for focus changes in the window state:
        state.onFocusChanged = { [weak self] isFocused in
            guard let self else { return }
            updateKeyboardShortcutsState()
            persistWindowSession(reason: "focusChanged:\(isFocused)")
        }

        // Hook into workspace switches for this window and assign a sticky instance number
        state.workspaceManager.addWorkspaceDidSwitchListener(label: "windowStateManager") { [weak self, weak state] newWorkspace in
            guard let self, let state else { return }
            let number = recordWorkspaceSwitch(forWindowID: state.windowID, to: newWorkspace)
            // Publish to the window so UI can react (e.g., in the title)
            state.workspaceInstanceNumber = number
            state.requestWindowTitleUpdate(reason: .workspaceChanged)
            persistWindowSession(reason: "workspaceSwitch")
        }

        applyNextRestoreEntryIfAvailable(to: state)

        // Assign an initial instance number if the workspace is already set
        if let ws = state.workspaceManager.activeWorkspace {
            let n = recordWorkspaceSwitch(forWindowID: state.windowID, to: ws)
            state.workspaceInstanceNumber = n
            state.requestWindowTitleUpdate(reason: .workspaceChanged)
        }

        // If we have pending URLs that arrived *before* any windows,
        // route them through the app router so scoped routes are parsed before
        // choosing a target window. Drain once and preserve ordering.
        let urlsToRoute = pendingURLs
        pendingURLs.removeAll()
        if !urlsToRoute.isEmpty {
            Task { @MainActor in
                for url in urlsToRoute {
                    await AppDeepLinkRouter.shared.route(url: url, preferredLegacyWindow: state)
                }
            }
        }

        updateKeyboardShortcutsState()
        persistWindowSession(reason: "registerWindow")
        #if DEBUG
            if let registerStartMS {
                WorkspaceRestorePerfLog.log(
                    "restore.window registerComplete windowID=\(state.windowID) registeredWindows=\(allWindows.count) remainingRestoreEntries=\(restoreQueue.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: registerStartMS))"
                )
            }
        #endif
    }

    func unregisterWindowState(_ state: WindowState) {
        state.beginClose()
        if let idx = allWindows.firstIndex(where: { $0 === state }) {
            allWindows.remove(at: idx)
        }
        explicitlyClosingWindowIDs.remove(state.windowID)

        // Skip notifications and updates during termination to prevent observation crashes
        guard !isTerminating else { return }

        // Notify that window count changed
        NotificationCenter.default.post(name: .windowCountDidChange, object: nil)

        // Inform the network manager that this window is gone
        Task { await ServerNetworkManager.shared.clearWindowSelectionIfClosed(state.windowID) }

        // Then update shortcuts in case we lost a focused window
        updateKeyboardShortcutsState()

        // Clear instance assignment for this window without reusing numbers
        clearInstanceAssignment(forWindowID: state.windowID)

        Task { @MainActor in
            await self.persistWindowSessionImmediately(reason: "unregisterWindow:\(state.windowID)")
        }
    }

    func markWindowAsExplicitlyClosing(windowID: Int) {
        guard !isTerminating else { return }
        guard allWindows.contains(where: { $0.windowID == windowID }) else { return }
        guard explicitlyClosingWindowIDs.insert(windowID).inserted else { return }

        Task { @MainActor in
            await self.persistWindowSessionImmediately(reason: "explicitClose:\(windowID)")
        }
    }

    func persistWindowSession(reason: String = "unspecified") {
        guard !AppLaunchConfiguration.current.suppressesWindowPersistence else { return }
        let snapshot = captureCurrentSession()
        Task { await windowSessionWriter.scheduleWrite(snapshot) }
    }

    func persistWindowSessionImmediately(reason: String = "unspecified") async {
        guard !AppLaunchConfiguration.current.suppressesWindowPersistence else { return }
        let snapshot = captureCurrentSession()
        await windowSessionWriter.writeImmediately(snapshot)
    }

    private func captureCurrentSession() -> WindowSessionSnapshot {
        let candidates = allWindows.map { window -> WindowSessionCaptureCandidate in
            guard let workspace = window.workspaceManager.activeWorkspace else {
                return WindowSessionCaptureCandidate(windowID: window.windowID, entry: nil)
            }
            guard !workspace.isEphemeral else {
                return WindowSessionCaptureCandidate(windowID: window.windowID, entry: nil)
            }

            let primaryPath = workspace.repoPaths.first.map { repoPath in
                (repoPath as NSString).expandingTildeInPath
            }

            let entry = WindowSessionEntry(
                windowKind: window.kind,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                isSystemWorkspace: workspace.isSystemWorkspace,
                isEphemeral: workspace.isEphemeral,
                primaryRepoPath: primaryPath,
                lastFocused: window.isCurrentlyFocused,
                workspaceInstanceNumber: window.workspaceInstanceNumber
            )
            return WindowSessionCaptureCandidate(windowID: window.windowID, entry: entry)
        }

        return WindowSessionSnapshotBuilder.build(
            version: 4,
            candidates: candidates,
            excludedWindowIDs: explicitlyClosingWindowIDs
        )
    }

    // MARK: - Keyboard Shortcuts Enabling/Disabling

    /// Updates `KeyboardShortcuts.isEnabled` depending on whether
    /// any of our tracked windows is currently focused and if shortcuts are enabled in settings.
    private func updateKeyboardShortcutsState() {
        // Skip during termination to prevent observation crashes
        guard !isTerminating else { return }

        let shortcutsEnabled = GlobalSettingsStore.shared.enableKeyboardShortcuts()

        // If *any* window is currently focused AND shortcuts are enabled, enable shortcuts; otherwise disable them.
        let anyFocused = allWindows.contains { $0.isCurrentlyFocused == true }
        let shouldEnable = anyFocused && shortcutsEnabled
        if shouldEnable {
            // Register handlers lazily to avoid installing Carbon hotkeys during background/inactive launch.
            GlobalKeyboardShortcutsCoordinator.shared.ensureHandlersRegistered()
        }
        KeyboardShortcuts.isEnabled = shouldEnable
    }

    // MARK: - Window Lookup Helpers (for MCP routing)

    /// Lookup a window by its ID.
    func window(withID id: Int) -> WindowState? {
        allWindows.first { $0.windowID == id }
    }

    /// Check if a window with the given ID exists.
    func hasWindow(id: Int) -> Bool {
        allWindows.contains { $0.windowID == id }
    }

    /// Check if a window exists and has MCP tools enabled.
    func hasWindowWithMCPEnabled(_ id: Int) -> Bool {
        allWindows.contains { $0.windowID == id && $0.mcpServer.windowToolsEnabled }
    }

    /// Get a window only if it exists and has MCP tools enabled.
    func mcpEnabledWindow(withID id: Int) -> WindowState? {
        allWindows.first { $0.windowID == id && $0.mcpServer.windowToolsEnabled }
    }

    /// Get the first window that has MCP tools enabled.
    func firstMCPEnabledWindow() -> WindowState? {
        allWindows.first { $0.mcpServer.windowToolsEnabled }
    }

    /// Get all window IDs that have MCP tools enabled.
    func mcpEnabledWindowIDs() -> [Int] {
        allWindows.filter(\.mcpServer.windowToolsEnabled).map(\.windowID)
    }

    /// Returns window count and multi-window mode status in a single call.
    func windowCountAndMode() -> (count: Int, isMultiWindowActive: Bool) {
        (allWindows.count, allWindows.count > 1)
    }

    // MARK: - App Termination

    /// Signals that the app is terminating. Call this at the START of applicationWillTerminate
    /// to prevent SwiftUI observation crashes during shutdown.
    nonisolated func signalTermination() {
        // Use MainActor.assumeIsolated since this is called from applicationWillTerminate
        // which runs on the main thread, but Swift doesn't know that statically.
        MainActor.assumeIsolated {
            self.isTerminating = true
            // Cancel any pending focus/workspace change notifications that might trigger updates
            self.cancellablesDuringTermination()
        }
    }

    /// Cancels Combine subscriptions and clears state that could trigger updates during shutdown.
    private func cancellablesDuringTermination() {
        focusCancellables.removeAll()
        // Clear callbacks that might trigger view updates
        for window in allWindows {
            window.onFocusChanged = nil
        }
    }

    // MARK: - MCP Server Coordination

    /// Stops MCP servers in **all** windows (unconditionally).
    /// During teardown, "running" state can be stale; we just want tools off.
    func stopAllServers() async {
        let windowIDs = allWindows.map(\.windowID)
        await withTaskGroup(of: Void.self) { group in
            for windowID in windowIDs {
                group.addTask { @MainActor [weak self] in
                    guard let self, let ws = window(withID: windowID) else { return }
                    await ws.mcpServer.stopServer()
                }
            }
        }
    }

    /// Shuts down all agent processes (Claude CLI, Codex app-server) across every window.
    /// Called during app termination to prevent orphaned child processes.
    /// Safe to call after `signalTermination()` — only performs cancellation and process teardown,
    /// no UI-observed state mutations.
    func shutdownAllAgentSessions() async {
        let windowIDs = allWindows.map(\.windowID)
        await withTaskGroup(of: Void.self) { group in
            for windowID in windowIDs {
                group.addTask { @MainActor [weak self] in
                    guard let self, let ws = window(withID: windowID) else { return }
                    await ws.agentModeViewModel.prepareForWindowClose()
                }
            }
        }
        // Stop dedicated CLI model polling so background refreshes cannot race shutdown.
        await CodexModelPollingService.shared.shutdown()
        await OpenCodeACPModelPollingService.shared.shutdown()
        await CursorACPModelPollingService.shared.shutdown()
    }

    // MARK: - Instance Number Management

    /// Records that a window switched to a given workspace and assigns a new sticky instance number.
    /// Returns the assigned number, or nil if workspace is nil.
    @discardableResult
    func recordWorkspaceSwitch(forWindowID windowID: Int, to workspace: WorkspaceModel?) -> Int? {
        // Skip during termination to prevent observation crashes
        guard !isTerminating else { return nil }

        // Preserve previous assignment in history (for reclaim) and clear current assignment
        if let prev = assignedInstanceByWindowID[windowID] {
            var perWS = windowWorkspaceNumberHistory[windowID] ?? [:]
            perWS[prev.workspaceID] = prev.number
            windowWorkspaceNumberHistory[windowID] = perWS
            assignedInstanceByWindowID.removeValue(forKey: windowID)
        }

        guard let ws = workspace else {
            NotificationCenter.default.post(
                name: .repoPromptWindowInstanceNumberDidChange,
                object: nil,
                userInfo: ["windowID": windowID, "number": NSNull()]
            )
            return nil
        }

        let wsID = ws.id

        // 1) Try to reclaim a remembered number for this window and workspace if not occupied
        if let remembered = windowWorkspaceNumberHistory[windowID]?[wsID] {
            let isOccupied = assignedInstanceByWindowID.contains { otherWindowID, current in
                otherWindowID != windowID && current.workspaceID == wsID && current.number == remembered
            }
            if !isOccupied {
                let assignedNumber = remembered
                assignedInstanceByWindowID[windowID] = (workspaceID: wsID, number: assignedNumber)
                // Ensure 'next' is beyond assigned
                let currentNext = nextInstanceNumberByWorkspace[wsID] ?? 1
                if assignedNumber >= currentNext {
                    nextInstanceNumberByWorkspace[wsID] = assignedNumber + 1
                }
                NotificationCenter.default.post(
                    name: .repoPromptWindowInstanceNumberDidChange,
                    object: nil,
                    userInfo: ["windowID": windowID, "number": assignedNumber]
                )
                return assignedNumber
            }
        }

        // 2) Try to consume a restored instance number for this workspace
        var assignedNumber: Int
        if var restored = restoredInstanceNumbersByWorkspace[wsID], !restored.isEmpty {
            assignedNumber = restored.removeFirst()
            restoredInstanceNumbersByWorkspace[wsID] = restored
        } else if let next = nextInstanceNumberByWorkspace[wsID] {
            // 3) Fallback: assign from the monotonic counter (only if seeded from valid data)
            assignedNumber = next
            nextInstanceNumberByWorkspace[wsID] = next + 1
        } else {
            // 4) Completely new workspace (fresh install or newly created)
            // Start numbering at 1
            assignedNumber = 1
            nextInstanceNumberByWorkspace[wsID] = 2
        }

        // Ensure the "next" counter is ahead of whatever we assigned
        let currentNext = nextInstanceNumberByWorkspace[wsID] ?? 1
        if assignedNumber >= currentNext {
            nextInstanceNumberByWorkspace[wsID] = assignedNumber + 1
        }

        assignedInstanceByWindowID[windowID] = (workspaceID: wsID, number: assignedNumber)

        NotificationCenter.default.post(
            name: .repoPromptWindowInstanceNumberDidChange,
            object: nil,
            userInfo: ["windowID": windowID, "number": assignedNumber]
        )
        return assignedNumber
    }

    /// Current assigned instance number for a given window ID, if any.
    func currentInstanceNumber(forWindowID windowID: Int) -> Int? {
        assignedInstanceByWindowID[windowID]?.number
    }

    /// Clears the instance assignment for a given window.
    func clearInstanceAssignment(forWindowID windowID: Int) {
        if let prev = assignedInstanceByWindowID.removeValue(forKey: windowID) {
            // Remember last number for reclaim (within this window's lifetime)
            var perWS = windowWorkspaceNumberHistory[windowID] ?? [:]
            perWS[prev.workspaceID] = prev.number
            windowWorkspaceNumberHistory[windowID] = perWS

            // Skip notifications during termination to prevent observation crashes
            guard !isTerminating else { return }

            NotificationCenter.default.post(
                name: .repoPromptWindowInstanceNumberDidChange,
                object: nil,
                userInfo: ["windowID": windowID, "number": NSNull()]
            )
        }
    }

    /// Computes a display name for the specified window, appending " (N)" when N ≥ 2.
    func displayName(for window: WindowState) -> String {
        guard let ws = window.workspaceManager.activeWorkspace else {
            return WindowTitleFormatter.defaultTitle
        }

        // Default/system workspace: always show the app name and never append the number
        if ws.isSystemWorkspace {
            return WindowTitleFormatter.defaultTitle
        }

        let base = ws.name
        if let n = currentInstanceNumber(forWindowID: window.windowID), n >= 2 {
            return "\(base) (\(n))"
        } else {
            return base
        }
    }
}

extension Notification.Name {
    /// Posted when a window's sticky instance number changes.
    /// userInfo: ["windowID": Int, "number": Int or NSNull()]
    static let repoPromptWindowInstanceNumberDidChange = Notification.Name("repoPromptWindowInstanceNumberDidChange")
}
