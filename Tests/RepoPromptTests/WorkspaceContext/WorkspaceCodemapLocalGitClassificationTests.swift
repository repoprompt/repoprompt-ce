import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapLocalGitClassificationTests: XCTestCase {
    func testPlainDirectoryIsDefinitelyNonGitWithoutExecutingGit() async throws {
        let sandbox = try makeDirectory("plain")
        let siblingRepository = sandbox.deletingLastPathComponent()
            .appendingPathComponent("sibling-repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: siblingRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: siblingRepository) }

        let result = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(sandbox)

        guard case let .definitelyNonGit(proof) = result else {
            return XCTFail("Expected a terminal non-Git proof, got \(result)")
        }
        XCTAssertTrue(WorkspaceCodemapLocalGitClassificationProbe.production.validate(proof))
    }

    func testWorktreeSubdirectoryRequiresGitPreflight() async throws {
        let root = try makeDirectory("worktree")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let subdirectory = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let result = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(subdirectory)

        XCTAssertEqual(result, .requiresGitPreflight)
    }

    func testLinkedWorktreeGitFileRequiresGitPreflight() async throws {
        let root = try makeDirectory("linked")
        try "gitdir: ../repository/.git/worktrees/linked\n".write(
            to: root.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let result = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(root)

        XCTAssertEqual(result, .requiresGitPreflight)
    }

    func testBareLikeOrPermissionAmbiguousRootRequiresGitPreflight() async throws {
        let bare = try makeDirectory("bare")
        try "ref: refs/heads/main\n".write(
            to: bare.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: bare.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        let missing = bare.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)

        let bareResult = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(bare)
        let missingResult = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(missing)
        XCTAssertEqual(bareResult, .requiresGitPreflight)
        XCTAssertEqual(missingResult, .requiresGitPreflight)
    }

    func testSymlinkedRootRequiresGitPreflight() async throws {
        let target = try makeDirectory("symlink-target")
        let link = target.deletingLastPathComponent()
            .appendingPathComponent("symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        let result = await WorkspaceCodemapLocalGitClassificationProbe.production.resolve(link)

        XCTAssertEqual(result, .requiresGitPreflight)
    }

    func testTransientPreflightIsNotTerminallyCached() async throws {
        let root = try makeDirectory("transient")
        try writeSwiftFile(in: root)
        let preflightCount = AsyncCounter()
        let store = WorkspaceFileContextStore(
            codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
            codemapGitEligibilityProbe: .init { _ in
                await preflightCount.increment()
                return .transientUnavailable(.repositoryChanging)
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .disabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        defer { Task { await store.unloadRoot(id: loaded.id) } }
        let file = try await firstFile(in: loaded, store: store)

        await assertTransient(store.requestCodemapArtifact(forFileID: file.id))
        await assertTransient(store.requestCodemapArtifact(forFileID: file.id))
        let count = await preflightCount.value
        XCTAssertEqual(count, 2)
    }

    func testUnloadReloadReclassifiesNewRootEpoch() async throws {
        let root = try makeDirectory("reload")
        try writeSwiftFile(in: root)
        let classificationCount = AsyncCounter()
        let gitPreflightCount = AsyncCounter()
        let productionProbe = WorkspaceCodemapLocalGitClassificationProbe.production
        let store = WorkspaceFileContextStore(
            codemapLocalGitClassificationProbe: .init { rootURL in
                await classificationCount.increment()
                return await productionProbe.resolve(rootURL)
            },
            codemapGitEligibilityProbe: .init { _ in
                await gitPreflightCount.increment()
                return .eligible
            }
        )

        let firstRoot = try await store.loadRoot(path: root.path)
        let firstRecord = try await firstFile(in: firstRoot, store: store)
        await assertNonGit(store.requestCodemapArtifact(forFileID: firstRecord.id))
        await assertNonGit(store.requestCodemapArtifact(forFileID: firstRecord.id))
        await store.unloadRoot(id: firstRoot.id)

        let secondRoot = try await store.loadRoot(path: root.path)
        let secondRecord = try await firstFile(in: secondRoot, store: store)
        await assertNonGit(store.requestCodemapArtifact(forFileID: secondRecord.id))
        await store.unloadRoot(id: secondRoot.id)

        XCTAssertNotEqual(firstRoot.id, secondRoot.id)
        let classifications = await classificationCount.value
        let gitPreflights = await gitPreflightCount.value
        XCTAssertEqual(classifications, 2)
        XCTAssertEqual(gitPreflights, 0)
    }

    func testAncestorGitCreationInvalidatesProofAndRunsGitPreflight() async throws {
        let ancestor = try makeDirectory("ancestor-git-creation")
        let root = ancestor.appendingPathComponent("Nested/Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSwiftFile(in: root)
        let gitPreflightCount = AsyncCounter()
        let store = WorkspaceFileContextStore(
            codemapLocalGitClassificationProbe: .production,
            codemapGitEligibilityProbe: .init { _ in
                await gitPreflightCount.increment()
                return .terminalUnavailable(.nonGit)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        defer { Task { await store.unloadRoot(id: loaded.id) } }
        let file = try await firstFile(in: loaded, store: store)

        await assertNonGit(store.requestCodemapArtifact(forFileID: file.id))
        let initialGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(initialGitPreflightCount, 0)

        try FileManager.default.createDirectory(
            at: ancestor.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        await assertNonGit(store.requestCodemapArtifact(forFileID: file.id))
        let finalGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(finalGitPreflightCount, 1)
    }

    func testIntermediateSymlinkRetargetInvalidatesProofAndRunsGitPreflight() async throws {
        let sandbox = try makeDirectory("symlink-retarget")
        let firstTarget = sandbox.appendingPathComponent("first", isDirectory: true)
        let secondTarget = sandbox.appendingPathComponent("second", isDirectory: true)
        let firstRoot = firstTarget.appendingPathComponent("Project", isDirectory: true)
        let secondRoot = secondTarget.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try writeSwiftFile(in: firstRoot)
        try writeSwiftFile(in: secondRoot)
        let link = sandbox.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: firstTarget)
        let logicalRoot = link.appendingPathComponent("Project", isDirectory: true)
        let gitPreflightCount = AsyncCounter()
        let store = WorkspaceFileContextStore(
            codemapLocalGitClassificationProbe: .production,
            codemapGitEligibilityProbe: .init { _ in
                await gitPreflightCount.increment()
                return .terminalUnavailable(.nonGit)
            }
        )
        let loaded = try await store.loadRoot(path: logicalRoot.path)
        defer { Task { await store.unloadRoot(id: loaded.id) } }
        let file = try await firstFile(in: loaded, store: store)

        await assertNonGit(store.requestCodemapArtifact(forFileID: file.id))
        let initialGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(initialGitPreflightCount, 0)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secondTarget)

        await assertNonGit(store.requestCodemapArtifact(forFileID: file.id))
        let finalGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(finalGitPreflightCount, 1)
    }

    func testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository() async throws {
        let root = try makeDirectory("watcher-conversion")
        try writeSwiftFile(in: root)
        let gitFixture = try ReviewGitRepositoryFixture(name: #function)
        addTeardownBlock { gitFixture.cleanup() }
        let gitPreflightCount = AsyncCounter()
        let productionGitEligibility = WorkspaceCodemapGitEligibilityProbe.production().resolve
        let store = WorkspaceFileContextStore(
            codemapLocalGitClassificationProbe: .production,
            codemapGitEligibilityProbe: .init { rootURL in
                await gitPreflightCount.increment()
                return await productionGitEligibility(rootURL)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
        }
        let file = try await firstFile(in: loaded, store: store)

        await assertNonGit(store.requestCodemapArtifact(forFileID: file.id))
        let initialGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(initialGitPreflightCount, 0)

        _ = try gitFixture.runGit(["init"], at: root)
        _ = try gitFixture.runGit(["config", "user.name", "RepoPrompt Test"], at: root)
        _ = try gitFixture.runGit(["config", "user.email", "repoprompt@example.test"], at: root)
        _ = try gitFixture.runGit(["config", "commit.gpgSign", "false"], at: root)
        _ = try gitFixture.runGit(["add", "."], at: root)
        _ = try gitFixture.runGit(["commit", "-m", "Initial commit"], at: root)
        await store.replayObservedFileSystemDeltas(rootID: loaded.id, deltas: [.folderAdded(".git")])

        let nextDemand = await store.requestCodemapArtifact(forFileID: file.id)
        let ready = try await settledReady(nextDemand, store: store)
        let finalGitPreflightCount = await gitPreflightCount.value
        XCTAssertEqual(finalGitPreflightCount, 1)
        _ = await store.cancelCodemapArtifactDemand(ready.ticket)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceCodemapLocalGitClassificationTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.standardizedFileURL
    }

    private func writeSwiftFile(in root: URL) throws {
        let file = root.appendingPathComponent("Sources/Feature.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "struct Feature {}\n".write(to: file, atomically: true, encoding: .utf8)
    }

    private func firstFile(
        in root: WorkspaceRootRecord,
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceFileRecord {
        let files = await store.files(inRoot: root.id)
        return try XCTUnwrap(files.first)
    }

    private func assertNonGit(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git result, got \(result)", file: file, line: line)
        }
    }

    private func settledReady(
        _ initial: WorkspaceCodemapArtifactDemandResult,
        store: WorkspaceFileContextStore,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandReady {
        var result = initial
        if case let .pending(ticket) = result {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                result = await store.codemapArtifactDemandStatus(ticket)
                guard case .pending = result else { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard case let .ready(ready) = result else {
            XCTFail("Expected ready codemap demand, got \(result)")
            throw LocalGitClassificationTestError.expectedReady
        }
        return ready
    }

    private func assertTransient(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTransient(.repositoryChanging)) = result else {
            return XCTFail("Expected transient Git result, got \(result)", file: file, line: line)
        }
    }
}

private enum LocalGitClassificationTestError: Error {
    case expectedReady
}

private actor AsyncCounter {
    private var storage = 0

    var value: Int {
        storage
    }

    func increment() {
        storage += 1
    }
}
