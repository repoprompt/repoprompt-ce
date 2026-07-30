import Foundation

struct PromptFileEntry {
    let file: FileViewModel
    let codemap: WorkspaceCodemapUIPresentationEntry?
    let ranges: [LineRange]?
    let role: ResolvedPromptFileEntryRole = .ordinary

    var isCodemap: Bool {
        codemap != nil
    }
}
