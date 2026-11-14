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
    package init(
        fileID: UUID,
        relativePath: String,
        renderedDisplayPath: String,
        isCodemapRequested: Bool,
        ranges: [LineRange]?,
        cachedFullTokenCount: Int?,
        loadedContent: String?,
        codeMapContent: String?,
        availableCodeMapTokenCount: Int
    ) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.renderedDisplayPath = renderedDisplayPath
        self.isCodemapRequested = isCodemapRequested
        self.ranges = ranges
        self.cachedFullTokenCount = cachedFullTokenCount
        self.loadedContent = loadedContent
        self.codeMapContent = codeMapContent
        self.availableCodeMapTokenCount = availableCodeMapTokenCount
    }
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
    package init(
        promptText: String,
        selectedInstructionsText: String,
        duplicateUserInstructionsAtTop: Bool,
        promptEntries: [PromptFileEntrySnapshot],
        fileTree: TokenCalculationFileTreeInput
    ) {
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.promptEntries = promptEntries
        self.fileTree = fileTree
    }
}
