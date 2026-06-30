import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapV6CacheDeletionTests: XCTestCase {
    func testMissingCacheDirectoryPublishesCompletionWithoutCreatingCacheDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let report = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

        XCTAssertEqual(report.retryableFailureCount, 0)
        XCTAssertEqual(report.completionWrittenCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.completionURL.path))
    }

    func testPlannerAndExecutorDeleteOnlyExactLowercaseHashNamedVersionSixFiles() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let versionSix = fixture.candidateName("a")
        let versionSeven = fixture.candidateName("b")
        let malformed = fixture.candidateName("c")
        try fixture.write(Data("{\"version\":6,\"payload\":{\"ignored\":true}}".utf8), name: versionSix)
        try fixture.write(Data("{\"version\":7}".utf8), name: versionSeven)
        try fixture.write(Data("not-json".utf8), name: malformed)
        let uppercaseName = String(repeating: "D", count: 64) + ".json"
        try fixture.write(Data("{\"version\":6}".utf8), name: uppercaseName)
        try fixture.write(Data("{\"version\":6}".utf8), name: "nested-name.json")
        let nestedDirectory = fixture.cacheURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        let nestedCandidate = nestedDirectory.appendingPathComponent(fixture.candidateName("d"))
        let nestedBytes = Data("{\"version\":6}".utf8)
        try nestedBytes.write(to: nestedCandidate)

        let report = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

        XCTAssertEqual(report.examinedCount, 3)
        XCTAssertEqual(report.eligibleV6Count, 1)
        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.retainedUnrecognizedCount, 2)
        XCTAssertEqual(report.retryableFailureCount, 0)
        XCTAssertFalse(fixture.exists(versionSix))
        XCTAssertTrue(fixture.exists(versionSeven))
        XCTAssertTrue(fixture.exists(malformed))
        XCTAssertTrue(fixture.exists(uppercaseName))
        XCTAssertTrue(fixture.exists("nested-name.json"))
        XCTAssertEqual(try Data(contentsOf: nestedCandidate), nestedBytes)
    }

    func testPlannerRetainsSymlinkHardlinkWrongModeOversizedAndSyntheticWrongOwnerEntries() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let hardlinked = fixture.candidateName("a")
        let hardlinkPeer = fixture.cacheURL.appendingPathComponent("hardlink-peer")
        try fixture.write(Data("{\"version\":6}".utf8), name: hardlinked)
        XCTAssertEqual(link(fixture.url(hardlinked).path, hardlinkPeer.path), 0)

        let symlink = fixture.candidateName("b")
        XCTAssertEqual(Darwin.symlink(hardlinkPeer.path, fixture.url(symlink).path), 0)

        let wrongMode = fixture.candidateName("c")
        try fixture.write(Data("{\"version\":6}".utf8), name: wrongMode, mode: 0o644)

        let oversized = fixture.candidateName("d")
        try fixture.createSparseFile(
            name: oversized,
            byteCount: CodeMapV6CacheDeletionPolicy.maximumCandidateByteCount + 1
        )

        let syntheticWrongOwner = fixture.candidateName("e")
        try fixture.write(Data("{\"version\":6}".utf8), name: syntheticWrongOwner)
        let planner = CodeMapV6CacheDeletionPlanner(
            hooks: CodeMapV6CacheDeletionPlannerHooks(candidateStatusTransform: { name, status in
                guard name == syntheticWrongOwner else { return status }
                var changed = status
                changed.st_uid = getuid() + 1
                return changed
            })
        )

        let plan = try planner.plan(target: fixture.target)

        XCTAssertEqual(plan.classification.examinedCount, 5)
        XCTAssertEqual(plan.classification.eligibleV6Count, 0)
        XCTAssertEqual(plan.classification.retainedUnrecognizedCount, 5)
        XCTAssertTrue(fixture.exists(hardlinked))
        XCTAssertTrue(fixture.exists(symlink))
        XCTAssertTrue(fixture.exists(wrongMode))
        XCTAssertTrue(fixture.exists(oversized))
        XCTAssertTrue(fixture.exists(syntheticWrongOwner))
    }

    func testCandidatePathReplacementRaceIsRetainedAndPreventsCompletion() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        let replacementData = Data("{\"version\":6,\"replacement\":true}".utf8)
        var injected = false
        let executor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(beforeRemoval: { candidateName in
                guard !injected else { return }
                injected = true
                let heldAside = fixture.cacheURL.appendingPathComponent("held-aside")
                try FileManager.default.moveItem(at: fixture.url(candidateName), to: heldAside)
                try fixture.write(replacementData, name: candidateName)
            })
        )

        let report = executor.execute(target: fixture.target)

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertGreaterThan(report.missingOrRacedCount, 0)
        XCTAssertGreaterThan(report.retryableFailureCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url(name)), replacementData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionURL.path))
    }

    func testCacheDirectoryReplacementRaceDoesNotTouchReplacementOrPublishCompletion() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        let replacementBytes = Data("replacement must remain".utf8)
        var injected = false
        let executor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(beforeRemoval: { _ in
                guard !injected else { return }
                injected = true
                let heldAside = fixture.root.appendingPathComponent("CodeMapCaches-held-aside", isDirectory: true)
                try FileManager.default.moveItem(at: fixture.cacheURL, to: heldAside)
                try FileManager.default.createDirectory(
                    at: fixture.cacheURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                XCTAssertEqual(chmod(fixture.cacheURL.path, 0o700), 0)
                try replacementBytes.write(to: fixture.url(name))
                XCTAssertEqual(chmod(fixture.url(name).path, 0o600), 0)
            })
        )

        let report = executor.execute(target: fixture.target)

        XCTAssertGreaterThan(report.retryableFailureCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url(name)), replacementBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionURL.path))
    }

    func testRemovalDirectorySynchronizationFailureRetriesOnNextExecution() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        let failingExecutor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(
                secureRemovalHooks: CodeMapSecureFileRemovalHooks(directorySynchronize: { _ in
                    errno = EIO
                    return -1
                })
            )
        )

        let first = failingExecutor.execute(target: fixture.target)
        let second = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

        XCTAssertGreaterThan(first.retryableFailureCount, 0)
        XCTAssertEqual(first.completionWrittenCount, 0)
        XCTAssertFalse(fixture.exists(name))
        XCTAssertEqual(second.retryableFailureCount, 0)
        XCTAssertEqual(second.completionWrittenCount, 1)
    }

    func testInjectedPerFileFailureRetainsCandidateAndRetriesOnNextExecution() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        let bytes = Data("{\"version\":6}".utf8)
        try fixture.write(bytes, name: name)
        let failingExecutor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(beforeRemoval: { _ in
                throw InjectedFailure()
            })
        )

        let first = failingExecutor.execute(target: fixture.target)
        XCTAssertGreaterThan(first.retryableFailureCount, 0)
        XCTAssertEqual(first.deletedCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url(name)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionURL.path))

        let second = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertEqual(second.retryableFailureCount, 0)
        XCTAssertEqual(second.deletedCount, 1)
        XCTAssertEqual(second.completionWrittenCount, 1)
    }

    func testCompletionPublicationFailureRetriesWithoutRestoringDeletedCache() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        let failingExecutor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(beforeCompletionPublication: {
                throw InjectedFailure()
            })
        )

        let first = failingExecutor.execute(target: fixture.target)

        XCTAssertEqual(first.deletedCount, 1)
        XCTAssertGreaterThan(first.retryableFailureCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionURL.path))

        let second = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertEqual(second.retryableFailureCount, 0)
        XCTAssertEqual(second.completionWrittenCount, 1)
    }

    func testCompletionDirectorySynchronizationFailureLeavesAtomicRecordForRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failingExecutor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(synchronize: { descriptor, operation in
                if operation == .maintenanceDirectory {
                    errno = EIO
                    return -1
                }
                return fsync(descriptor)
            })
        )

        let first = failingExecutor.execute(target: fixture.target)
        let second = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

        XCTAssertGreaterThan(first.retryableFailureCount, 0)
        XCTAssertEqual(first.completionWrittenCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.completionURL.path))
        XCTAssertEqual(second.retryableFailureCount, 0)
        XCTAssertEqual(second.completionWrittenCount, 0)
    }

    func testLockContentionIsRetryableAndDoesNotTouchCacheOrCompletion() throws {
        do {
            let fixture = try Fixture(createCache: true)
            defer { fixture.remove() }
            let name = fixture.candidateName("a")
            let bytes = Data("{\"version\":6}".utf8)
            try fixture.write(bytes, name: name)
            try fixture.createMaintenanceDirectoryAndLock()
            let lockDescriptor = Darwin.open(fixture.lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
            defer {
                _ = flock(lockDescriptor, LOCK_UN)
                Darwin.close(lockDescriptor)
            }
            XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)

            let report = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

            XCTAssertEqual(report.lockContentionCount, 1)
            XCTAssertEqual(report.retryableFailureCount, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.url(name)), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionURL.path))
        }

        let replacementFixture = try Fixture(createCache: true)
        defer { replacementFixture.remove() }
        let replacementName = replacementFixture.candidateName("b")
        let replacementBytes = Data("{\"version\":6}".utf8)
        try replacementFixture.write(replacementBytes, name: replacementName)
        var replacementError: Error?
        var contenderReport: CodeMapV6CacheDeletionReport?
        let executor = CodeMapV6CacheDeletionExecutor(
            hooks: CodeMapV6CacheDeletionExecutorHooks(didAcquireLock: {
                do {
                    try replacementFixture.replaceLockFile()
                    contenderReport = CodeMapV6CacheDeletionExecutor().execute(target: replacementFixture.target)
                } catch {
                    replacementError = error
                }
            })
        )

        let replacedReport = executor.execute(target: replacementFixture.target)

        XCTAssertNil(replacementError)
        XCTAssertEqual(contenderReport?.lockContentionCount, 1)
        XCTAssertGreaterThan(replacedReport.retryableFailureCount, 0)
        XCTAssertEqual(replacedReport.deletedCount, 0)
        XCTAssertEqual(try Data(contentsOf: replacementFixture.url(replacementName)), replacementBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementFixture.completionURL.path))
    }

    func testCrossProcessLockContentionSerializesDeletionAndLaterRetrySucceeds() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 is unavailable for cross-process flock coverage")
        }
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        try fixture.createMaintenanceDirectoryAndLock()
        let readyURL = fixture.root.appendingPathComponent("lock-ready")
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-c",
            "import fcntl, pathlib, sys, time; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(30)",
            fixture.lockURL.path,
            readyURL.path
        ]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let contended = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertEqual(contended.lockContentionCount, 1)
        XCTAssertTrue(fixture.exists(name))
        process.terminate()
        process.waitUntilExit()

        let retry = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertEqual(retry.retryableFailureCount, 0)
        XCTAssertEqual(retry.deletedCount, 1)
        XCTAssertEqual(retry.completionWrittenCount, 1)
    }

    func testMatchingCompletionIsIdempotentAndMalformedCompletionIsRetryable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        let completionBytes = try Data(contentsOf: fixture.completionURL)

        let second = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertEqual(first.completionWrittenCount, 1)
        XCTAssertEqual(second.retryableFailureCount, 0)
        XCTAssertEqual(second.completionWrittenCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.completionURL), completionBytes)

        try Data("{\"schemaVersion\":1,\"deletionEpoch\":\"wrong\"}".utf8)
            .write(to: fixture.completionURL)
        XCTAssertEqual(chmod(fixture.completionURL.path, 0o600), 0)
        let malformed = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)
        XCTAssertGreaterThan(malformed.retryableFailureCount, 0)
        XCTAssertEqual(malformed.completionWrittenCount, 0)
    }

    func testContentAddressedRuntimeTreesRemainByteForByteUntouched() throws {
        let fixture = try Fixture(createCache: true)
        defer { fixture.remove() }
        let name = fixture.candidateName("a")
        try fixture.write(Data("{\"version\":6}".utf8), name: name)
        let contentAddressedRuntimeRoot = fixture.root.appendingPathComponent(
            "CodeMapArtifactRuntime-debug",
            isDirectory: true
        )
        let files = [
            contentAddressedRuntimeRoot.appendingPathComponent("artifacts/v1/blob"),
            contentAddressedRuntimeRoot.appendingPathComponent("locators/v1/locator"),
            contentAddressedRuntimeRoot.appendingPathComponent("manifests/v1/manifest")
        ]
        var expected: [String: Data] = [:]
        for (index, file) in files.enumerated() {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = Data("modern-\(index)".utf8)
            try bytes.write(to: file)
            expected[file.path] = bytes
        }

        let report = CodeMapV6CacheDeletionExecutor().execute(target: fixture.target)

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.retryableFailureCount, 0)
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), try XCTUnwrap(expected[file.path]))
        }
    }

    func testReportTelemetryShapeContainsOnlyNumericStoredFields() {
        let report = CodeMapV6CacheDeletionReport()
        for child in Mirror(reflecting: report).children {
            XCTAssertTrue(child.value is Int || child.value is UInt64, "non-numeric field: \(child.label ?? "?")")
        }
    }
}

