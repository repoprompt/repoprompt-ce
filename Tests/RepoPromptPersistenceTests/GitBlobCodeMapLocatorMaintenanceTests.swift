import Darwin
import Foundation
import RepoPromptCodeMapCore
import RepoPromptFoundation
@testable import RepoPromptPersistence
import XCTest

#if DEBUG
    final class GitBlobCodeMapLocatorMaintenanceTests: XCTestCase {
        func testRepeatedSweepsReuseValidationButStillInspectEveryLeaf() async throws {
            let fixture = try await makeFixture(count: 65)
            let policy = GitBlobCodeMapLocatorStorePolicy(
                maximumRecordCount: 128, maximumByteCount: 16 * 1024 * 1024,
                maintenanceEntryLimit: 512, maintenanceReconciliationInterval: 16
            )
            let store = try GitBlobCodeMapLocatorStore(rootURL: fixture.root, policy: policy)
            for association in fixture.associations.prefix(64) {
                let result = try await store.write(association: association)
                XCTAssertEqual(result, .inserted)
            }
            let accounting = await store.debugMaintenanceAccounting()
            let validation = await store.debugMaintenanceValidationCounts()
            XCTAssertEqual(accounting.sweepCount, 4)
            XCTAssertEqual(accounting.examinedRecordCount, 100) // 1 + 17 + 33 + 49
            XCTAssertEqual(accounting.estimatedRecordCount, 64)
            XCTAssertEqual(validation.decodes, 49)
            XCTAssertEqual(validation.hits, 51)
            XCTAssertEqual(validation.retainedProofs, 49)
            for _ in 0 ..< 20 {
                let result = try await store.write(association: fixture.associations[0])
                XCTAssertEqual(result, .alreadyPresent)
            }
            let afterRepeat = await store.debugMaintenanceAccounting()
            XCTAssertEqual(afterRepeat, accounting)

            let cold = try GitBlobCodeMapLocatorStore(rootURL: fixture.root, policy: policy)
            let result = try await cold.write(association: fixture.associations[64])
            XCTAssertEqual(result, .inserted)
            let coldAccounting = await cold.debugMaintenanceAccounting()
            let coldValidation = await cold.debugMaintenanceValidationCounts()
            XCTAssertEqual(coldAccounting.examinedRecordCount, 65)
            XCTAssertEqual(coldValidation.decodes, 65)
            XCTAssertEqual(coldValidation.hits, 0)
        }

        func testChangedBytesAndInsecureLeavesCannotReuseValidation() async throws {
            let fixture = try await makeFixture(count: 1)
            let store = try GitBlobCodeMapLocatorStore(rootURL: fixture.root)
            let association = fixture.associations[0]
            _ = try await store.write(association: association)
            let url = store.recordURL(for: association.identity)
            _ = try await store.maintain()
            let warm = await store.debugMaintenanceValidationCounts()
            XCTAssertEqual(warm.decodes, 1)
            XCTAssertEqual(warm.hits, 1)

            let replacement = try await makeAssociation(
                root: fixture.root, identity: association.identity, digestByte: 2
            )
            let validBytes = try GitBlobCodeMapLocatorRecordCodec.encode(association: replacement)
            try overwriteInPlacePreservingModificationDate(url, with: validBytes)
            let changed = try await store.maintain()
            let afterChange = await store.debugMaintenanceValidationCounts()
            XCTAssertEqual(changed.remainingRecordCount, 1)
            XCTAssertEqual(afterChange.decodes, 2)
            XCTAssertEqual(afterChange.hits, 1)
            let read = try await store.read(identity: association.identity)
            XCTAssertEqual(read, .hit(replacement.artifactKey))

            // Leave the old trailing checksum intact: a cached checksum field alone is not proof.
            var corrupt = validBytes
            corrupt[0] ^= 1
            try overwriteInPlacePreservingModificationDate(url, with: corrupt)
            let removed = try await store.maintain()
            let afterCorruption = await store.debugMaintenanceValidationCounts()
            XCTAssertEqual(removed.removedCorruptCount, 1)
            XCTAssertEqual(removed.remainingRecordCount, 0)
            XCTAssertEqual(afterCorruption.decodes, 3)
            XCTAssertEqual(afterCorruption.retainedProofs, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

            _ = try await store.write(association: association)
            _ = try await store.maintain()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            let insecure = try await store.maintain()
            let afterInsecure = await store.debugMaintenanceValidationCounts()
            XCTAssertEqual(insecure.remainingRecordCount, 0)
            XCTAssertEqual(afterInsecure.retainedProofs, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Insecure leaves remain ignored, not removed")
        }

        func testHighWaterEvictionPreservesNewRecordAndBoundsProofs() async throws {
            for byteLimited in [false, true] {
                let fixture = try await makeFixture(count: 9)
                let recordBytes = try GitBlobCodeMapLocatorRecordCodec.encode(
                    association: fixture.associations[0]
                ).count
                let policy = GitBlobCodeMapLocatorStorePolicy(
                    maximumRecordCount: byteLimited ? 128 : 8,
                    maximumByteCount: byteLimited ? UInt64(recordBytes * 8) : 16 * 1024 * 1024,
                    maintenanceEntryLimit: 512, maintenanceReconciliationInterval: 256
                )
                let store = try GitBlobCodeMapLocatorStore(rootURL: fixture.root, policy: policy)
                for (index, association) in fixture.associations.prefix(8).enumerated() {
                    _ = try await store.write(association: association)
                    // The ninth publication will sort oldest, so retaining it requires the protected-digest rule.
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSinceNow: 1000 + Double(index))],
                        ofItemAtPath: store.recordURL(for: association.identity).path
                    )
                }
                _ = try await store.write(association: fixture.associations[8])
                let accounting = await store.debugMaintenanceAccounting()
                let validation = await store.debugMaintenanceValidationCounts()
                let result = try XCTUnwrap(accounting.lastResult)
                XCTAssertEqual(accounting.sweepCount, 2)
                XCTAssertEqual(accounting.examinedRecordCount, 10) // First insert + high-water sweep.
                XCTAssertEqual(result.evictedCount, 2)
                XCTAssertEqual(result.remainingRecordCount, 7)
                XCTAssertLessThanOrEqual(result.remainingByteCount, policy.maximumByteCount)
                XCTAssertLessThanOrEqual(validation.retainedProofs, 7)
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordURL(for: fixture.associations[0].identity).path))
                let protected = try await store.read(identity: fixture.associations[8].identity)
                XCTAssertEqual(protected, .hit(fixture.associations[8].artifactKey))
            }
        }

        func testIncompleteScansStillFailClosedWithWarmProofs() async throws {
            let fixture = try await makeFixture(count: 3)
            let writer = try GitBlobCodeMapLocatorStore(rootURL: fixture.root)
            for association in fixture.associations {
                _ = try await writer.write(association: association)
            }
            let store = try GitBlobCodeMapLocatorStore(
                rootURL: fixture.root,
                policy: .init(maximumRecordCount: 4, maximumByteCount: 16 * 1024 * 1024, maintenanceEntryLimit: 2)
            )
            for _ in 0 ..< 2 {
                do {
                    _ = try await store.maintain()
                    XCTFail("Incomplete scans must not prove quota compliance")
                } catch {
                    XCTAssertEqual(error as? GitBlobCodeMapLocatorStoreError, .quotaExceeded)
                }
            }
            let validation = await store.debugMaintenanceValidationCounts()
            XCTAssertGreaterThan(validation.hits, 0)
            XCTAssertLessThanOrEqual(validation.retainedProofs, 2)
        }

        private struct Fixture {
            let root: URL
            let associations: [VerifiedGitBlobCodeMapLocatorAssociation]
        }

        private func makeFixture(count: Int) async throws -> Fixture {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("locator-validation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let resolved = try XCTUnwrap(base.path.withCString { pointer -> String? in
                guard let path = realpath(pointer, nil) else { return nil }
                defer { free(path) }
                return String(cString: path)
            })
            let root = URL(fileURLWithPath: resolved, isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
            let namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32))
            var associations: [VerifiedGitBlobCodeMapLocatorAssociation] = []
            for index in 1 ... count {
                let identity = try GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: namespace, objectFormat: .sha1,
                    blobOID: String(format: "%040x", index), pipelineIdentity: pipeline
                )
                try await associations.append(makeAssociation(root: root, identity: identity, digestByte: 1))
            }
            return Fixture(root: root, associations: associations)
        }

        private func makeAssociation(
            root: URL, identity: GitBlobCodeMapLocatorIdentity, digestByte: UInt8
        ) async throws -> VerifiedGitBlobCodeMapLocatorAssociation {
            let key = CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: digestByte, count: 32)),
                rawByteCount: 1, pipelineIdentity: identity.pipelineIdentity
            )
            let artifacts = try CodeMapArtifactStore(rootURL: root)
            _ = try await artifacts.insert(key: key, deterministicOutcome: .readyNoSymbols)
            guard case let .hit(_, handle) = try await artifacts.lookup(key: key) else {
                throw CodeMapArtifactFileStoreError.integrityCollision
            }
            return try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: identity, artifactKey: key, casHandle: handle
            )
        }

        private func overwriteInPlacePreservingModificationDate(_ url: URL, with data: Data) throws {
            let oldBytes = try Data(contentsOf: url)
            XCTAssertEqual(data.count, oldBytes.count)
            let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: data)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
#endif
