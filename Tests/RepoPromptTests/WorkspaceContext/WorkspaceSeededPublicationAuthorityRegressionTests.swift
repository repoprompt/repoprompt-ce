import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class WorkspaceSeededPublicationAuthorityRegressionTests: XCTestCase {
        private enum HelperEnvironment {
            static let isHelper = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_HELPER"
            static let readyMarkerPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_READY_MARKER"
            static let completionMarkerPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_COMPLETION_MARKER"
            static let fixtureParentPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_FIXTURE_PARENT"
        }

        private static let readyMarker = "seeded-publication-authority-fixture-ready\n"
        private static let completionMarker = "seeded-publication-authority-commit-completed\n"

        /// The authority and watermark permits are intentionally non-recursive. This
        /// executes the real pending seeded-root commit after a first published root
        /// has installed the static all-loaded cache identity. The helper process
        /// contains the known-bad self-deadlock so its forced cleanup cannot strand
        /// the shared XCTest process on the baseline.
        func testPendingSeededPublicationCompletesWhenPublishedFencesAreQueryable() async throws {
            if ProcessInfo.processInfo.environment[HelperEnvironment.isHelper] == "1" {
                try await runSeededPublicationHelper()
                return
            }

            let root = try makeTestDirectory(name: "seeded-publication-authority-helper")
            let coordinationDirectory = root.appendingPathComponent("coordination", isDirectory: true)
            let helperTemporaryDirectory = root.appendingPathComponent("helper-tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: coordinationDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperTemporaryDirectory, withIntermediateDirectories: true)

            let readyMarkerURL = coordinationDirectory.appendingPathComponent("ready")
            let completionMarkerURL = coordinationDirectory.appendingPathComponent("completed")
            let result = try runHelperTestProcess(
                readyMarkerURL: readyMarkerURL,
                completionMarkerURL: completionMarkerURL,
                helperTemporaryDirectory: helperTemporaryDirectory
            )

            XCTAssertEqual(
                result.terminationStatus,
                0,
                "Seeded publication helper XCTest failed:\n\(result.output)"
            )
            XCTAssertEqual(
                try String(contentsOf: completionMarkerURL, encoding: .utf8),
                Self.completionMarker,
                "The helper must write its completion marker only after the second real pending seeded-root commit returns.\n\(result.output)"
            )
        }

        private enum MarkerWaitOutcome {
            case observed
            case deadlineExpired
            case childTerminated
        }

        private func runHelperTestProcess(
            readyMarkerURL: URL,
            completionMarkerURL: URL,
            helperTemporaryDirectory: URL
        ) throws -> (terminationStatus: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest",
                "-XCTest",
                "RepoPromptTests.WorkspaceSeededPublicationAuthorityRegressionTests",
                Bundle(for: WorkspaceSeededPublicationAuthorityRegressionTests.self).bundleURL.path
            ]

            var environment = ProcessInfo.processInfo.environment
            environment[HelperEnvironment.isHelper] = "1"
            environment[HelperEnvironment.readyMarkerPath] = readyMarkerURL.path
            environment[HelperEnvironment.completionMarkerPath] = completionMarkerURL.path
            environment[HelperEnvironment.fixtureParentPath] = helperTemporaryDirectory.path
            environment["TMPDIR"] = helperTemporaryDirectory.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice

            let outputURL = readyMarkerURL.deletingLastPathComponent().appendingPathComponent("helper.log")
            try Data().write(to: outputURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            process.standardOutput = outputHandle
            process.standardError = outputHandle

            let completion = DispatchSemaphore(value: 0)
            let readyOrTermination = DispatchSemaphore(value: 0)
            let completionOrTermination = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                completion.signal()
                readyOrTermination.signal()
                completionOrTermination.signal()
            }
            try process.run()

            let readyOutcome: MarkerWaitOutcome
            do {
                readyOutcome = try waitForMarker(
                    at: readyMarkerURL,
                    deadline: 30,
                    wakeSignal: readyOrTermination
                )
            } catch {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 1,
                    description: "Could not observe the helper ready marker: \(error.localizedDescription)",
                    reaped: reaped,
                    output: output
                )
            }
            guard case .observed = readyOutcome else {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let description = switch readyOutcome {
                case .deadlineExpired:
                    "Seeded publication helper did not reach the second commit before the 30-second startup deadline."
                case .childTerminated:
                    "Seeded publication helper exited before reaching the second commit."
                case .observed:
                    "unreachable"
                }
                throw helperProcessFailure(code: 1, description: description, reaped: reaped, output: output)
            }

            let completionOutcome: MarkerWaitOutcome
            do {
                completionOutcome = try waitForMarker(
                    at: completionMarkerURL,
                    deadline: 3,
                    wakeSignal: completionOrTermination
                )
            } catch {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 2,
                    description: "Could not observe the helper completion marker: \(error.localizedDescription)",
                    reaped: reaped,
                    output: output
                )
            }
            switch completionOutcome {
            case .observed:
                break
            case .deadlineExpired:
                let childWasRunningAtDeadline = process.isRunning
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 2,
                    description: "Seeded publication helper exceeded the bounded post-ready commit deadline while childRunningAtDeadline=\(childWasRunningAtDeadline).",
                    reaped: reaped,
                    output: output
                )
            case .childTerminated:
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 4,
                    description: "Seeded publication helper exited before writing its completion marker.",
                    reaped: reaped,
                    output: output
                )
            }

            if completion.wait(timeout: .now() + 10) == .timedOut {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 3,
                    description: "Seeded publication helper did not exit after its completed commit.",
                    reaped: reaped,
                    output: output
                )
            }

            return try (process.terminationStatus, String(contentsOf: outputURL, encoding: .utf8))
        }

        private func runSeededPublicationHelper() async throws {
            var phase = "fixture"
            var sourceA: URL?
            var sourceB: URL?

            do {
                let fixtureParent = try requiredExistingDirectoryURL(HelperEnvironment.fixtureParentPath)
                let fixture = try ReviewGitRepositoryFixture(
                    name: "SeededPublicationAuthorityRegression",
                    parentDirectory: fixtureParent
                )
                defer { fixture.cleanup() }
                let readyMarkerURL = try requiredMarkerURL(HelperEnvironment.readyMarkerPath)
                let completionMarkerURL = try requiredMarkerURL(HelperEnvironment.completionMarkerPath)

                phase = "source repositories"
                sourceA = try fixture.makeRepository(
                    named: "source-a",
                    files: ["Sources/Alpha.swift": "struct Alpha {}\n"]
                )
                sourceB = try fixture.makeRepository(
                    named: "source-b",
                    files: ["Sources/Beta.swift": "struct Beta {}\n"]
                )
                let sourceA = try XCTUnwrap(sourceA)
                let sourceB = try XCTUnwrap(sourceB)
                let git = GitService()
                let store = WorkspaceFileContextStore()

                phase = "source snapshot admission"
                let loadedA = try await store.loadRoot(path: sourceA.path, kind: .primaryWorkspace)
                let loadedB = try await store.loadRoot(path: sourceB.path, kind: .primaryWorkspace)
                let admissionA = try await store.admitReusableSnapshotForLoadedRoot(
                    rootID: loadedA.id,
                    expectedStandardizedPath: loadedA.standardizedFullPath
                )
                let admissionB = try await store.admitReusableSnapshotForLoadedRoot(
                    rootID: loadedB.id,
                    expectedStandardizedPath: loadedB.standardizedFullPath
                )
                guard case .admitted = admissionA,
                      case .admitted = admissionB
                else {
                    throw testFailure("Source snapshot admission failed: A=\(admissionA), B=\(admissionB).")
                }

                phase = "first seeded preparation"
                let first = try await makeSeededWorktreePreparation(store: store, git: git, source: sourceA)
                phase = "first seeded publication"
                let firstRoots = try await store.commitSessionWorktreeOwnership(first.preparation)
                guard firstRoots.count == 1, let firstRoot = firstRoots.first else {
                    throw testFailure("The first seeded publication did not install exactly one root.")
                }

                phase = "static cache priming"
                _ = await store.lookupPath("Alpha.swift", profile: .uiAssisted, rootScope: .allLoaded)
                let staticCacheCount = await store.staticPathMatchSnapshotCacheCountForTesting()
                guard staticCacheCount == 1 else {
                    throw testFailure("The first publication did not cache the all-loaded static lookup identity.")
                }

                phase = "second seeded preparation"
                let second = try await makeSeededWorktreePreparation(store: store, git: git, source: sourceB)
                let firstFenceIsCurrent = await store.publishedSeededAuthorityIsCurrentForTesting(rootID: firstRoot.rootID)
                guard firstFenceIsCurrent else {
                    throw testFailure("The first published seeded authority fence was not current before the second commit.")
                }
                try Self.readyMarker.write(to: readyMarkerURL, atomically: true, encoding: .utf8)

                phase = "second seeded publication"
                let secondRoots = try await store.commitSessionWorktreeOwnership(second.preparation)
                guard secondRoots.count == 1 else {
                    throw testFailure("The second seeded publication did not install exactly one root.")
                }

                let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                guard ownership.installedOwnerCount == 2, ownership.rootClaimCount == 2 else {
                    throw testFailure("Both independently published seeded roots must retain ownership.")
                }
                try Self.completionMarker.write(to: completionMarkerURL, atomically: true, encoding: .utf8)

                await store.releaseSessionWorktreeOwnership(ownerID: first.ownerID)
                await store.releaseSessionWorktreeOwnership(ownerID: second.ownerID)
                await store.unloadRoots(ids: [loadedA.id, loadedB.id])
            } catch {
                func sourceDescription(_ source: URL?) -> String {
                    guard let source else { return "not-created" }
                    return "path=\(source.path), exists=\(FileManager.default.fileExists(atPath: source.path))"
                }
                throw testFailure(
                    "Seeded publication helper failed during \(phase), sourceA={\(sourceDescription(sourceA))}, sourceB={\(sourceDescription(sourceB))}: \(error)."
                )
            }
        }

        private func makeSeededWorktreePreparation(
            store: WorkspaceFileContextStore,
            git: GitService,
            source: URL
        ) async throws -> (ownerID: UUID, preparation: WorkspaceSessionWorktreeOwnershipPreparation) {
            let ownerID = UUID()
            let startupContext = WorktreeStartupContext(
                agentSessionID: ownerID,
                flags: WorktreeStartupFeatureFlags(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )
            let expectedGeneration = await store.nextSessionWorktreeOwnershipGeneration(ownerID: ownerID)
            let plan = try GitWorktreeDefaultPathPlanner.plan(
                GitWorktreeDefaultPathPlanner.Request(
                    mainWorktreeRoot: source,
                    existingWorktreeRoots: [source],
                    detach: true,
                    purpose: .agentStart(sessionID: ownerID.uuidString)
                )
            )
            // Receipt witnessing requires an existing, stable app-managed parent before
            // Git creates the destination. The destination itself must remain absent.
            try FileManager.default.createDirectory(
                at: plan.appManagedContainer,
                withIntermediateDirectories: true
            )
            var watchRootIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: plan.appManagedContainer.path,
                isDirectory: &watchRootIsDirectory
            ), watchRootIsDirectory.boolValue else {
                throw testFailure("The receipt witness root was not a directory: \(plan.appManagedContainer.path).")
            }
            let targetExists = FileManager.default.fileExists(atPath: plan.path.path)
            guard !targetExists else {
                throw testFailure("The planned worktree destination already exists: \(plan.path.path).")
            }
            let initializationContext = try GitWorktreeInitializationContext(
                agentSessionID: ownerID,
                correlationID: startupContext.correlationID,
                logicalRootPath: source.path,
                expectedOwnerBindingGeneration: expectedGeneration,
                repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
                observeReceipt: true
            )
            var sourceIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
                  sourceIsDirectory.boolValue
            else {
                throw testFailure("The source repository disappeared before real worktree creation: \(source.path).")
            }
            let creation: GitWorktreeCreateResult
            do {
                creation = try await git.createWorktreeWithResult(
                    request: plan.createRequest,
                    at: source,
                    initializationContext: initializationContext
                )
            } catch {
                throw testFailure(
                    "Real worktree creation failed for source=\(source.path), target=\(plan.path.path), sourceIsDirectory=\(sourceIsDirectory.boolValue): \(error)."
                )
            }
            let receipt = try XCTUnwrap(
                creation.initializationReceipt,
                "The helper requires a real worktree creation receipt to exercise seeded publication."
            )
            let targetPath = (creation.descriptor.path as NSString).standardizingPath
            if let fallback = receipt.fallbackReason() {
                let decisions = WorktreeStartupInstrumentation.receiptDecisions(
                    correlationID: startupContext.correlationID
                )
                throw testFailure(
                    "The real creation receipt is ineligible before Store preparation: fallback=\(fallback), creationFallback=\(String(describing: creation.initializationFallbackReason)), witness=\(receipt.witnessCoverage), decisions=\(decisions)."
                )
            }
            let hint = WorkspaceRootMaterializationHint(
                bindingID: "seeded-publication-\(ownerID.uuidString)",
                standardizedTargetPath: targetPath,
                creationReceipt: receipt,
                correlationID: startupContext.correlationID
            )
            let preparation = try await store.prepareSessionWorktreeOwnership(
                ownerID: ownerID,
                bindingFingerprint: "seeded-publication-\(ownerID.uuidString)",
                physicalRootPaths: [targetPath],
                startupContext: startupContext,
                initializationHintsByPhysicalRootPath: [targetPath: hint]
            )
            guard preparation.pendingSeededRootPreparations.count == 1 else {
                let observation = preparation.materializationHintObservationsByPhysicalRootPath[
                    targetPath
                ]
                let receiptDecisions = WorktreeStartupInstrumentation.receiptDecisions(
                    correlationID: startupContext.correlationID
                )
                throw testFailure(
                    "The helper did not reach the real pending seeded-root commit path for \(source.path): observation=\(String(describing: observation)), creationFallback=\(String(describing: creation.initializationFallbackReason)), receiptDecisions=\(receiptDecisions)."
                )
            }
            return (ownerID, preparation)
        }

        private func requiredMarkerURL(_ key: String) throws -> URL {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else {
                throw NSError(
                    domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing helper environment \(key)"]
                )
            }
            return URL(fileURLWithPath: path)
        }

        private func requiredExistingDirectoryURL(_ key: String) throws -> URL {
            let url = try requiredMarkerURL(key)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw testFailure("Helper fixture parent is not an existing directory: \(url.path).")
            }
            return url
        }

        private func waitForMarker(
            at markerURL: URL,
            deadline: TimeInterval,
            wakeSignal: DispatchSemaphore
        ) throws -> MarkerWaitOutcome {
            if FileManager.default.fileExists(atPath: markerURL.path) { return .observed }
            let directoryURL = markerURL.deletingLastPathComponent()
            let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                throw testFailure("Could not observe helper coordination directory: \(directoryURL.path).")
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename],
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                if FileManager.default.fileExists(atPath: markerURL.path) {
                    wakeSignal.signal()
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            defer { source.cancel() }

            if FileManager.default.fileExists(atPath: markerURL.path) { return .observed }
            guard wakeSignal.wait(timeout: .now() + deadline) == .success else {
                return FileManager.default.fileExists(atPath: markerURL.path) ? .observed : .deadlineExpired
            }
            return FileManager.default.fileExists(atPath: markerURL.path) ? .observed : .childTerminated
        }

        private func helperProcessFailure(
            code: Int,
            description: String,
            reaped: Bool,
            output: String
        ) -> NSError {
            NSError(
                domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(description)\(cleanupResultDescription(reaped: reaped))\n\(output)"
                ]
            )
        }

        private func terminateAndReap(_ process: Process, completion: DispatchSemaphore) -> Bool {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return completion.wait(timeout: .now() + 5) == .success && !process.isRunning
        }

        private func cleanupResultDescription(reaped: Bool) -> String {
            reaped ? "" : " Forced helper cleanup did not reap the child within five seconds."
        }

        private func testFailure(_ description: String) -> NSError {
            NSError(
                domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
#endif
