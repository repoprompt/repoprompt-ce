import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceFolderOpenResolverTests: XCTestCase {
    func testNoMatchReturnsNoCandidatesOrWinner() {
        let workspace = makeWorkspace(id: 1, name: "Other", paths: ["/tmp/other"])

        XCTAssertEqual(ids(WorkspaceFolderOpenResolver.eligibleMatches(forFolderPath: "/tmp/selected", in: [workspace])), [])
        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/selected", in: [workspace]))
    }

    func testOneExactMatchReturnsWorkspace() {
        let workspace = makeWorkspace(id: 1, name: "Exact", paths: ["/tmp/selected"])

        XCTAssertEqual(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/selected", in: [workspace])?.id, workspace.id)
    }

    func testSeveralMatchesPreferNewestRegardlessOfInputOrder() {
        let older = makeWorkspace(id: 1, name: "Older", paths: ["/tmp/selected"], modified: 10)
        let newest = makeWorkspace(id: 2, name: "Newest", paths: ["/tmp/selected"], modified: 20)

        XCTAssertEqual(ids(WorkspaceFolderOpenResolver.eligibleMatches(forFolderPath: "/tmp/selected", in: [older, newest])), [newest.id, older.id])
        XCTAssertEqual(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/selected", in: [older, newest])?.id, newest.id)
    }

    func testRecentOrderingUsesFoldedNameExactNameThenUUIDForTies() {
        let alphaLaterID = makeWorkspace(id: 2, name: "alpha", paths: ["/tmp/selected"])
        let alphaEarlierID = makeWorkspace(id: 1, name: "alpha", paths: ["/tmp/selected"])
        let uppercaseAlpha = makeWorkspace(id: 3, name: "Alpha", paths: ["/tmp/selected"])
        let beta = makeWorkspace(id: 4, name: "beta", paths: ["/tmp/selected"])

        XCTAssertEqual(
            ids(WorkspaceRecentOrdering.sorted([beta, alphaLaterID, uppercaseAlpha, alphaEarlierID])),
            [uppercaseAlpha.id, alphaEarlierID.id, alphaLaterID.id, beta.id]
        )
    }

    func testMultiRootAndDuplicateRootsProduceOneCandidate() {
        let workspace = makeWorkspace(
            id: 1,
            name: "Multi",
            paths: ["/tmp/first", "/tmp/selected", "/tmp/selected/./"]
        )

        XCTAssertEqual(ids(WorkspaceFolderOpenResolver.eligibleMatches(forFolderPath: "/tmp/selected", in: [workspace])), [workspace.id])
    }

    func testSystemHiddenAndEphemeralMatchesAreExcluded() {
        let eligible = makeWorkspace(id: 1, name: "Eligible", paths: ["/tmp/selected"], modified: 1)
        let system = makeWorkspace(id: 2, name: "System", paths: ["/tmp/selected"], modified: 4, system: true)
        let hidden = makeWorkspace(id: 3, name: "Hidden", paths: ["/tmp/selected"], modified: 3, hidden: true)
        let ephemeral = makeWorkspace(id: 4, name: "Ephemeral", paths: ["/tmp/selected"], modified: 2, ephemeral: true)

        XCTAssertEqual(
            ids(WorkspaceFolderOpenResolver.eligibleMatches(forFolderPath: "/tmp/selected", in: [system, hidden, ephemeral, eligible])),
            [eligible.id]
        )
        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/selected", in: [system, hidden, ephemeral]))
    }

    func testCanonicalPathVariantsMatch() {
        let homeRoot = "\(NSHomeDirectory())/ResolverProject"
        let workspace = makeWorkspace(id: 1, name: "Variants", paths: [homeRoot])
        let variants = [
            " ~/ResolverProject ",
            "\(NSHomeDirectory())/./ResolverProject/",
            homeRoot.uppercased()
        ]

        for variant in variants {
            XCTAssertEqual(
                WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: variant, in: [workspace])?.id,
                workspace.id,
                "Expected variant to match: \(variant)"
            )
        }
    }

    func testParentAndChildPathsDoNotMatch() {
        let workspace = makeWorkspace(id: 1, name: "Exact only", paths: ["/tmp/root/project"])

        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/root", in: [workspace]))
        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/root/project/child", in: [workspace]))
    }

    func testEmptySelectionAndEmptyWorkspaceRootsDoNotMatch() {
        let blankRoot = makeWorkspace(id: 1, name: "Blank", paths: ["", "   \n"])

        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: " \n", in: [blankRoot]))
        XCTAssertNil(WorkspaceFolderOpenResolver.bestEligibleMatch(forFolderPath: "/tmp/selected", in: [blankRoot]))
    }

    func testEphemeralAdmissionIsExplicitAndNeverAdmitsSystemOrHidden() {
        let ephemeral = makeWorkspace(id: 1, name: "Ephemeral", paths: ["/tmp/selected"], ephemeral: true)
        let systemEphemeral = makeWorkspace(id: 2, name: "System", paths: ["/tmp/selected"], system: true, ephemeral: true)
        let hiddenEphemeral = makeWorkspace(id: 3, name: "Hidden", paths: ["/tmp/selected"], hidden: true, ephemeral: true)

        XCTAssertEqual(ids(WorkspaceFolderOpenResolver.eligibleMatches(forFolderPath: "/tmp/selected", in: [ephemeral])), [])
        XCTAssertEqual(
            ids(WorkspaceFolderOpenResolver.eligibleMatches(
                forFolderPath: "/tmp/selected",
                in: [systemEphemeral, hiddenEphemeral, ephemeral],
                admittingEphemeral: true
            )),
            [ephemeral.id]
        )
    }

    @MainActor
    func testMenuOrderingMatchesRecentOrderingPolicy() async {
        let fixtures = [
            makeWorkspace(id: 4, name: "beta", paths: ["/tmp/four"], modified: 10),
            makeWorkspace(id: 2, name: "alpha", paths: ["/tmp/two"], modified: 10),
            makeWorkspace(id: 3, name: "Alpha", paths: ["/tmp/three"], modified: 10),
            makeWorkspace(id: 1, name: "newest", paths: ["/tmp/one"], modified: 20)
        ]
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()
        manager.workspaces = fixtures

        XCTAssertEqual(ids(manager.workspacesForMenu()), ids(WorkspaceRecentOrdering.sorted(fixtures)))
    }

    private func ids(_ workspaces: [WorkspaceModel]) -> [UUID] {
        workspaces.map(\.id)
    }

    private func makeWorkspace(
        id: Int,
        name: String,
        paths: [String],
        modified: TimeInterval = 0,
        system: Bool = false,
        hidden: Bool = false,
        ephemeral: Bool = false
    ) -> WorkspaceModel {
        WorkspaceModel(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            dateModified: Date(timeIntervalSince1970: modified),
            name: name,
            repoPaths: paths,
            lastUsed: Date(timeIntervalSince1970: 0),
            isSystemWorkspace: system,
            ephemeralFlag: ephemeral,
            isHiddenInMenus: hidden
        )
    }

    @MainActor
    private func makeComposition() -> WindowStateComposition {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowStateCompositionFactory.make(
            windowID: -1200 - Int.random(in: 1 ... 99),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
    }
}
