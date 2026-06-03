import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentWorkspaceRootsSidebarStoreTests: XCTestCase {
    func testRowsMarkPrimaryAndMovementForMultipleRoots() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        let rootC = makeProjection(name: "C", path: "/tmp/C")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [rootA, rootB, rootC])

        XCTAssertEqual(rows.map(\.id), [rootA.id, rootB.id, rootC.id])
        XCTAssertEqual(rows.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(rows.map(\.fullPath), ["/tmp/A", "/tmp/B", "/tmp/C"])
        XCTAssertEqual(rows.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(rows.map(\.canMoveUp), [false, true, true])
        XCTAssertEqual(rows.map(\.canMoveDown), [true, true, false])
        XCTAssertEqual(rows.map(\.standardizedFullPath), [rootA.standardizedFullPath, rootB.standardizedFullPath, rootC.standardizedFullPath])
        XCTAssertEqual(rows.map(\.worktree), [nil, nil, nil])
        XCTAssertEqual(rows.map(\.gitContext), [nil, nil, nil])
    }

    func testRowsDoNotMarkSingleRootAsPrimaryOrMovable() {
        let root = makeProjection(name: "Only", path: "/tmp/Only")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [root])

        XCTAssertEqual(rows, [
            AgentWorkspaceRootRow(
                id: root.id,
                name: "Only",
                fullPath: "/tmp/Only",
                standardizedFullPath: root.standardizedFullPath,
                isPrimary: false,
                canMoveUp: false,
                canMoveDown: false
            )
        ])
    }

    func testRowsAttachGitContextByStandardizedRootPathWithoutChangingOrder() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        let contextB = makeGitContext(repository: "Repo", worktree: "B", branch: "feature/b")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [rootA, rootB]) { path in
            path == rootB.standardizedFullPath ? contextB : nil
        }

        XCTAssertEqual(rows.map(\.id), [rootA.id, rootB.id])
        XCTAssertEqual(rows.map(\.isPrimary), [true, false])
        XCTAssertNil(rows[0].gitContext)
        XCTAssertEqual(rows[1].gitContext, contextB)
        XCTAssertEqual(rows[1].gitContext?.breadcrumbText, "Repo / B / feature/b")
    }

    // MARK: - Worktree indicators (Item 10)

    func testWithWorktreeAttachesIndicatorWithoutMutatingOtherFields() {
        let base = AgentWorkspaceRootRow(
            id: UUID(),
            name: "Repo",
            fullPath: "/tmp/Repo",
            isPrimary: true,
            canMoveUp: false,
            canMoveDown: true
        )
        let indicator = makeIndicator()

        let enriched = base.withWorktree(indicator)

        XCTAssertNil(base.worktree)
        XCTAssertEqual(enriched.worktree, indicator)
        XCTAssertEqual(enriched.id, base.id)
        XCTAssertEqual(enriched.name, base.name)
        XCTAssertEqual(enriched.fullPath, base.fullPath)
        XCTAssertEqual(enriched.standardizedFullPath, base.standardizedFullPath)
        XCTAssertEqual(enriched.isPrimary, base.isPrimary)
        XCTAssertEqual(enriched.canMoveUp, base.canMoveUp)
        XCTAssertEqual(enriched.canMoveDown, base.canMoveDown)
        XCTAssertEqual(enriched.gitContext, base.gitContext)
    }

    func testWithWorktreePreservesGitContext() {
        let context = makeGitContext(repository: "Repo", worktree: "repo", branch: "main")
        let base = AgentWorkspaceRootRow(
            id: UUID(),
            name: "Repo",
            fullPath: "/tmp/Repo",
            isPrimary: true,
            canMoveUp: false,
            canMoveDown: true,
            gitContext: context
        )
        let indicator = makeIndicator()

        let enriched = base.withWorktree(indicator)

        XCTAssertEqual(enriched.gitContext, context)
        XCTAssertEqual(enriched.worktree, indicator)
    }

    func testIndicatorMakePrefersBindingColorAndLabel() {
        let summary = makeSummary(visualLabel: "feature-x", visualColorHex: "#1a2b3c")
        let identity = WorktreeVisualIdentity(
            label: "global-label",
            colorHex: "#FFFFFF",
            iconName: "leaf.fill",
            markerStyle: .ring
        )

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        XCTAssertEqual(indicator.label, "feature-x")
        // Binding color wins and is normalized to uppercase.
        XCTAssertEqual(indicator.colorHex, "#1A2B3C")
        // Icon/marker are sourced from the resolved global identity.
        XCTAssertEqual(indicator.iconName, "leaf.fill")
        XCTAssertEqual(indicator.markerStyle, .ring)
        XCTAssertTrue(indicator.isAvailable)
        XCTAssertEqual(indicator.capsuleText, "WT feature-x")
    }

    func testIndicatorMakeFallsBackToResolvedIdentityForMissingOrInvalidFields() {
        let summary = makeSummary(
            visualLabel: nil,
            visualColorHex: "not-a-color",
            worktreeName: nil,
            branch: "rp/agent/abc-feature"
        )
        let identity = WorktreeVisualIdentity(
            label: nil,
            colorHex: "#0A0B0C",
            iconName: "circle.fill",
            markerStyle: .dot
        )

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        // Invalid binding color falls back to the resolved identity color.
        XCTAssertEqual(indicator.colorHex, "#0A0B0C")
        // Label falls through to the branch when no labels are set.
        XCTAssertEqual(indicator.label, "rp/agent/abc-feature")
    }

    func testIndicatorLabelFallsBackToWorktreeIDTail() {
        let summary = makeSummary(
            visualLabel: nil,
            visualColorHex: nil,
            worktreeName: nil,
            branch: nil
        )
        let identity = WorktreeVisualIdentity(colorHex: "#101112")

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        XCTAssertEqual(indicator.label, "89abcdef")
    }

    func testIndicatorUnavailableSurfacesStaleStateInTooltipAndAccessibility() {
        let summary = makeSummary(visualLabel: "feature-x", visualColorHex: "#112233")
        let identity = WorktreeVisualIdentity(colorHex: "#112233")

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: false
        )

        XCTAssertFalse(indicator.isAvailable)
        XCTAssertTrue(indicator.tooltipText.contains("unavailable"))
        XCTAssertTrue(indicator.tooltipText.contains("feature-x"))
        XCTAssertTrue(indicator.accessibilityText.contains("unavailable"))
    }

    private func makeSummary(
        visualLabel: String? = "feature-x",
        visualColorHex: String? = "#123456",
        worktreeName: String? = "wt-name",
        branch: String? = "main"
    ) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: "binding-1",
            repositoryID: "gitrepo_abc",
            repoKey: "repo",
            logicalRootPath: "/tmp/Repo",
            logicalRootName: "Repo",
            worktreeID: "wt_0123456789abcdef",
            worktreeRootPath: "/tmp/Repo-wt",
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: Date()
        )
    }

    private func makeGitContext(
        repository: String,
        worktree: String,
        branch: String?
    ) -> GitWorktreeContextSummary {
        GitWorktreeContextSummary(
            repositoryID: "gitrepo-test",
            repoKey: "repo-test",
            repositoryDisplayName: repository,
            worktreeID: "wt-test",
            worktreePath: "/tmp/\(worktree)",
            worktreeName: worktree,
            branch: branch,
            head: "1234567890abcdef",
            isDetached: false
        )
    }

    private func makeIndicator() -> AgentWorktreeIndicator {
        AgentWorktreeIndicator.make(
            summary: makeSummary(),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#123456"),
            isAvailable: true
        )
    }

    private func makeProjection(
        id: UUID = UUID(),
        name: String,
        path: String,
        isSystemRoot: Bool = false
    ) -> WorkspaceRootShellProjection {
        WorkspaceRootShellProjection(
            id: id,
            name: name,
            fullPath: path,
            standardizedFullPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            isSystemRoot: isSystemRoot
        )
    }
}
