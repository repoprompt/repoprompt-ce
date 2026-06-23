import Foundation

struct PromptFileEntry {
    let file: FileViewModel
    let isCodemap: Bool
    let ranges: [LineRange]?
    let role: ResolvedPromptFileEntryRole = .ordinary
}
