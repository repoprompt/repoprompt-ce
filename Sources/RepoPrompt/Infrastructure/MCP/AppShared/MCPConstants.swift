import Foundation
import RepoPromptShared

/// Centralised constants used by the MCP layer.
/// TCP/Bonjour transport has been removed – only the UNIX bootstrap socket is used.
enum MCPConstants {
    // Debug tag appended to service names in debug builds to prevent
    // accidentally connecting debug clients to production servers.
    #if DEBUG
        static let debugTag = "-DEBUG"
    #else
        static let debugTag = ""
    #endif

    /// Helper to expose the current build flavor in a structured way.
    static var buildFlavor: MCPBuildFlavor {
        debugTag.isEmpty ? .release : .debug
    }

    /// Service version tag for protocol compatibility.
    /// Bump this when making breaking changes to force old CLIs to exit.
    /// MCP2 -> MCP3: Added kill signal semantics and culling heuristics.
    /// MCP3 -> MCP4: Added client identity caching for reconnects, improved retry logic.
    static let serviceVersionTag = "-MCP4"

    /// Bootstrap socket protocol version number.
    /// CLI sends this in handshake; app can reject incompatible versions.
    static let bootstrapProtocolVersion = MCPBootstrapProtocol.currentVersion

    /// Content context identifier for heartbeat frames.
    static let hbContextID = "com.repoprompt.mcp.heartbeat"
}
