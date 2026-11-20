import Foundation
import RepoPromptShared
import RepoPromptWorkspaceContext

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

enum MCPFilesystemConstants {
    static let identity = WorkspaceContextFilesystemIdentity.identity

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
        do {
            _ = try MCPBootstrapDirectory.open(at: socketDirectoryURL(), createIfMissing: true)
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
