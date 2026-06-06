//
//  PromptAssemblyBuilder.swift
//  RepoPromptCore
//
//  Created by Eric Provencher on 2025-04-16.
//

import Foundation

/// Combines independently produced snippets in a caller-supplied order.
public struct PromptAssemblyBuilder {
    public static let defaultSectionOrder: [PromptSection] = [
        .fileMap,
        .fileContents,
        .gitDiff,
        .metaPrompts,
        .userInstructions
    ]

    public let policy: PromptRenderPolicy
    public let snippets: [PromptSection: String]

    public init(policy: PromptRenderPolicy, snippets: [PromptSection: String]) {
        self.policy = policy
        self.snippets = snippets
    }

    public init(
        order: [PromptSection],
        disabled: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        snippets: [PromptSection: String]
    ) {
        self.init(
            policy: PromptRenderPolicy(
                sectionOrder: order,
                disabledSections: disabled,
                duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
            ),
            snippets: snippets
        )
    }

    public func build() -> String {
        var output = ""
        if policy.duplicateUserInstructionsAtTop,
           let user = snippets[.userInstructions],
           user.isEmpty == false
        {
            output += user.hasSuffix("\n") ? user : (user + "\n")
        }

        for section in policy.sectionOrder where !policy.disabledSections.contains(section) {
            guard let snippet = snippets[section], snippet.isEmpty == false else { continue }
            output += snippet
            if !snippet.hasSuffix("\n") { output += "\n" }
        }
        return output
    }

    /// Convenience static wrapper.
    public static func build(
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
