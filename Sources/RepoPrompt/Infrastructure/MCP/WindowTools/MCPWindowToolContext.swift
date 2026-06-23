import Foundation
import RepoPromptCore

/// Narrow per-call context handed to extracted window-tool providers.
struct MCPWindowToolContext {
    let toolName: String
    let windowID: Int
    let runtimeRequest: MCPRuntimeRequestContext?

    var runtimeID: WorkspaceRuntimeID? {
        runtimeRequest?.runtimeID
    }

    var adapterTicket: MCPRuntimeAdapterTicket? {
        runtimeRequest?.adapterTicket
    }
}
