import Foundation
@testable import RepoPrompt
import XCTest

final class GitBlobSourceMaterializationServiceTests: XCTestCase {
    func testRealGitObjectMaterializationDoesNotReadWorktreeFallback() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let sourceText = "struct ObjectOnly {}\n"
        let root = try fixture.makeRepository(
            named: "repository",
            files: ["Sources/ObjectOnly.swift": sourceText]
        )
        let gitService = GitService()
        let capabilityService = WorkspaceCodemapGitCapabilityService(
            gitService: gitService,
            namespaceSalt: Data(repeating: 0x55, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        let state = await capabilityService.resolve(
            root: WorkspaceCodemapGitCapabilityRequest(
                rootID: UUID(),
                rootLifetimeID: UUID(),
                loadedRootURL: root
            )
        )
        guard case let .eligible(capability) = state else {
            return XCTFail("Expected eligible Git capability, received \(state)")
        }
        let oid = try GitBlobOID(
            objectFormat: capability.objectFormat,
            lowercaseHex: fixture.headBlobOID(for: "Sources/ObjectOnly.swift", at: root)
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Sources/ObjectOnly.swift")
        )

        let validated = try await GitBlobSourceMaterializationService(gitService: gitService)
            .materialize(capability: capability, blobOID: oid)
        XCTAssertEqual(validated.rawBytes, Data(sourceText.utf8))
        XCTAssertEqual(validated.blobOID, oid)
    }

    func testVerifiedSHA1AndSHA256BytesProduceClosedGitSourceProvenance() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let bytes = Data([0x00, 0xFF, 0x41, 0x0A])

        for format in [GitObjectFormat.sha1, .sha256] {
            let capability = try makeCapability(format: format, fixture: fixture)
            let oid = GitBlobOID.blob(bytes: bytes, objectFormat: format)
            let service = GitBlobSourceMaterializationService(
                client: GitBlobSourceMaterializationClient(
                    size: { _, _ in UInt64(bytes.count) },
                    bytes: { _, _, _ in bytes }
                )
            )

            let validated = try await service.materialize(capability: capability, blobOID: oid)
            XCTAssertEqual(validated.rawBytes, bytes)
            XCTAssertEqual(validated.blobOID, oid)
            XCTAssertEqual(validated.repositoryNamespace, capability.repositoryNamespace)
            let source = CodeMapSourceSnapshot(validatedGitBlob: validated)
            XCTAssertEqual(
                source.provenance,
                .cleanGitBlob(repositoryNamespace: capability.repositoryNamespace, blobOID: oid)
            )
        }
    }

    func testWrongOIDAndTruncatedOutputAreRejectedWithoutFallback() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let expectedBytes = Data("expected".utf8)
        let expectedOID = GitBlobOID.blob(bytes: expectedBytes, objectFormat: .sha1)

