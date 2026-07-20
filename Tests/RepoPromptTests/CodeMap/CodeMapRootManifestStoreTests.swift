import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class CodeMapRootManifestStoreTests: XCTestCase {
    func testNamespaceSeparatesCanonicalLinkedSubdirectoryAndPipelineIdentity() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let canonical = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x11,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Canonical", trailingNewline: false)
        )
        let linked = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x22,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Linked", trailingNewline: false)
        )
        let subdirectory = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x11,
            prefix: "Sources",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Subdirectory", trailingNewline: false)
        )
        let python = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x11,
            prefix: "",
            path: "Sources/App.py",
            text: "class App: pass",
            language: .python
        )
        let otherRepository = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-other-repository",
            worktreeByte: 0x11,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("OtherRepository", trailingNewline: false)
        )
        XCTAssertEqual(canonical.namespace.repositoryNamespace, linked.namespace.repositoryNamespace)
        XCTAssertNotEqual(canonical.namespace.repositoryNamespace, otherRepository.namespace.repositoryNamespace)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, linked.namespace.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, subdirectory.namespace.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, python.namespace.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, otherRepository.namespace.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.worktreeIdentity, linked.namespace.worktreeIdentity)
        XCTAssertEqual(subdirectory.namespace.repositoryRelativeLoadedRootPrefix, "Sources")

        let sha256 = try namespaceLike(canonical.namespace, objectFormat: .sha256)
        let schemaTwo = try namespaceLike(canonical.namespace, schemaVersion: 2)
        let policyTwo = try namespaceLike(canonical.namespace, policyVersion: 2)
        let repositoryEpochTwo = try namespaceLike(canonical.namespace, repositoryBindingEpoch: "repository-binding-2")
        let worktreeEpochTwo = try namespaceLike(canonical.namespace, worktreeBindingEpoch: "worktree-binding-2")
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, schemaTwo.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, policyTwo.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, sha256.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, repositoryEpochTwo.storageDigestHex)
        XCTAssertNotEqual(canonical.namespace.storageDigestHex, worktreeEpochTwo.storageDigestHex)
        XCTAssertEqual(
            try CodeMapRootManifestNamespace(canonicalBytes: canonical.namespace.canonicalBytes),
            canonical.namespace
        )
    }

    func testNamespaceContainsOnlyCanonicalPathsWithinLoadedRootPrefix() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x12,
            prefix: "Sources",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("CanonicalPath", trailingNewline: false)
        )

        for path in ["Sources/App.swift", "Sources/Nested/App.swift"] {
            XCTAssertTrue(fixture.namespace.contains(repositoryRelativePath: path), path)
        }
        for path in [
            "", "Sources", "Source/App.swift", "Sources2/App.swift", "/Sources/App.swift",
            "Sources/App.swift/", "Sources//App.swift", "Sources/./App.swift", "Sources/../App.swift"
        ] {
            XCTAssertFalse(fixture.namespace.contains(repositoryRelativePath: path), path)
        }
        for prefix in ["/Sources", "Sources/", "Sources//Nested", "Sources/./Nested", "Sources/../Nested"] {
            XCTAssertThrowsError(
                try namespaceLike(fixture.namespace, repositoryRelativeLoadedRootPrefix: prefix),
                prefix
            ) {
                XCTAssertEqual($0 as? CodeMapRootManifestModelError, .invalidRelativePath)
            }
        }
    }

    func testVerifiedCleanSnapshotRoundTripsWithoutAbsoluteDisplayOrSourceLeakage() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let secretSource = "struct SecretSourceBody_\(UUID().uuidString.replacingOccurrences(of: "-", with: "")) {}"
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x31,
            prefix: "Sources",
            path: "Sources/Nested/App.swift",
            text: secretSource
        )
        let store = try CodeMapRootManifestStore(rootURL: root, accessEpochSeconds: { 0 })

        let initial = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(initial, .miss)
        let insert = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        XCTAssertEqual(insert, .inserted(manifestGeneration: 1))
        guard case let .hit(snapshot) = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("expected complete manifest hit")
        }
        XCTAssertEqual(snapshot.records, [fixture.record])
        XCTAssertEqual(snapshot.records.first?.repositoryRelativePath, "Sources/Nested/App.swift")
        XCTAssertEqual(snapshot.records.first?.locatorIdentity.blobOID, fixture.record.locatorIdentity.blobOID)
        XCTAssertEqual(snapshot.records.first?.artifactKey, fixture.record.artifactKey)
        XCTAssertEqual(snapshot.records.first?.contribution?.schemaVersion, 1)
        XCTAssertEqual(snapshot.records.first?.contribution?.policyVersion, 1)
        XCTAssertNotNil(snapshot.records.first?.contributionEnvelope)
        XCTAssertEqual(
            snapshot.records.first?.contributionEnvelope,
            fixture.record.contributionEnvelope
        )

        let unchanged = try await store.updateCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 999
        )
        XCTAssertEqual(unchanged, .unchanged(manifestGeneration: 1))
        let manifestData = try Data(contentsOf: store.manifestURL(for: fixture.namespace))
        let persisted = try CodeMapRootManifestCodec.decodeStored(
            manifestData,
            filenameDigest: fixture.namespace.storageDigestHex
        )
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 999)
        do {
            _ = try await store.updateCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: persisted.records,
                lastAccessEpochSeconds: 1000
            )
            XCTFail("codec-decoded records must not become a publication proof")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestModelError, .corruptRecord)
        }
        XCTAssertEqual(try decodeManifest(fixture.namespace, from: store).lastAccessEpochSeconds, 999)
        XCTAssertNotNil(manifestData.range(of: Data("Sources/Nested/App.swift".utf8)))
        XCTAssertNil(manifestData.range(of: Data(root.path.utf8)))
        XCTAssertNil(manifestData.range(of: Data("logical://display/App.swift".utf8)))
        XCTAssertNil(manifestData.range(of: Data(secretSource.utf8)))
        XCTAssertFalse(try recursiveRelativePaths(at: root).contains { $0.contains("Sources/Nested/App.swift") })
        let didRemove = try await store.removeNamespace(fixture.namespace)
        XCTAssertTrue(didRemove)
        let removed = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(removed, .miss)
    }

    func testVerifiedCleanRecordRequiresExactOutcomeContributionContract() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x32,
            prefix: "",
            path: "Sources/Baseline.swift",
            text: SwiftFixtureSource.emptyStruct("Baseline", trailingNewline: false)
        )
        let readyArtifact = makeArtifact(name: "ReadySymbol")
        let outcomes: [(CodeMapSyntaxArtifactOutcome, CodeMapRootManifestOutcome)] = [
            (.ready(readyArtifact), .ready),
            (.readyNoSymbols, .readyNoSymbols),
            (.oversize(.utf8Bytes(actual: 20, limit: 10)), .terminalOversize),
            (.decodeFailed(.undecodable), .terminalDecodeFailure),
            (.parseFailed(.parserReturnedNilTree), .terminalParseFailure)
        ]

        for (index, entry) in outcomes.enumerated() {
            let prepared = try await makeAssociation(
                artifactStore: artifactStore,
                namespaceScope: #function,
                text: "struct Outcome\(index) {}",
                pipeline: fixture.namespace.pipelineIdentity,
                objectFormat: fixture.namespace.objectFormat,
                outcome: entry.0
            )
            let contribution: CodeMapSelectionGraphContribution? = switch entry.0 {
            case let .ready(artifact):
                CodeMapSelectionGraphContribution(artifactKey: prepared.key, artifact: artifact)
            case .readyNoSymbols:
                CodeMapSelectionGraphContribution(
                    artifactKey: prepared.key,
                    definitions: [],
                    references: []
                )
            case .oversize, .decodeFailed, .parseFailed:
                nil
            }
            let record = try CodeMapRootManifestRecord.verifiedClean(
                namespace: fixture.namespace,
                repositoryRelativePath: "Sources/Outcome\(index).swift",
                gitMode: .regular,
                association: prepared.association,
                contribution: contribution,
                authority: fixture.authority,
                bindingGeneration: UInt64(index + 1)
            )
            XCTAssertEqual(record.outcome, entry.1)
            XCTAssertEqual(record.contribution, contribution.map(CodeMapRootManifestContributionIdentity.init))

            let invalidContribution = contribution == nil
                ? CodeMapSelectionGraphContribution(
                    artifactKey: prepared.key,
                    definitions: [],
                    references: []
                )
                : nil
            XCTAssertThrowsError(try CodeMapRootManifestRecord.verifiedClean(
                namespace: fixture.namespace,
                repositoryRelativePath: "Sources/Rejected\(index).swift",
                gitMode: .regular,
                association: prepared.association,
                contribution: invalidContribution,
                authority: fixture.authority,
                bindingGeneration: UInt64(index + 10)
            )) {
                XCTAssertEqual($0 as? CodeMapRootManifestModelError, .invalidContribution)
            }
        }

        let ready = try await makeAssociation(
            artifactStore: artifactStore,
            namespaceScope: #function,
            text: SwiftFixtureSource.emptyStruct("ReadyMismatch", trailingNewline: false),
            pipeline: fixture.namespace.pipelineIdentity,
            objectFormat: fixture.namespace.objectFormat,
            outcome: .ready(readyArtifact)
        )
        let wrongReadyContribution = CodeMapSelectionGraphContribution(
            artifactKey: ready.key,
            definitions: [],
            references: []
        )
        XCTAssertThrowsError(try CodeMapRootManifestRecord.verifiedClean(
            namespace: fixture.namespace,
            repositoryRelativePath: "Sources/ReadyMismatch.swift",
            gitMode: .regular,
            association: ready.association,
            contribution: wrongReadyContribution,
            authority: fixture.authority,
            bindingGeneration: 20
        )) {
            XCTAssertEqual($0 as? CodeMapRootManifestModelError, .invalidContribution)
        }
    }

    func testLoadRejectsStaleAuthoritySchemaPolicyPipelineAndWholeSnapshotMismatch() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x41,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Authority", trailingNewline: false)
        )
        let store = try CodeMapRootManifestStore(rootURL: root)
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        let staleAuthority = try authorityLike(fixture.authority, generation: 2, index: "index-2")
        let stale = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: staleAuthority
        )
        XCTAssertEqual(stale, .stale(existingAuthority: fixture.authority))
        for namespace in try [
            namespaceLike(fixture.namespace, schemaVersion: 2),
            namespaceLike(fixture.namespace, policyVersion: 2),
            namespaceLike(
                fixture.namespace,
                pipelineIdentity: SyntaxManager().pipelineIdentity(
                    for: .python,
                    decoderPolicy: .workspaceAutomaticV1
                )
            )
        ] {
            let result = try await store.loadCurrentManifest(
                namespace: namespace,
                currentAuthority: fixture.authority
            )
            XCTAssertEqual(result, .miss)
        }

        var corrupted = try Data(contentsOf: store.manifestURL(for: fixture.namespace))
        let authorityDigest = fixture.authority.digest.bytes
        let range = try XCTUnwrap(corrupted.range(of: authorityDigest))
        corrupted[range.lowerBound] ^= 0x01
        try replaceFile(at: store.manifestURL(for: fixture.namespace), data: corrupted)
        let noPartial = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(noPartial, .miss)
    }

    func testCorruptOversizedTruncatedAndChecksumRecordsQuarantineAsMiss() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x51,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Corrupt", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64
        )
        let store = try CodeMapRootManifestStore(rootURL: root, policy: policy)

        for mutation in 0 ..< 4 {
            _ = try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: UInt64(mutation + 1)
            )
            let url = store.manifestURL(for: fixture.namespace)
            let original = try Data(contentsOf: url)
            let damaged: Data
            switch mutation {
            case 0:
                damaged = original.dropLast()
            case 1:
                var value = original
                value[value.count / 2] ^= 0xFF
                damaged = value
            case 2:
                damaged = Data(repeating: 0xA5, count: Int(policy.maximumManifestByteCount) + 1)
            default:
                damaged = Data(original.prefix(12))
            }
            try replaceFile(at: url, data: damaged)
            let result = try await store.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            )
            XCTAssertEqual(result, .miss)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.manifestCount, 0)
        XCTAssertEqual(accounting.quarantineCount, 4)
        let decodeFailures = await store.decodeFailureAccounting()
        XCTAssertEqual(decodeFailures.totalCount, 3)
        XCTAssertEqual(decodeFailures.counts[.checksumMismatch], 2)
        XCTAssertEqual(decodeFailures.counts[.invalidEnvelope], 1)
    }

    func testSymlinkHardlinkWrongModeAndRootReplacementFailClosed() async throws {
        let root = try makeSecureRoot()
        let external = try makeSecureRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x61,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Secure", trailingNewline: false)
        )
        let store = try CodeMapRootManifestStore(rootURL: root)
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let url = store.manifestURL(for: fixture.namespace)

        XCTAssertEqual(chmod(url.path, 0o644), 0)
        let wrongMode = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(wrongMode, .miss)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        let hardlink = url.deletingLastPathComponent().appendingPathComponent("hardlink")
        XCTAssertEqual(link(url.path, hardlink.path), 0)
        let hardlinked = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(hardlinked, .miss)
        await XCTAssertThrowsManifestSecurity {
            try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 2
            )
        }
        try FileManager.default.removeItem(at: hardlink)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: external.appendingPathComponent("outside")
        )
        let symlink = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(symlink, .miss)
        await XCTAssertThrowsManifestSecurity {
            try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 3
            )
        }

        let alias = root.deletingLastPathComponent().appendingPathComponent("manifest-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try CodeMapRootManifestStore(rootURL: alias))

        try FileManager.default.removeItem(at: url)
        let replacement = ManifestRootReplacementHook(root: root)
        let replacingStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: {},
                beforePublish: { replacement.replaceOnce() },
                beforeMaintenanceLock: {}
            )
        )
        do {
            _ = try await replacingStore.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 4
            )
            XCTFail("expected root replacement rejection")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureDirectory)
        }
        let replacementFailure = replacement.failure
        XCTAssertNil(replacementFailure)
    }

    func testIndependentWritersAndReadersObserveOnlyCompleteAtomicSnapshots() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let first = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x71,
            prefix: "",
            path: "Sources/First.swift",
            text: SwiftFixtureSource.emptyStruct("First", trailingNewline: false)
        )
        let secondRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: first.namespace,
            authority: first.authority,
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("Second", trailingNewline: false),
            bindingGeneration: 2
        )
        let alternativeFirst = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: first.namespace,
            authority: first.authority,
            path: "Sources/Third.swift",
            text: SwiftFixtureSource.emptyStruct("Third", trailingNewline: false),
            bindingGeneration: 3
        )
        let alternativeSecond = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: first.namespace,
            authority: first.authority,
            path: "Sources/XFourth.swift",
            text: SwiftFixtureSource.emptyStruct("Fourth", trailingNewline: false),
            bindingGeneration: 4
        )
        let firstSnapshot = [first.record, secondRecord]
        let alternativeSnapshot = [alternativeFirst, alternativeSecond]
        let firstStore = try CodeMapRootManifestStore(rootURL: root)
        let secondStore = try CodeMapRootManifestStore(rootURL: root)
        _ = try await firstStore.replaceCurrentManifest(
            namespace: first.namespace,
            authority: first.authority,
            records: firstSnapshot,
            lastAccessEpochSeconds: 1
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0 ..< 24 {
                group.addTask {
                    let store = iteration.isMultiple(of: 2) ? firstStore : secondStore
                    let records = iteration.isMultiple(of: 2) ? firstSnapshot : alternativeSnapshot
                    _ = try await store.replaceCurrentManifest(
                        namespace: first.namespace,
                        authority: first.authority,
                        records: records,
                        lastAccessEpochSeconds: UInt64(iteration + 2)
                    )
                }
                group.addTask {
                    let store = iteration.isMultiple(of: 2) ? secondStore : firstStore
                    let result = try await store.loadCurrentManifest(
                        namespace: first.namespace,
                        currentAuthority: first.authority
                    )
                    if case let .hit(snapshot) = result {
                        XCTAssertTrue(snapshot.records == firstSnapshot || snapshot.records == alternativeSnapshot)
                    } else if result != .miss {
                        XCTFail("atomic reader observed \(result)")
                    }
                }
            }
            try await group.waitForAll()
        }
        guard case let .hit(final) = try await firstStore.loadCurrentManifest(
            namespace: first.namespace,
            currentAuthority: first.authority
        ) else {
            return XCTFail("expected final complete snapshot")
        }
        XCTAssertTrue(final.records == firstSnapshot || final.records == alternativeSnapshot)
    }

    func testIndependentStoresMergeDisjointNamespaceDeltasWithoutClobbering() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let first = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x72,
            prefix: "",
            path: "Sources/First.swift",
            text: SwiftFixtureSource.emptyStruct("First", trailingNewline: false)
        )
        let second = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: first.namespace,
            authority: first.authority,
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("Second", trailingNewline: false),
            bindingGeneration: 2
        )
        let gate = ManifestLockedMergeGate()
        let firstStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { gate.firstWriterAcquiredLockAndWait() }
            )
        )
        let secondStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { gate.secondWriterAcquiredLock() },
                beforeMaintenanceLock: { gate.secondWriterAttemptedLock() }
            )
        )

        let firstWrite = Task {
            try await firstStore.mergeCurrentManifest(
                namespace: first.namespace,
                authority: first.authority,
                replacingPreviouslyObservedAuthority: nil,
                upserting: [first.record],
                removing: [],
                lastAccessEpochSeconds: 1
            )
        }
        XCTAssertTrue(gate.waitUntilFirstWriterAcquiredLock())
        let secondWrite = Task {
            try await secondStore.mergeCurrentManifest(
                namespace: first.namespace,
                authority: first.authority,
                replacingPreviouslyObservedAuthority: nil,
                upserting: [second],
                removing: [],
                lastAccessEpochSeconds: 2
            )
        }
        XCTAssertTrue(gate.waitUntilSecondWriterAttemptedLock())
        XCTAssertFalse(gate.didSecondWriterAcquireLock)
        gate.releaseFirstWriter()
        _ = try await (firstWrite.value, secondWrite.value)
        XCTAssertTrue(gate.didSecondWriterAcquireLock)

        guard case let .hit(snapshot) = try await firstStore.loadCurrentManifest(
            namespace: first.namespace,
            currentAuthority: first.authority
        ) else {
            return XCTFail("Expected merged namespace manifest.")
        }
        XCTAssertEqual(
            Set(snapshot.records.map(\.repositoryRelativePath)),
            ["Sources/First.swift", "Sources/Second.swift"]
        )
        XCTAssertEqual(snapshot.manifestGeneration, 2)
    }

    func testDelayedOldWriterCannotReplaceNewerNamespaceAuthority() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let original = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x73,
            prefix: "",
            path: "Sources/Original.swift",
            text: SwiftFixtureSource.emptyStruct("Original", trailingNewline: false)
        )
        let newerAuthority = try authorityLike(
            original.authority,
            generation: original.authority.authorityGeneration + 1,
            index: "index-new-authority"
        )
        let delayedRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: original.namespace,
            authority: original.authority,
            path: "Sources/Delayed.swift",
            text: SwiftFixtureSource.emptyStruct("Delayed", trailingNewline: false),
            bindingGeneration: 2
        )
        let newerRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: original.namespace,
            authority: newerAuthority,
            path: "Sources/Newer.swift",
            text: SwiftFixtureSource.emptyStruct("Newer", trailingNewline: false),
            bindingGeneration: 3
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: original.namespace,
            authority: original.authority,
            records: [original.record],
            lastAccessEpochSeconds: 1
        )

        let delay = ManifestAccessRefreshGate()
        let oldStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeMaintenanceLock: { await delay.block() }
            )
        )
        let newerStore = try CodeMapRootManifestStore(rootURL: root)
        let oldWrite = Task {
            try await oldStore.mergeCurrentManifest(
                namespace: original.namespace,
                authority: original.authority,
                replacingPreviouslyObservedAuthority: original.authority,
                upserting: [delayedRecord],
                removing: [],
                lastAccessEpochSeconds: 2
            )
        }
        await delay.waitUntilBlocked()
        let newerWrite = try await newerStore.mergeCurrentManifest(
            namespace: original.namespace,
            authority: newerAuthority,
            replacingPreviouslyObservedAuthority: original.authority,
            upserting: [newerRecord],
            removing: [],
            lastAccessEpochSeconds: 3
        )
        XCTAssertEqual(newerWrite, .replaced(manifestGeneration: 2))
        await delay.release()
        do {
            _ = try await oldWrite.value
            XCTFail("Expected the delayed predecessor writer to be rejected.")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestModelError, .staleAuthority)
        }

        guard case let .hit(snapshot) = try await baseline.loadCurrentManifest(
            namespace: original.namespace,
            currentAuthority: newerAuthority
        ) else {
            return XCTFail("Expected the newer namespace authority to remain published.")
        }
        XCTAssertEqual(snapshot.authority, newerAuthority)
        XCTAssertEqual(snapshot.records.map(\.repositoryRelativePath), ["Sources/Newer.swift"])
        let staleLoad = try await baseline.loadCurrentManifest(
            namespace: original.namespace,
            currentAuthority: original.authority
        )
        XCTAssertEqual(staleLoad, .stale(existingAuthority: newerAuthority))
    }

    func testStaleWriterThatObservedCurrentAuthorityCannotRollNamespaceBack() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let stale = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x74,
            prefix: "",
            path: "Sources/Stale.swift",
            text: SwiftFixtureSource.emptyStruct("Stale", trailingNewline: false)
        )
        let currentAuthority = try authorityLike(
            stale.authority,
            generation: stale.authority.authorityGeneration + 1,
            index: "index-current-authority"
        )
        let currentRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: stale.namespace,
            authority: currentAuthority,
            path: "Sources/Current.swift",
            text: SwiftFixtureSource.emptyStruct("Current", trailingNewline: false),
            bindingGeneration: 2
        )
        let store = try CodeMapRootManifestStore(rootURL: root)
        let staleSession = try await store.registerManifestWriterSession()
        let staleWriterValue = await store.claimManifestWriterAuthority(
            namespace: stale.namespace,
            authority: stale.authority,
            writerSession: staleSession
        )
        let staleWriter = try XCTUnwrap(staleWriterValue)
        let currentSession = try await store.registerManifestWriterSession()
        let currentWriterValue = await store.claimManifestWriterAuthority(
            namespace: stale.namespace,
            authority: currentAuthority,
            writerSession: currentSession
        )
        let currentWriter = try XCTUnwrap(currentWriterValue)
        _ = try await store.mergeCurrentManifest(
            namespace: stale.namespace,
            authority: currentAuthority,
            writerAuthority: currentWriter,
            replacingPreviouslyObservedAuthority: nil,
            upserting: [currentRecord],
            removing: [],
            lastAccessEpochSeconds: 1
        )

        do {
            _ = try await store.mergeCurrentManifest(
                namespace: stale.namespace,
                authority: stale.authority,
                writerAuthority: staleWriter,
                replacingPreviouslyObservedAuthority: currentAuthority,
                upserting: [stale.record],
                removing: [],
                lastAccessEpochSeconds: 2
            )
            XCTFail("Expected the superseded writer session to be rejected.")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .staleWriterAuthority)
        }
        guard case let .hit(snapshot) = try await store.loadCurrentManifest(
            namespace: stale.namespace,
            currentAuthority: currentAuthority
        ) else {
            return XCTFail("Expected the current authority to remain published.")
        }
        XCTAssertEqual(snapshot.authority, currentAuthority)
        XCTAssertEqual(snapshot.manifestGeneration, 1)
        XCTAssertEqual(snapshot.records, [currentRecord])
    }

    func testNilMissRefreshesInterveningAuthorityAndRetriesDeltaMerge() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let predecessor = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x75,
            prefix: "",
            path: "Sources/Predecessor.swift",
            text: SwiftFixtureSource.emptyStruct("Predecessor", trailingNewline: false)
        )
        let targetAuthority = try authorityLike(
            predecessor.authority,
            generation: predecessor.authority.authorityGeneration + 1,
            index: "index-target-authority"
        )
        let targetRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: predecessor.namespace,
            authority: targetAuthority,
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("Target", trailingNewline: false),
            bindingGeneration: 2
        )
        let store = try CodeMapRootManifestStore(rootURL: root)
        let writerSession = try await store.registerManifestWriterSession()
        let writerValue = await store.claimManifestWriterAuthority(
            namespace: predecessor.namespace,
            authority: targetAuthority,
            writerSession: writerSession
        )
        let writer = try XCTUnwrap(writerValue)
        let initialLoad = try await store.loadCurrentManifest(
            namespace: predecessor.namespace,
            currentAuthority: targetAuthority
        )
        XCTAssertEqual(initialLoad, .miss)

        let interveningStore = try CodeMapRootManifestStore(rootURL: root)
        _ = try await interveningStore.replaceCurrentManifest(
            namespace: predecessor.namespace,
            authority: predecessor.authority,
            records: [predecessor.record],
            lastAccessEpochSeconds: 1
        )
        do {
            _ = try await store.mergeCurrentManifest(
                namespace: predecessor.namespace,
                authority: targetAuthority,
                writerAuthority: writer,
                replacingPreviouslyObservedAuthority: nil,
                upserting: [targetRecord],
                removing: [],
                lastAccessEpochSeconds: 2
            )
            XCTFail("Expected the nil predecessor observation to conflict.")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestModelError, .staleAuthority)
        }
        let refreshed = try await store.loadCurrentManifest(
            namespace: predecessor.namespace,
            currentAuthority: targetAuthority
        )
        guard case let .stale(observedAuthority) = refreshed else {
            return XCTFail("Expected the intervening authority to be observed.")
        }
        XCTAssertEqual(observedAuthority, predecessor.authority)
        _ = try await store.mergeCurrentManifest(
            namespace: predecessor.namespace,
            authority: targetAuthority,
            writerAuthority: writer,
            replacingPreviouslyObservedAuthority: observedAuthority,
            upserting: [targetRecord],
            removing: [],
            lastAccessEpochSeconds: 3
        )
        guard case let .hit(snapshot) = try await store.loadCurrentManifest(
            namespace: predecessor.namespace,
            currentAuthority: targetAuthority
        ) else {
            return XCTFail("Expected refreshed delta merge to publish.")
        }
        XCTAssertEqual(snapshot.authority, targetAuthority)
        XCTAssertEqual(snapshot.records, [targetRecord])
    }

    func testMaintenanceRecoversInterruptedTemporaryPublication() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x81,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("Temporary", trailingNewline: false)
        )
        let store = try CodeMapRootManifestStore(rootURL: root)
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let temporary = store.manifestURL(for: fixture.namespace)
            .deletingLastPathComponent()
            .appendingPathComponent(".tmp.999999.interrupted")
        try Data("partial".utf8).write(to: temporary, options: .withoutOverwriting)
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        let before = try await store.accounting()
        XCTAssertEqual(before.temporaryCount, 1)
        let maintenance = try await store.maintain()
        XCTAssertEqual(maintenance.removedTemporaryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        guard case let .hit(snapshot) = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("temporary recovery damaged published manifest")
        }
        XCTAssertEqual(snapshot.records, [fixture.record])
    }

    func testQuotaAccountingAndGCRemainFiniteAndNamespaceScoped() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 2,
            maximumStoreByteCount: 128 * 1024,
            maximumQuarantineCount: 2,
            maintenanceEntryLimit: 32
        )
        let store = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        var fixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0x91), 0x92, 0x93].enumerated() {
            let fixture = try await makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct Quota\(index) {}"
            )
            fixtures.append(fixture)
            _ = try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: UInt64(index + 1)
            )
        }
        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.manifestCount, 2)
        XCTAssertEqual(accounting.recordCount, 2)
        XCTAssertLessThanOrEqual(accounting.manifestByteCount, policy.maximumStoreByteCount)
        let results = try await fixtures.asyncMap { fixture in
            try await store.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            )
        }
        XCTAssertEqual(results.count(where: {
            if case .hit = $0 {
                true
            } else {
                false
            }
        }), 2)
        XCTAssertEqual(results.count(where: { $0 == .miss }), 1)

        await XCTAssertThrowsManifestQuota {
            try await store.replaceCurrentManifest(
                namespace: fixtures[1].namespace,
                authority: fixtures[1].authority,
                records: Array(repeating: fixtures[1].record, count: 5),
                lastAccessEpochSeconds: 10
            )
        }
        let maintenance = try await store.maintain(maximumEntries: 32)
        XCTAssertLessThanOrEqual(maintenance.accounting.manifestCount, 2)
        XCTAssertFalse(maintenance.accounting.hasMore)
    }

    func testAccountingTracksExactBytesQuarantineAndPartialBounds() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 4,
            maximumStoreByteCount: 256 * 1024,
            maximumQuarantineCount: 2,
            maintenanceEntryLimit: 32
        )
        let store = try CodeMapRootManifestStore(rootURL: root, policy: policy, accessEpochSeconds: { 0 })
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        var fixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0x90), 0x91, 0x92].enumerated() {
            let fixture = try await makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct Accounting\(index) {}"
            )
            fixtures.append(fixture)
            _ = try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: UInt64(index + 1)
            )
        }
        let liveBytes = try fixtures.reduce(into: UInt64(0)) { total, fixture in
            try total += UInt64(Data(contentsOf: store.manifestURL(for: fixture.namespace)).count)
        }
        let complete = try await store.accounting()
        XCTAssertEqual(complete.manifestCount, 3)
        XCTAssertEqual(complete.manifestByteCount, liveBytes)
        XCTAssertEqual(complete.recordCount, 3)
        XCTAssertEqual(complete.temporaryCount, 0)
        XCTAssertEqual(complete.quarantineCount, 0)
        XCTAssertFalse(complete.hasMore)

        let partial = try await store.accounting(maximumEntries: 1)
        XCTAssertTrue(partial.hasMore)
        XCTAssertLessThanOrEqual(partial.manifestCount, 1)
        XCTAssertLessThanOrEqual(partial.recordCount, 1)
        XCTAssertLessThanOrEqual(partial.manifestByteCount, liveBytes)

        let temporary = store.manifestURL(for: fixtures[0].namespace)
            .deletingLastPathComponent()
            .appendingPathComponent(".tmp.accounting")
        try Data("partial".utf8).write(to: temporary, options: .withoutOverwriting)
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        for fixture in fixtures {
            let url = store.manifestURL(for: fixture.namespace)
            var corrupt = try Data(contentsOf: url)
            corrupt[corrupt.count / 2] ^= 0xFF
            try replaceFile(at: url, data: corrupt)
            let result = try await store.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            )
            XCTAssertEqual(result, .miss)
        }
        let quarantined = try await store.accounting()
        XCTAssertEqual(quarantined.manifestCount, 0)
        XCTAssertEqual(quarantined.manifestByteCount, 0)
        XCTAssertEqual(quarantined.recordCount, 0)
        XCTAssertEqual(quarantined.temporaryCount, 1)
        XCTAssertEqual(quarantined.quarantineCount, 3)

        let maintenance = try await store.maintain()
        XCTAssertEqual(maintenance.removedTemporaryCount, 1)
        XCTAssertEqual(maintenance.removedQuarantineCount, 1)
        XCTAssertEqual(maintenance.accounting.temporaryCount, 0)
        XCTAssertEqual(maintenance.accounting.quarantineCount, 2)
    }

    func testSemanticNoOpBelowAccessRefreshThresholdDoesNotRewriteOrScan() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x97,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("BelowThreshold", trailingNewline: false)
        )
        let unrelated = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-unrelated",
            worktreeByte: 0x9B,
            prefix: "",
            path: "Sources/Unrelated.swift",
            text: SwiftFixtureSource.emptyStruct("UnrelatedBelowThreshold", trailingNewline: false)
        )
        let publications = ManifestPublicationCounter()
        let scanRecorder = ManifestScanInspectionRecorder()
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { publications.increment() },
                onManifestScanInspection: { scanRecorder.record($0) }
            ),
            accessEpochSeconds: { 0 }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        _ = try await store.replaceCurrentManifest(
            namespace: unrelated.namespace,
            authority: unrelated.authority,
            records: [unrelated.record],
            lastAccessEpochSeconds: 100
        )
        let baselineAccounting = try await store.accounting()
        XCTAssertTrue(scanRecorder.inspectedDigests.contains(unrelated.namespace.storageDigestHex))
        scanRecorder.reset()

        let result = try await store.updateCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 159
        )

        XCTAssertEqual(result, .unchanged(manifestGeneration: 1))
        XCTAssertEqual(publications.value, 2)
        XCTAssertEqual(scanRecorder.inspectedDigests, [])
        let persisted = try decodeManifest(fixture.namespace, from: store)
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 100)
        XCTAssertEqual(persisted.manifestGeneration, 1)
        let finalAccounting = try await store.accounting()
        XCTAssertEqual(finalAccounting, baselineAccounting)
    }

    func testAccessRefreshAtThresholdPublishesWithoutGlobalScanOrStoreGrowth() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x98,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("ExactThreshold", trailingNewline: false)
        )
        let unrelated = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-unrelated",
            worktreeByte: 0x9C,
            prefix: "",
            path: "Sources/Unrelated.swift",
            text: SwiftFixtureSource.emptyStruct("UnrelatedExactThreshold", trailingNewline: false)
        )
        let publications = ManifestPublicationCounter()
        let scanRecorder = ManifestScanInspectionRecorder()
        let clock = ManifestAccessClock(160)
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { publications.increment() },
                onManifestScanInspection: { scanRecorder.record($0) }
            ),
            accessEpochSeconds: { clock.value }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        _ = try await store.replaceCurrentManifest(
            namespace: unrelated.namespace,
            authority: unrelated.authority,
            records: [unrelated.record],
            lastAccessEpochSeconds: 100
        )
        let baselineAccounting = try await store.accounting()
        XCTAssertTrue(scanRecorder.inspectedDigests.contains(unrelated.namespace.storageDigestHex))
        scanRecorder.reset()

        guard case let .hit(loaded) = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("threshold access refresh lost the current manifest")
        }
        XCTAssertEqual(loaded.lastAccessEpochSeconds, 100)
        await store.waitForPendingAccessRefreshesForTesting()

        XCTAssertEqual(publications.value, 3)
        XCTAssertEqual(scanRecorder.inspectedDigests, [])
        let persisted = try decodeManifest(fixture.namespace, from: store)
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 160)
        XCTAssertEqual(persisted.manifestGeneration, 1)
        let finalAccounting = try await store.accounting()
        XCTAssertEqual(finalAccounting, baselineAccounting)
    }

    func testAccessRefreshSkippingGlobalReconciliationRejectsTargetShardDisplacement() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x9D,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("DisplacedRefreshShard", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        let replacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let scanRecorder = ManifestScanInspectionRecorder()
        let refreshingStore = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { replacement.replaceOnce() },
                onManifestScanInspection: { scanRecorder.record($0) }
            ),
            accessEpochSeconds: { 160 }
        )

        guard case let .hit(loaded) = try await refreshingStore.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("scheduled access refresh lost the admitted manifest")
        }
        XCTAssertEqual(loaded.lastAccessEpochSeconds, 100)
        await refreshingStore.waitForPendingAccessRefreshesForTesting()

        XCTAssertNil(replacement.failure)
        XCTAssertEqual(scanRecorder.inspectedDigests, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline.manifestURL(for: fixture.namespace).path))
        let freshStore = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let result = try await freshStore.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(result, .miss)
    }

    func testAccessRefreshSkippingGlobalReconciliationRejectsPublishedTargetFileDisplacement() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x9E,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("DisplacedRefreshTarget", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        let targetURL = baseline.manifestURL(for: fixture.namespace)
        let replacement = try ManifestTargetFileReplacementHook(
            targetURL: targetURL,
            replacementData: Data(contentsOf: targetURL)
        )
        let scanRecorder = ManifestScanInspectionRecorder()
        let refreshingStore = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { replacement.replaceOnce() },
                onManifestScanInspection: { scanRecorder.record($0) }
            ),
            accessEpochSeconds: { 160 }
        )

        guard case let .hit(loaded) = try await refreshingStore.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("scheduled access refresh lost the admitted manifest")
        }
        XCTAssertEqual(loaded.lastAccessEpochSeconds, 100)
        await refreshingStore.waitForPendingAccessRefreshesForTesting()

        XCTAssertNil(replacement.failure)
        XCTAssertEqual(scanRecorder.inspectedDigests, [])
        let persisted = try decodeManifest(fixture.namespace, from: baseline)
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 100)
        XCTAssertEqual(persisted.manifestGeneration, 1)
        XCTAssertEqual(persisted.records, [fixture.record])
    }

    func testRecordMutationBelowAccessRefreshThresholdStillRewrites() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x99,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("MutationBaseline", trailingNewline: false)
        )
        let addedRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/Added.swift",
            text: SwiftFixtureSource.emptyStruct("MutationAdded", trailingNewline: false),
            bindingGeneration: 1
        )
        let publications = ManifestPublicationCounter()
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { publications.increment() }
            ),
            accessEpochSeconds: { 0 }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )

        let result = try await store.updateCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record, addedRecord],
            lastAccessEpochSeconds: 120
        )

        XCTAssertEqual(result, .replaced(manifestGeneration: 2))
        XCTAssertEqual(publications.value, 2)
        let persisted = try decodeManifest(fixture.namespace, from: store)
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 120)
        XCTAssertEqual(persisted.manifestGeneration, 2)
        XCTAssertEqual(persisted.records, [addedRecord, fixture.record])
    }

    func testAuthorityMutationBelowAccessRefreshThresholdStillRewrites() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x9A,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("AuthorityMutation", trailingNewline: false)
        )
        let newerAuthority = try authorityLike(
            fixture.authority,
            generation: fixture.authority.authorityGeneration + 1,
            index: "index-2"
        )
        let publications = ManifestPublicationCounter()
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 60
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { publications.increment() }
            ),
            accessEpochSeconds: { 0 }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [],
            lastAccessEpochSeconds: 100
        )

        let result = try await store.updateCurrentManifest(
            namespace: fixture.namespace,
            authority: newerAuthority,
            records: [],
            lastAccessEpochSeconds: 120
        )

        XCTAssertEqual(result, .replaced(manifestGeneration: 2))
        XCTAssertEqual(publications.value, 2)
        let persisted = try decodeManifest(fixture.namespace, from: store)
        XCTAssertEqual(persisted.authority, newerAuthority)
        XCTAssertEqual(persisted.lastAccessEpochSeconds, 120)
        XCTAssertEqual(persisted.manifestGeneration, 2)
        XCTAssertTrue(persisted.records.isEmpty)
    }

    func testConcurrentLoadsPersistMonotonicCoalescedAccessEpoch() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x93,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("ConcurrentTouch", trailingNewline: false)
        )
        let unrelated = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-unrelated",
            worktreeByte: 0x94,
            prefix: "",
            path: "Sources/Unrelated.swift",
            text: SwiftFixtureSource.emptyStruct("UnrelatedTouch", trailingNewline: false)
        )
        let clock = ManifestAccessClock(500)
        let scanRecorder = ManifestScanInspectionRecorder()
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 10,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 10,
            maximumStoreByteCount: 640 * 1024,
            maximumQuarantineCount: 10,
            maintenanceEntryLimit: 64,
            minimumAccessRefreshIntervalSeconds: 1
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                onManifestScanInspection: { scanRecorder.record($0) }
            ),
            accessEpochSeconds: { clock.value }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 100
        )
        _ = try await store.replaceCurrentManifest(
            namespace: unrelated.namespace,
            authority: unrelated.authority,
            records: [unrelated.record],
            lastAccessEpochSeconds: 100
        )
        XCTAssertTrue(scanRecorder.inspectedDigests.contains(unrelated.namespace.storageDigestHex))
        scanRecorder.reset()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    guard case .hit = try await store.loadCurrentManifest(
                        namespace: fixture.namespace,
                        currentAuthority: fixture.authority
                    ) else {
                        return XCTFail("concurrent touch lost the current manifest")
                    }
                }
            }
            try await group.waitForAll()
        }
        await store.waitForPendingAccessRefreshesForTesting()
        XCTAssertEqual(scanRecorder.inspectedDigests, [])
        let touched = try decodeManifest(fixture.namespace, from: store)
        XCTAssertEqual(touched.lastAccessEpochSeconds, 500)
        XCTAssertEqual(touched.manifestGeneration, 1)

        let unchanged = try await store.updateCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 400
        )
        XCTAssertEqual(unchanged, .unchanged(manifestGeneration: 1))
        XCTAssertEqual(try decodeManifest(fixture.namespace, from: store).lastAccessEpochSeconds, 500)
    }

    func testOrdinaryPublicationUsesAtMostTwoBoundedStoreScans() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = ManifestStoreWorkCounter()
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                scanStarted: { work.recordScan() }
            )
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xD1,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("SingleScan", trailingNewline: false)
        )

        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        XCTAssertLessThanOrEqual(work.scanCount, 2)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("single-scan publication must remain readable")
        }
        let populatedCacheCount = await store.decodedManifestCacheEntryCountForTesting()
        XCTAssertEqual(populatedCacheCount, 1)
        let removed = try await store.removeNamespace(fixture.namespace)
        XCTAssertTrue(removed)
        let removedCacheCount = await store.decodedManifestCacheEntryCountForTesting()
        XCTAssertEqual(removedCacheCount, 0)
    }

    func testEvictingPublicationUsesAtMostThreeBoundedStoreScans() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = ManifestStoreWorkCounter()
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(scanStarted: { work.recordScan() })
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let first = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-first",
            worktreeByte: 0xD8,
            prefix: "",
            path: "Sources/First.swift",
            text: SwiftFixtureSource.emptyStruct("First", trailingNewline: false)
        )
        let second = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-second",
            worktreeByte: 0xD9,
            prefix: "",
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("Second", trailingNewline: false)
        )
        _ = try await store.replaceCurrentManifest(
            namespace: first.namespace,
            authority: first.authority,
            records: [first.record],
            lastAccessEpochSeconds: 1
        )
        work.reset()

        _ = try await store.replaceCurrentManifest(
            namespace: second.namespace,
            authority: second.authority,
            records: [second.record],
            lastAccessEpochSeconds: 2
        )

        XCTAssertLessThanOrEqual(work.scanCount, 3)
        let evicted = try await store.loadCurrentManifest(
            namespace: first.namespace,
            currentAuthority: first.authority
        )
        XCTAssertEqual(evicted, .miss)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: second.namespace,
            currentAuthority: second.authority
        ) else {
            return XCTFail("new publication must survive quota eviction")
        }
    }

    func testNearCapacityPublicationKeepsScanCountAndElapsedTimeBounded() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let policy = CodeMapRootManifestStorePolicy.default
        let namespaceScope = "\(#function)-shared"
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        for index in 0 ..< 255 {
            let fixture = try await makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: namespaceScope,
                worktreeByte: UInt8(index),
                prefix: "",
                path: "Sources/Resident.swift",
                text: "struct NearCapacityResident\(index) {}"
            )
            let snapshot = try CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: UInt64(index),
                records: [fixture.record]
            )
            let insertion = try ManifestEntryInsertionHook(
                url: locator.manifestURL(for: fixture.namespace),
                data: CodeMapRootManifestCodec.encode(snapshot: snapshot)
            )
            insertion.insertOnce()
            XCTAssertNil(insertion.failure, "resident fixture index \(index)")
        }
        let target = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: namespaceScope,
            worktreeByte: 0xFF,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("NearCapacityTarget", trailingNewline: false)
        )
        let work = ManifestStoreWorkCounter()
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(scanStarted: { work.recordScan() })
        )

        let clock = ContinuousClock()
        let started = clock.now
        _ = try await store.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 100
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(work.scanCount, 2, "target publication scan count")
        XCTAssertLessThan(elapsed, .seconds(15), "target publication elapsed time")
        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.manifestCount, 256, "target publication manifest count")
        XCTAssertFalse(accounting.hasMore, "target publication accounting must be complete")
    }

    func testDecodedManifestCacheHonorsEncodedByteBudget() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        var fixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0xE8), 0xE9].enumerated() {
            try await fixtures.append(makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct CacheBudget\(index) {}"
            ))
        }
        let snapshots = try fixtures.enumerated().map { index, fixture in
            try CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: UInt64(index + 1),
                records: [fixture.record]
            )
        }
        let encodedSizes = try snapshots.map { try CodeMapRootManifestCodec.encode(snapshot: $0).count }
        let cacheBudget = try UInt64(XCTUnwrap(encodedSizes.max()))
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 4,
            maximumStoreByteCount: 256 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32,
            maximumDecodedManifestCacheByteCount: cacheBudget
        )
        let store = try CodeMapRootManifestStore(rootURL: root, policy: policy)

        for fixture in fixtures {
            _ = try await store.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 1
            )
            let cachedBytes = await store.decodedManifestCacheByteCountForTesting()
            XCTAssertLessThanOrEqual(cachedBytes, cacheBudget)
        }

        let cachedCount = await store.decodedManifestCacheEntryCountForTesting()
        let cachedBytes = await store.decodedManifestCacheByteCountForTesting()
        XCTAssertEqual(cachedCount, 1)
        XCTAssertLessThanOrEqual(cachedBytes, cacheBudget)
    }

    func testPostRenameMutationIsReconciledWithoutReportingDurableCommitAsFailure() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let target = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-target",
            worktreeByte: 0xD6,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("PostRenameTarget", trailingNewline: false)
        )
        let intruder = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-intruder",
            worktreeByte: 0xD7,
            prefix: "",
            path: "Sources/Intruder.swift",
            text: SwiftFixtureSource.emptyStruct("PostRenameIntruder", trailingNewline: false)
        )
        let intruderSnapshot = try CodeMapRootManifestSnapshot(
            namespace: intruder.namespace,
            authority: intruder.authority,
            manifestGeneration: 1,
            lastAccessEpochSeconds: 0,
            records: [intruder.record]
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32
        )
        let locator = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            accessEpochSeconds: { 0 }
        )
        let insertion = try ManifestEntryInsertionHook(
            url: locator.manifestURL(for: intruder.namespace),
            data: CodeMapRootManifestCodec.encode(snapshot: intruderSnapshot)
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { insertion.insertOnce() }
            ),
            accessEpochSeconds: { 0 }
        )

        let result = try await store.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 10
        )

        XCTAssertNil(insertion.failure)
        XCTAssertEqual(result, .inserted(manifestGeneration: 1))
        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.manifestCount, 1)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: target.namespace,
            currentAuthority: target.authority
        ) else {
            return XCTFail("durably committed protected target must survive post-rename reconciliation")
        }
        let intruderResult = try await store.loadCurrentManifest(
            namespace: intruder.namespace,
            currentAuthority: intruder.authority
        )
        XCTAssertEqual(intruderResult, .miss)
    }

    func testDurableCommitSchedulesBoundedFollowUpMaintenance() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xDA,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("MaintenanceRetryTarget", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 2
        )
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let insertion = ManifestTemporaryBurstInsertionHook(
            manifestURL: locator.manifestURL(for: fixture.namespace),
            count: 7
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { insertion.insertOnce() },
                committedMaintenanceRetrySleep: { _ in }
            )
        )

        let result = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        await store.waitForCommittedMaintenanceRetryForTesting()

        XCTAssertEqual(result, .inserted(manifestGeneration: 1))
        XCTAssertNil(insertion.failure)
        let retryState = await store.committedMaintenanceRetryStateForTesting()
        XCTAssertEqual(retryState.pendingCount, 0)
        XCTAssertEqual(retryState.attempt, 0)
        XCTAssertFalse(retryState.isScheduled)
        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.temporaryCount, 0)
        XCTAssertFalse(accounting.hasMore)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("durable target must remain readable after follow-up maintenance")
        }
    }

    func testCommittedMaintenanceRetryPreservesProtectedPublicationUnderQuotaPressure() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let target = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-target",
            worktreeByte: 0xDC,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("ProtectedRetryTarget", trailingNewline: false)
        )
        let intruder = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-intruder",
            worktreeByte: 0xDD,
            prefix: "",
            path: "Sources/Intruder.swift",
            text: SwiftFixtureSource.emptyStruct("RetryQuotaIntruder", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 2
        )
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let intruderSnapshot = try CodeMapRootManifestSnapshot(
            namespace: intruder.namespace,
            authority: intruder.authority,
            manifestGeneration: 1,
            lastAccessEpochSeconds: 100,
            records: [intruder.record]
        )
        let insertion = try ManifestEntryInsertionHook(
            url: locator.manifestURL(for: intruder.namespace),
            data: CodeMapRootManifestCodec.encode(snapshot: intruderSnapshot)
        )
        let temporaryBurst = ManifestTemporaryBurstInsertionHook(
            manifestURL: locator.manifestURL(for: target.namespace),
            count: 3
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: {
                    insertion.insertOnce()
                    temporaryBurst.insertOnce()
                },
                committedMaintenanceRetrySleep: { _ in }
            )
        )

        let result = try await store.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 1
        )
        await store.waitForCommittedMaintenanceRetryForTesting()

        XCTAssertEqual(result, .inserted(manifestGeneration: 1))
        XCTAssertNil(insertion.failure)
        XCTAssertNil(temporaryBurst.failure)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: target.namespace,
            currentAuthority: target.authority
        ) else {
            return XCTFail("follow-up maintenance must preserve the exact durable publication")
        }
        guard case .hit = try await store.loadCurrentManifest(
            namespace: intruder.namespace,
            currentAuthority: intruder.authority
        ) else {
            return XCTFail("bounded retry pressure should remain observable in this fixture")
        }
        let retryState = await store.committedMaintenanceRetryStateForTesting()
        XCTAssertEqual(retryState.pendingCount, 1)
        XCTAssertEqual(retryState.attempt, 3)
        XCTAssertFalse(retryState.isScheduled)
    }

    func testCommittedMaintenanceRetryStopsAfterBoundedAttempts() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xDB,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("BoundedMaintenanceRetry", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 2
        )
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let insertion = ManifestTemporaryBurstInsertionHook(
            manifestURL: locator.manifestURL(for: fixture.namespace),
            count: 40
        )
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { insertion.insertOnce() },
                committedMaintenanceRetrySleep: { _ in }
            )
        )

        let result = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        await store.waitForCommittedMaintenanceRetryForTesting()

        XCTAssertEqual(result, .inserted(manifestGeneration: 1))
        XCTAssertNil(insertion.failure)
        let retryState = await store.committedMaintenanceRetryStateForTesting()
        XCTAssertEqual(retryState.pendingCount, 1)
        XCTAssertEqual(retryState.attempt, 3)
        XCTAssertFalse(retryState.isScheduled)
        let productionStatus = await store.maintenanceStatus()
        XCTAssertTrue(productionStatus.hasPendingCommittedWork)
        XCTAssertEqual(productionStatus.attempt, 3)
        XCTAssertFalse(productionStatus.isScheduled)
        XCTAssertTrue(productionStatus.isExhausted)
        let accounting = try await store.accounting(maximumEntries: 2)
        XCTAssertTrue(accounting.hasMore)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("retry exhaustion must not invalidate the durable target")
        }
    }

    func testPublicMaintainHonorsPendingCommittedTargetProtection() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let target = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-target",
            worktreeByte: 0xDE,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("MaintainedTarget", trailingNewline: false)
        )
        let intruder = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-intruder",
            worktreeByte: 0xDF,
            prefix: "",
            path: "Sources/Intruder.swift",
            text: SwiftFixtureSource.emptyStruct("MaintenanceIntruder", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 4
        )
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let intruderSnapshot = try CodeMapRootManifestSnapshot(
            namespace: intruder.namespace,
            authority: intruder.authority,
            manifestGeneration: 1,
            lastAccessEpochSeconds: 100,
            records: [intruder.record]
        )
        let insertion = try ManifestEntryInsertionHook(
            url: locator.manifestURL(for: intruder.namespace),
            data: CodeMapRootManifestCodec.encode(snapshot: intruderSnapshot)
        )
        let temporaryBurst = ManifestTemporaryBurstInsertionHook(
            manifestURL: locator.manifestURL(for: target.namespace),
            count: 7
        )
        let retryGate = ManifestAccessRefreshGate()
        defer { retryGate.release() }
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: {
                    insertion.insertOnce()
                    temporaryBurst.insertOnce()
                },
                committedMaintenanceRetrySleep: { _ in await retryGate.block() }
            )
        )

        let publication = try await store.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 1
        )
        await retryGate.waitUntilBlocked()
        let maintenance = try await store.maintain()

        XCTAssertEqual(publication, .inserted(manifestGeneration: 1))
        XCTAssertFalse(maintenance.accounting.hasMore)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: target.namespace,
            currentAuthority: target.authority
        ) else {
            return XCTFail("public maintenance must preserve pending exact committed protection")
        }
        let intruderResult = try await store.loadCurrentManifest(
            namespace: intruder.namespace,
            currentAuthority: intruder.authority
        )
        XCTAssertEqual(intruderResult, .miss)
        let retryState = await store.committedMaintenanceRetryStateForTesting()
        XCTAssertEqual(retryState.pendingCount, 0)
        XCTAssertEqual(retryState.attempt, 0)
        XCTAssertFalse(retryState.isScheduled)
    }

    func testLaterCleanPublicationClearsObsoleteCommittedMaintenanceDebt() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let first = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-first",
            worktreeByte: 0xE0,
            prefix: "",
            path: "Sources/First.swift",
            text: SwiftFixtureSource.emptyStruct("FirstCleanPublication", trailingNewline: false)
        )
        let second = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-second",
            worktreeByte: 0xE1,
            prefix: "",
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("SecondCleanPublication", trailingNewline: false)
        )
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 2,
            maximumStoreByteCount: 128 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 4
        )
        let locator = try CodeMapRootManifestStore(rootURL: root, policy: policy)
        let temporaryBurst = ManifestTemporaryBurstInsertionHook(
            manifestURL: locator.manifestURL(for: first.namespace),
            count: 7
        )
        let retryGate = ManifestAccessRefreshGate()
        defer { retryGate.release() }
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { temporaryBurst.insertOnce() },
                committedMaintenanceRetrySleep: { _ in await retryGate.block() }
            )
        )

        _ = try await store.replaceCurrentManifest(
            namespace: first.namespace,
            authority: first.authority,
            records: [first.record],
            lastAccessEpochSeconds: 1
        )
        await retryGate.waitUntilBlocked()
        try temporaryBurst.removeInsertedFiles()
        let publication = try await store.replaceCurrentManifest(
            namespace: second.namespace,
            authority: second.authority,
            records: [second.record],
            lastAccessEpochSeconds: 2
        )

        XCTAssertEqual(publication, .inserted(manifestGeneration: 1))
        let retryState = await store.committedMaintenanceRetryStateForTesting()
        XCTAssertEqual(retryState.pendingCount, 0)
        XCTAssertEqual(retryState.attempt, 0)
        XCTAssertFalse(retryState.isScheduled)
        for fixture in [first, second] {
            guard case .hit = try await store.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            ) else {
                return XCTFail("authoritative clean publication must preserve both manifests")
            }
        }
    }

    func testCoalescedAccessRefreshesAvoidStoreWideReconciliation() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let writer = try CodeMapRootManifestStore(rootURL: root, accessEpochSeconds: { 0 })
        var fixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0xD2), 0xD3, 0xD4].enumerated() {
            let fixture = try await makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct BatchedAccess\(index) {}"
            )
            fixtures.append(fixture)
            _ = try await writer.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 1
            )
        }

        let gate = ManifestAccessRefreshGate()
        let work = ManifestStoreWorkCounter()
        let touching = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeMaintenanceLock: { await gate.block() },
                scanStarted: { work.recordScan() }
            ),
            accessEpochSeconds: { 500 }
        )
        guard case .hit = try await touching.loadCurrentManifest(
            namespace: fixtures[0].namespace,
            currentAuthority: fixtures[0].authority
        ) else {
            return XCTFail("expected first access-refresh source hit")
        }
        await gate.waitUntilBlocked()
        for fixture in fixtures.dropFirst() {
            guard case .hit = try await touching.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            ) else {
                return XCTFail("expected coalesced access-refresh source hit")
            }
        }
        work.reset()
        await gate.release()
        await touching.waitForPendingAccessRefreshesForTesting()

        XCTAssertEqual(work.scanCount, 0)
        for fixture in fixtures {
            let touched = try decodeManifest(fixture.namespace, from: touching)
            XCTAssertEqual(touched.lastAccessEpochSeconds, 500)
            XCTAssertEqual(touched.manifestGeneration, 1)
            XCTAssertEqual(touched.records, [fixture.record])
        }
    }

    func testInPlaceChildMutationInvalidatesDecodedManifestCache() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = ManifestStoreWorkCounter()
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                scanStarted: { work.recordScan() }
            )
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xD5,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("CachedOriginal", trailingNewline: false)
        )
        let added = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/Added.swift",
            text: SwiftFixtureSource.emptyStruct("CachedAdded", trailingNewline: false),
            bindingGeneration: 2
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        _ = try await store.accounting()

        let externallyMutated = try CodeMapRootManifestSnapshot(
            namespace: fixture.namespace,
            authority: fixture.authority,
            manifestGeneration: 2,
            lastAccessEpochSeconds: 1,
            records: [added, fixture.record].sorted {
                $0.repositoryRelativePath.utf8.lexicographicallyPrecedes($1.repositoryRelativePath.utf8)
            }
        )
        let encoded = try CodeMapRootManifestCodec.encode(snapshot: externallyMutated)
        try overwriteFileInPlace(at: store.manifestURL(for: fixture.namespace), data: encoded)
        work.reset()

        let accounting = try await store.accounting()
        XCTAssertEqual(accounting.recordCount, 2)
        XCTAssertLessThanOrEqual(work.scanCount, 1)
    }

    func testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 2,
            maximumStoreByteCount: 128 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32,
            minimumAccessRefreshIntervalSeconds: 1
        )
        let clock = ManifestAccessClock(100)
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            policy: policy,
            accessEpochSeconds: { clock.value }
        )
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        var fixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0x94), 0x95, 0x96].enumerated() {
            try await fixtures.append(makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct LogicalLRU\(index) {}"
            ))
        }
        _ = try await store.replaceCurrentManifest(
            namespace: fixtures[0].namespace,
            authority: fixtures[0].authority,
            records: [fixtures[0].record],
            lastAccessEpochSeconds: 10
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixtures[1].namespace,
            authority: fixtures[1].authority,
            records: [fixtures[1].record],
            lastAccessEpochSeconds: 20
        )
        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixtures[0].namespace,
            currentAuthority: fixtures[0].authority
        ) else {
            return XCTFail("expected hot manifest hit")
        }
        await store.waitForPendingAccessRefreshesForTesting()
        let touched = try decodeManifest(fixtures[0].namespace, from: store)
        XCTAssertEqual(touched.lastAccessEpochSeconds, 100)
        XCTAssertEqual(touched.manifestGeneration, 1)
        XCTAssertEqual(touched.records, [fixtures[0].record])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: store.manifestURL(for: fixtures[0].namespace).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10000)],
            ofItemAtPath: store.manifestURL(for: fixtures[1].namespace).path
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixtures[2].namespace,
            authority: fixtures[2].authority,
            records: [fixtures[2].record],
            lastAccessEpochSeconds: 30
        )

        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixtures[0].namespace,
            currentAuthority: fixtures[0].authority
        ) else {
            return XCTFail("persisted logical access should retain the hot old manifest")
        }
        let coldResult = try await store.loadCurrentManifest(
            namespace: fixtures[1].namespace,
            currentAuthority: fixtures[1].authority
        )
        XCTAssertEqual(coldResult, .miss)
        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixtures[2].namespace,
            currentAuthority: fixtures[2].authority
        ) else {
            return XCTFail("newly inserted manifest should remain resident")
        }

        let tieRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: tieRoot) }
        let tiePolicy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 3,
            maximumStoreByteCount: 192 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32
        )
        let tieStore = try CodeMapRootManifestStore(
            rootURL: tieRoot,
            policy: tiePolicy,
            accessEpochSeconds: { 0 }
        )
        let tieArtifactStore = try CodeMapArtifactStore(rootURL: tieRoot)
        var tieFixtures: [ManifestFixture] = []
        for (index, byte) in [UInt8(0xA4), 0xA5, 0xA6, 0xA7].enumerated() {
            let fixture = try await makeFixture(
                root: tieRoot,
                artifactStore: tieArtifactStore,
                namespaceScope: "\(#function)-tie-\(index)",
                worktreeByte: byte,
                prefix: "",
                path: "Sources/App.swift",
                text: "struct TieBreak\(index) {}"
            )
            tieFixtures.append(fixture)
            if index < 3 {
                _ = try await tieStore.replaceCurrentManifest(
                    namespace: fixture.namespace,
                    authority: fixture.authority,
                    records: [fixture.record],
                    lastAccessEpochSeconds: 10
                )
            }
        }
        let generationTwoRecord = try await makeRecord(
            root: tieRoot,
            artifactStore: tieArtifactStore,
            namespaceScope: "\(#function)-tie-0",
            namespace: tieFixtures[0].namespace,
            authority: tieFixtures[0].authority,
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("TieBreakSecond", trailingNewline: false),
            bindingGeneration: 2
        )
        _ = try await tieStore.replaceCurrentManifest(
            namespace: tieFixtures[0].namespace,
            authority: tieFixtures[0].authority,
            records: [tieFixtures[0].record, generationTwoRecord],
            lastAccessEpochSeconds: 10
        )
        _ = try await tieStore.replaceCurrentManifest(
            namespace: tieFixtures[3].namespace,
            authority: tieFixtures[3].authority,
            records: [tieFixtures[3].record],
            lastAccessEpochSeconds: 10
        )
        let digestOrdered = tieFixtures[1 ... 2].sorted {
            $0.namespace.storageDigestHex < $1.namespace.storageDigestHex
        }
        guard case .hit = try await tieStore.loadCurrentManifest(
            namespace: tieFixtures[0].namespace,
            currentAuthority: tieFixtures[0].authority
        ) else {
            return XCTFail("higher generation must survive an access-epoch tie")
        }
        let lowerDigestResult = try await tieStore.loadCurrentManifest(
            namespace: digestOrdered[0].namespace,
            currentAuthority: digestOrdered[0].authority
        )
        XCTAssertEqual(lowerDigestResult, .miss)
        guard case .hit = try await tieStore.loadCurrentManifest(
            namespace: digestOrdered[1].namespace,
            currentAuthority: digestOrdered[1].authority
        ) else {
            return XCTFail("higher digest must survive the final deterministic tie break")
        }
    }

    func testStaleAndInterruptedAccessTouchesFailClosed() async throws {
        let staleRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        let artifactStore = try CodeMapArtifactStore(rootURL: staleRoot)
        let fixture = try await makeFixture(
            root: staleRoot,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-stale",
            worktreeByte: 0x97,
            prefix: "",
            path: "Sources/Old.swift",
            text: SwiftFixtureSource.emptyStruct("StaleTouchOld", trailingNewline: false)
        )
        let replacement = try await makeRecord(
            root: staleRoot,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-stale",
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/New.swift",
            text: SwiftFixtureSource.emptyStruct("StaleTouchNew", trailingNewline: false),
            bindingGeneration: 2
        )
        let baseline = try CodeMapRootManifestStore(rootURL: staleRoot, accessEpochSeconds: { 0 })
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let gate = ManifestAccessRefreshGate()
        let touching = try CodeMapRootManifestStore(
            rootURL: staleRoot,
            hooks: CodeMapRootManifestStoreHooks(
                beforeMaintenanceLock: { await gate.block() }
            ),
            accessEpochSeconds: { 100 }
        )
        guard case .hit = try await touching.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("expected touch source hit")
        }
        await gate.waitUntilBlocked()
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [replacement],
            lastAccessEpochSeconds: 50
        )
        await gate.release()
        await touching.waitForPendingAccessRefreshesForTesting()
        let afterStaleTouch = try decodeManifest(fixture.namespace, from: baseline)
        XCTAssertEqual(afterStaleTouch.records, [replacement])
        XCTAssertEqual(afterStaleTouch.lastAccessEpochSeconds, 50)
        XCTAssertEqual(afterStaleTouch.manifestGeneration, 2)

        for point in [
            CodeMapRootManifestStoreFaultPoint.afterTemporaryWrite,
            .afterManifestRename
        ] {
            let root = try makeSecureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let storeRoot = try CodeMapArtifactStore(rootURL: root)
            let crashFixture = try await makeFixture(
                root: root,
                artifactStore: storeRoot,
                namespaceScope: "\(#function)-\(point.rawValue)",
                worktreeByte: point == .afterTemporaryWrite ? 0x98 : 0x99,
                prefix: "",
                path: "Sources/App.swift",
                text: SwiftFixtureSource.emptyStruct("InterruptedTouch", trailingNewline: false)
            )
            let writer = try CodeMapRootManifestStore(rootURL: root, accessEpochSeconds: { 0 })
            _ = try await writer.replaceCurrentManifest(
                namespace: crashFixture.namespace,
                authority: crashFixture.authority,
                records: [crashFixture.record],
                lastAccessEpochSeconds: 1
            )
            let crashing = try CodeMapRootManifestStore(
                rootURL: root,
                hooks: CodeMapRootManifestStoreHooks(
                    faultAction: { $0 == point ? .simulateProcessTermination : .proceed }
                ),
                accessEpochSeconds: { 100 }
            )
            guard case .hit = try await crashing.loadCurrentManifest(
                namespace: crashFixture.namespace,
                currentAuthority: crashFixture.authority
            ) else {
                return XCTFail("expected interrupted touch source hit")
            }
            await crashing.waitForPendingAccessRefreshesForTesting()

            let restarted = try CodeMapRootManifestStore(rootURL: root, accessEpochSeconds: { 0 })
            let maintenance = try await restarted.maintain()
            let recovered = try decodeManifest(crashFixture.namespace, from: restarted)
            XCTAssertEqual(recovered.records, [crashFixture.record])
            XCTAssertEqual(recovered.manifestGeneration, 1)
            XCTAssertEqual(
                recovered.lastAccessEpochSeconds,
                point == .afterTemporaryWrite ? 1 : 100
            )
            XCTAssertEqual(
                maintenance.removedTemporaryCount,
                point == .afterTemporaryWrite ? 1 : 0
            )
        }
    }

    func testCorruptTargetReplacementAtQuotaCountsAsInsertion() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let target = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-target",
            worktreeByte: 0x94,
            prefix: "",
            path: "Sources/Target.swift",
            text: SwiftFixtureSource.emptyStruct("Target", trailingNewline: false)
        )
        let resident = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: "\(#function)-resident",
            worktreeByte: 0x95,
            prefix: "",
            path: "Sources/Resident.swift",
            text: SwiftFixtureSource.emptyStruct("Resident", trailingNewline: false)
        )
        let permissive = try CodeMapRootManifestStore(rootURL: root)
        for fixture in [target, resident] {
            _ = try await permissive.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 1
            )
        }
        let targetEncodedByteCount = try Data(contentsOf: permissive.manifestURL(for: target.namespace)).count
        let residentEncodedByteCount = try Data(contentsOf: permissive.manifestURL(for: resident.namespace)).count
        try replaceFile(
            at: permissive.manifestURL(for: target.namespace),
            data: Data("valid-size-corrupt-target".utf8)
        )

        let strictPolicy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: 64 * 1024,
            maximumManifestCount: 1,
            maximumStoreByteCount: 64 * 1024,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32
        )
        let strict = try CodeMapRootManifestStore(rootURL: root, policy: strictPolicy)
        let result = try await strict.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 2
        )
        XCTAssertEqual(result, .replaced(manifestGeneration: 1))
        let strictAccounting = try await strict.accounting()
        XCTAssertEqual(strictAccounting.manifestCount, 1)
        guard case .hit = try await strict.loadCurrentManifest(
            namespace: target.namespace,
            currentAuthority: target.authority
        ) else {
            return XCTFail("replacement target must occupy the sole manifest quota slot")
        }
        let residentResult = try await strict.loadCurrentManifest(
            namespace: resident.namespace,
            currentAuthority: resident.authority
        )
        XCTAssertEqual(residentResult, .miss)
        await strict.waitForPendingAccessRefreshesForTesting()

        await strict.waitForPendingAccessRefreshesForTesting()
        _ = try await permissive.replaceCurrentManifest(
            namespace: resident.namespace,
            authority: resident.authority,
            records: [resident.record],
            lastAccessEpochSeconds: 3
        )
        var equalSizeCorruption = try Data(contentsOf: permissive.manifestURL(for: target.namespace))
        equalSizeCorruption[equalSizeCorruption.count / 2] ^= 0xFF
        try replaceFile(at: permissive.manifestURL(for: target.namespace), data: equalSizeCorruption)
        let byteLimit = UInt64(max(targetEncodedByteCount, residentEncodedByteCount))
        let byteStrictPolicy = CodeMapRootManifestStorePolicy(
            maximumRecordCountPerManifest: 4,
            maximumManifestByteCount: byteLimit,
            maximumManifestCount: 10,
            maximumStoreByteCount: byteLimit,
            maximumQuarantineCount: 4,
            maintenanceEntryLimit: 32
        )
        let byteStrict = try CodeMapRootManifestStore(rootURL: root, policy: byteStrictPolicy)
        _ = try await byteStrict.replaceCurrentManifest(
            namespace: target.namespace,
            authority: target.authority,
            records: [target.record],
            lastAccessEpochSeconds: 4
        )
        let byteAccounting = try await byteStrict.accounting()
        XCTAssertEqual(byteAccounting.manifestCount, 1)
        XCTAssertLessThanOrEqual(byteAccounting.manifestByteCount, byteLimit)
    }

    func testReplacedLockCannotCreateConcurrentMutationDomain() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x96,
            prefix: "",
            path: "Sources/First.swift",
            text: SwiftFixtureSource.emptyStruct("FirstLockDomain", trailingNewline: false)
        )
        let second = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/Second.swift",
            text: SwiftFixtureSource.emptyStruct("SecondLockDomain", trailingNewline: false),
            bindingGeneration: 2
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        let gate = ManifestLockReplacementGate(root: root)
        let staleStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeMaintenanceLock: { await gate.replaceLockAndWait() }
            )
        )
        let staleTask = Task {
            try await staleStore.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [second],
                lastAccessEpochSeconds: 2
            )
        }
        await gate.waitUntilReplaced()

        let currentStore = try CodeMapRootManifestStore(rootURL: root)
        let currentResult = try await currentStore.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record, second],
            lastAccessEpochSeconds: 3
        )
        XCTAssertEqual(currentResult, .replaced(manifestGeneration: 2))
        await gate.release()
        do {
            _ = try await staleTask.value
            XCTFail("the old lock/layout identity must fail before mutation")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureDirectory)
        }
        guard case let .hit(snapshot) = try await currentStore.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("current lock domain lost its authoritative snapshot")
        }
        XCTAssertEqual(snapshot.records, [fixture.record, second])
        let gateFailure = await gate.failure
        XCTAssertNil(gateFailure)
    }

    func testRootAndShardReplacementInvalidateReadAndMutationAuthority() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x97,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("ReplacementAuthority", trailingNewline: false)
        )
        let replacementRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/Replacement.swift",
            text: SwiftFixtureSource.emptyStruct("ReplacementCommit", trailingNewline: false),
            bindingGeneration: 2
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        let readShardReplacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let shardReader = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { readShardReplacement.replaceOnce() }
            )
        )
        let replacedShardRead = try await shardReader.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(replacedShardRead, .miss)
        let readReplacementFailure = readShardReplacement.failure
        XCTAssertNil(readReplacementFailure)

        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 2
        )
        let writeShardReplacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let shardWriter = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeShardReplacement.replaceOnce() }
            )
        )
        do {
            _ = try await shardWriter.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 3
            )
            XCTFail("a displaced shard must not receive a successful write")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureDirectory)
        }
        let displacedTemporaryCount = try writeShardReplacement.displacedTemporaryCount()
        XCTAssertEqual(displacedTemporaryCount, 0)
        let writeReplacementFailure = writeShardReplacement.failure
        XCTAssertNil(writeReplacementFailure)

        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 4
        )
        var corrupt = try Data(contentsOf: baseline.manifestURL(for: fixture.namespace))
        corrupt[corrupt.count / 2] ^= 0xFF
        try replaceFile(at: baseline.manifestURL(for: fixture.namespace), data: corrupt)
        let quarantineReplacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let quarantineReader = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeMaintenanceLock: { quarantineReplacement.replaceOnce() }
            )
        )
        let quarantineResult = try await quarantineReader.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(quarantineResult, .miss)
        let quarantineEntryCount = try quarantineReplacement.quarantineEntryCount()
        XCTAssertEqual(quarantineEntryCount, 0)
        let quarantineReplacementFailure = quarantineReplacement.failure
        XCTAssertNil(quarantineReplacementFailure)

        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 5
        )
        let commitReplacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let commitWriter = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterPublishRename: { commitReplacement.replaceOnce() }
            )
        )
        do {
            _ = try await commitWriter.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [replacementRecord],
                lastAccessEpochSeconds: 6
            )
            XCTFail("shard displacement at the rename boundary must not report success")
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline.manifestURL(for: fixture.namespace).path))
        let commitReplacementFailure = commitReplacement.failure
        XCTAssertNil(commitReplacementFailure)
    }

    func testReplacedRootCannotReturnAdmittedManifestHit() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0x98,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("DetachedRead", trailingNewline: false)
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let replacement = ManifestRootReplacementHook(root: root)
        let reader = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { replacement.replaceOnce() }
            )
        )
        let replacedRootRead = try await reader.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(replacedRootRead, .miss)
        let replacementFailure = replacement.failure
        XCTAssertNil(replacementFailure)
    }

    func testCrashBoundariesRecoverOrphansAndPreserveCompleteSnapshots() async throws {
        for point in CodeMapRootManifestStoreFaultPoint.allCasesForTesting {
            let root = try makeSecureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let artifactStore = try CodeMapArtifactStore(rootURL: root)
            let fixture = try await makeFixture(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(point.rawValue)",
                worktreeByte: UInt8(0xA0 + CodeMapRootManifestStoreFaultPoint.allCasesForTesting.firstIndex(of: point)!),
                prefix: "",
                path: "Sources/Old.swift",
                text: SwiftFixtureSource.emptyStruct("OldCrashBoundary", trailingNewline: false)
            )
            let replacement = try await makeRecord(
                root: root,
                artifactStore: artifactStore,
                namespaceScope: "\(#function)-\(point.rawValue)",
                namespace: fixture.namespace,
                authority: fixture.authority,
                path: "Sources/New.swift",
                text: SwiftFixtureSource.emptyStruct("NewCrashBoundary", trailingNewline: false),
                bindingGeneration: 2
            )
            let baseline = try CodeMapRootManifestStore(rootURL: root)
            _ = try await baseline.replaceCurrentManifest(
                namespace: fixture.namespace,
                authority: fixture.authority,
                records: [fixture.record],
                lastAccessEpochSeconds: 1
            )
            let crashing = try CodeMapRootManifestStore(
                rootURL: root,
                hooks: CodeMapRootManifestStoreHooks(
                    faultAction: { $0 == point ? .simulateProcessTermination : .proceed }
                )
            )
            do {
                _ = try await crashing.replaceCurrentManifest(
                    namespace: fixture.namespace,
                    authority: fixture.authority,
                    records: [replacement],
                    lastAccessEpochSeconds: 2
                )
                XCTFail("expected simulated process termination at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? CodeMapRootManifestStoreError,
                    .simulatedProcessTermination(point)
                )
            }

            let restarted = try CodeMapRootManifestStore(rootURL: root)
            let maintenance = try await restarted.maintain()
            let expected = point == .afterTemporaryWrite || point == .afterTemporaryFileSync
                ? [fixture.record]
                : [replacement]
            guard case let .hit(snapshot) = try await restarted.loadCurrentManifest(
                namespace: fixture.namespace,
                currentAuthority: fixture.authority
            ) else {
                return XCTFail("crash boundary \(point) lost the complete authoritative snapshot")
            }
            XCTAssertEqual(snapshot.records, expected)
            XCTAssertEqual(
                maintenance.removedTemporaryCount,
                point == .afterTemporaryWrite || point == .afterTemporaryFileSync ? 1 : 0
            )
            XCTAssertEqual(maintenance.accounting.temporaryCount, 0)
        }
    }

    func testHostileChecksummedCodecFramesFailClosedWithinBounds() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA4,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("HostileCodec", trailingNewline: false)
        )
        let second = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: fixture.authority,
            path: "Sources/Bpp.swift",
            text: SwiftFixtureSource.emptyStruct("HostileCodecSecond", trailingNewline: false),
            bindingGeneration: 2
        )
        let snapshot = try CodeMapRootManifestSnapshot(
            namespace: fixture.namespace,
            authority: fixture.authority,
            manifestGeneration: 1,
            lastAccessEpochSeconds: 1,
            records: [fixture.record]
        )
        let encoded = try CodeMapRootManifestCodec.encode(snapshot: snapshot)
        let canonical = try CodeMapRootManifestCodec.decodeStored(
            encoded,
            filenameDigest: fixture.namespace.storageDigestHex
        )
        XCTAssertEqual(try CodeMapRootManifestCodec.encode(snapshot: canonical), encoded)
        let offsets = try manifestCodecOffsets(in: encoded)
        var hostile: [(String, Data)] = []

        var oversizedNamespace = encoded
        writeUInt32(UInt32(CodeMapRootManifestNamespace.maximumCanonicalByteCount + 1), at: offsets.namespaceLengthOffset, in: &oversizedNamespace)
        hostile.append(("oversized namespace prefix", checksummedManifest(oversizedNamespace)))
        var oversizedAuthority = encoded
        writeUInt32(16 * 1024 + 1, at: offsets.authorityLengthOffset, in: &oversizedAuthority)
        hostile.append(("oversized authority prefix", checksummedManifest(oversizedAuthority)))
        var oversizedCount = encoded
        writeUInt32(UInt32(CodeMapRootManifestCodec.maximumRecordCount + 1), at: offsets.recordCountOffset, in: &oversizedCount)
        hostile.append(("oversized record count", checksummedManifest(oversizedCount)))
        var impossibleCount = encoded
        writeUInt32(UInt32(CodeMapRootManifestCodec.maximumRecordCount), at: offsets.recordCountOffset, in: &impossibleCount)
        hostile.append(("payload-impossible bounded count", checksummedManifest(impossibleCount)))
        var invalidUTF8 = encoded
        invalidUTF8[offsets.records[0].pathDataRange.lowerBound] = 0xFF
        hostile.append(("invalid UTF-8 path", checksummedManifest(invalidUTF8)))
        var invalidPath = encoded
        invalidPath.replaceSubrange(
            offsets.records[0].pathDataRange,
            with: Data("Sources/../x.swif".utf8)
        )
        hostile.append(("invalid repository-relative path", checksummedManifest(invalidPath)))
        var invalidMode = encoded
        invalidMode[offsets.records[0].modeOffset] = 0xFF
        hostile.append(("invalid Git mode tag", checksummedManifest(invalidMode)))
        var invalidOutcome = encoded
        invalidOutcome[offsets.records[0].outcomeOffset] = 0xFF
        hostile.append(("invalid outcome tag", checksummedManifest(invalidOutcome)))
        var invalidContribution = encoded
        invalidContribution[offsets.records[0].contributionTagOffset] = 0xFF
        hostile.append(("invalid contribution tag", checksummedManifest(invalidContribution)))
        var terminalWithContribution = encoded
        terminalWithContribution[offsets.records[0].outcomeOffset] = CodeMapRootManifestOutcome
            .terminalParseFailure.rawValue
        hostile.append(("terminal outcome with contribution", checksummedManifest(terminalWithContribution)))
        var trailingPayload = Data(encoded.dropLast(32))
        trailingPayload.append(0)
        trailingPayload.append(Data(SHA256.hash(data: trailingPayload)))
        hostile.append(("trailing payload byte", trailingPayload))

        let pair = try CodeMapRootManifestCodec.encode(
            snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 1,
                records: [fixture.record, second]
            )
        )
        let pairOffsets = try manifestCodecOffsets(in: pair)
        var duplicate = pair
        duplicate.replaceSubrange(pairOffsets.records[1].pathDataRange, with: Data("Sources/App.swift".utf8))
        hostile.append(("duplicate path", checksummedManifest(duplicate)))
        var outOfOrder = pair
        outOfOrder.replaceSubrange(pairOffsets.records[0].pathDataRange, with: Data("Sources/Zpp.swift".utf8))
        hostile.append(("out-of-order path", checksummedManifest(outOfOrder)))

        let changedAuthority = try authorityLike(fixture.authority, generation: 2, index: "index-2")
        let changedRecord = try await makeRecord(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            namespace: fixture.namespace,
            authority: changedAuthority,
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("HostileCodec", trailingNewline: false),
            bindingGeneration: 1
        )
        let changedAuthorityData = try CodeMapRootManifestCodec.encode(
            snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: changedAuthority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 1,
                records: [changedRecord]
            )
        )
        let changedOffsets = try manifestCodecOffsets(in: changedAuthorityData)
        var authorityMismatch = encoded
        authorityMismatch.replaceSubrange(
            offsets.authorityPrefixedRange,
            with: changedAuthorityData[changedOffsets.authorityPrefixedRange]
        )
        hostile.append(("record authority mismatch", checksummedManifest(authorityMismatch)))

        let python = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA4,
            prefix: "",
            path: "Sources/App.py",
            text: "class HostileCodec: pass",
            language: .python
        )
        let pythonData = try CodeMapRootManifestCodec.encode(
            snapshot: CodeMapRootManifestSnapshot(
                namespace: python.namespace,
                authority: python.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 1,
                records: [python.record]
            )
        )
        let pythonOffsets = try manifestCodecOffsets(in: pythonData)
        var keyMismatch = encoded
        keyMismatch.replaceSubrange(
            offsets.records[0].keyPrefixedRange,
            with: pythonData[pythonOffsets.records[0].keyPrefixedRange]
        )
        hostile.append(("artifact key pipeline mismatch", checksummedManifest(keyMismatch)))

        for (label, data) in hostile {
            let expectedFailure: CodeMapRootManifestDecodeFailure? = switch label {
            case "invalid contribution tag", "terminal outcome with contribution":
                .contributionValidation
            case "duplicate path", "out-of-order path":
                .orderingValidation
            case "record authority mismatch":
                .authorityValidation
            default:
                nil
            }
            XCTAssertThrowsError(
                try CodeMapRootManifestCodec.decodeStored(
                    data,
                    filenameDigest: fixture.namespace.storageDigestHex
                ),
                label
            ) { error in
                if let expectedFailure {
                    XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, expectedFailure, label)
                }
            }
        }
    }

    func testRepeatedSemanticQuarantineDelaysAndEventuallyRepairsTheFailingAuthority() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA9,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("RepeatedSemanticFailure", trailingNewline: false)
        )
        let clock = ManifestAccessClock(100)
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                waitForRegenerationBackpressure: { seconds in clock.advance(by: seconds) }
            ),
            accessEpochSeconds: { clock.value }
        )
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        func replaceWithInvalidContributionTag() throws {
            var data = try Data(contentsOf: store.manifestURL(for: fixture.namespace))
            let offsets = try manifestCodecOffsets(in: data)
            data[offsets.records[0].contributionTagOffset] = 0xFF
            try replaceFile(
                at: store.manifestURL(for: fixture.namespace),
                data: checksummedManifest(data)
            )
        }

        try replaceWithInvalidContributionTag()
        let firstFailure = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(firstFailure, .miss)
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 2
        )

        try replaceWithInvalidContributionTag()
        let secondFailure = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        )
        XCTAssertEqual(secondFailure, .miss)
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 3
        )

        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("the blocked durability write should repair after its delay")
        }
        let accounting = await store.decodeFailureAccounting()
        XCTAssertEqual(accounting.counts[.contributionValidation], 2)
        XCTAssertEqual(accounting.regenerationBackpressureCount, 1)
        XCTAssertEqual(clock.value, 130)
    }

    func testMaintenanceRepeatedSemanticQuarantineDelaysAndBackpressuresRepair() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA8,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("MaintenanceSemanticFailure", trailingNewline: false)
        )
        let clock = ManifestAccessClock(100)
        let store = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                waitForRegenerationBackpressure: { seconds in clock.advance(by: seconds) }
            ),
            accessEpochSeconds: { clock.value }
        )

        func replaceWithInvalidContributionTag() throws {
            var data = try Data(contentsOf: store.manifestURL(for: fixture.namespace))
            let offsets = try manifestCodecOffsets(in: data)
            data[offsets.records[0].contributionTagOffset] = 0xFF
            try replaceFile(
                at: store.manifestURL(for: fixture.namespace),
                data: checksummedManifest(data)
            )
        }

        func maintainUntilQuarantined() async throws -> CodeMapRootManifestMaintenanceResult {
            for _ in 0 ..< 10 {
                let result = try await store.maintain()
                if result.quarantinedCorruptCount > 0 {
                    return result
                }
            }
            return try await store.maintain()
        }

        // First valid publication.
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )

        // Corrupt the manifest; maintenance scan discovers the semantic failure.
        try replaceWithInvalidContributionTag()
        let firstResult = try await maintainUntilQuarantined()
        XCTAssertEqual(firstResult.quarantinedCorruptCount, 1)

        // Re-publish without a delay; the first scan-discovered failure has not
        // crossed the regeneration threshold.
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 2
        )

        // Corrupt and scan again; repeated scan-discovered semantic corruption
        // now triggers a regeneration backoff.
        try replaceWithInvalidContributionTag()
        let secondResult = try await maintainUntilQuarantined()
        XCTAssertEqual(secondResult.quarantinedCorruptCount, 1)

        // The repair write should be blocked for the base backoff, then succeed.
        _ = try await store.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 3
        )

        guard case .hit = try await store.loadCurrentManifest(
            namespace: fixture.namespace,
            currentAuthority: fixture.authority
        ) else {
            return XCTFail("the repair write should be observable after its backoff")
        }
        let accounting = await store.decodeFailureAccounting()
        XCTAssertEqual(accounting.counts[.contributionValidation], 2)
        XCTAssertEqual(accounting.regenerationBackpressureCount, 1)
        XCTAssertEqual(clock.value, 130)
    }

    func testStoredManifestDecodeFailureAttributesValidatedFrameStage() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA7,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("DecodeAttribution", trailingNewline: false)
        )
        let encoded = try CodeMapRootManifestCodec.encode(
            snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 1,
                records: [fixture.record]
            )
        )
        let offsets = try manifestCodecOffsets(in: encoded)

        var checksumMismatch = encoded
        checksumMismatch[checksumMismatch.index(before: checksumMismatch.endIndex)] ^= 0xFF
        XCTAssertThrowsError(try CodeMapRootManifestCodec.decodeStored(
            checksumMismatch,
            filenameDigest: fixture.namespace.storageDigestHex
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .checksumMismatch)
        }

        var unsupportedCodec = encoded
        writeUInt32(99, at: CodeMapRootManifestCodec.magic.count, in: &unsupportedCodec)
        XCTAssertThrowsError(try CodeMapRootManifestCodec.decodeStored(
            checksummedManifest(unsupportedCodec),
            filenameDigest: fixture.namespace.storageDigestHex
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .unsupportedCodecVersion)
        }

        XCTAssertThrowsError(try CodeMapRootManifestCodec.decodeStored(
            encoded,
            filenameDigest: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .namespaceDigestMismatch)
        }

        var invalidRecord = encoded
        invalidRecord.replaceSubrange(
            offsets.records[0].pathDataRange,
            with: Data("Sources/../x.swif".utf8)
        )
        XCTAssertThrowsError(try CodeMapRootManifestCodec.decodeStored(
            checksummedManifest(invalidRecord),
            filenameDigest: fixture.namespace.storageDigestHex
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .recordValidation)
        }

        var trailingPayload = Data(encoded.dropLast(32))
        trailingPayload.append(0)
        trailingPayload.append(Data(SHA256.hash(data: trailingPayload)))
        XCTAssertThrowsError(try CodeMapRootManifestCodec.decodeStored(
            trailingPayload,
            filenameDigest: fixture.namespace.storageDigestHex
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .trailingPayload)
        }

        let differentNamespace = try namespaceLike(
            fixture.namespace,
            worktreeIdentity: worktreeIdentity(0xA8)
        )
        XCTAssertThrowsError(try CodeMapRootManifestCodec.decode(
            encoded,
            expectedNamespace: differentNamespace,
            filenameDigest: fixture.namespace.storageDigestHex
        )) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .expectedNamespaceMismatch)
        }
    }

    func testRemoveNamespaceRejectsRootReplacementBeforeSuccessReturn() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA5,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("RemoveTerminalAuthority", trailingNewline: false)
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let replacement = ManifestRootReplacementHook(root: root)
        let removingStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeTerminalAuthorityCheck: { operation in
                    guard case .removeNamespace = operation else { return }
                    replacement.replaceOnce()
                }
            )
        )

        await XCTAssertThrowsManifestDirectorySecurity {
            try await removingStore.removeNamespace(fixture.namespace)
        }
        XCTAssertNil(replacement.failure)
        let currentStore = try CodeMapRootManifestStore(rootURL: root)
        let currentAccounting = try await currentStore.accounting()
        XCTAssertEqual(currentAccounting.manifestCount, 0)
    }

    func testAccountingRejectsShardReplacementBeforeReturningDetachedCounts() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA6,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("AccountingTerminalAuthority", trailingNewline: false)
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let replacement = ManifestShardReplacementHook(root: root, namespace: fixture.namespace)
        let accountingStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeTerminalAuthorityCheck: { operation in
                    guard case .accounting = operation else { return }
                    replacement.replaceOnce()
                }
            )
        )

        await XCTAssertThrowsManifestDirectorySecurity {
            try await accountingStore.accounting()
        }
        XCTAssertNil(replacement.failure)
        let currentAccounting = try await baseline.accounting()
        XCTAssertEqual(currentAccounting.manifestCount, 0)
    }

    func testMaintainRejectsLockReplacementAfterMutationBeforeSuccessReturn() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try CodeMapArtifactStore(rootURL: root)
        let fixture = try await makeFixture(
            root: root,
            artifactStore: artifactStore,
            namespaceScope: #function,
            worktreeByte: 0xA7,
            prefix: "",
            path: "Sources/App.swift",
            text: SwiftFixtureSource.emptyStruct("MaintenanceTerminalAuthority", trailingNewline: false)
        )
        let baseline = try CodeMapRootManifestStore(rootURL: root)
        _ = try await baseline.replaceCurrentManifest(
            namespace: fixture.namespace,
            authority: fixture.authority,
            records: [fixture.record],
            lastAccessEpochSeconds: 1
        )
        let temporary = baseline.manifestURL(for: fixture.namespace)
            .deletingLastPathComponent()
            .appendingPathComponent(".tmp.999999.terminal-authority")
        try Data("orphan".utf8).write(to: temporary, options: .withoutOverwriting)
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)

        let replacement = ManifestMaintenanceLockReplacementHook(root: root)
        let maintenanceStore = try CodeMapRootManifestStore(
            rootURL: root,
            hooks: CodeMapRootManifestStoreHooks(
                beforeTerminalAuthorityCheck: { operation in
                    guard case .maintenance = operation else { return }
                    replacement.replaceOnce()
                }
            )
        )
        await XCTAssertThrowsManifestDirectorySecurity {
            try await maintenanceStore.maintain()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertNil(replacement.failure)

        let currentStore = try CodeMapRootManifestStore(rootURL: root)
        let currentMaintenance = try await currentStore.maintain()
        XCTAssertEqual(currentMaintenance.accounting.manifestCount, 1)
        XCTAssertEqual(currentMaintenance.accounting.temporaryCount, 0)
    }

    func testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries() async throws {
        for (operationIndex, operation) in ManifestScanMutationOperation.allCases.enumerated() {
            for (entryIndex, entryKind) in ManifestInjectedEntryKind.allCases.enumerated() {
                let root = try makeSecureRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let policy = CodeMapRootManifestStorePolicy(
                    maximumRecordCountPerManifest: 4,
                    maximumManifestByteCount: 64 * 1024,
                    maximumManifestCount: 2,
                    maximumStoreByteCount: 128 * 1024,
                    maximumQuarantineCount: 4,
                    maintenanceEntryLimit: 32
                )
                let artifactStore = try CodeMapArtifactStore(rootURL: root)
                let scope = "\(#function)-\(operation)-\(entryKind)"
                let baseline = try await makeFixture(
                    root: root,
                    artifactStore: artifactStore,
                    namespaceScope: scope,
                    worktreeByte: UInt8(0xB0 + operationIndex * 4 + entryIndex),
                    prefix: "",
                    path: "Sources/Baseline.swift",
                    text: SwiftFixtureSource.emptyStruct("TerminalBaseline", trailingNewline: false)
                )
                let injected = try await makeFixture(
                    root: root,
                    artifactStore: artifactStore,
                    namespaceScope: "\(scope)-injected",
                    worktreeByte: UInt8(0xC0 + operationIndex * 4 + entryIndex),
                    prefix: "",
                    path: "Sources/Injected.swift",
                    text: SwiftFixtureSource.emptyStruct("TerminalInjected", trailingNewline: false)
                )
                let target = try await makeFixture(
                    root: root,
                    artifactStore: artifactStore,
                    namespaceScope: "\(scope)-target",
                    worktreeByte: UInt8(0xD0 + operationIndex * 4 + entryIndex),
                    prefix: "",
                    path: "Sources/Target.swift",
                    text: SwiftFixtureSource.emptyStruct("TerminalTarget", trailingNewline: false)
                )
                let baselineStore = try CodeMapRootManifestStore(
                    rootURL: root,
                    policy: policy,
                    accessEpochSeconds: { 0 }
                )
                _ = try await baselineStore.replaceCurrentManifest(
                    namespace: baseline.namespace,
                    authority: baseline.authority,
                    records: [baseline.record],
                    lastAccessEpochSeconds: 1
                )

                let insertion: ManifestEntryInsertionHook
                switch entryKind {
                case .valid:
                    let snapshot = try CodeMapRootManifestSnapshot(
                        namespace: injected.namespace,
                        authority: injected.authority,
                        manifestGeneration: 1,
                        lastAccessEpochSeconds: 1,
                        records: [injected.record]
                    )
                    insertion = try ManifestEntryInsertionHook(
                        url: baselineStore.manifestURL(for: injected.namespace),
                        data: CodeMapRootManifestCodec.encode(snapshot: snapshot)
                    )
                case .corrupt:
                    let baselineURL = baselineStore.manifestURL(for: baseline.namespace)
                    let nameByte = baseline.namespace.storageDigestHex.first == "0" ? "1" : "0"
                    insertion = ManifestEntryInsertionHook(
                        url: baselineURL.deletingLastPathComponent()
                            .appendingPathComponent(String(repeating: nameByte, count: 64)),
                        data: Data("checksum-invalid-terminal-entry".utf8)
                    )
                }

                let guardedStore = try CodeMapRootManifestStore(
                    rootURL: root,
                    policy: policy,
                    hooks: CodeMapRootManifestStoreHooks(
                        beforeTerminalAuthorityCheck: { observedOperation in
                            guard operation.matches(observedOperation) else { return }
                            insertion.insertOnce()
                        }
                    ),
                    accessEpochSeconds: { 0 }
                )
                await XCTAssertThrowsManifestDirectorySecurity {
                    switch operation {
                    case .accounting:
                        try await guardedStore.accounting()
                    case .maintenance:
                        try await guardedStore.maintain()
                    case .publicationQuota:
                        try await guardedStore.replaceCurrentManifest(
                            namespace: target.namespace,
                            authority: target.authority,
                            records: [target.record],
                            lastAccessEpochSeconds: 2
                        )
                    }
                }
                XCTAssertNil(insertion.failure)
                XCTAssertTrue(FileManager.default.fileExists(atPath: insertion.url.path))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: baselineStore.manifestURL(for: target.namespace).path
                ))

                let currentStore = try CodeMapRootManifestStore(
                    rootURL: root,
                    policy: policy,
                    accessEpochSeconds: { 0 }
                )
                let accounting = try await currentStore.accounting()
                XCTAssertEqual(accounting.manifestCount, entryKind == .valid ? 2 : 1)
            }
        }
    }

    private func makeFixture(
        root: URL,
        artifactStore: CodeMapArtifactStore,
        namespaceScope: String,
        worktreeByte: UInt8,
        prefix: String,
        path: String,
        text: String,
        language: LanguageType = .swift,
        authorityGeneration: UInt64 = 1,
        objectFormat: GitObjectFormat = .sha1,
        repositoryBindingEpoch: String = "repository-binding-1",
        worktreeBindingEpoch: String? = nil
    ) async throws -> ManifestFixture {
        let source = try await WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: Data(text.utf8),
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
        guard case let .cleanGitBlob(repositoryNamespace, _) = source.provenance else {
            throw CodeMapRootManifestModelError.invalidNamespace
        }
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: language,
            decoderPolicy: source.decoderPolicy
        )
        let resolvedWorktreeBindingEpoch = worktreeBindingEpoch ??
            "worktree-binding-\(String(format: "%02x", worktreeByte))"
        let namespace = try CodeMapRootManifestNamespace(
            repositoryNamespace: repositoryNamespace,
            worktreeIdentity: worktreeIdentity(worktreeByte),
            repositoryRelativeLoadedRootPrefix: prefix,
            objectFormat: objectFormat,
            pipelineIdentity: pipeline,
            repositoryBindingEpoch: repositoryBindingEpoch,
            worktreeBindingEpoch: resolvedWorktreeBindingEpoch
        )
        let authority = try CodeMapRootManifestAuthority(
            authorityGeneration: authorityGeneration,
            repositoryBindingEpoch: repositoryBindingEpoch,
            worktreeBindingEpoch: resolvedWorktreeBindingEpoch,
            layoutGeneration: "layout-1",
            indexGeneration: "index-1",
            checkoutConfigurationGeneration: "checkout-1",
            attributeGeneration: "attributes-1",
            sparseGeneration: "sparse-1",
            metadataGeneration: "metadata-1"
        )
        let record = try await makeRecord(
            source: source,
            artifactStore: artifactStore,
            namespace: namespace,
            authority: authority,
            path: path,
            text: text,
            pipeline: pipeline,
            bindingGeneration: 1
        )
        return ManifestFixture(namespace: namespace, authority: authority, record: record)
    }

    private func makeRecord(
        root _: URL,
        artifactStore: CodeMapArtifactStore,
        namespaceScope: String,
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        path: String,
        text: String,
        bindingGeneration: UInt64
    ) async throws -> CodeMapRootManifestRecord {
        let source = try await WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: Data(text.utf8),
            objectFormat: namespace.objectFormat,
            namespaceScope: namespaceScope
        )
        return try await makeRecord(
            source: source,
            artifactStore: artifactStore,
            namespace: namespace,
            authority: authority,
            path: path,
            text: text,
            pipeline: namespace.pipelineIdentity,
            bindingGeneration: bindingGeneration
        )
    }

    private func makeRecord(
        source: CodeMapSourceSnapshot,
        artifactStore: CodeMapArtifactStore,
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        path: String,
        text: String,
        pipeline: CodeMapPipelineIdentity,
        bindingGeneration: UInt64
    ) async throws -> CodeMapRootManifestRecord {
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance,
              repositoryNamespace == namespace.repositoryNamespace
        else {
            throw CodeMapRootManifestModelError.invalidNamespace
        }
        let key = CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: Data(text.utf8)))),
            rawByteCount: UInt64(text.utf8.count),
            pipelineIdentity: pipeline
        )
        _ = try await artifactStore.insert(key: key, deterministicOutcome: .readyNoSymbols)
        let handle: CodeMapArtifactHandle
        switch try await artifactStore.lookup(key: key) {
        case let .hit(_, value): handle = value
        case .miss: throw CodeMapRootManifestModelError.artifactKeyMismatch
        }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: locator,
            artifactKey: key,
            casHandle: handle
        )
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: key,
            definitions: [],
            references: []
        )
        return try CodeMapRootManifestRecord.verifiedClean(
            namespace: namespace,
            repositoryRelativePath: path,
            gitMode: .regular,
            association: association,
            contribution: contribution,
            authority: authority,
            bindingGeneration: bindingGeneration
        )
    }

    private func makeAssociation(
        artifactStore: CodeMapArtifactStore,
        namespaceScope: String,
        text: String,
        pipeline: CodeMapPipelineIdentity,
        objectFormat: GitObjectFormat,
        outcome: CodeMapSyntaxArtifactOutcome
    ) async throws -> ManifestAssociationFixture {
        let bytes = Data(text.utf8)
        let source = try await WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: bytes,
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw CodeMapRootManifestModelError.invalidNamespace
        }
        let key = CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: bytes))),
            rawByteCount: UInt64(bytes.count),
            pipelineIdentity: pipeline
        )
        _ = try await artifactStore.insert(key: key, deterministicOutcome: outcome)
        let handle: CodeMapArtifactHandle
        switch try await artifactStore.lookup(key: key) {
        case let .hit(_, value): handle = value
        case .miss: throw CodeMapRootManifestModelError.artifactKeyMismatch
        }
        let identity = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        return try ManifestAssociationFixture(
            key: key,
            association: VerifiedGitBlobCodeMapLocatorAssociation.verify(
                source: source,
                identity: identity,
                artifactKey: key,
                casHandle: handle
            )
        )
    }

    private func makeArtifact(name: String) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            exports: [],
            classes: [ClassInfo(name: name, methods: [], properties: [])],
            interfaces: [],
            aliases: [],
            literalUnions: [],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func namespaceLike(
        _ namespace: CodeMapRootManifestNamespace,
        repositoryNamespace: GitBlobRepositoryNamespace? = nil,
        worktreeIdentity: String? = nil,
        repositoryRelativeLoadedRootPrefix: String? = nil,
        objectFormat: GitObjectFormat? = nil,
        schemaVersion: UInt32? = nil,
        policyVersion: UInt32? = nil,
        pipelineIdentity: CodeMapPipelineIdentity? = nil,
        repositoryBindingEpoch: String? = nil,
        worktreeBindingEpoch: String? = nil
    ) throws -> CodeMapRootManifestNamespace {
        try CodeMapRootManifestNamespace(
            repositoryNamespace: repositoryNamespace ?? namespace.repositoryNamespace,
            worktreeIdentity: worktreeIdentity ?? namespace.worktreeIdentity,
            repositoryRelativeLoadedRootPrefix: repositoryRelativeLoadedRootPrefix ??
                namespace.repositoryRelativeLoadedRootPrefix,
            objectFormat: objectFormat ?? namespace.objectFormat,
            schemaVersion: schemaVersion ?? namespace.schemaVersion,
            policyVersion: policyVersion ?? namespace.policyVersion,
            pipelineIdentity: pipelineIdentity ?? namespace.pipelineIdentity,
            repositoryBindingEpoch: repositoryBindingEpoch ?? namespace.repositoryBindingEpoch,
            worktreeBindingEpoch: worktreeBindingEpoch ?? namespace.worktreeBindingEpoch
        )
    }

    private func authorityLike(
        _ authority: CodeMapRootManifestAuthority,
        generation: UInt64,
        index: String
    ) throws -> CodeMapRootManifestAuthority {
        try CodeMapRootManifestAuthority(
            authorityGeneration: generation,
            repositoryBindingEpoch: authority.repositoryBindingEpoch,
            worktreeBindingEpoch: authority.worktreeBindingEpoch,
            layoutGeneration: authority.layoutGeneration,
            indexGeneration: index,
            checkoutConfigurationGeneration: authority.checkoutConfigurationGeneration,
            attributeGeneration: authority.attributeGeneration,
            sparseGeneration: authority.sparseGeneration,
            metadataGeneration: authority.metadataGeneration
        )
    }

    private func worktreeIdentity(_ byte: UInt8) -> String {
        "wt_" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func makeSecureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapRootManifestStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(root.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }

    private func replaceFile(at url: URL, data: Data) throws {
        let replacement = url.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString)")
        try data.write(to: replacement, options: .withoutOverwriting)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
    }

    private func overwriteFileInPlace(at url: URL, data: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodeMapRootManifestStoreError.ioFailure(operation: "test-open", code: errno) }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 0), 0)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else {
                    throw CodeMapRootManifestStoreError.ioFailure(operation: "test-write", code: errno)
                }
                offset += written
            }
        }
        XCTAssertEqual(fsync(descriptor), 0)
    }

    private func decodeManifest(
        _ namespace: CodeMapRootManifestNamespace,
        from store: CodeMapRootManifestStore
    ) throws -> CodeMapRootManifestSnapshot {
        try CodeMapRootManifestCodec.decodeStored(
            Data(contentsOf: store.manifestURL(for: namespace)),
            filenameDigest: namespace.storageDigestHex
        )
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

    private func XCTAssertThrowsManifestSecurity(
        _ operation: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected manifest security failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureLeaf, file: file, line: line)
        }
    }

    private func XCTAssertThrowsManifestDirectorySecurity(
        _ operation: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected manifest directory security failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureDirectory, file: file, line: line)
        }
    }

    private func XCTAssertThrowsManifestQuota(
        _ operation: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected manifest quota failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodeMapRootManifestStoreError, .quotaExceeded, file: file, line: line)
        }
    }
}

