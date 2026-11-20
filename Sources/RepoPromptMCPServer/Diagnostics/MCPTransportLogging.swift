import Foundation

/// Centralized debug logging control for MCP transport layer.
/// Set flags to false to reduce console spam.
package enum MCPDebugLogging {
    private static var envDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    }

    /// Log transport-level details (send/receive byte counts, message previews)
    package static var transportVerbose = envDebugEnabled

    /// Log connection lifecycle events (connect, disconnect, EOF)
    package static var connectionLifecycle = envDebugEnabled

    /// Log routing decisions and tab context binding
    package static var routing = envDebugEnabled

    /// Log all debug messages (master switch - overrides individual flags when false)
    package static var enabled = envDebugEnabled
}

/// Logs MCP transport-level debug messages when enabled.
@inline(__always)
package func mcpTransportLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.transportVerbose {
            print("[MCPTransport] \(message())")
            fflush(stdout)
        }
    #endif
}

/// Logs MCP connection lifecycle debug messages when enabled.
@inline(__always)
package func mcpConnectionLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.connectionLifecycle {
            print("[MCPConnection] \(message())")
            fflush(stdout)
        }
    #endif
}

/// Logs MCP routing debug messages when enabled.
@inline(__always)
package func mcpRoutingDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.routing {
            print("[MCPRouting] \(message())")
        }
    #endif
}
