import Combine
import Darwin
import Foundation
import RepoPromptShared

/// Monitors the MCP events directory for error events written by external CLI clients.
/// Surfaces these events to the UI even when network communication is impossible.
@MainActor
final class MCPExternalEventsMonitor: ObservableObject {
    static let shared = MCPExternalEventsMonitor()

    /// The most recent external client error event
    @Published private(set) var latestEvent: MCPExternalClientEvent?

    /// Number of similar errors from the same client in the tracking window
    @Published private(set) var recentErrorCount: Int = 0

    /// The last successfully connected client's MCP protocol name (e.g., "claude-ai", "cursor")
    /// Used as a fallback when CLI can't detect the client name from the process tree
    @Published private(set) var lastConnectedClientProtocolName: String?

    private let eventsDirectory: URL
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var lastSeenFilename: String?

    /// Tracks recent errors for frequency detection (client+code -> timestamps)
    private var recentErrors: [(clientName: String?, code: MCPExternalClientEvent.Code, timestamp: Date)] = []
    private let errorTrackingWindow: TimeInterval = 5 * 60 // 5 minutes

    private init() {
        eventsDirectory = MCPExternalClientEvent.eventsDirectoryURL
        setupDirectory()
    }

    deinit {
        let source = dispatchSource
        dispatchSource = nil
        let fd = directoryFileDescriptor
        directoryFileDescriptor = -1
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Setup

    private func setupDirectory() {
        do {
            try MCPExternalClientEvent.ensureEventsDirectoryExists()
        } catch {
            // Directory creation failed - monitor won't work but app should continue
            print("MCPExternalEventsMonitor: Failed to create events directory: \(error)")
        }
    }

    // MARK: - Public API

    static func openDirectoryWatcherFD(at url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Starts monitoring for new event files
    func start() {
        guard dispatchSource == nil else { return }

        // Open directory file descriptor
        let openedFD: Int32
        do {
            openedFD = try Self.openDirectoryWatcherFD(at: eventsDirectory)
        } catch {
            print("MCPExternalEventsMonitor: Failed to open events directory for monitoring: \(error)")
            return
        }
        directoryFileDescriptor = openedFD

        // Create dispatch source for directory changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: openedFD,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDirectoryChange()
            }
        }

        source.setCancelHandler {
            Darwin.close(openedFD)
        }

        dispatchSource = source
        source.resume()

        // Load latest on startup
        loadLatestRecent()
    }