private struct ManifestFixture {
    let namespace: CodeMapRootManifestNamespace
    let authority: CodeMapRootManifestAuthority
    let record: CodeMapRootManifestRecord
}

private struct ManifestAssociationFixture {
    let key: CodeMapArtifactKey
    let association: VerifiedGitBlobCodeMapLocatorAssociation
}

private enum ManifestScanMutationOperation: CaseIterable {
    case accounting
    case maintenance
    case publicationQuota

    func matches(_ operation: CodeMapRootManifestStoreTerminalOperation) -> Bool {
        switch (self, operation) {
        case (.accounting, .accounting),
             (.maintenance, .maintenance),
             (.publicationQuota, .publicationQuota):
            true
        default:
            false
        }
    }
}

private enum ManifestInjectedEntryKind: CaseIterable, Equatable {
    case valid
    case corrupt
}

private final class ManifestEntryInsertionHook: @unchecked Sendable {
    let url: URL
    private let data: Data
    private let lock = NSLock()
    private var inserted = false
    private var storedFailure: Error?

    init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func insertOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !inserted else { return }
        inserted = true
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(parent.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try data.write(to: url, options: .withoutOverwriting)
            guard chmod(url.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            storedFailure = error
        }
    }
}

private final class ManifestPublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private final class ManifestTemporaryBurstInsertionHook: @unchecked Sendable {
    private let manifestURL: URL
    private let count: Int
    private let lock = NSLock()
    private var inserted = false
    private var storedFailure: Error?

