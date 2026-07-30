import RepoPromptCodeMapCore

extension CodeMapSyntaxArtifact {
    var apiTokenCount: Int {
        TokenCalculationService.estimateTokens(for: apiDescription)
    }
}

extension CodeMapAPIContentFormatter {
    static func pathAndImportsBlock(displayPath: String, imports: [String]) -> String {
        (["File: \(displayPath)", "Imports:"] + imports.map { "  - \($0)" }).joined(separator: "\n")
    }
}
