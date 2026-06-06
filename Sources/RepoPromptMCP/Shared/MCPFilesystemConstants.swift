import Foundation
import RepoPromptShared

// MARK: - MCP Debug Logging

#if DEBUG
    private var mcpFilesystemConstantsDebugLoggingEnabled = false
    private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {
        guard mcpFilesystemConstantsDebugLoggingEnabled else { return }
        print("[MCPFilesystemConstants] \(message())")
    }
#else
    private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Centralized debug logging control for MCP transport layer.
/// Set flags to false to reduce console spam.
enum MCPDebugLogging {
    /// Log transport-level details (send/receive byte counts, message previews)
    static var transportVerbose = false

    /// Log connection lifecycle events (connect, disconnect, EOF)
    static var connectionLifecycle = false

    /// Log routing decisions and tab context binding
    static var routing = false

    /// Log all debug messages (master switch - overrides individual flags when false)
    static var enabled = false
}

/// Logs MCP transport-level debug messages when enabled.
@inline(__always)
func mcpTransportLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.transportVerbose {
            print("[MCPTransport] \(message())")
        }
    #endif
}

/// Logs MCP connection lifecycle debug messages when enabled.
@inline(__always)
func mcpConnectionLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.connectionLifecycle {
            print("[MCPConnection] \(message())")
        }
    #endif
}

/// Logs MCP routing debug messages when enabled.
@inline(__always)
func mcpRoutingDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.routing {
            print("[MCPRouting] \(message())")
        }
    #endif
}

enum MCPFilesystemConstants {
    #if DEBUG
        static let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
    #else
        static let identity = MCPFilesystemIdentity.repoPromptCE(.release)
    #endif

    static var socketDirName: String {
        identity.socketDirectoryName
    }

    static var socketVersion: Int {
        identity.protocolVersion
    }

    static var bootstrapSocketName: String {
        identity.bootstrapSocketName
    }

    static func socketDirectoryURL() -> URL {
        identity.socketDirectoryURL()
    }

    @discardableResult
    static func ensureSocketDirectoryExists() -> Bool {
        let url = socketDirectoryURL()
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            return true
        }

        do {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            mcpFilesystemConstantsDebugLog("Failed to create socket directory: \(error)")
            return false
        }
    }

    static func bootstrapSocketURL() -> URL {
        identity.bootstrapSocketURL()
    }

    static func eventsDirectoryURL() -> URL {
        identity.externalEventsDirectoryURL()
    }
}