    init(manifestURL: URL, count: Int) {
        self.manifestURL = manifestURL
        self.count = count
    }

    var failure: Error? {
        lock.withLock { storedFailure }
    }

    func insertOnce() {
        lock.withLock {
            guard !inserted else { return }
            inserted = true
            do {
                let parent = manifestURL.deletingLastPathComponent()
                for index in 0 ..< count {
                    let temporary = parent.appendingPathComponent(".tmp.injected.\(index)")
                    try Data("temporary-\(index)".utf8).write(to: temporary, options: .withoutOverwriting)
                    guard chmod(temporary.path, 0o600) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            } catch {
                storedFailure = error
            }
        }
    }

    func removeInsertedFiles() throws {
        try lock.withLock {
            let parent = manifestURL.deletingLastPathComponent()
            for index in 0 ..< count {
                let temporary = parent.appendingPathComponent(".tmp.injected.\(index)")
                if FileManager.default.fileExists(atPath: temporary.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
            }
        }
    }
}

private final class ManifestScanInspectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String] = []

    var inspectedDigests: [String] {
        lock.withLock { digests }
    }

    func record(_ digest: String) {
        lock.withLock { digests.append(digest) }
    }

    func reset() {
        lock.withLock { digests.removeAll(keepingCapacity: true) }
    }
}

