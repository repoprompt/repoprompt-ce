import Foundation

extension DecisionServiceCapabilities {
    /// The shared advertised limits of the two finite-choice routing backends.
    static var routingBackend: Self {
        .init(
            contextKinds: [.text],
            finiteChoice: .init(
                minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
                maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
                maximumAggregateBytes: 128 * 1024
            ),
            evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
        )
    }

    func supportsAutomaticTextChoice(instructions: String) -> Bool {
        contextKinds.contains(.text)
            && finiteChoice.minimumChoices <= 2
            && finiteChoice.maximumChoices >= 2
            && finiteChoice.maximumContextBytes >= 2048
            && finiteChoice.maximumInstructionsBytes >= instructions.utf8.count
            && finiteChoice.maximumChoiceDescriptionBytes >= 128
            && finiteChoice.maximumAggregateBytes >= 4096
    }
}
