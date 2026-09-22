import Foundation

/// Narrow per-call context handed to extracted window-tool providers.
struct MCPAppToolInvocation {
    let toolName: String
    let windowID: Int
}
