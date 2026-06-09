import RepoPromptCore
import XCTest

final class PromptAssemblyBuilderTests: XCTestCase {
    func testSectionIdentityAndDefaultOrderRemainStable() {
        XCTAssertEqual(PromptSection.allCases.map(\.rawValue), [
            "fileMap",
            "fileContents",
            "metaPrompts",
            "userInstructions",
            "gitDiff"
        ])
        XCTAssertEqual(PromptAssemblyBuilder.defaultSectionOrder, [
            .fileMap,
            .fileContents,
            .gitDiff,
            .metaPrompts,
            .userInstructions
        ])
    }

    func testAssemblyPreservesDisabledSectionsDuplicationAndTrailingNewlines() {
        let policy = PromptRenderPolicy(
            sectionOrder: [.metaPrompts, .fileContents, .userInstructions, .fileMap, .gitDiff],
            disabledSections: [.fileContents, .userInstructions],
            duplicateUserInstructionsAtTop: true
        )
        let snippets: [PromptSection: String] = [
            .fileMap: "MAP",
            .fileContents: "FILES\n\n",
            .metaPrompts: "META\n",
            .userInstructions: "USER\n\n",
            .gitDiff: ""
        ]

        XCTAssertEqual(
            PromptAssemblyBuilder(policy: policy, snippets: snippets).build(),
            "USER\n\nMETA\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder(policy: policy, snippets: snippets).build(layout: .lineTerminatedFragments),
            "USER\n\nMETA\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: policy.sectionOrder,
                disabled: [.fileContents],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nUSER\n\nMAP\n"
        )
    }

    func testBlankLineSeparatedLayoutNormalizesFragmentsWithoutChangingDefaultBuild() {
        let policy = PromptRenderPolicy(
            sectionOrder: [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions],
            disabledSections: [.gitDiff],
            duplicateUserInstructionsAtTop: true
        )
        let snippets: [PromptSection: String] = [
            .fileMap: "<file_map>\nTREE\n</file_map>\n",
            .fileContents: "<file_contents>\nFILES\n</file_contents>\n\n",
            .gitDiff: "<git_diff>\nDIFF\n</git_diff>\n",
            .metaPrompts: "<meta>\nMETA\n</meta>",
            .userInstructions: "<user>\nUSER\n</user>\n\n"
        ]
        let builder = PromptAssemblyBuilder(policy: policy, snippets: snippets)

        XCTAssertEqual(
            builder.build(),
            "<user>\nUSER\n</user>\n\n<file_map>\nTREE\n</file_map>\n<file_contents>\nFILES\n</file_contents>\n\n<meta>\nMETA\n</meta>\n<user>\nUSER\n</user>\n\n"
        )
        XCTAssertEqual(
            builder.build(layout: .blankLineSeparatedFragments),
            "<user>\nUSER\n</user>\n\n<file_map>\nTREE\n</file_map>\n\n<file_contents>\nFILES\n</file_contents>\n\n<meta>\nMETA\n</meta>\n\n<user>\nUSER\n</user>"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: policy.sectionOrder,
                disabled: policy.disabledSections,
                duplicateUserInstructionsAtTop: policy.duplicateUserInstructionsAtTop,
                snippets: snippets,
                layout: .blankLineSeparatedFragments
            ),
            builder.build(layout: .blankLineSeparatedFragments)
        )
    }
}
