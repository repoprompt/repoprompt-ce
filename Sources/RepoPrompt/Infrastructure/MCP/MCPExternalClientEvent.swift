import Foundation
import RepoPromptShared

// MARK: - User-Facing Descriptions

extension MCPExternalClientEvent {
    /// Whether this event represents an expected/clean termination that should not be surfaced in the UI.
    /// This handles events from older CLI versions that logged host disconnects as connection failures.
    var isIgnorableForUI: Bool {
        // Host disconnects (stdin closed, broken pipe) are expected behavior, not errors
        if code == .connectionFailed,
           humanMessage.lowercased().contains("host disconnected")
        {
            return true
        }
        return false
    }

    /// Client name for display, with fallback
    private var displayClientName: String {
        clientName ?? "An external MCP client"
    }

    /// Returns a user-friendly description suitable for display in the UI.
    /// Surfaces details from the CLI when available for better diagnostics.
    var userFacingDescription: String {
        descriptionWithClientName(displayClientName)
    }

    /// Returns a description using the provided client name (for resolved name scenarios)
    func descriptionWithClientName(_ clientName: String) -> String {
        switch code {
        case .timeoutNoServices:
            return "\(clientName) could not find any MCP services. Ensure RepoPrompt is running and Local Network permission is granted."

        case .timeoutWithCandidates:
            var msg = "\(clientName) found MCP services on the network but none matched this RepoPrompt instance."
            if let candidates = details?["candidates"], !candidates.isEmpty {
                let count = candidates.components(separatedBy: ",").count
                if count == 1 {
                    msg += " Another RepoPrompt instance may be running."
                } else {
                    msg += " Found \(count) other RepoPrompt instances."
                }
            }
            return msg

        case .serviceNameMismatch:
            return "\(clientName) found MCP services but none matched this RepoPrompt instance."

        case .deviceMismatch:
            let serviceCount = details?["found"]?.components(separatedBy: ",").count ?? 0
            if serviceCount > 1 {
                return "\(clientName) found \(serviceCount) RepoPrompt instances on other devices. Make sure RepoPrompt is running on this machine."
            }
            return "\(clientName) found a RepoPrompt instance on another device. Make sure RepoPrompt is running on this machine."

        case .buildFlavorMismatch:
            // This typically only affects developers - show generic version mismatch
            return "\(clientName) found a RepoPrompt instance but there's a version mismatch. Try updating both the app and CLI."

        case .protocolVersionMismatch, .incompatibleServiceVersion:
            return "\(clientName) found an incompatible RepoPrompt version. Update both the app and CLI to the same release."

        case .malformedServiceName:
            return "\(clientName) found MCP services but couldn't connect. The app and CLI may be incompatible versions."

        case .localNetworkPolicyDenied:
            return "\(clientName) was denied Local Network access. Grant permission for both RepoPrompt and the terminal in System Settings."

        case .connectionFailed:
            var msg = "\(clientName) failed to establish a connection."
            if let underlying = details?["underlying"], !underlying.isEmpty {
                if let friendlyError = Self.friendlyErrorMessage(underlying) {
                    msg += " \(friendlyError)"
                }
            }
            return msg

        case .approvalDenied:
            return "\(clientName) connection was denied. Check the MCP approval dialog in RepoPrompt."

        case .unknown:
            return "\(clientName): \(humanMessage)"
        }
    }

    /// Converts raw error strings into user-friendly messages
    private static func friendlyErrorMessage(_ error: String) -> String? {
        let lower = error.lowercased()

        // Connection reset / closed
        if lower.contains("54") || lower.contains("reset") || lower.contains("closed") {
            return "The connection was closed unexpectedly."
        }
        // Connection refused
        if lower.contains("61") || lower.contains("refused") {
            return "Connection refused. Is the MCP server enabled?"
        }
        // Timeout
        if lower.contains("timed out") || lower.contains("timeout") {
            return "The connection timed out."
        }
        // Network unreachable
        if lower.contains("network"), lower.contains("unreachable") {
            return "Network unreachable."
        }
        // Host not found
        if lower.contains("host"), lower.contains("not found") || lower.contains("unknown") {
            return "Could not find the host."
        }

        // Don't show raw technical errors
        return nil
    }

    /// Returns troubleshooting suggestions based on the error code and details
    var troubleshootingSuggestion: String? {
        switch code {
        case .timeoutNoServices:
            return "Check System Settings → Privacy & Security → Local Network. Ensure RepoPrompt is running."

        case .timeoutWithCandidates:
            return "Other RepoPrompt instances were found. Make sure you're connecting to the right one."

        case .localNetworkPolicyDenied:
            return "Open System Settings → Privacy & Security → Local Network and enable for both apps."

        case .serviceNameMismatch:
            return "Verify the correct RepoPrompt instance is running on this machine."

        case .deviceMismatch:
            return "RepoPrompt was found on another device. Ensure it's running on THIS machine."

        case .malformedServiceName, .buildFlavorMismatch:
            return "Try updating both the RepoPrompt app and CLI to the latest version."

        case .protocolVersionMismatch, .incompatibleServiceVersion:
            return "Update both RepoPrompt and the CLI to the latest version."

        case .connectionFailed:
            if let underlying = details?["underlying"]?.lowercased() {
                if underlying.contains("54") || underlying.contains("reset") {
                    return "Connection was reset. The server may have restarted. Try again."
                }
                if underlying.contains("61") || underlying.contains("refused") {
                    return "Connection refused. Ensure the MCP server is enabled in RepoPrompt."
                }
            }
            return "Check that RepoPrompt's MCP server is enabled and try again."

        case .approvalDenied:
            return "The connection was denied. Check the MCP approval dialog in RepoPrompt."

        case .unknown:
            return nil
        }
    }
}

// MARK: - Event Directory

extension MCPExternalClientEvent {
    /// The directory where external client events are stored.
    /// Uses MCPFilesystemConstants for consistent gating by build flavor and version.
    static var eventsDirectoryURL: URL {
        MCPFilesystemConstants.eventsDirectoryURL()
    }

    /// Ensures the events directory exists
    static func ensureEventsDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: eventsDirectoryURL,
            withIntermediateDirectories: true
        )
    }
}
