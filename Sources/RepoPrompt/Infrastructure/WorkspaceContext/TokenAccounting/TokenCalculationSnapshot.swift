import Foundation

struct PromptFileEntrySnapshot {
    let fileID: UUID
    let relativePath: String
    let renderedDisplayPath: String
    let isCodemapRequested: Bool
    let ranges: [LineRange]?
    let cachedFullTokenCount: Int?
    let loadedContent: String?
    let codeMapContent: String?
    let availableCodeMapTokenCount: Int
}

enum TokenCalculationFileTreeInput {
    case none
    case rendered(String)
    case snapshot(FileTreeSelectionSnapshot)
}

struct TokenCalculationSnapshot {
    let promptText: String
    let selectedInstructionsText: String
    let duplicateUserInstructionsAtTop: Bool
    let promptEntries: [PromptFileEntrySnapshot]
    let fileTree: TokenCalculationFileTreeInput
}
