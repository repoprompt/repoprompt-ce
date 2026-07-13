import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Behavioral coverage for the posix_spawn-based git launch path:
    /// stdin/EOF semantics, environment and working-directory propagation,
    /// exit/signal status parity, spawn-failure surfacing, byte limits, and
    /// cancellation/timeout intent accrued while the synchronous spawn call is
    /// in flight.
    final class GitProcessSpawnMigrationTests: XCTestCase {
        private var tempRoot: URL?

        override func tearDownWithError() throws {
            if let tempRoot {
                try? FileManager.default.removeItem(at: tempRoot)
            }
            tempRoot = nil
        }

        func testStdinDataReachesGitChildWithPromptEOFAfterWrite() async throws {
            let repo = try makeRepository()
            let service = makeGitService()

            let (stdout, _, exitCode) = try await service.runGitDataForTesting(
                ["hash-object", "--stdin"],
                at: repo,
                stdin: Data("hello\n".utf8),
                commandTimeout: .seconds(15)
            )

            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(trimmed(stdout), "ce013625030ba8dba906f756967f9e9ca394464a")
        }

        func testNilStdinDeliversPromptEOFToGitChild() async throws {
            let repo = try makeRepository()
            let service = makeGitService()

            // Without a prompt EOF on the launcher-created stdin pipe, git
            // blocks reading stdin forever and this call could only end by
            // command timeout.
            let (stdout, _, exitCode) = try await service.runGitDataForTesting(
                ["hash-object", "--stdin"],
                at: repo,
                commandTimeout: .seconds(15)
            )

            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(trimmed(stdout), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        }

        func testEnvironmentAndWorkingDirectoryPropagateToGitChild() async throws {
            let repo = try makeRepository()
            let service = makeGitService()

            let (identOut, _, identCode) = try await service.runGitDataForTesting(
                ["var", "GIT_AUTHOR_IDENT"],
                at: repo,
                env: [
                    "GIT_AUTHOR_NAME": "Env Probe",
                    "GIT_AUTHOR_EMAIL": "env@example.com",
                    "GIT_AUTHOR_DATE": "1234567890 +0000"
                ],
                commandTimeout: .seconds(15)
            )
            XCTAssertEqual(identCode, 0)
            XCTAssertEqual(trimmed(identOut), "Env Probe <env@example.com> 1234567890 +0000")

            let (topLevelOut, _, topLevelCode) = try await service.runGitDataForTesting(
                ["rev-parse", "--show-toplevel"],
                at: repo,
                commandTimeout: .seconds(15)
            )
            XCTAssertEqual(topLevelCode, 0)
            XCTAssertEqual(
                URL(fileURLWithPath: trimmed(topLevelOut)).resolvingSymlinksInPath().path,
                repo.resolvingSymlinksInPath().path
            )
        }

        func testGitChildKilledBySignalReportsSignalNumberAsExitStatus() async throws {
            let repo = try makeRepository()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                try ProcessLauncher.spawn(
                    command: "/bin/sh",
                    arguments: ["-c", "kill -KILL $$"],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            }
            let service = makeGitService(spawner: spawner)

            let (_, _, exitCode) = try await service.runGitDataForTesting(
                ["status"],
                at: repo,
                commandTimeout: .seconds(15)
            )

            // SIGKILL is intentional: unlike SIGTERM, its disposition cannot be
            // inherited as ignored or blocked from the XCTest host.
            // Process.terminationStatus parity surfaces the raw signal number,
            // not a 128+signal shell convention.
            XCTAssertEqual(exitCode, SIGKILL)
        }

        func testSpawnFailureSurfacesLauncherError() async throws {
            let repo = try makeRepository()
            let spawner: GitService.ProcessSpawner = { _, _, _, _ in
                throw ProcessLauncherError.spawnFailed(errno: ENOENT)
            }
            let service = makeGitService(spawner: spawner)

            do {
                _ = try await service.runGitDataForTesting(["status"], at: repo)
                XCTFail("expected spawn failure to propagate")
            } catch let error as ProcessLauncherError {
                guard case let .spawnFailed(errnoValue) = error else {
                    XCTFail("unexpected launcher error: \(error)")
                    return
                }
                XCTAssertEqual(errnoValue, ENOENT)
            }
        }

        func testCancellationAccruedDuringBlockedSpawnTerminatesChildOnReturn() async throws {
            let repo = try makeRepository()
            let spawnEntered = expectation(description: "spawn entered")
            let releaseSpawn = DispatchSemaphore(value: 0)
            let pidBox = PIDBox()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                spawnEntered.fulfill()
                releaseSpawn.wait()
                let spawned = try ProcessLauncher.spawn(
                    command: "/bin/sleep",
                    arguments: ["30"],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
                pidBox.pid = spawned.pid
                return spawned
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(500))

            let task = Task {
                try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    commandTimeout: .seconds(30)
                )
            }
            await fulfillment(of: [spawnEntered], timeout: 5)
            task.cancel()
            releaseSpawn.signal()

            switch await task.result {
            case .success:
                XCTFail("expected cancellation to propagate")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }
            try await waitForProcessExit(pidBox.pid)
        }

        func testTimeoutBudgetConsumedDuringBlockedSpawnFiresImmediately() async throws {
            let repo = try makeRepository()
            let pidBox = PIDBox()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                // Simulate a launch call that outlives the whole command
                // timeout; the timeout must fire right after spawn returns.
                usleep(300_000)
                let spawned = try ProcessLauncher.spawn(
                    command: "/usr/bin/true",
                    arguments: [],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
                pidBox.pid = spawned.pid
                return spawned
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(500))

            do {
                _ = try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    commandTimeout: .milliseconds(100)
                )
                XCTFail("expected timeout")
            } catch let error as GitService.GitProcessCaptureError {
                XCTAssertEqual(error, .timedOut)
            }
            try await waitForProcessExit(pidBox.pid)
        }

        func testSpoolingSpawnFailureMapsToTargetEvidenceLaunchClassification() async throws {
            let repo = try makeRepository()
            let spawner: GitService.ProcessSpawner = { _, _, _, _ in
                throw ProcessLauncherError.spawnFailed(errno: ENOENT)
            }
            let service = makeGitService(spawner: spawner)

            do {
                _ = try await service.runGitSpoolingForTesting(["status"], at: repo)
                XCTFail("expected spooling spawn failure")
            } catch {
                XCTAssertEqual(
                    GitService.targetEvidenceCollectionError(error) as? GitTargetEvidenceCollectionError,
                    .processLaunch(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                )
            }
        }

        func testSpoolingExpiredSpawnBudgetBeatsFastChildCompletion() async throws {
            let repo = try makeRepository()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                usleep(300_000)
                return try ProcessLauncher.spawn(
                    command: "/usr/bin/true",
                    arguments: [],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(100))

            do {
                _ = try await service.runGitSpoolingForTesting(
                    ["status"],
                    at: repo,
                    activityTimeout: .milliseconds(100)
                )
                XCTFail("expected expired spawn budget to win")
            } catch let error as GitService.GitProcessCaptureError {
                XCTAssertEqual(error, .timedOut)
            }
        }

        func testSpoolingCancellationCleansTermResistantProcessFamily() async throws {
            let repo = try makeRepository()
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-spool-pid-\(UUID().uuidString)")
            let readiness = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-spool-ready-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: readiness)
            }
            let script = "(trap '' TERM; : > '\(readiness.path)'; sleep 30) & echo $! > '\(marker.path)'; wait"
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                try ProcessLauncher.spawn(
                    command: "/bin/sh",
                    arguments: ["-c", script],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(200))
            let task = Task {
                try await service.runGitSpoolingForTesting(["status"], at: repo)
            }
            let descendantPID = try await waitForMarkerPID(at: marker)
            try await waitForMarker(at: readiness)
            task.cancel()

            switch await task.result {
            case .success:
                XCTFail("expected cancellation")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }
            try await waitForProcessExit(descendantPID, timeoutSeconds: 3)
        }

        func testStdoutByteLimitExceededTerminatesChildAndThrows() async throws {
            let repo = try makeRepository()
            let pidBox = PIDBox()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                let spawned = try ProcessLauncher.spawn(
                    command: "/bin/sh",
                    arguments: ["-c", "head -c 200000 /dev/zero; sleep 30"],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
                pidBox.pid = spawned.pid
                return spawned
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(500))

            do {
                _ = try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    stdoutByteLimit: 1000,
                    commandTimeout: .seconds(30)
                )
                XCTFail("expected stdout byte limit failure")
            } catch let error as GitService.GitProcessCaptureError {
                XCTAssertEqual(error, .stdoutByteLimitExceeded)
            }
            try await waitForProcessExit(pidBox.pid)
        }

        func testCancellationKillsSpawnedProcessGroupDescendants() async throws {
            let repo = try makeRepository()
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-marker-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let script = "sleep 30 & echo $! > '\(marker.path)'; wait"
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                try ProcessLauncher.spawn(
                    command: "/bin/sh",
                    arguments: ["-c", script],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(500))

            let task = Task {
                try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    commandTimeout: .seconds(30)
                )
            }
            let descendantPID = try await waitForMarkerPID(at: marker)
            task.cancel()
            _ = await task.result

            // Process-group SIGTERM must reach the backgrounded descendant,
            // not only the direct /bin/sh child.
            try await waitForProcessExit(descendantPID)
        }

        func testDrainSetupFailureReapsChildBeforeCompleting() async throws {
            let repo = try makeRepository()
            let pidBox = PIDBox()
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                let spawned = try ProcessLauncher.spawn(
                    command: "/bin/sleep",
                    arguments: ["30"],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
                pidBox.pid = spawned.pid
                return spawned
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(500))
            await service.setDrainCreationFailureForTesting(InjectedDrainFailure())

            do {
                _ = try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    commandTimeout: .seconds(30)
                )
                XCTFail("expected injected drain failure")
            } catch is InjectedDrainFailure {
                // Completion releases the admission lease, so by the time the
                // call throws the spawned child must already be terminated and
                // reaped -- no polling grace is allowed here.
                let pid = pidBox.pid
                XCTAssertGreaterThan(pid, 0, "spawned pid was never recorded")
                let killResult = kill(pid, 0)
                XCTAssertTrue(
                    killResult == -1 && errno == ESRCH,
                    "child \(pid) still alive when drain-failure command completed"
                )
            }
        }

        func testCancellationKillsTermResistantDescendantAfterDirectChildExits() async throws {
            let repo = try makeRepository()
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-resistant-\(UUID().uuidString)")
            let readiness = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-resistant-ready-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: readiness)
            }
            // The subshell ignores SIGTERM (and hands that disposition to its
            // sleep), while the direct /bin/sh exits promptly on the first
            // group SIGTERM -- reproducing a reaped direct child with a live
            // TERM-resistant descendant.
            let script = "(trap '' TERM; : > '\(readiness.path)'; sleep 30) & echo $! > '\(marker.path)'; wait"
            let spawner: GitService.ProcessSpawner = { _, _, environment, workingDirectory in
                try ProcessLauncher.spawn(
                    command: "/bin/sh",
                    arguments: ["-c", script],
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            }
            let service = makeGitService(spawner: spawner, terminationGrace: .milliseconds(200))

            let task = Task {
                try await service.runGitDataForTesting(
                    ["status"],
                    at: repo,
                    commandTimeout: .seconds(30)
                )
            }
            let descendantPID = try await waitForMarkerPID(at: marker)
            try await waitForMarker(at: readiness)
            task.cancel()

            switch await task.result {
            case .success:
                XCTFail("expected cancellation to propagate")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }
            // Group escalation must SIGKILL the TERM-resistant descendant even
            // though the direct child was reaped first; command completion is
            // expected to have already waited for the group to be gone.
            try await waitForProcessExit(descendantPID, timeoutSeconds: 3)
        }

        // MARK: - Helpers

        private func makeGitService(
            spawner: GitService.ProcessSpawner? = nil,
            terminationGrace: Duration = .seconds(2)
        ) -> GitService {
            if let spawner {
                return GitService(
                    processTerminationGrace: terminationGrace,
                    processSpawner: spawner
                )
            }
            return GitService(processTerminationGrace: terminationGrace)
        }

        private func makeRepository() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitProcessSpawnMigrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempRoot = root
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init", "--initial-branch=main"]
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("git init unavailable in this environment")
            }
            return root
        }

        private func trimmed(_ data: Data) -> String {
            (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func waitForProcessExit(_ pid: pid_t, timeoutSeconds: Double = 5) async throws {
            XCTAssertGreaterThan(pid, 0, "spawned pid was never recorded")
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if kill(pid, 0) == -1, errno == ESRCH {
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("process \(pid) still alive after \(timeoutSeconds)s")
        }

        private func waitForMarker(at url: URL, timeoutSeconds: Double = 5) async throws {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: url.path) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            struct MarkerTimeout: Error {}
            throw MarkerTimeout()
        }

        private func waitForMarkerPID(at url: URL, timeoutSeconds: Double = 5) async throws -> pid_t {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if let contents = try? String(contentsOf: url, encoding: .utf8),
                   let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
                   pid > 0
                {
                    return pid
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            struct MarkerTimeout: Error {}
            throw MarkerTimeout()
        }
    }

    private struct InjectedDrainFailure: Error {}

    private final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPID: pid_t = 0

        var pid: pid_t {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedPID
            }
            set {
                lock.lock()
                storedPID = newValue
                lock.unlock()
            }
        }
    }
#endif
