import Foundation
import RepoPromptFoundation

package struct PromptFileEntrySnapshot {
    package let fileID: UUID
    package let relativePath: String
    package let renderedDisplayPath: String
    package let isCodemapRequested: Bool
    package let ranges: [LineRange]?
    package let cachedFullTokenCount: Int?
    package let loadedContent: String?
    package let codeMapContent: String?
    package let availableCodeMapTokenCount: Int
}

package enum TokenCalculationFileTreeInput {
    case none
    case rendered(String)
    case snapshot(FileTreeSelectionSnapshot)
}

package struct TokenCalculationSnapshot {
    package let promptText: String
    package let selectedInstructionsText: String
    package let duplicateUserInstructionsAtTop: Bool
    package let promptEntries: [PromptFileEntrySnapshot]
    package let fileTree: TokenCalculationFileTreeInput
}
