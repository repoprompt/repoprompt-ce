//
//  PromptAssemblyBuilder.swift
//  RepoPromptCore
//
//  Created by Eric Provencher on 2025-04-16.
//

import Foundation

public enum PromptAssemblyLayout: Equatable, Sendable {
    /// Existing behavior: append fragments as-is and ensure each included fragment ends in a newline.
    case lineTerminatedFragments

    /// Normalize fragments by trimming trailing newlines and separating included fragments with one blank line.
    case blankLineSeparatedFragments
}

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
        build(layout: .lineTerminatedFragments)
    }

    public func build(layout: PromptAssemblyLayout) -> String {
        switch layout {
        case .lineTerminatedFragments:
            buildLineTerminatedFragments()
        case .blankLineSeparatedFragments:
            buildBlankLineSeparatedFragments()
        }
    }

    /// Convenience static wrapper.
    public static func build(
        order: [PromptSection],
        disabled: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        snippets: [PromptSection: String]
    ) -> String {
        build(
            order: order,
            disabled: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets,
            layout: .lineTerminatedFragments
        )
    }

    public static func build(
        order: [PromptSection],
        disabled: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        snippets: [PromptSection: String],
        layout: PromptAssemblyLayout
    ) -> String {
        PromptAssemblyBuilder(
            order: order,
            disabled: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            snippets: snippets
        ).build(layout: layout)
    }

    private func buildLineTerminatedFragments() -> String {
        var output = ""
        for snippet in orderedSnippets() {
            output += snippet
            if !snippet.hasSuffix("\n") { output += "\n" }
        }
        return output
    }

    private func buildBlankLineSeparatedFragments() -> String {
        let fragments = orderedSnippets()
            .map(Self.trimmingTrailingNewlines)
            .filter { !$0.isEmpty }
        return fragments.joined(separator: "\n\n")
    }

    private func orderedSnippets() -> [String] {
        var ordered: [String] = []
        if policy.duplicateUserInstructionsAtTop,
           let user = snippets[.userInstructions],
           user.isEmpty == false
        {
            ordered.append(user)
        }

        for section in policy.sectionOrder where !policy.disabledSections.contains(section) {
            guard let snippet = snippets[section], snippet.isEmpty == false else { continue }
            ordered.append(snippet)
        }
        return ordered
    }

    private static func trimmingTrailingNewlines(_ value: String) -> String {
        var trimmed = value
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