private final class ManifestAccessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        storedValue = value
    }

    var value: UInt64 {
        lock.withLock { storedValue }
    }

    func advance(by amount: UInt64) {
        lock.withLock {
            let (sum, overflow) = storedValue.addingReportingOverflow(amount)
            storedValue = overflow ? .max : sum
        }
    }
}

private final class ManifestLockedMergeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let firstWriterFence = TestBlockingFence(name: "manifest locked merge first-writer fence")
    private var firstWriterAcquired = false
    private var secondWriterAttempted = false
    private var secondWriterAcquired = false

    var didSecondWriterAcquireLock: Bool {
        condition.withLock { secondWriterAcquired }
    }

    func firstWriterAcquiredLockAndWait(timeout: TimeInterval = TestFenceDefaults.releaseWait) {
        condition.lock()
        firstWriterAcquired = true
        condition.broadcast()
        condition.unlock()
        firstWriterFence.enterAndWait(timeout: timeout)
    }

    func secondWriterAttemptedLock() {
        condition.withLock {
            secondWriterAttempted = true
            condition.broadcast()
        }
    }

    func secondWriterAcquiredLock() {
        condition.withLock {
            secondWriterAcquired = true
            condition.broadcast()
        }
    }

    func waitUntilFirstWriterAcquiredLock(timeout: TimeInterval = TestFenceDefaults.enterWait) -> Bool {
        wait(timeout: timeout) { firstWriterAcquired }
    }

    func waitUntilSecondWriterAttemptedLock(timeout: TimeInterval = TestFenceDefaults.enterWait) -> Bool {
        wait(timeout: timeout) { secondWriterAttempted }
    }

    func releaseFirstWriter() {
        firstWriterFence.release()
    }

    private func wait(timeout: TimeInterval, condition predicate: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard condition.wait(until: deadline) else { return predicate() }
        }
        return true
    }
}

