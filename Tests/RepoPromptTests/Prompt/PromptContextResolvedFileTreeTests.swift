@testable import RepoPromptApp
import XCTest

final class PromptContextResolvedFileTreeTests: XCTestCase {
    func testResolvedFileTreeRenderingTruthTable() {
        let scenarios: [(name: String, includeFileTree: Bool, fileTreeMode: FileTreeOption, rendersFileTree: Bool, effectiveMode: FileTreeOption)] = [
            ("included none mode", true, .none, false, .none),
            ("disabled selected mode", false, .selected, false, .none),
            ("included selected mode", true, .selected, true, .selected),
            ("included auto mode", true, .auto, true, .auto)
        ]

        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.name) { _ in
                let context = makeContext(
                    includeFileTree: scenario.includeFileTree,
                    fileTreeMode: scenario.fileTreeMode
                )

                XCTAssertEqual(context.rendersFileTree, scenario.rendersFileTree)
                XCTAssertEqual(context.effectiveFileTreeMode, scenario.effectiveMode)
            }
        }
    }

    private func makeContext(
        includeFileTree: Bool,
        fileTreeMode: FileTreeOption
    ) -> PromptContextResolved {
        PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: true,
            includeFileTree: includeFileTree,
            fileTreeMode: fileTreeMode,
            codeMapUsage: .auto,
            gitInclusion: .none,
            storedPromptIds: nil
        )
    }
}
