enum AgentSessionHandoffInstructionsPolicy {
    static let maximumCharacterCount = 20000

    enum Validation: Equatable {
        case valid(count: Int)
        case tooLong(count: Int, maximum: Int)
    }

    static func characterCount(of instructions: String) -> Int {
        instructions.count
    }

    static func validation(of instructions: String) -> Validation {
        let count = characterCount(of: instructions)
        guard count <= maximumCharacterCount else {
            return .tooLong(count: count, maximum: maximumCharacterCount)
        }
        return .valid(count: count)
    }
}
