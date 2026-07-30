//
//  PromptAssemblyBuilder.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-16.
//

import Foundation

/// All blocks that can appear in the final prompt, in *logical* order.
/// The raw value is persisted in UserDefaults, so never rename casually.
enum PromptSection: String, CaseIterable, Identifiable, Codable {
    case fileMap, fileContents, metaPrompts, userInstructions, gitDiff

    var id: String {
        rawValue
    }

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

/// Combines independently‑produced snippets in a caller‑supplied order.
struct PromptAssemblyBuilder {
    static let defaultSectionOrder: [PromptSection] = [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]

    let order: [PromptSection]
    let disabled: Set<PromptSection> // existing switches → pass in
    let duplicateUserInstructionsAtTop: Bool // new toggle
    let snippets: [PromptSection: String] // empty / missing → ignored

    func build() -> String {
        var out = ""
        // optional first User Instructions block
        if duplicateUserInstructionsAtTop,
           let user = snippets[.userInstructions],
           user.isEmpty == false
        {
            out += user.hasSuffix("\n") ? user : (user + "\n")
        }

        for section in order where !disabled.contains(section) {
            guard let snip = snippets[section], snip.isEmpty == false else { continue }
            out += snip
            if !snip.hasSuffix("\n") {
                out += "\n"
            }
        }
        return out
    }

    /// Convenience static wrapper.
    static func build(
        order: [PromptSection],
        disabled: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        snippets: [PromptSection: String]
    ) -> String {
        PromptAssemblyBuilder(
            order: order,
            disabled: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets
        ).build()
    }
}
