package struct CodexCapabilitySettings: Equatable {
    package let appsEnabled: Bool
    package let pluginsEnabled: Bool
    package let mcpElicitationEnabled: Bool
    package let toolSuggestionsEnabled: Bool

    package init(appsEnabled: Bool, pluginsEnabled: Bool, mcpElicitationEnabled: Bool, toolSuggestionsEnabled: Bool) {
        self.appsEnabled = appsEnabled
        self.pluginsEnabled = pluginsEnabled
        self.mcpElicitationEnabled = mcpElicitationEnabled
        self.toolSuggestionsEnabled = toolSuggestionsEnabled
    }

    /// Armed sessions keep structured MCP provenance without enabling unrelated capabilities.
    package static let computerUse = CodexCapabilitySettings(
        appsEnabled: false,
        pluginsEnabled: false,
        mcpElicitationEnabled: true,
        toolSuggestionsEnabled: false
    )

    package static let disabled = CodexCapabilitySettings(
        appsEnabled: false,
        pluginsEnabled: false,
        mcpElicitationEnabled: false,
        toolSuggestionsEnabled: false
    )
}