private final class ManifestStoreWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0

    var scanCount: Int {
        lock.withLock { scans }
    }

    func recordScan() {
        lock.withLock { scans += 1 }
    }

    func reset() {
        lock.withLock { scans = 0 }
    }
}

/// Manifest access refresh block/release fence (shared `TestReleaseFence`).
private final class ManifestAccessRefreshGate: @unchecked Sendable {
    private let fence = TestReleaseFence(name: "manifest access refresh gate")

    func block() async {
        await fence.enterAndWait()
    }

    func waitUntilBlocked(timeout: TimeInterval = TestFenceDefaults.enterWait) async {
        _ = await fence.waitUntilEntered(timeout: timeout)
    }

    func release() {
        fence.release()
    }
}

private final class ManifestRootReplacementHook: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var replaced = false
    private var storedFailure: Error?

    init(root: URL) {
        self.root = root
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func replaceOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return }
        replaced = true
        do {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            storedFailure = error
        }
    }
}

private final class ManifestMaintenanceLockReplacementHook: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var replaced = false
    private var storedFailure: Error?

    init(root: URL) {
        self.root = root
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func replaceOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return }
        replaced = true
        do {
            let version = root
                .appendingPathComponent("CodeMapRootManifests", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
            let current = version.appendingPathComponent("maintenance.lock")
            let replacement = version.appendingPathComponent("terminal-lock-\(UUID().uuidString)")
            try Data().write(to: replacement, options: .withoutOverwriting)
            guard chmod(replacement.path, 0o600) == 0,
                  rename(replacement.path, current.path) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            storedFailure = error
        }
    }
}

