import Foundation

package struct PromptFileEntrySnapshot {
    package let fileID: UUID
    package let relativePath: String
    package let isCodemapRequested: Bool
    package let ranges: [LineRange]?
    package let cachedFullTokenCount: Int?
    package let loadedContent: String?
    package let codeMapContent: String?
    package let availableCodeMapTokenCount: Int

    package init(
        fileID: UUID,
        relativePath: String,
        isCodemapRequested: Bool,
        ranges: [LineRange]?,
        cachedFullTokenCount: Int?,
        loadedContent: String?,
        codeMapContent: String?,
        availableCodeMapTokenCount: Int
    ) {
        self.fileID = fileID
        self.relativePath = relativePath
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
