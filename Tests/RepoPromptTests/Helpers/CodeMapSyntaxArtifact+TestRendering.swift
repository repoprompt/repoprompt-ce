import Foundation
@testable import RepoPrompt

extension CodeMapSyntaxArtifact {
    func renderedCodeMap(displayPath: String) -> String {
        CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: imports
        ) + apiDescription
    }
}
