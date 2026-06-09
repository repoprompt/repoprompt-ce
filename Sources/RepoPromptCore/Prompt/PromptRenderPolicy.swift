public struct PromptRenderPolicy: Equatable, Sendable {
    public let sectionOrder: [PromptSection]
    public let disabledSections: Set<PromptSection>
    public let duplicateUserInstructionsAtTop: Bool

    public init(
        sectionOrder: [PromptSection],
        disabledSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool
    ) {
        self.sectionOrder = sectionOrder
        self.disabledSections = disabledSections
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
    }
}
