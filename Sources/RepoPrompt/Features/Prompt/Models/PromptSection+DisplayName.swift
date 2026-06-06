import RepoPromptCore

extension PromptSection {
    var displayName: String {
        switch self {
        case .fileMap: "File Tree"
        case .fileContents: "File Contents"
        case .gitDiff: "Git Diff"
        case .metaPrompts: "Meta Prompts"
        case .userInstructions: "User Instructions"
        }
    }
}