private actor ManifestLockReplacementGate {
    private let root: URL
    private var replaced = false
    private var released = false
    private var replacementWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var failure: Error?

    init(root: URL) {
        self.root = root
    }

    func replaceLockAndWait() async {
        if !replaced {
            do {
                let version = root
                    .appendingPathComponent("CodeMapRootManifests", isDirectory: true)
                    .appendingPathComponent("v1", isDirectory: true)
                let lock = version.appendingPathComponent("maintenance.lock")
                let replacement = version.appendingPathComponent("replacement-lock-\(UUID().uuidString)")
                try Data().write(to: replacement, options: .withoutOverwriting)
                guard chmod(replacement.path, 0o600) == 0,
                      rename(replacement.path, lock.path) == 0
                else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                failure = error
            }
            replaced = true
            let waiters = replacementWaiters
            replacementWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilReplaced() async {
        if replaced {
            return
        }
        await withCheckedContinuation { replacementWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ManifestShardReplacementHook: @unchecked Sendable {
    private let root: URL
    private let namespace: CodeMapRootManifestNamespace
    private let lock = NSLock()
    private var replaced = false
    private var displaced: URL?
    private var storedFailure: Error?

    init(root: URL, namespace: CodeMapRootManifestNamespace) {
        self.root = root
        self.namespace = namespace
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func replaceOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return }
        replaced = true
        do {
            let manifests = root
                .appendingPathComponent("CodeMapRootManifests", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("manifests", isDirectory: true)
            let shard = manifests.appendingPathComponent(namespace.shard, isDirectory: true)
            let displaced = manifests.appendingPathComponent(
                ".displaced-\(namespace.shard)-\(UUID().uuidString)",
                isDirectory: true
            )
            guard rename(shard.path, displaced.path) == 0,
                  mkdir(shard.path, 0o700) == 0,
                  chmod(shard.path, 0o700) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.displaced = displaced
        } catch {
            storedFailure = error
        }
    }

    func displacedTemporaryCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let displaced else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: displaced.path)
            .count(where: { $0.hasPrefix(".tmp.") })
    }

    func quarantineEntryCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let quarantine = root
            .appendingPathComponent("CodeMapRootManifests", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("quarantine", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count
    }
}

private final class ManifestTargetFileReplacementHook: @unchecked Sendable {
    private let targetURL: URL
    private let replacementData: Data
    private let lock = NSLock()
    private var replaced = false
    private var storedFailure: Error?

    init(targetURL: URL, replacementData: Data) {
        self.targetURL = targetURL
        self.replacementData = replacementData
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func replaceOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return }
        replaced = true
        do {
            let replacement = targetURL.deletingLastPathComponent()
                .appendingPathComponent(".replacement-\(UUID().uuidString)")
            try replacementData.write(to: replacement, options: .withoutOverwriting)
            guard chmod(replacement.path, 0o600) == 0,
                  rename(replacement.path, targetURL.path) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            storedFailure = error
        }
    }
}

private struct ManifestCodecOffsets {
    struct Record {
        let pathDataRange: Range<Int>
        let keyPrefixedRange: Range<Int>
        let modeOffset: Int
        let outcomeOffset: Int
        let contributionTagOffset: Int
    }

    let namespaceLengthOffset: Int
    let authorityLengthOffset: Int
    let authorityPrefixedRange: Range<Int>
    let recordCountOffset: Int
    let records: [Record]
}

private func manifestCodecOffsets(in data: Data) throws -> ManifestCodecOffsets {
    let checksumCount = 32
    let payloadEnd = data.count - checksumCount
    guard payloadEnd > CodeMapRootManifestCodec.magic.count + 4 else {
        throw CodeMapRootManifestModelError.corruptRecord
    }
    var cursor = CodeMapRootManifestCodec.magic.count + 4
    let namespaceLengthOffset = cursor
    let namespaceCount = try manifestUInt32(in: data, at: cursor)
    cursor += 4 + Int(namespaceCount)
    let authorityLengthOffset = cursor
    let authorityCount = try manifestUInt32(in: data, at: cursor)
    let authorityPrefixedRange = cursor ..< cursor + 4 + Int(authorityCount)
    cursor = authorityPrefixedRange.upperBound
    cursor += 8 + 8
    let recordCountOffset = cursor
    let recordCount = try manifestUInt32(in: data, at: cursor)
    cursor += 4
    var records: [ManifestCodecOffsets.Record] = []
    for _ in 0 ..< recordCount {
        let pathCount = try manifestUInt32(in: data, at: cursor)
        cursor += 4
        let pathRange = cursor ..< cursor + Int(pathCount)
        cursor = pathRange.upperBound

        let locatorCount = try manifestUInt32(in: data, at: cursor)
        cursor += 4 + Int(locatorCount)
        let keyStart = cursor
        let keyCount = try manifestUInt32(in: data, at: cursor)
        cursor += 4 + Int(keyCount)
        let keyRange = keyStart ..< cursor

        let modeOffset = cursor
        cursor += 1
        let outcomeOffset = cursor
        cursor += 1
        guard cursor < payloadEnd else { throw CodeMapRootManifestModelError.corruptRecord }
        let contributionTagOffset = cursor
        let contributionTag = data[cursor]
        cursor += 1
        if contributionTag == 1 {
            cursor += 4 + 4 + CodeMapSHA256Digest.byteCount
            let definitionCount = try manifestUInt32(in: data, at: cursor)
            cursor += 4
            for _ in 0 ..< definitionCount {
                let byteCount = try manifestUInt32(in: data, at: cursor)
                cursor += 4 + Int(byteCount)
            }
            let referenceCount = try manifestUInt32(in: data, at: cursor)
            cursor += 4
            for _ in 0 ..< referenceCount {
                let byteCount = try manifestUInt32(in: data, at: cursor)
                cursor += 4 + Int(byteCount)
            }
        }
        cursor += 8 + 8 + CodeMapSHA256Digest.byteCount
        guard cursor <= payloadEnd else { throw CodeMapRootManifestModelError.corruptRecord }
        records.append(.init(
            pathDataRange: pathRange,
            keyPrefixedRange: keyRange,
            modeOffset: modeOffset,
            outcomeOffset: outcomeOffset,
            contributionTagOffset: contributionTagOffset
        ))
    }
    return ManifestCodecOffsets(
        namespaceLengthOffset: namespaceLengthOffset,
        authorityLengthOffset: authorityLengthOffset,
        authorityPrefixedRange: authorityPrefixedRange,
        recordCountOffset: recordCountOffset,
        records: records
    )
}

private func manifestUInt32(in data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw CodeMapRootManifestModelError.corruptRecord
    }
    return data[offset ..< offset + 4].reduce(into: UInt32(0)) { value, byte in
        value = (value << 8) | UInt32(byte)
    }
}

private func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data[offset] = UInt8((value >> 24) & 0xFF)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8) & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}

private func checksummedManifest(_ data: Data) -> Data {
    var payload = Data(data.dropLast(32))
    payload.append(Data(SHA256.hash(data: payload)))
    return payload
}

private extension CodeMapRootManifestStoreFaultPoint {
    static let allCasesForTesting: [Self] = [
        .afterTemporaryWrite,
        .afterTemporaryFileSync,
        .afterManifestRename,
        .afterManifestDirectorySync
    ]
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
