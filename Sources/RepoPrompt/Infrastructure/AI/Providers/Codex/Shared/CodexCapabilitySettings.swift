struct CodexCapabilitySettings: Equatable {
    let appsEnabled: Bool
    let pluginsEnabled: Bool
    let mcpElicitationEnabled: Bool
    let toolSuggestionsEnabled: Bool

    static let disabled = CodexCapabilitySettings(
        appsEnabled: false,
        pluginsEnabled: false,
        mcpElicitationEnabled: false,
        toolSuggestionsEnabled: false
    )
}
