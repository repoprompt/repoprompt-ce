import RepoPromptShared

/// One boxed owner shared by app adapters and the server publication boundary.
package enum MCPToolDispatchContextValues {
    package static let authorization = BoxedTaskLocal<MCPToolDispatchAuthorization?>(nil)
    package static let explicitWindowHint = BoxedTaskLocal<MCPExplicitWindowRoutingHint?>(nil)
}
