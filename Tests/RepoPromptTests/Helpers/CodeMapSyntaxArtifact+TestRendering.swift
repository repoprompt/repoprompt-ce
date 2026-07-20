import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore

extension CodeMapSyntaxArtifact {
    func renderedCodeMap(displayPath: String) -> String {
        CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: imports
        ) + apiDescription
    }
}
