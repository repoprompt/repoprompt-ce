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
            PromptAssemblyBuilder.build(
                order: policy.sectionOrder,
                disabled: [.fileContents],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nUSER\n\nMAP\n"
        )
    }
}