private struct InjectedFailure: Error {}

private final class Fixture {
    let root: URL
    let cacheURL: URL
    let maintenanceURL: URL

    var target: CodeMapV6CacheDeletionTarget {
        CodeMapV6CacheDeletionTarget(applicationSupportRootURL: root)
    }

    var completionURL: URL {
        maintenanceURL.appendingPathComponent(CodeMapV6CacheDeletionPolicy.completionFileName)
    }

    var lockURL: URL {
        maintenanceURL.appendingPathComponent(CodeMapV6CacheDeletionPolicy.lockFileName)
    }

    init(createCache: Bool = false) throws {
        let unresolvedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapV6Deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unresolvedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(unresolvedRoot.path, 0o700), 0)
        root = unresolvedRoot.resolvingSymlinksInPath()
        cacheURL = root.appendingPathComponent(CodeMapV6CacheDeletionPolicy.cacheDirectoryName, isDirectory: true)
        maintenanceURL = root.appendingPathComponent(
            CodeMapV6CacheDeletionPolicy.maintenanceDirectoryName,
            isDirectory: true
        )
        if createCache {
            try FileManager.default.createDirectory(
                at: cacheURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            XCTAssertEqual(chmod(cacheURL.path, 0o700), 0)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func candidateName(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64) + ".json"
    }

    func url(_ name: String) -> URL {
        cacheURL.appendingPathComponent(name)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    func write(_ data: Data, name: String, mode: mode_t = 0o600) throws {
        try data.write(to: url(name))
        XCTAssertEqual(chmod(url(name).path, mode), 0)
    }

    func createSparseFile(name: String, byteCount: off_t) throws {
        let descriptor = Darwin.open(url(name).path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(fchmod(descriptor, 0o600), 0)
        XCTAssertEqual(ftruncate(descriptor, byteCount), 0)
    }

    func createMaintenanceDirectoryAndLock() throws {
        try FileManager.default.createDirectory(
            at: maintenanceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(maintenanceURL.path, 0o700), 0)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
    }

    func replaceLockFile() throws {
        XCTAssertEqual(unlink(lockURL.path), 0)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
    }
}
