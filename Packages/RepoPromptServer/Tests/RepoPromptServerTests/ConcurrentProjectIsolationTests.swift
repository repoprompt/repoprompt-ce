import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ConcurrentProjectIsolationTests: XCTestCase {
    func testConcurrentProjectsIsolateRuntimesSessionsToolsWorktreesAndChildren() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
            .appendingPathComponent(".test-concurrent-isolation-\(UUID().uuidString)", isDirectory: true)
        let alphaRoot = base.appendingPathComponent("alpha", isDirectory: true)
        let betaRoot = base.appendingPathComponent("beta", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", base.path]
            try? chmod.run()
            chmod.waitUntilExit()
            try? FileManager.default.removeItem(at: base)
        }

        try await Self.initializeGitRepository(at: alphaRoot, markerFile: "alpha.txt", marker: "alpha-secret")
        try await Self.initializeGitRepository(at: betaRoot, markerFile: "beta.txt", marker: "beta-secret")

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        let authority = RepoPromptHeadlessAuthority(store: store, worktreeService: worktreeService)
        try await authority.recover()
        let actor = ExternalActor(userID: "iso", username: "iso", displayName: "Isolation")

        let alpha = try await authority.createProject(
            input: .init(name: "Alpha", roots: [.init(logicalName: "source", path: alphaRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "alpha-project",
            requestDigest: "alpha-project"
        )
        let beta = try await authority.createProject(
            input: .init(name: "Beta", roots: [.init(logicalName: "source", path: betaRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "beta-project",
            requestDigest: "beta-project"
        )
        XCTAssertNotEqual(alpha.projectID, beta.projectID)
        let alphaRootID = try XCTUnwrap(alpha.roots.first?.rootID)
        let betaRootID = try XCTUnwrap(beta.roots.first?.rootID)
        XCTAssertNotEqual(alphaRootID, betaRootID)

        let snapshots = await authority.projectSnapshots()
        XCTAssertEqual(Set(snapshots.map(\.projectID)), [alpha.projectID, beta.projectID])

        async let alphaTreeTask = authority.projectTree(projectID: alpha.projectID, request: .init(rootID: alphaRootID))
        async let betaTreeTask = authority.projectTree(projectID: beta.projectID, request: .init(rootID: betaRootID))
        async let alphaSearchTask = authority.projectSearch(projectID: alpha.projectID, request: .init(rootID: alphaRootID, query: "secret"))
        async let betaSearchTask = authority.projectSearch(projectID: beta.projectID, request: .init(rootID: betaRootID, query: "secret"))
        let alphaTree = try await alphaTreeTask
        let betaTree = try await betaTreeTask
        let alphaSearch = try await alphaSearchTask
        let betaSearch = try await betaSearchTask

        let alphaSession = try await authority.createSession(
            input: .init(projectID: alpha.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "alpha"),
            externalActor: actor,
            idempotencyKey: "alpha-session",
            requestDigest: "alpha-session"
        )
        let betaSession = try await authority.createSession(
            input: .init(projectID: beta.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "beta"),
            externalActor: actor,
            idempotencyKey: "beta-session",
            requestDigest: "beta-session"
        )

        XCTAssertEqual(alphaSession.projectID, alpha.projectID)
        XCTAssertEqual(betaSession.projectID, beta.projectID)
        XCTAssertTrue(alphaTree.contains { $0.logicalPath == "alpha.txt" })
        XCTAssertFalse(alphaTree.contains { $0.logicalPath == "beta.txt" })
        XCTAssertTrue(betaTree.contains { $0.logicalPath == "beta.txt" })
        XCTAssertFalse(betaTree.contains { $0.logicalPath == "alpha.txt" })
        XCTAssertEqual(Set(alphaSearch.map(\.preview)), ["alpha-secret"])
        XCTAssertEqual(Set(betaSearch.map(\.preview)), ["beta-secret"])

        do {
            _ = try await authority.projectTree(projectID: alpha.projectID, request: .init(rootID: betaRootID))
            XCTFail("expected foreign root rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        do {
            _ = try await authority.projectFile(
                projectID: beta.projectID,
                request: .init(rootID: alphaRootID, logicalPath: "alpha.txt", maximumBytes: 1024)
            )
            XCTFail("expected foreign file rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }

        let alphaTemplate = try await authority.replaceProjectSelectionTemplate(
            projectID: alpha.projectID,
            entries: [.init(rootID: alphaRootID, logicalPath: "alpha.txt", mode: .full)],
            expectedRevision: 1,
            actor: actor,
            idempotencyKey: "alpha-template",
            requestDigest: "alpha-template"
        )
        XCTAssertEqual(alphaTemplate.entries.map(\.logicalPath), ["alpha.txt"])
        do {
            _ = try await authority.replaceProjectSelectionTemplate(
                projectID: beta.projectID,
                entries: [.init(rootID: alphaRootID, logicalPath: "alpha.txt", mode: .full)],
                expectedRevision: 1,
                actor: actor,
                idempotencyKey: "beta-cross-template",
                requestDigest: "beta-cross-template"
            )
            XCTFail("expected foreign template root rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }

        let alphaChild = try await authority.spawnChildSession(
            parentSessionID: alphaSession.sessionID,
            initialPrompt: "child",
            role: "explore",
            label: "probe"
        )
        XCTAssertEqual(alphaChild.projectID, alpha.projectID)
        XCTAssertEqual(alphaChild.parentSessionID, alphaSession.sessionID)
        XCTAssertEqual(alphaChild.rootSessionID, alphaSession.sessionID)
        let alphaChildren = try await authority.childSessionSnapshots(parentSessionID: alphaSession.sessionID)
        let betaChildren = try await authority.childSessionSnapshots(parentSessionID: betaSession.sessionID)
        XCTAssertEqual(alphaChildren.map(\.sessionID), [alphaChild.sessionID])
        XCTAssertTrue(betaChildren.isEmpty)

        do {
            _ = try await authority.createSession(
                input: .init(
                    projectID: beta.projectID,
                    parentSessionID: alphaSession.sessionID,
                    provider: .codex,
                    visibility: .privateSession
                ),
                externalActor: actor,
                idempotencyKey: "cross-child",
                requestDigest: "cross-child"
            )
            XCTFail("expected public child-session rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }

        async let alphaWorktreeTask = authority.worktreeSnapshots(projectID: alpha.projectID)
        async let betaWorktreeTask = authority.worktreeSnapshots(projectID: beta.projectID)
        let alphaWorktrees = try await alphaWorktreeTask
        let betaWorktrees = try await betaWorktreeTask
        XCTAssertFalse(alphaWorktrees.isEmpty)
        XCTAssertFalse(betaWorktrees.isEmpty)
        XCTAssertTrue(alphaWorktrees.allSatisfy { $0.projectID == alpha.projectID && $0.sessionID == alphaSession.sessionID })
        XCTAssertTrue(betaWorktrees.allSatisfy { $0.projectID == beta.projectID && $0.sessionID == betaSession.sessionID })
        XCTAssertTrue(alphaWorktrees.allSatisfy { $0.physicalPath.localizedCaseInsensitiveContains(alpha.projectID.uuidString) })
        XCTAssertTrue(betaWorktrees.allSatisfy { $0.physicalPath.localizedCaseInsensitiveContains(beta.projectID.uuidString) })
        let alphaBinding = try XCTUnwrap(alphaWorktrees.first)
        do {
            _ = try await authority.worktreeSnapshot(projectID: beta.projectID, bindingID: alphaBinding.bindingID)
            XCTFail("expected foreign worktree rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .notFound)
        }

        let alphaEvents = try await authority.events(after: nil, limit: 200, projectID: alpha.projectID)
        let betaEvents = try await authority.events(after: nil, limit: 200, projectID: beta.projectID)
        XCTAssertFalse(alphaEvents.events.isEmpty)
        XCTAssertFalse(betaEvents.events.isEmpty)
        XCTAssertTrue(alphaEvents.events.allSatisfy { $0.projectID == alpha.projectID })
        XCTAssertTrue(betaEvents.events.allSatisfy { $0.projectID == beta.projectID })
        XCTAssertTrue(alphaEvents.events.contains { $0.sessionID == alphaSession.sessionID })
        XCTAssertFalse(alphaEvents.events.contains { $0.sessionID == betaSession.sessionID })
        XCTAssertTrue(betaEvents.events.contains { $0.sessionID == betaSession.sessionID })
        XCTAssertFalse(betaEvents.events.contains { $0.sessionID == alphaSession.sessionID })
    }

    private static func initializeGitRepository(at root: URL, markerFile: String, marker: String) async throws {
        try marker.write(to: root.appendingPathComponent(markerFile), atomically: true, encoding: .utf8)
        let command = LocalWorkspaceCommandRunner()
        _ = try await command.run(
            executable: "/usr/bin/git",
            arguments: ["init", "-b", "main", root.path],
            workingDirectory: root.path,
            maximumBytes: 65536
        )
        _ = try await command.run(
            executable: "/usr/bin/git",
            arguments: ["-C", root.path, "add", markerFile],
            workingDirectory: root.path,
            maximumBytes: 65536
        )
        _ = try await command.run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", root.path,
                "-c", "user.name=Test",
                "-c", "user.email=test@example.invalid",
                "commit", "-m", "initial",
            ],
            workingDirectory: root.path,
            maximumBytes: 65536
        )
    }
}
