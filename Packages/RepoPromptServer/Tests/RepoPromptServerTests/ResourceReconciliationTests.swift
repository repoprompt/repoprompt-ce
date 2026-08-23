import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ResourceReconciliationTests: XCTestCase {
    func testPostRecoveryReconciliationDeletesOnlyOrphanedProviderResources() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-provider-reconciliation-\(UUID().uuidString)", isDirectory: true)
        let artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        let providerHomes = directory.appendingPathComponent("provider-homes", isDirectory: true)
        let providerOutput = directory.appendingPathComponent("provider-output", isDirectory: true)
        for path in [artifacts, worktrees, providerHomes, providerOutput] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let orphanedRunID = UUID()
        let activeRunID = UUID()
        let orphanedHome = providerHomes.appendingPathComponent(orphanedRunID.uuidString, isDirectory: true)
        let activeHome = providerHomes.appendingPathComponent(activeRunID.uuidString, isDirectory: true)
        let unrecordedHome = providerHomes.appendingPathComponent("unrecorded", isDirectory: true)
        let orphanedOutput = providerOutput.appendingPathComponent("orphaned.stdout")
        for path in [orphanedHome, activeHome, unrecordedHome] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data("output".utf8).write(to: orphanedOutput)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let orphanedHomeRecord = OwnedResourceRecord(
            kind: .providerHome,
            runID: orphanedRunID,
            externalID: UUID(),
            internalPathIdentity: orphanedHome.path,
            lifecycleState: .active
        )
        let activeHomeRecord = OwnedResourceRecord(
            kind: .providerHome,
            runID: activeRunID,
            externalID: UUID(),
            internalPathIdentity: activeHome.path,
            lifecycleState: .active
        )
        let orphanedOutputRecord = OwnedResourceRecord(
            kind: .providerOutput,
            runID: orphanedRunID,
            externalID: UUID(),
            internalPathIdentity: orphanedOutput.path,
            lifecycleState: .active
        )
        for record in [orphanedHomeRecord, activeHomeRecord, orphanedOutputRecord] {
            try await store.reserveOwnedResource(record)
        }

        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path,
            providerHomeRoot: providerHomes.path,
            providerOutputRoot: providerOutput.path
        )
        let report = await reconciler.reconcileProviderResourcesAfterProcessRecovery(
            activeRunIDs: [activeRunID]
        )

        XCTAssertEqual(report.inspected, 2)
        XCTAssertEqual(report.deleted, 2)
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrecordedHome.path))
        let retained = try await store.ownedResource(
            externalID: XCTUnwrap(activeHomeRecord.externalID),
            kind: .providerHome
        )
        XCTAssertEqual(retained?.lifecycleState, .active)
        try await store.close()
    }

    func testReconciliationDeletesOnlyRecordedExpiredArtifactsAndPreservesDirtyWorktrees() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-resource-reconciliation-\(UUID().uuidString)", isDirectory: true)
        let artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let providerHomes = directory.appendingPathComponent("provider-homes", isDirectory: true)
        let providerOutput = directory.appendingPathComponent("provider-output", isDirectory: true)
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHomes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerOutput, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let artifactPath = artifacts.appendingPathComponent("owned.bin")
        let unknownPath = artifacts.appendingPathComponent("unknown.bin")
        let worktreePath = worktrees.appendingPathComponent("dirty", isDirectory: true)
        let providerHomePath = providerHomes.appendingPathComponent("expired", isDirectory: true)
        try Data("owned".utf8).write(to: artifactPath)
        try Data("unknown".utf8).write(to: unknownPath)
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHomePath, withIntermediateDirectories: true)
        try Data("credential".utf8).write(to: providerHomePath.appendingPathComponent("auth.json"))
        let providerStdout = providerOutput.appendingPathComponent("expired.stdout")
        let providerStderr = providerOutput.appendingPathComponent("expired.stderr")
        try Data("out".utf8).write(to: providerStdout)
        try Data("err".utf8).write(to: providerStderr)
        let cloneOperation = projects.appendingPathComponent(".source-staging/operation", isDirectory: true)
        let cloneFinal = projects.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unknownProject = projects.appendingPathComponent("not-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneOperation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloneFinal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknownProject, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: unknownProject.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(
            at: cloneOperation.appendingPathComponent("repository-symlink"),
            withDestinationURL: unknownProject
        )

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let deadline = Date().addingTimeInterval(15 * 60)
        let artifact = OwnedResourceRecord(
            kind: .artifact,
            externalID: UUID(),
            internalPathIdentity: artifactPath.path,
            lifecycleState: .prepared,
            observedBytes: 5,
            contentDigest: CanonicalSigning.bodyDigest(Data("owned".utf8)),
            retentionDeadline: deadline
        )
        let worktree = OwnedResourceRecord(
            kind: .worktree,
            externalID: UUID(),
            internalPathIdentity: worktreePath.path,
            lifecycleState: .prepared,
            metadata: ["sourceRoot": source.path],
            retentionDeadline: deadline
        )
        let providerHome = OwnedResourceRecord(
            kind: .providerHome,
            externalID: UUID(),
            internalPathIdentity: providerHomePath.path,
            lifecycleState: .cleanupPending,
            retentionDeadline: deadline
        )
        let providerCapture = OwnedResourceRecord(
            kind: .providerOutput,
            externalID: UUID(),
            internalPathIdentity: providerStdout.path,
            temporaryPathIdentity: providerStderr.path,
            lifecycleState: .cleanupPending,
            retentionDeadline: deadline
        )
        let interruptedClone = OwnedResourceRecord(
            kind: .cloneStaging,
            projectID: UUID(),
            externalID: UUID(),
            internalPathIdentity: cloneFinal.path,
            temporaryPathIdentity: cloneOperation.path,
            lifecycleState: .preparing,
            retentionDeadline: deadline
        )
        try await store.reserveOwnedResource(artifact)
        try await store.reserveOwnedResource(worktree)
        try await store.reserveOwnedResource(providerHome)
        try await store.reserveOwnedResource(providerCapture)
        try await store.reserveOwnedResource(interruptedClone)
        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path,
            providerHomeRoot: providerHomes.path,
            providerOutputRoot: providerOutput.path,
            projectRoot: projects.path,
            runner: DirtyWorktreeRunner()
        )
        let report = try await reconciler.reconcileStartup()
        XCTAssertEqual(report.deleted, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerHomePath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerStdout.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerStderr.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneOperation.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownProject.appendingPathComponent("sentinel").path))
        let persistedWorktree = try await store.ownedResource(externalID: XCTUnwrap(worktree.externalID), kind: .worktree)
        XCTAssertEqual(persistedWorktree?.lifecycleState, .quarantined)
        try await store.close()
    }

    func testStartupReconciliationRejectsReplacedSymlinkProjectRootWithoutDeletingOutsideVolume() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-resource-reconciliation-\(UUID().uuidString)", isDirectory: true)
        let artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        for path in [artifacts, worktrees, projects, outside] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path,
            projectRoot: projects.path
        )
        let outsideCheckout = outside.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideCheckout, withIntermediateDirectories: true)
        try Data("must survive".utf8).write(to: outsideCheckout.appendingPathComponent("sentinel"))
        let record = OwnedResourceRecord(
            kind: .cloneStaging,
            projectID: UUID(),
            externalID: UUID(),
            internalPathIdentity: projects.appendingPathComponent("checkout").path,
            lifecycleState: .preparing,
            retentionDeadline: Date().addingTimeInterval(-1)
        )
        try await store.reserveOwnedResource(record)

        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: outside)
        do {
            _ = try await reconciler.reconcileStartup()
            XCTFail("Expected immutable project-root rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideCheckout.appendingPathComponent("sentinel").path))
        let persisted = try await store.ownedResource(externalID: XCTUnwrap(record.externalID), kind: .cloneStaging)
        XCTAssertEqual(persisted?.lifecycleState, .preparing)
        try await store.close()
    }

    func testPinnedProjectRootRemovalCannotBeRedirectedByReplacementRace() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-resource-reconciliation-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        let original = directory.appendingPathComponent("projects-original", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("owned"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("owned"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: projects.appendingPathComponent("owned/sentinel"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("owned/sentinel"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let canonical = try LocalFilesystemAuthority().canonicalizeRoot(projects.path)
        let pinned = try PinnedFilesystemRoot(path: canonical.path, identity: canonical.identity)
        try FileManager.default.moveItem(at: projects, to: original)
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: outside)
        try pinned.removeTree(at: projects.appendingPathComponent("owned").path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("owned").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("owned/sentinel").path))
    }
}

private actor DirtyWorktreeRunner: WorkspaceCommandRunning {
    func run(
        executable _: String,
        arguments: [String],
        workingDirectory _: String,
        maximumBytes _: Int
    ) async throws -> String {
        if arguments.contains("status") { return " M important.txt\n" }
        return ""
    }
}
