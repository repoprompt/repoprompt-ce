import CryptoKit
import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class GitBlobCodeMapLocatorStoreTests: XCTestCase {
    func testNamespaceUsesSharedCommonDirectoryForCanonicalAndLinkedLayouts() throws {
        let fixture = try makeRepositoryDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let salt = Data(repeating: 0xA5, count: GitBlobRepositoryNamespace.saltByteCount)
        let canonical = GitRepositoryLayout(
            workTreeRoot: fixture.canonicalRoot,
            dotGitPath: fixture.commonDirectory,
            gitDir: fixture.commonDirectory,
            commonDir: fixture.commonDirectory,
            isWorktree: false
        )
        let linkedGitDirectory = fixture.commonDirectory
            .appendingPathComponent("worktrees/linked", isDirectory: true)
        let linked = GitRepositoryLayout(
            workTreeRoot: fixture.linkedRoot,
            dotGitPath: fixture.linkedRoot.appendingPathComponent(".git"),
            gitDir: linkedGitDirectory,
            commonDir: fixture.commonDirectory,
            isWorktree: true
        )

        let canonicalNamespace = try GitBlobRepositoryNamespace(repositoryLayout: canonical, salt: salt)
        let linkedNamespace = try GitBlobRepositoryNamespace(repositoryLayout: linked, salt: salt)

        XCTAssertEqual(canonicalNamespace, linkedNamespace)
        XCTAssertEqual(canonicalNamespace.rawValue.count, 64)
        XCTAssertFalse(canonicalNamespace.rawValue.contains(fixture.canonicalRoot.lastPathComponent))
        XCTAssertNotEqual(
            canonicalNamespace,
            try GitBlobRepositoryNamespace(
                commonDirectory: fixture.commonDirectory,
                salt: Data(repeating: 0x5A, count: GitBlobRepositoryNamespace.saltByteCount)
            )
        )
    }

    func testSHA1AndSHA256IdentityRoundTripsAndRejectsNoncanonicalValues() throws {
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorCommon")
        defer { try? FileManager.default.removeItem(at: commonDirectory) }
        let namespace = try GitBlobRepositoryNamespace(
            commonDirectory: commonDirectory,
            salt: Data(repeating: 7, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        XCTAssertEqual(
            namespace,
            try GitBlobRepositoryNamespace(
                commonDirectory: commonDirectory,
                salt: Data(repeating: 7, count: GitBlobRepositoryNamespace.saltByteCount)
            )
        )
        let pipeline = try pipelineIdentity(.swift)

        for (format, oid) in [
            (GitObjectFormat.sha1, String(repeating: "1a", count: 20)),
            (.sha256, String(repeating: "2b", count: 32))
        ] {
            let identity = try GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: namespace,
                objectFormat: format,
                blobOID: oid,
                pipelineIdentity: pipeline
            )
            XCTAssertEqual(try GitBlobCodeMapLocatorIdentity(canonicalBytes: identity.canonicalBytes), identity)
            XCTAssertEqual(identity.storageDigestHex.count, 64)
            XCTAssertEqual(identity.shard.count, 2)
            XCTAssertEqual(try GitObjectFormat(gitValue: format.rawValue), format)
        }

        XCTAssertThrowsError(try GitBlobRepositoryNamespace(rawValue: String(repeating: "A", count: 64))) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .invalidNamespace)
        }
        XCTAssertThrowsError(
            try GitBlobRepositoryNamespace(commonDirectory: commonDirectory, salt: Data(repeating: 0, count: 31))
        ) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .invalidNamespaceSalt)
        }
        for (format, oid) in [
            (GitObjectFormat.sha1, String(repeating: "a", count: 39)),
            (.sha1, String(repeating: "A", count: 40)),
            (.sha256, String(repeating: "g", count: 64)),
            (.sha256, String(repeating: "a", count: 40))
        ] {
            XCTAssertThrowsError(
                try GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: namespace,
                    objectFormat: format,
                    blobOID: oid,
                    pipelineIdentity: pipeline
                )
            ) {
                XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .invalidObjectID)
            }
        }

        let valid = try makeIdentity(namespace: namespace, format: .sha1, pipeline: pipeline)
        var unknownFormat = valid.canonicalBytes
        unknownFormat[GitBlobCodeMapLocatorIdentity.domain.utf8.count + 32] = 0
        XCTAssertThrowsError(try GitBlobCodeMapLocatorIdentity(canonicalBytes: unknownFormat)) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .unsupportedObjectFormat)
        }
        XCTAssertThrowsError(try GitBlobCodeMapLocatorIdentity(canonicalBytes: valid.canonicalBytes + Data([0])))

        var oversizedRecord = GitBlobCodeMapLocatorRecordCodec.magic
        oversizedRecord.append(contentsOf: [0, 0, 0, 1])
        oversizedRecord.append(contentsOf: [0, 1, 0, 1])
        oversizedRecord.append(contentsOf: [0, 0, 0, 0])
        oversizedRecord.append(Data(SHA256.hash(data: oversizedRecord)))
        XCTAssertThrowsError(
            try GitBlobCodeMapLocatorRecordCodec.decodeStored(
                oversizedRecord,
                filenameDigest: valid.storageDigestHex
            )
        ) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .inputTooLarge)
        }
    }

    func testStoreRoundTripsBothObjectFormatsAndIsIdempotent() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorRoundTripCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let namespace = try makeNamespace(commonDirectory: commonDirectory)
        let pipeline = try pipelineIdentity(.swift)
        let store = try GitBlobCodeMapLocatorStore(rootURL: root)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)

        for format in [GitObjectFormat.sha1, .sha256] {
            let association = try await makeVerifiedAssociation(
                text: "struct Located {}",
                namespace: namespace,
                format: format,
                pipeline: pipeline,
                artifactStore: artifactStore
            )
            let identity = association.identity
            let key = association.artifactKey
            let initialRead = try await store.read(identity: identity)
            XCTAssertEqual(initialRead, .miss)
            let initialWrite = try await store.write(association: association)
            XCTAssertEqual(initialWrite, .inserted)
            let storedRead = try await store.read(identity: identity)
            XCTAssertEqual(storedRead, .hit(key))
            let repeatedWrite = try await store.write(association: association)
            XCTAssertEqual(repeatedWrite, .alreadyPresent)

            let recordURL = store.recordURL(for: identity)
            XCTAssertEqual(recordURL.lastPathComponent, identity.storageDigestHex)
            XCTAssertEqual(recordURL.deletingLastPathComponent().lastPathComponent, identity.shard)
            XCTAssertEqual(permissions(at: recordURL), 0o600)
        }
    }

    func testAssociationProofRejectsIndependentIdentityKeyAndCASInputsBeforePublication() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipelineIdentity(.swift)
        let rawBytes = Data("struct Proven {}".utf8)
        let source = try makeCleanSource(rawBytes: rawBytes, format: .sha1)
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            return XCTFail("expected clean Git blob provenance")
        }
        let key = makeArtifactKey(text: "struct Proven {}", pipeline: pipeline)
        let identity = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        _ = try await artifactStore.insert(key: key, deterministicOutcome: .readyNoSymbols)
        let handle = try await requireHandle(artifactStore, key: key)
        let hookRecorder = GitBlobLocatorHookRecorder()
        let locatorStore = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: {},
                beforePublish: { await hookRecorder.record() }
            )
        )

        let wrongCountKey = CodeMapArtifactKey(
            rawSHA256: key.rawSHA256,
            rawByteCount: key.rawByteCount + 1,
            pipelineIdentity: pipeline
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: identity,
            artifactKey: wrongCountKey,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .rawByteCountMismatch)
        }

        let wrongDigestKey = makeArtifactKey(text: "struct Pr0ven {}", pipeline: pipeline)
        XCTAssertEqual(wrongDigestKey.rawByteCount, key.rawByteCount)
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: identity,
            artifactKey: wrongDigestKey,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .rawDigestMismatch)
        }

        let pythonPipeline = try pipelineIdentity(.python)
        let wrongPipelineIdentity = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pythonPipeline
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: wrongPipelineIdentity,
            artifactKey: key,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .pipelineMismatch)
        }

        let worktreeFixture = try await WorkspaceCodemapAuthorityTestFixture.make(
            name: #function,
            files: ["Sources/Proven.swift": "struct Proven {}"]
        )
        let worktreeSource = try await worktreeFixture.validatedWorktreeSource(
            loadedRootRelativePath: "Sources/Proven.swift"
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: worktreeSource,
            identity: identity,
            artifactKey: key,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .sourceProvenanceMismatch)
        }

        let otherNamespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "cd", count: 32))
        let wrongNamespaceIdentity = try makeIdentity(
            namespace: otherNamespace,
            format: .sha1,
            pipeline: pipeline,
            rawBytes: rawBytes
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: wrongNamespaceIdentity,
            artifactKey: key,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .repositoryNamespaceMismatch)
        }

        let wrongFormatIdentity = try makeIdentity(
            namespace: repositoryNamespace,
            format: .sha256,
            pipeline: pipeline,
            rawBytes: rawBytes
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: wrongFormatIdentity,
            artifactKey: key,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .objectFormatMismatch)
        }

        let wrongOIDIdentity = try GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            objectFormat: .sha1,
            blobOID: String(repeating: "ab", count: 20),
            pipelineIdentity: pipeline
        )
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: wrongOIDIdentity,
            artifactKey: key,
            casHandle: handle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .gitBlobOIDMismatch)
        }

        let otherKey = makeArtifactKey(text: "struct Other {}", pipeline: pipeline)
        _ = try await artifactStore.insert(key: otherKey, deterministicOutcome: .readyNoSymbols)
        let otherHandle = try await requireHandle(artifactStore, key: otherKey)
        XCTAssertThrowsError(try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: identity,
            artifactKey: key,
            casHandle: otherHandle
        )) {
            XCTAssertEqual($0 as? VerifiedGitBlobCodeMapLocatorAssociationError, .casHandleMismatch)
        }

        let hookCountBeforeValidPublication = await hookRecorder.count
        XCTAssertEqual(hookCountBeforeValidPublication, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locatorStore.recordURL(for: identity).path))
        let valid = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: identity,
            artifactKey: key,
            casHandle: handle
        )
        let writeResult = try await locatorStore.write(association: valid)
        let hookCountAfterValidPublication = await hookRecorder.count
        XCTAssertEqual(writeResult, .inserted)
        XCTAssertEqual(hookCountAfterValidPublication, 1)
    }

    func testCodecAndStoreFailClosedForKeyMismatchAndCorruption() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorCorruptionCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let namespace = try makeNamespace(commonDirectory: commonDirectory)
        let swiftPipeline = try pipelineIdentity(.swift)
        let pythonPipeline = try pipelineIdentity(.python)
        let identity = try makeIdentity(namespace: namespace, format: .sha1, pipeline: swiftPipeline)
        let differentIdentity = try makeIdentity(namespace: namespace, format: .sha256, pipeline: swiftPipeline)
        let pythonKey = makeArtifactKey(text: "class Valid: pass", pipeline: pythonPipeline)

        XCTAssertThrowsError(
            try GitBlobCodeMapLocatorRecordCodec.validate(artifactKey: pythonKey, for: identity)
        ) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .artifactKeyMismatch)
        }

        let store = try GitBlobCodeMapLocatorStore(rootURL: root)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let association = try await makeVerifiedAssociation(
            text: "struct Valid {}",
            namespace: namespace,
            format: .sha1,
            pipeline: swiftPipeline,
            artifactStore: artifactStore
        )
        let storedIdentity = association.identity
        let encoded = try GitBlobCodeMapLocatorRecordCodec.encode(association: association)
        XCTAssertThrowsError(
            try GitBlobCodeMapLocatorRecordCodec.decode(
                encoded,
                expectedIdentity: differentIdentity,
                filenameDigest: differentIdentity.storageDigestHex
            )
        ) {
            XCTAssertEqual($0 as? GitBlobCodeMapLocatorModelError, .identityMismatch)
        }
        let writeResult = try await store.write(association: association)
        XCTAssertEqual(writeResult, .inserted)
        let recordURL = store.recordURL(for: storedIdentity)
        let storedEncoded = try GitBlobCodeMapLocatorRecordCodec.encode(association: association)
        let handle = try FileHandle(forUpdating: recordURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(storedEncoded.count / 2))
        try handle.write(contentsOf: Data([storedEncoded[storedEncoded.count / 2] ^ 0xFF]))
        try handle.synchronize()
        let corruptedRead = try await store.read(identity: storedIdentity)
        XCTAssertEqual(corruptedRead, .corrupt)
        let repairResult = try await store.write(association: association)
        let repairedRead = try await store.read(identity: storedIdentity)
        XCTAssertEqual(repairResult, .inserted)
        XCTAssertEqual(repairedRead, .hit(association.artifactKey))
    }

    func testPersistenceContainsNoCommonDirectoryPathOrRawOIDInFilenames() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "secret-repository-path-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let namespace = try makeNamespace(commonDirectory: commonDirectory)
        let pipeline = try pipelineIdentity(.swift)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let association = try await makeVerifiedAssociation(
            text: "func pathFree() {}",
            namespace: namespace,
            format: .sha1,
            pipeline: pipeline,
            artifactStore: artifactStore
        )
        let identity = association.identity
        let rawOID = identity.blobOID.lowercaseHex
        let store = try GitBlobCodeMapLocatorStore(rootURL: root)
        _ = try await store.write(association: association)

        XCTAssertNil(identity.canonicalBytes.range(of: Data(commonDirectory.path.utf8)))
        let relativePaths = try recursiveRelativePaths(at: root)
        XCTAssertFalse(relativePaths.contains { $0.contains(commonDirectory.lastPathComponent) })
        XCTAssertFalse(relativePaths.contains { $0.contains(rawOID) })
        let record = try Data(contentsOf: store.recordURL(for: identity))
        XCTAssertNil(record.range(of: Data(commonDirectory.path.utf8)))
        XCTAssertNil(record.range(of: Data(commonDirectory.lastPathComponent.utf8)))
    }

    func testStoreRejectsSymlinkLeafWithoutFollowingIt() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorSymlinkCommon")
        let external = try makeDirectory(prefix: "GitBlobLocatorSymlinkExternal")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
            try? FileManager.default.removeItem(at: external)
        }
        let pipeline = try pipelineIdentity(.swift)
        let identity = try makeIdentity(
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline
        )
        let store = try GitBlobCodeMapLocatorStore(rootURL: root)
        let recordURL = store.recordURL(for: identity)
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let externalFile = external.appendingPathComponent("external")
        try Data("outside".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: externalFile)

        do {
            _ = try await store.read(identity: identity)
            XCTFail("expected insecure symlink rejection")
        } catch {
            XCTAssertEqual(error as? GitBlobCodeMapLocatorStoreError, .insecureLeaf)
        }
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), "outside")
    }

    func testCrossInstancePublicationHasNoInsecureLeafWindowAndOneWinner() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorConcurrentCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let pipeline = try pipelineIdentity(.swift)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let association = try await makeVerifiedAssociation(
            text: "struct Concurrent {}",
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline,
            artifactStore: artifactStore
        )
        let identity = association.identity
        let key = association.artifactKey
        let gate = GitBlobLocatorAsyncGate()
        let writer = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: {},
                beforePublish: { await gate.enterAndWait() }
            )
        )
        let reader = try GitBlobCodeMapLocatorStore(rootURL: root)
        let task = Task { try await writer.write(association: association) }
        await gate.waitUntilEntered()
        let readDuringPublish = try await reader.read(identity: identity)
        await gate.release()
        let publishResult = try await task.value
        let readAfterPublish = try await reader.read(identity: identity)
        XCTAssertEqual(readDuringPublish, .miss)
        XCTAssertEqual(publishResult, .inserted)
        XCTAssertEqual(readAfterPublish, .hit(key))

        let first = try GitBlobCodeMapLocatorStore(rootURL: root)
        let second = try GitBlobCodeMapLocatorStore(rootURL: root)
        async let firstResult = first.write(association: association)
        async let secondResult = second.write(association: association)
        let results = try await [firstResult, secondResult]
        XCTAssertEqual(results.count(where: { $0 == .alreadyPresent }), 2)
    }

    func testPublicationRefreshesStaleLayoutBeforeMaintenanceLockAfterRootReplacement() async throws {
        let root = try makeSecureRoot()
        let artifactRoot = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorRootReplacementCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifactRoot)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let pipeline = try pipelineIdentity(.swift)
        let artifactStore = try CodeMapArtifactStore(rootURL: artifactRoot)
        let association = try await makeVerifiedAssociation(
            text: "struct ReplacedRoot {}",
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline,
            artifactStore: artifactStore
        )
        let replacementHook = GitBlobLocatorRootReplacementHook(root: root)
        let store = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: {},
                beforePublish: {},
                beforeMaintenanceLock: { await replacementHook.replaceOnce() }
            )
        )

        let writeResult = try await store.write(association: association)
        XCTAssertEqual(writeResult, .inserted)
        if let failure = await replacementHook.failure {
            throw failure
        }
        let readResult = try await store.read(identity: association.identity)
        XCTAssertEqual(readResult, .hit(association.artifactKey))
    }

    func testConcurrentDistinctPublicationsAtCountQuotaDoNotReportIntegrityCollision() async throws {
        let root = try makeSecureRoot()
        let artifactRoot = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorQuotaConcurrencyCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifactRoot)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let namespace = try makeNamespace(commonDirectory: commonDirectory)
        let pipeline = try pipelineIdentity(.swift)
        let policy = GitBlobCodeMapLocatorStorePolicy(
            maximumRecordCount: 1,
            maximumByteCount: UInt64(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount * 2),
            maintenanceEntryLimit: 16
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: artifactRoot)
        var associations: [VerifiedGitBlobCodeMapLocatorAssociation] = []
        for text in ["struct First {}", "struct Second {}"] {
            try await associations.append(makeVerifiedAssociation(
                text: text,
                namespace: namespace,
                format: .sha1,
                pipeline: pipeline,
                artifactStore: artifactStore
            ))
        }
        let identities = associations.map(\.identity)
        let barrier = GitBlobLocatorAsyncBarrier(participantCount: 2)
        let first = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            policy: policy,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: {},
                beforePublish: { await barrier.arriveAndWait() }
            )
        )
        let second = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            policy: policy,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: {},
                beforePublish: { await barrier.arriveAndWait() }
            )
        )

        let firstAssociation = associations[0]
        let secondAssociation = associations[1]
        async let firstResult = first.write(association: firstAssociation)
        async let secondResult = second.write(association: secondAssociation)
        let results = try await [firstResult, secondResult]

        XCTAssertEqual(results, [.inserted, .inserted])
        let maintenance = try await first.maintain()
        XCTAssertEqual(maintenance.remainingRecordCount, 1)
        let reads = try await [
            first.read(identity: identities[0]),
            first.read(identity: identities[1])
        ]
        XCTAssertEqual(reads.count(where: { if case .hit = $0 { true } else { false } }), 1)
    }

    func testMaintenanceClosesEachRecordDescriptorDuringLargePass() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorDescriptorCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let pipeline = try pipelineIdentity(.swift)
        let identity = try makeIdentity(
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline
        )
        let entryCount = 512
        let policy = GitBlobCodeMapLocatorStorePolicy(
            maximumRecordCount: entryCount,
            maximumByteCount: UInt64(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount * entryCount),
            maintenanceEntryLimit: entryCount + 1
        )
        let store = try GitBlobCodeMapLocatorStore(rootURL: root, policy: policy)
        let shard = store.recordURL(for: identity).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: shard,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for index in 0 ..< entryCount {
            let temporary = shard.appendingPathComponent(".tmp.fd-scope.\(index)")
            try Data().write(to: temporary)
            XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        }

        let result = try await store.maintain()

        XCTAssertEqual(result.examinedCount, entryCount)
        XCTAssertEqual(result.removedTemporaryCount, entryCount)
        XCTAssertEqual(result.remainingRecordCount, 0)
    }

    func testMaintenanceEnforcesCountAndByteQuotasAndCleansCrashResidueOnRestart() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorMaintenanceCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let namespace = try makeNamespace(commonDirectory: commonDirectory)
        let pipeline = try pipelineIdentity(.swift)
        let policy = GitBlobCodeMapLocatorStorePolicy(
            maximumRecordCount: 2,
            maximumByteCount: UInt64(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount * 2),
            maintenanceEntryLimit: 32
        )
        let store = try GitBlobCodeMapLocatorStore(rootURL: root, policy: policy)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        var associations: [VerifiedGitBlobCodeMapLocatorAssociation] = []
        for index in 0 ..< 3 {
            try await associations.append(makeVerifiedAssociation(
                text: "record-\(index)",
                namespace: namespace,
                format: .sha1,
                pipeline: pipeline,
                artifactStore: artifactStore
            ))
        }
        let identities = associations.map(\.identity)
        for association in associations {
            _ = try await store.write(association: association)
        }
        let countResult = try await store.maintain()
        XCTAssertLessThanOrEqual(countResult.remainingRecordCount, 2)

        let surviving = identities.filter { FileManager.default.fileExists(atPath: store.recordURL(for: $0).path) }
        let shard = try XCTUnwrap(surviving.first).shard
        let shardURL = store.recordURL(for: surviving[0]).deletingLastPathComponent()
        let temporary = shardURL.appendingPathComponent(".tmp.999999.crash")
        try Data("residue".utf8).write(to: temporary)
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        let corruptIdentity = try XCTUnwrap(identities.first { !FileManager.default.fileExists(atPath: store.recordURL(for: $0).path) })
        let corruptURL = store.recordURL(for: corruptIdentity)
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("corrupt".utf8).write(to: corruptURL)
        XCTAssertEqual(chmod(corruptURL.path, 0o600), 0)

        let restarted = try GitBlobCodeMapLocatorStore(rootURL: root, policy: policy)
        let cleanup = try await restarted.maintain()
        XCTAssertGreaterThanOrEqual(cleanup.removedTemporaryCount, 1)
        XCTAssertGreaterThanOrEqual(cleanup.removedCorruptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(shard.count == 2)

        let sampleRecord = try GitBlobCodeMapLocatorRecordCodec.encode(association: associations[0])
        let bytePolicy = GitBlobCodeMapLocatorStorePolicy(
            maximumRecordCount: 8,
            maximumByteCount: UInt64(sampleRecord.count + 16),
            maintenanceEntryLimit: 32
        )
        let byteRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: byteRoot) }
        let byteStore = try GitBlobCodeMapLocatorStore(rootURL: byteRoot, policy: bytePolicy)
        let byteArtifactStore = try CodeMapArtifactStore(rootURL: byteRoot)
        for index in 0 ..< 2 {
            let association = try await makeVerifiedAssociation(
                text: String(repeating: "x", count: 40 + index),
                namespace: namespace,
                format: .sha1,
                pipeline: pipeline,
                artifactStore: byteArtifactStore
            )
            _ = try await byteStore.write(association: association)
        }
        let byteResult = try await byteStore.maintain()
        XCTAssertLessThanOrEqual(byteResult.remainingByteCount, bytePolicy.maximumByteCount)
    }

    func testReadMapsTruncateAndAtomicReplaceRacesToCorruptOrMiss() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorReadRaceCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let pipeline = try pipelineIdentity(.swift)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let association = try await makeVerifiedAssociation(
            text: "struct Race {}",
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline,
            artifactStore: artifactStore
        )
        let identity = association.identity
        let writer = try GitBlobCodeMapLocatorStore(rootURL: root)
        _ = try await writer.write(association: association)
        let recordURL = writer.recordURL(for: identity)

        let truncateGate = GitBlobLocatorAsyncGate()
        let truncateReader = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: { await truncateGate.enterAndWait() },
                beforePublish: {}
            )
        )
        let truncateTask = Task { try await truncateReader.read(identity: identity) }
        await truncateGate.waitUntilEntered()
        let handle = try FileHandle(forWritingTo: recordURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        await truncateGate.release()
        let truncatedRead = try await truncateTask.value
        XCTAssertEqual(truncatedRead, .corrupt)

        try FileManager.default.removeItem(at: recordURL)
        _ = try await writer.write(association: association)
        let original = try Data(contentsOf: recordURL)
        let replaceGate = GitBlobLocatorAsyncGate()
        let replaceReader = try GitBlobCodeMapLocatorStore(
            rootURL: root,
            hooks: GitBlobCodeMapLocatorStoreHooks(
                afterReadAdmission: { await replaceGate.enterAndWait() },
                beforePublish: {}
            )
        )
        let replaceTask = Task { try await replaceReader.read(identity: identity) }
        await replaceGate.waitUntilEntered()
        let replacement = recordURL.deletingLastPathComponent().appendingPathComponent("replacement")
        try original.write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        XCTAssertEqual(rename(replacement.path, recordURL.path), 0)
        await replaceGate.release()
        let replacedRead = try await replaceTask.value
        XCTAssertEqual(replacedRead, .corrupt)
    }

    func testStoreRejectsWrongModeFileTypeHardLinkAndDirectorySymlink() async throws {
        let root = try makeSecureRoot()
        let commonDirectory = try makeDirectory(prefix: "GitBlobLocatorSecurityCommon")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: commonDirectory)
        }
        let pipeline = try pipelineIdentity(.swift)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let association = try await makeVerifiedAssociation(
            text: "struct Secure {}",
            namespace: makeNamespace(commonDirectory: commonDirectory),
            format: .sha1,
            pipeline: pipeline,
            artifactStore: artifactStore
        )
        let identity = association.identity
        let store = try GitBlobCodeMapLocatorStore(rootURL: root)
        _ = try await store.write(association: association)
        let recordURL = store.recordURL(for: identity)

        XCTAssertEqual(chmod(recordURL.path, 0o644), 0)
        await XCTAssertThrowsLocatorSecurity { try await store.read(identity: identity) }
        XCTAssertEqual(chmod(recordURL.path, 0o600), 0)
        let hardLink = recordURL.deletingLastPathComponent().appendingPathComponent("hard-link")
        XCTAssertEqual(link(recordURL.path, hardLink.path), 0)
        await XCTAssertThrowsLocatorSecurity { try await store.read(identity: identity) }
        try FileManager.default.removeItem(at: hardLink)

        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
        await XCTAssertThrowsLocatorSecurity { try await store.read(identity: identity) }
        try FileManager.default.removeItem(at: recordURL)

        let shardURL = recordURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: shardURL)
        let external = try makeDirectory(prefix: "GitBlobLocatorExternalShard")
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: shardURL, withDestinationURL: external)
        do {
            _ = try await store.read(identity: identity)
            XCTFail("expected directory symlink rejection")
        } catch {
            XCTAssertNotNil(error as? GitBlobCodeMapLocatorStoreError)
        }
    }

    func testStoreRejectsSymlinkedWrongModeAndSwappedRoots() async throws {
        let realRoot = try makeSecureRoot()
        let parent = realRoot.deletingLastPathComponent()
        let alias = parent.appendingPathComponent("locator-root-alias-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: realRoot)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        XCTAssertThrowsError(try GitBlobCodeMapLocatorStore(rootURL: alias))

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(alias.path, 0o755), 0)
        XCTAssertThrowsError(try GitBlobCodeMapLocatorStore(rootURL: alias))

        XCTAssertEqual(chmod(alias.path, 0o700), 0)
        let store = try GitBlobCodeMapLocatorStore(rootURL: alias)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        let pipeline = try pipelineIdentity(.swift)
        let identity = try makeIdentity(
            namespace: makeNamespace(commonDirectory: realRoot),
            format: .sha1,
            pipeline: pipeline
        )
        do {
            _ = try await store.read(identity: identity)
            XCTFail("expected swapped-root rejection")
        } catch {
            XCTAssertNotNil(error as? GitBlobCodeMapLocatorStoreError)
        }
    }

    private func XCTAssertThrowsLocatorSecurity(
        _ operation: () async throws -> GitBlobCodeMapLocatorReadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected locator security rejection", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GitBlobCodeMapLocatorStoreError, .insecureLeaf, file: file, line: line)
        }
    }

    private func pipelineIdentity(_ language: LanguageType) throws -> CodeMapPipelineIdentity {
        try SyntaxManager().pipelineIdentity(for: language, decoderPolicy: .workspaceAutomaticV1)
    }

    private func makeNamespace(commonDirectory: URL) throws -> GitBlobRepositoryNamespace {
        try GitBlobRepositoryNamespace(
            commonDirectory: commonDirectory,
            salt: Data(repeating: 0x3C, count: GitBlobRepositoryNamespace.saltByteCount)
        )
    }

    private func makeIdentity(
        namespace: GitBlobRepositoryNamespace,
        format: GitObjectFormat,
        pipeline: CodeMapPipelineIdentity,
        rawBytes: Data = Data("locator-identity".utf8)
    ) throws -> GitBlobCodeMapLocatorIdentity {
        try GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: namespace,
            objectFormat: format,
            blobOID: gitBlobOID(rawBytes, format: format),
            pipelineIdentity: pipeline
        )
    }

    private func makeArtifactKey(text: String, pipeline: CodeMapPipelineIdentity) -> CodeMapArtifactKey {
        let data = Data(text.utf8)
        return CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            rawByteCount: UInt64(data.count),
            pipelineIdentity: pipeline
        )
    }

    private func makeVerifiedAssociation(
        text: String,
        namespace _: GitBlobRepositoryNamespace,
        format: GitObjectFormat,
        pipeline: CodeMapPipelineIdentity,
        artifactStore: CodeMapArtifactStore
    ) async throws -> VerifiedGitBlobCodeMapLocatorAssociation {
        let rawBytes = Data(text.utf8)
        let source = try makeCleanSource(rawBytes: rawBytes, format: format)
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let key = makeArtifactKey(text: text, pipeline: pipeline)
        let identity = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        _ = try await artifactStore.insert(key: key, deterministicOutcome: .readyNoSymbols)
        let handle = try await requireHandle(artifactStore, key: key)
        return try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: identity,
            artifactKey: key,
            casHandle: handle
        )
    }

    private func makeCleanSource(
        rawBytes: Data,
        format: GitObjectFormat
    ) throws -> CodeMapSourceSnapshot {
        try WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: rawBytes,
            objectFormat: format
        )
    }

    private func requireHandle(
        _ artifactStore: CodeMapArtifactStore,
        key: CodeMapArtifactKey
    ) async throws -> CodeMapArtifactHandle {
        switch try await artifactStore.lookup(key: key) {
        case let .hit(_, verifiedHandle): verifiedHandle
        case .miss:
            XCTFail("expected verified CAS handle")
            throw GitBlobCodeMapLocatorStoreError.integrityCollision
        }
    }

    private func gitBlobOID(_ bytes: Data, format: GitObjectFormat) -> String {
        var canonical = Data("blob \(bytes.count)\0".utf8)
        canonical.append(bytes)
        let digest = switch format {
        case .sha1: Data(Insecure.SHA1.hash(data: canonical))
        case .sha256: Data(SHA256.hash(data: canonical))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeSecureRoot() throws -> URL {
        let root = try makeDirectory(prefix: "GitBlobCodeMapLocatorStoreTests")
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func makeDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(directory.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }

    private func makeRepositoryDirectories() throws -> (
        base: URL,
        canonicalRoot: URL,
        linkedRoot: URL,
        commonDirectory: URL
    ) {
        let base = try makeDirectory(prefix: "GitBlobLocatorLayouts")
        let canonical = base.appendingPathComponent("canonical", isDirectory: true)
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        let common = canonical.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        return (base, canonical, linked, common)
    }

    private func permissions(at url: URL) -> Int {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return Int(status.st_mode & mode_t(0o777))
    }

    private func recursiveRelativePaths(at root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
    }
}

private actor GitBlobLocatorHookRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor GitBlobLocatorRootReplacementHook {
    private let root: URL
    private var didReplace = false
    private(set) var failure: Error?

    init(root: URL) {
        self.root = root
    }

    func replaceOnce() {
        guard !didReplace else { return }
        didReplace = true
        do {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            XCTAssertEqual(chmod(root.path, 0o700), 0)
        } catch {
            failure = error
        }
    }
}

private actor GitBlobLocatorAsyncBarrier {
    private let participantCount: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participantCount {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor GitBlobLocatorAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
