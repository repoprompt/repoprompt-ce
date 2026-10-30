package enum CodexProcessConfiguration {
    package enum ReasoningSummary: String {
        case auto
        case concise
        case detailed
        case none
    }

    package struct FeaturePolicy: Equatable {
        package var goalsEnabled: Bool
        package var memoriesEnabled: Bool
        package var computerUseEnabled: Bool
        package var capabilities: CodexCapabilitySettings

        package init(goalsEnabled: Bool, memoriesEnabled: Bool, computerUseEnabled: Bool, capabilities: CodexCapabilitySettings) {
            self.goalsEnabled = goalsEnabled
            self.memoriesEnabled = memoriesEnabled
            self.computerUseEnabled = computerUseEnabled
            self.capabilities = capabilities
        }

        package static let defaultDisabled = FeaturePolicy(
            goalsEnabled: false,
            memoriesEnabled: false,
            computerUseEnabled: false,
            capabilities: .disabled
        )
        package static let enabledForGoals = FeaturePolicy(
            goalsEnabled: true,
            memoriesEnabled: false,
            computerUseEnabled: false,
            capabilities: .disabled
        )
        package static func resolved(
            goalsEnabled: Bool,
            memoriesEnabled: Bool,
            computerUseEnabled: Bool,
            capabilities: CodexCapabilitySettings = .disabled
        ) -> FeaturePolicy {
            FeaturePolicy(
                goalsEnabled: goalsEnabled,
                memoriesEnabled: memoriesEnabled,
                computerUseEnabled: computerUseEnabled,
                capabilities: capabilities
            )
        }
    }
}
