import Foundation

/// Represents an entry in a prompt file, containing a file view model, a flag for codemap, and optional line ranges.
struct PromptFileEntry {
    let file: FileViewModel
    let isCodemap: Bool
    let ranges: [LineRange]?
}
