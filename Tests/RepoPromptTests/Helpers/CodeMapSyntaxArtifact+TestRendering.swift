import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
@testable import RepoPromptWorkspaceContext

extension CodeMapSyntaxArtifact {
    func renderedCodeMap(displayPath: String) -> String {
        CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: imports
        ) + apiDescription
    }
}
