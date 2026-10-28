struct CodexCapabilitySettings: Equatable {
    let appsEnabled: Bool
    let pluginsEnabled: Bool
    let mcpElicitationEnabled: Bool
    let toolSuggestionsEnabled: Bool

    /// Armed sessions keep structured MCP provenance without enabling unrelated capabilities.
    static let computerUse = CodexCapabilitySettings(
        appsEnabled: false,
        pluginsEnabled: false,
        mcpElicitationEnabled: true,
        toolSuggestionsEnabled: false
    )

    static let disabled = CodexCapabilitySettings(
        appsEnabled: false,
        pluginsEnabled: false,
        mcpElicitationEnabled: false,
        toolSuggestionsEnabled: false
    )
}