    /// Stops monitoring
    func stop() {
        let source = dispatchSource
        dispatchSource = nil
        let fd = directoryFileDescriptor
        directoryFileDescriptor = -1
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Loads the most recent displayable event if it's fresh enough (within maxAge)
    func loadLatestRecent(maxAge: TimeInterval = 24 * 3600) {
        guard let latestFile = findLatestDisplayableEventFile() else { return }

        do {
            let event = try loadEvent(from: latestFile)

            // Only show if fresh enough
            if Date().timeIntervalSince(event.timestamp) < maxAge {
                latestEvent = event
                lastSeenFilename = latestFile.lastPathComponent
            }
        } catch {
            print("MCPExternalEventsMonitor: Failed to load latest event: \(error)")
        }
    }

    /// Clears the current event (e.g., when user dismisses it)
    func clearLatestEvent() {
        latestEvent = nil
    }

    /// Clears the current event only if it was from the specified client.
    /// Call this when a client successfully connects to clear any previous error for that client.
    func clearEventForClient(_ clientName: String) {
        // Always track the last connected client's protocol name
        lastConnectedClientProtocolName = clientName

        guard let event = latestEvent else { return }
        // Match if the event's client name matches (fuzzy match for protocol vs detected names)
        if clientNamesMatch(event.clientName, clientName) || event.clientName == nil {
            // If the event has no client name, it's likely from the same client that just connected
            latestEvent = nil
            recentErrorCount = 0
            // Also clear tracked errors for this client
            recentErrors.removeAll { clientNamesMatch($0.clientName, clientName) || $0.clientName == nil }
        }
    }

    /// Returns a user-friendly display name for the given MCP protocol name
    func friendlyClientName(forProtocol protocolName: String?) -> String {
        guard let name = protocolName else { return "An external client" }
        let key = extractClientKey(from: name.lowercased())
        switch key {
        case "claude-desktop": return "Claude Desktop"
        case "claude-code": return "Claude Code"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        case "windsurf": return "Windsurf"
        case "zed": return "Zed"
        case "vscode": return "VS Code"
        default: return name
        }
    }

    /// Fuzzy match client names - handles cases like "Claude Desktop" (detected) vs "claude-ai" (protocol)
    private func clientNamesMatch(_ detected: String?, _ protocol: String) -> Bool {
        // Exact match
        if detected == `protocol` {
            return true
        }

        // Both empty/nil
        if (detected == nil || detected?.isEmpty == true) && `protocol`.isEmpty {
            return true
        }

        guard let detected = detected?.lowercased() else { return false }
        let protocolLower = `protocol`.lowercased()

        // Normalize and compare - extract key identifier
        let detectedKey = extractClientKey(from: detected)
        let protocolKey = extractClientKey(from: protocolLower)

        return detectedKey == protocolKey || detected.contains(protocolKey) || protocolLower.contains(detectedKey)
    }

    /// Extracts the key identifier from a client name (e.g., "claude-desktop" from "Claude Desktop" or "claude-ai")
    private func extractClientKey(from name: String) -> String {
        // Known mappings: detected names (from CLI) -> protocol names (from MCP handshake)
        // Note: Claude Desktop and Claude Code are separate clients
        let keyMappings: [(patterns: [String], key: String)] = [
            (["claude-code", "claude code"], "claude-code"), // Claude Code CLI - must check before generic "claude"
            (["claude-ai", "claude desktop"], "claude-desktop"), // Claude Desktop app
            (["cursor"], "cursor"),
            (["codex"], "codex"),
            (["windsurf"], "windsurf"),
            (["zed"], "zed"),
            (["vscode", "vs code", "code"], "vscode")
        ]

        for (patterns, key) in keyMappings {
            if patterns.contains(where: { name.contains($0) }) {
                return key
            }
        }

        // Return first word as fallback
        return name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first(where: { !$0.isEmpty }) ?? name
    }

    // MARK: - Private Helpers

    private func handleDirectoryChange() {
        guard let latestFile = findLatestEventFile() else { return }

        // Skip if we've already processed this file
        let filename = latestFile.lastPathComponent
        if filename == lastSeenFilename {
            return
        }

        do {
            let event = try loadEvent(from: latestFile)
            lastSeenFilename = filename

            // Skip ignorable events (like host disconnects) - don't update UI or track
            if event.isIgnorableForUI {
                return
            }

            // Track this error for frequency detection
            trackError(event)

            // Update the latest event and count
            latestEvent = event
            recentErrorCount = countSimilarRecentErrors(to: event)
        } catch {
            print("MCPExternalEventsMonitor: Failed to load new event: \(error)")
        }
    }

    /// Tracks an error for frequency detection
    private func trackError(_ event: MCPExternalClientEvent) {
        // Prune old errors outside the tracking window
        let cutoff = Date().addingTimeInterval(-errorTrackingWindow)
        recentErrors.removeAll { $0.timestamp < cutoff }

        // Add the new error
        recentErrors.append((event.clientName, event.code, event.timestamp))
    }

    /// Counts how many similar errors (same client + same code) occurred recently
    private func countSimilarRecentErrors(to event: MCPExternalClientEvent) -> Int {
        let cutoff = Date().addingTimeInterval(-errorTrackingWindow)
        return recentErrors.count(where: { entry in
            entry.timestamp >= cutoff &&
                entry.clientName == event.clientName &&
                entry.code == event.code
        })
    }

    /// Finds the latest event file that should be displayed in the UI.
    /// Skips ignorable events (like host disconnects from older CLI versions).
    private func findLatestDisplayableEventFile() -> URL? {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Filter for CLI event files and sort by name (which includes timestamp)
        let eventFiles = contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("cli-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // Descending by filename

        // Find the first event that should be displayed (not ignorable)
        for fileURL in eventFiles {
            if let event = try? loadEvent(from: fileURL), !event.isIgnorableForUI {
                return fileURL
            }
        }

        return nil
    }

    /// Finds the absolute latest event file (for tracking purposes, even if ignorable)
    private func findLatestEventFile() -> URL? {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Filter for CLI event files and sort by name (which includes timestamp)
        let eventFiles = contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("cli-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // Descending by filename

        return eventFiles.first
    }

    private func loadEvent(from url: URL) throws -> MCPExternalClientEvent {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPExternalClientEvent.self, from: data)
    }
}

// MARK: - Event Cleanup

extension MCPExternalEventsMonitor {
    /// Removes old event files (older than maxAge)
    func cleanupOldEvents(maxAge: TimeInterval = 7 * 24 * 3600) {
        let fileManager = FileManager.default
        let cutoffDate = Date().addingTimeInterval(-maxAge)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in contents where fileURL.pathExtension == "json" {
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoffDate
            else {
                continue
            }

            try? fileManager.removeItem(at: fileURL)
        }
    }
}