        let wrongBytes = Data("different".utf8)
        let wrongOIDService = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(wrongBytes.count) },
                bytes: { _, _, _ in wrongBytes }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await wrongOIDService.materialize(capability: capability, blobOID: expectedOID)
        } errorHandler: { error in
            XCTAssertEqual(error as? GitBlobSourceMaterializationError, .oidMismatch)
        }

        let truncatedService = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(expectedBytes.count + 1) },
                bytes: { _, _, _ in expectedBytes }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await truncatedService.materialize(capability: capability, blobOID: expectedOID)
        } errorHandler: { error in
            XCTAssertEqual(
                error as? GitBlobSourceMaterializationError,
                .truncated(expected: UInt64(expectedBytes.count + 1), actual: expectedBytes.count)
            )
        }
    }

    func testDeclaredAndStreamedOversizeAreBoundedBeforePublication() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let bytes = Data("bounded".utf8)
        let oid = GitBlobOID.blob(bytes: bytes, objectFormat: .sha1)
        let policy = GitBlobSourceMaterializationPolicy(maximumRawByteCount: 4)

        let declaredOversize = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in 5 },
                bytes: { _, _, _ in XCTFail("Oversized declarations must not read object bytes")
                    return Data()
                }
            ),
            policy: policy
        )
        await XCTAssertThrowsErrorAsync {
            try await declaredOversize.materialize(capability: capability, blobOID: oid)
        } errorHandler: { error in
            XCTAssertEqual(error as? GitBlobSourceMaterializationError, .oversized(limit: 4, actual: 5))
        }

        let streamedOversize = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in 4 },
                bytes: { _, _, requestedByteCount in
                    XCTAssertEqual(requestedByteCount, 4)
                    throw GitBlobObjectReadError.stdoutLimitExceeded
                }
            ),
            policy: policy
        )
        await XCTAssertThrowsErrorAsync {
            try await streamedOversize.materialize(capability: capability, blobOID: oid)
        } errorHandler: { error in
            XCTAssertEqual(
                error as? GitBlobSourceMaterializationError,
                .excess(expected: 4, actualAtLeast: 5)
            )
        }
    }

    func testDeclaredSizeBoundsCaptureAndLengthMismatchSkipsHashing() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let exactBytes = Data("four".utf8)
        let oid = GitBlobOID.blob(bytes: exactBytes, objectFormat: .sha1)
        let policy = GitBlobSourceMaterializationPolicy(maximumRawByteCount: exactBytes.count)

        let exactHashRecorder = MaterializationHashRecorder()
        let exactService = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(exactBytes.count) },
                bytes: { _, _, requestedByteCount in
                    XCTAssertEqual(requestedByteCount, exactBytes.count)
                    return exactBytes
                }
            ),
            policy: policy,
            oidForBytes: { bytes, format in
                exactHashRecorder.record()
                return GitBlobOID.blob(bytes: bytes, objectFormat: format)
            }
        )
        let validated = try await exactService.materialize(capability: capability, blobOID: oid)
        XCTAssertEqual(validated.rawBytes, exactBytes)
        XCTAssertEqual(exactHashRecorder.count, 1)

        let mismatches: [(Data, GitBlobSourceMaterializationError)] = [
            (
                Data(exactBytes.dropLast()),
                .truncated(expected: UInt64(exactBytes.count), actual: exactBytes.count - 1)
            ),
            (
                exactBytes + Data([0x00]),
                .excess(expected: UInt64(exactBytes.count), actualAtLeast: UInt64(exactBytes.count + 1))
            )
        ]
        for (returnedBytes, expectedError) in mismatches {
            let mismatchHashRecorder = MaterializationHashRecorder()
            let service = GitBlobSourceMaterializationService(
                client: GitBlobSourceMaterializationClient(
                    size: { _, _ in UInt64(exactBytes.count) },
                    bytes: { _, _, requestedByteCount in
                        XCTAssertEqual(requestedByteCount, exactBytes.count)
                        return returnedBytes
                    }
                ),
                policy: policy,
                oidForBytes: { bytes, format in
                    mismatchHashRecorder.record()
                    return GitBlobOID.blob(bytes: bytes, objectFormat: format)
                }
            )
            await XCTAssertThrowsErrorAsync {
                try await service.materialize(capability: capability, blobOID: oid)
            } errorHandler: { error in
                XCTAssertEqual(error as? GitBlobSourceMaterializationError, expectedError)
            }
            XCTAssertEqual(mismatchHashRecorder.count, 0)
        }
    }

    func testSizeAndDiagnosticOverflowRemainTyped() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let bytes = Data("typed".utf8)
        let oid = GitBlobOID.blob(bytes: bytes, objectFormat: .sha1)

        let scenarios: [(GitBlobObjectReadError, GitBlobSourceMaterializationError)] = [
            (
                .stdoutLimitExceeded,
                .commandOutputOverflow(phase: .declaredSize, stream: .stdout)
            ),
            (
                .stderrLimitExceeded,
                .commandOutputOverflow(phase: .declaredSize, stream: .stderr)
            )
        ]
        for (readError, expectedError) in scenarios {
            let service = GitBlobSourceMaterializationService(
                client: GitBlobSourceMaterializationClient(
                    size: { _, _ in throw readError },
                    bytes: { _, _, _ in XCTFail("Size overflow must not read object bytes")
                        return Data()
                    }
                )
            )
            await XCTAssertThrowsErrorAsync {
                try await service.materialize(capability: capability, blobOID: oid)
            } errorHandler: { error in
                XCTAssertEqual(error as? GitBlobSourceMaterializationError, expectedError)
            }
        }

        let byteDiagnosticOverflow = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(bytes.count) },
                bytes: { _, _, _ in throw GitBlobObjectReadError.stderrLimitExceeded }
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await byteDiagnosticOverflow.materialize(capability: capability, blobOID: oid)
        } errorHandler: { error in
            XCTAssertEqual(
                error as? GitBlobSourceMaterializationError,
                .commandOutputOverflow(phase: .bytes, stream: .stderr)
            )
        }
    }

    func testCancellationPropagatesAndPublishesNoSnapshot() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let bytes = Data("cancel".utf8)
        let oid = GitBlobOID.blob(bytes: bytes, objectFormat: .sha1)
        let gate = MaterializationCancellationGate()
        let service = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(bytes.count) },
                bytes: { _, _, _ in
                    await gate.enter()
                    try await Task.sleep(for: .seconds(60))
                    return bytes
                }
            )
        )

        let task = Task { try await service.materialize(capability: capability, blobOID: oid) }
        await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not publish a validated source snapshot")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationDuringOIDHashingPublishesNoSnapshot() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let capability = try makeCapability(format: .sha1, fixture: fixture)
        let bytes = Data("hash cancellation".utf8)
        let oid = GitBlobOID.blob(bytes: bytes, objectFormat: .sha1)
        let gate = MaterializationHashCancellationGate()
        let service = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(bytes.count) },
                bytes: { _, _, _ in bytes }
            ),
            oidForBytes: { bytes, format in
                gate.hash(bytes: bytes, objectFormat: format)
            }
        )

        let task = Task { try await service.materialize(capability: capability, blobOID: oid) }
        await gate.waitUntilHashing()
        task.cancel()
        gate.releaseHashing()
        do {
            _ = try await task.value
            XCTFail("Cancellation after OID verification must not publish a validated source snapshot")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeCapability(
        format: GitObjectFormat,
        fixture: ReviewGitRepositoryFixture
    ) throws -> GitCodemapRootCapability {
        let root = fixture.sandbox.appendingPathComponent("root-\(format.rawValue)", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let layout = GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: gitDirectory,
            gitDir: gitDirectory,
            commonDir: gitDirectory,
            isWorktree: false
        )
        let namespace = try GitBlobRepositoryNamespace(
            repositoryLayout: layout,
            salt: Data(repeating: 0x33, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        let epoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let authority = WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: 1,
            repositoryNamespace: namespace,
            objectFormat: format,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "config",
            attributeGeneration: "attributes",
            sparseGeneration: "sparse",
            metadataGeneration: "metadata"
        )
        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: gitDirectory,
            mainWorktreeRoot: root
        )
        return GitCodemapRootCapability(
            rootEpoch: epoch,
            repositoryLayout: layout,
            repositoryIdentity: repositoryIdentity,
            worktreeID: GitWorktreeIdentity.worktreeID(
                repositoryID: repositoryIdentity.repositoryID,
                gitDir: gitDirectory,
                isMain: true,
                path: root
            ),
            repositoryNamespace: namespace,
            objectFormat: format,
            repositoryRelativeLoadedRootPrefix: "",
            repositoryAuthority: authority
        )
    }
}

private actor MaterializationCancellationGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class MaterializationHashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
    }
}

private final class MaterializationHashCancellationGate: @unchecked Sendable {
    private let hashingEntered = DispatchSemaphore(value: 0)
    private let hashingRelease = DispatchSemaphore(value: 0)

    func hash(bytes: Data, objectFormat: GitObjectFormat) -> GitBlobOID {
        hashingEntered.signal()
        hashingRelease.wait()
        return GitBlobOID.blob(bytes: bytes, objectFormat: objectFormat)
    }

    func waitUntilHashing() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.hashingEntered.wait()
                continuation.resume()
            }
        }
    }

    func releaseHashing() {
        hashingRelease.signal()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
