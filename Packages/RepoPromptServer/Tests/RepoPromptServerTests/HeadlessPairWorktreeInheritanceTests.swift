import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class HeadlessPairWorktreeInheritanceTests: XCTestCase {
    func testChildPairInheritsRootWorktreeForReadsAndReportEdits() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-pair-worktree-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let command = LocalWorkspaceCommandRunner()
        try "canonical checkout".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", source.path], workingDirectory: base.path, maximumBytes: 65536)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", source.path, "add", "README.md"], workingDirectory: source.path, maximumBytes: 65536)
        _ = try await command.run(
            executable: "/usr/bin/git",
            arguments: ["-C", source.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"],
            workingDirectory: source.path,
            maximumBytes: 65536
        )

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store)
        )
        let actor = ExternalActor(userID: "pair", username: "pair", displayName: "Pair")
        let project = try await authority.createProject(
            input: .init(name: "Investigate", roots: [.init(logicalName: "source", path: source.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "pair-project",
            requestDigest: "pair-project"
        )
        let parent = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "pair-parent",
            requestDigest: "pair-parent"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let parentBinding = RepoPromptMCPBinding(sessionID: parent.sessionID, actor: actor)
        let report = "docs/investigations/pair-report.md"
        let seed = "# Investigation\n\n## Investigator Findings\n"
        _ = try await adapter.invoke(
            toolName: "apply_edits",
            argumentsJSON: json(["path": report, "rewrite": seed]),
            binding: parentBinding
        )

        let parentBindings = try await authority.worktreeSnapshots(projectID: project.projectID)
        let worktree = try XCTUnwrap(parentBindings.first { $0.sessionID == parent.sessionID && $0.ownershipState == .active })
        let worktreeReport = URL(fileURLWithPath: worktree.physicalPath).appendingPathComponent(report)
        let canonicalReport = source.appendingPathComponent(report)
        XCTAssertEqual(try String(contentsOf: worktreeReport, encoding: .utf8), seed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalReport.path))

        let child = try await authority.spawnChildSession(
            parentSessionID: parent.sessionID,
            initialPrompt: "Investigate the harness. Append findings to \(report).",
            role: "pair",
            label: "Investigate: harness"
        )
        let childWorktrees = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).worktrees
        XCTAssertTrue(childWorktrees.contains { $0.bindingID == worktree.bindingID })

        let childBinding = RepoPromptMCPBinding(sessionID: child.sessionID, actor: actor)
        let readData = try await adapter.invoke(
            toolName: "read_file",
            argumentsJSON: json(["path": report]),
            binding: childBinding
        )
        let read = try JSONSerialization.jsonObject(with: readData) as? [String: Any]
        XCTAssertEqual(read?["content"] as? String, seed)

        let searchData = try await adapter.invoke(
            toolName: "file_search",
            argumentsJSON: json(["pattern": "Investigator Findings"]),
            binding: childBinding
        )
        let search = try JSONSerialization.jsonObject(with: searchData) as? [[String: Any]]
        XCTAssertTrue((search ?? []).contains { ($0["logicalPath"] as? String) == report })

        let findings = "\n- Pair inherited the parent worktree and edited the report.\n"
        _ = try await adapter.invoke(
            toolName: "apply_edits",
            argumentsJSON: json([
                "path": report,
                "search": "## Investigator Findings\n",
                "replace": "## Investigator Findings\n\(findings)"
            ]),
            binding: childBinding
        )
        XCTAssertTrue(try String(contentsOf: worktreeReport, encoding: .utf8).contains("Pair inherited the parent worktree"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalReport.path))
        try await store.close()
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
