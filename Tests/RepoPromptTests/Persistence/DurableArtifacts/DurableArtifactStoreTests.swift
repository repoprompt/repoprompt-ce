import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class DurableArtifactStoreTests: XCTestCase {
    func testStreamingPublicationHasNoEntryCountCapAndValidatesAuthenticatedExactEOF() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let identity = Data("many-records".utf8)
        let result = try store.publishObject(
            family: DurableArtifactTestSupport.family,
            schemaVersion: 7,
            canonicalIdentity: identity,
            admittedByteUpperBound: 2 * 1024 * 1024
        ) { writer in
            for index in 0 ..< 20001 {
                try writer.appendRecord(Data(String(format: "%08d", index).utf8))
            }
        }
        guard case let .published(id, byteCount) = result else {
            return XCTFail("Expected publication, got \(result)")
        }
        XCTAssertGreaterThan(byteCount, 20001 * 8)
        let expectation = DurableArtifactObjectExpectation(id: id, schemaVersion: 7, canonicalIdentity: identity)
        guard case let .available(lease) = try store.openObject(expectation) else {
            return XCTFail("Expected verified lease")
        }
        var count: UInt64 = 0
        try lease.forEachRecord { _ in count += 1 }
        XCTAssertEqual(count, 20001)
        lease.close()

        let handle = try FileHandle(forWritingTo: DurableArtifactTestSupport.objectURL(store: store, id: id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        guard case .corruptQuarantined = try store.openObject(expectation) else {
            return XCTFail("Trailing bytes must quarantine the object")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: DurableArtifactTestSupport.objectURL(store: store, id: id).path
            )
        )
    }

    func testUnsortedAndDuplicateRecordsFailWithoutLeavingTrustedOrWorkFiles() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        for records in [["b", "a"], ["a", "a"]] {
            XCTAssertThrowsError(try store.publishObject(
                family: DurableArtifactTestSupport.family,
                schemaVersion: 1,
                canonicalIdentity: Data("bad-order".utf8),
                admittedByteUpperBound: 4096
            ) { writer in
                for record in records {
                    try writer.appendRecord(Data(record.utf8))
                }
            }) { error in
                XCTAssertEqual(error as? DurableArtifactStoreError, .unsortedRecords)
            }
        }
        let work = store.rootURL.appendingPathComponent("v1/work")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testSecurityRejectsModeHardlinkSymlinkAndRootReplacement() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let id = try DurableArtifactTestSupport.publish(store)
        let object = DurableArtifactTestSupport.objectURL(store: store, id: id)
        let expectation = DurableArtifactTestSupport.expectation(id: id)

        XCTAssertEqual(chmod(object.path, 0o644), 0)
        XCTAssertThrowsError(try store.openObject(expectation))
        XCTAssertEqual(chmod(object.path, 0o600), 0)

        let hardlink = object.deletingLastPathComponent().appendingPathComponent("hardlink")
        XCTAssertEqual(link(object.path, hardlink.path), 0)
        XCTAssertThrowsError(try store.openObject(expectation))
        XCTAssertEqual(unlink(hardlink.path), 0)

        let displaced = object.deletingLastPathComponent().appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: object, to: displaced)
        XCTAssertEqual(symlink(displaced.lastPathComponent, object.path), 0)
        XCTAssertThrowsError(try store.openObject(expectation))
        XCTAssertEqual(unlink(object.path), 0)
        try FileManager.default.moveItem(at: displaced, to: object)

        let durableRoot = store.rootURL
        let movedRoot = durableRoot.deletingLastPathComponent().appendingPathComponent("moved-root")
        try FileManager.default.moveItem(at: durableRoot, to: movedRoot)
        try FileManager.default.createDirectory(at: durableRoot, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(durableRoot.path, 0o700), 0)
        XCTAssertThrowsError(try store.openObject(expectation))
    }

    func testValidatedDescriptorPublicationIgnoresTemporaryPathReplacement() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(
            "WorkspaceDurableArtifacts-tests/v1/work",
            isDirectory: true
        )
        let store = try DurableArtifactTestSupport.makeStore(at: root, crashAction: { point in
            guard point == .beforeObjectInstall else { return }
            let name = try FileManager.default.contentsOfDirectory(atPath: work.path)
                .first { $0.hasPrefix(".tmp.") }!
            let original = work.appendingPathComponent(name)
            try FileManager.default.moveItem(
                at: original,
                to: work.appendingPathComponent("displaced.validated")
            )
            guard FileManager.default.createFile(
                atPath: original.path,
                contents: Data("attacker".utf8)
            ) else { throw CocoaError(.fileWriteUnknown) }
            guard chmod(original.path, 0o600) == 0 else {
                throw DurableArtifactStoreError.ioFailure(operation: "attacker-mode", code: errno)
            }
        })
        let id = try DurableArtifactTestSupport.publish(
            store,
            identity: "descriptor-source",
            records: ["a", "b"]
        )
        let lease = try requireLease(store, id: id, identity: "descriptor-source")
        var records = [String]()
        try lease.forEachRecord { records.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(records, ["a", "b"])
        lease.close()
    }

    func testFailedObjectPostCheckRestoresValidatedDescriptorAndFailsClosed() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let oracleRoot = try DurableArtifactTestSupport.makeApplicationSupport()
        let oracle = try DurableArtifactTestSupport.makeStore(at: oracleRoot)
        let id = try DurableArtifactTestSupport.publish(oracle, identity: "post-check", records: ["a"])
        try FileManager.default.removeItem(at: oracleRoot)

        let attacker = Data("attacker bytes".utf8)
        let object = root.appendingPathComponent(
            "WorkspaceDurableArtifacts-tests/v1/objects/\(id.family.rawValue)/\(id.digest.hex.prefix(2))/\(id.digest.hex)"
        )
        let store = try DurableArtifactTestSupport.makeStore(at: root, crashAction: { point in
            guard point == .afterObjectInstallBeforeValidation else { return }
            try FileManager.default.moveItem(
                at: object,
                to: object.deletingLastPathComponent().appendingPathComponent("displaced-object")
            )
            guard FileManager.default.createFile(atPath: object.path, contents: attacker) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard chmod(object.path, 0o600) == 0 else {
                throw DurableArtifactStoreError.ioFailure(operation: "attacker-mode", code: errno)
            }
        })
        XCTAssertThrowsError(try DurableArtifactTestSupport.publish(
            store,
            identity: "post-check",
            records: ["a"]
        ))
        XCTAssertNotEqual(try Data(contentsOf: object), attacker)
        let peer = try DurableArtifactTestSupport.makeStore(at: root)
        guard case .familyDisabled = try peer.openObject(
            DurableArtifactTestSupport.expectation(id: id, identity: "post-check")
        ) else { return XCTFail("Peer must observe the durable family-disable marker") }
    }

    func testCollisionDisableMarkerSurvivesSubprocessCrashBeforeQuarantineAndPeersFailClosed() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "collision-crash" else { return XCTFail("Unexpected worker action") }
            let store = try DurableArtifactTestSupport.makeStore(
                at: worker.root,
                crashExitPoint: .afterFamilyDisableSync,
                forcedDigestByte: 0x44
            )
            _ = try DurableArtifactTestSupport.publish(store, identity: "second", records: ["b"])
            return XCTFail("Collision disable crash point was not reached")
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DurableArtifactTestSupport.makeStore(at: root, forcedDigestByte: 0x44)
        _ = try DurableArtifactTestSupport.publish(first, identity: "first", records: ["a"])
        let child = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "collision-crash",
            root: root
        )
        try DurableArtifactSubprocess.wait(child, expectedStatus: 86)

        let peer = try DurableArtifactTestSupport.makeStore(at: root, forcedDigestByte: 0x44)
        XCTAssertEqual(
            try peer.publishObject(
                family: DurableArtifactTestSupport.family,
                schemaVersion: 1,
                canonicalIdentity: Data("peer".utf8),
                admittedByteUpperBound: 4096
            ) { try $0.appendRecord(Data("c".utf8)) },
            .familyDisabled
        )
        let marker = peer.rootURL.appendingPathComponent(
            "v1/disabled/\(DurableArtifactTestSupport.family.rawValue).disabled"
        )
        var status = stat()
        XCTAssertEqual(lstat(marker.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testConcurrentSubprocessPublishersReturnOnePublishedOneCoalescedAndPreserveInode() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard ["publish-leader", "publish-contender", "publish-existing"].contains(worker.action) else {
                return XCTFail("Unexpected publisher worker")
            }
            let store: LocalDurableArtifactStore = if worker.action == "publish-leader" {
                try DurableArtifactTestSupport.makeStore(
                    at: worker.root,
                    crashAction: { point in
                        guard point == .beforeObjectInstall else { return }
                        try DurableArtifactSubprocess.signal(worker.ready)
                        try DurableArtifactSubprocess.waitForSignal(worker.release)
                    }
                )
            } else {
                try DurableArtifactTestSupport.makeStore(at: worker.root)
            }
            if worker.action == "publish-contender" {
                let firstAttempt = try store.publishObject(
                    family: DurableArtifactTestSupport.family,
                    schemaVersion: 1,
                    canonicalIdentity: Data("publisher-race".utf8),
                    admittedByteUpperBound: 4096
                ) { try $0.appendRecord(Data("same".utf8)) }
                guard firstAttempt == .busy else {
                    return XCTFail("Contender must overlap the checked install window: \(firstAttempt)")
                }
                try DurableArtifactSubprocess.signal(worker.ready)
                try DurableArtifactSubprocess.waitForSignal(worker.release)
            }
            let result = try store.publishObject(
                family: DurableArtifactTestSupport.family,
                schemaVersion: 1,
                canonicalIdentity: Data("publisher-race".utf8),
                admittedByteUpperBound: 4096
            ) { try $0.appendRecord(Data("same".utf8)) }
            let id: DurableArtifactObjectID
            let outcome: String
            let byteCount: UInt64
            switch result {
            case let .published(value, bytes):
                guard worker.action == "publish-leader" else {
                    return XCTFail("Only the gated leader may publish")
                }
                id = value
                byteCount = bytes
                outcome = "published"
            case let .coalesced(value, bytes):
                guard worker.action != "publish-leader" else {
                    return XCTFail("Gated leader must publish")
                }
                id = value
                byteCount = bytes
                outcome = "coalesced"
            default:
                return XCTFail("Unexpected publication result: \(result)")
            }
            let object = DurableArtifactTestSupport.objectURL(store: store, id: id)
            var status = stat()
            XCTAssertEqual(lstat(object.path, &status), 0)
            try DurableArtifactSubprocess.writeResult(
                "\(outcome):\(id.digest.hex):\(byteCount):\(status.st_dev):\(status.st_ino)",
                to: worker.result
            )
            return
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try DurableArtifactTestSupport.makeStore(at: root)
        let leaderReady = root.appendingPathComponent(".publish-leader-ready")
        let leaderRelease = root.appendingPathComponent(".publish-leader-release")
        let leaderResult = root.appendingPathComponent(".publish-leader-result")
        let leader = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "publish-leader",
            root: root,
            ready: leaderReady,
            release: leaderRelease,
            result: leaderResult
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(leader, release: leaderRelease) }
        try DurableArtifactSubprocess.waitForSignal(leaderReady)

        let contenderReady = root.appendingPathComponent(".publish-contender-ready")
        let contenderRelease = root.appendingPathComponent(".publish-contender-release")
        let contenderResult = root.appendingPathComponent(".publish-contender-result")
        let contender = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "publish-contender",
            root: root,
            ready: contenderReady,
            release: contenderRelease,
            result: contenderResult
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(contender, release: contenderRelease) }
        try DurableArtifactSubprocess.waitForSignal(contenderReady)
        try DurableArtifactSubprocess.signal(leaderRelease)
        try DurableArtifactSubprocess.wait(leader)
        try DurableArtifactSubprocess.signal(contenderRelease)
        try DurableArtifactSubprocess.wait(contender)

        let published = try DurableArtifactSubprocess.readResult(leaderResult).split(separator: ":")
        let coalesced = try DurableArtifactSubprocess.readResult(contenderResult).split(separator: ":")
        XCTAssertEqual(published.count, 5)
        XCTAssertEqual(coalesced.count, 5)
        XCTAssertEqual(published[0], "published")
        XCTAssertEqual(coalesced[0], "coalesced")
        XCTAssertEqual(Array(published.dropFirst()), Array(coalesced.dropFirst()))
        let digestHex = String(published[1])
        let id = try DurableArtifactObjectID(
            family: DurableArtifactTestSupport.family,
            digest: DurableArtifactDigest(hex: digestHex)
        )
        let object = DurableArtifactTestSupport.objectURL(store: base, id: id)
        var before = stat()
        XCTAssertEqual(lstat(object.path, &before), 0)
        XCTAssertEqual(String(before.st_dev), String(published[3]))
        XCTAssertEqual(String(before.st_ino), String(published[4]))
        let lease = try requireLease(base, id: id, identity: "publisher-race")
        var records = [String]()
        try lease.forEachRecord { records.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(records, ["same"])
        lease.close()

        let result = root.appendingPathComponent(".publish-existing-result")
        let existing = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "publish-existing",
            root: root,
            result: result
        )
        try DurableArtifactSubprocess.wait(existing)
        let existingOutcome = try DurableArtifactSubprocess.readResult(result).split(separator: ":")
        XCTAssertEqual(existingOutcome[0], "coalesced")
        XCTAssertEqual(Array(existingOutcome.dropFirst()), Array(published.dropFirst()))
        var after = stat()
        XCTAssertEqual(lstat(object.path, &after), 0)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
    }

    func testCatalogPublicationUsesValidatedDescriptorAndRestoresPriorPointerAfterPathSwap() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try DurableArtifactTestSupport.makeStore(at: root)
        let old = try DurableArtifactTestSupport.publish(base, identity: "old", records: ["a"])
        let new = try DurableArtifactTestSupport.publish(base, identity: "new", records: ["b"])
        guard case let .published(pointer) = try base.compareAndSwapCatalog(
            family: DurableArtifactTestSupport.family,
            expectedRevision: nil,
            target: old,
            admittedByteUpperBound: 4096
        ) else { return XCTFail("Expected initial catalog") }
        let catalog = base.rootURL.appendingPathComponent(
            "v1/catalogs/\(DurableArtifactTestSupport.family.rawValue).catalog"
        )
        let originalBytes = try Data(contentsOf: catalog)
        let attacker = Data("attacker catalog".utf8)
        let attacking = try DurableArtifactTestSupport.makeStore(at: root, crashAction: { point in
            guard point == .afterCatalogInstallBeforeValidation else { return }
            try FileManager.default.moveItem(
                at: catalog,
                to: catalog.deletingLastPathComponent().appendingPathComponent("displaced-new-catalog")
            )
            guard FileManager.default.createFile(atPath: catalog.path, contents: attacker) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard chmod(catalog.path, 0o600) == 0 else {
                throw DurableArtifactStoreError.ioFailure(operation: "catalog-attacker-mode", code: errno)
            }
        })
        XCTAssertThrowsError(try attacking.compareAndSwapCatalog(
            family: DurableArtifactTestSupport.family,
            expectedRevision: pointer.revision,
            target: new,
            admittedByteUpperBound: 4096
        ))
        XCTAssertEqual(try Data(contentsOf: catalog), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: catalog), attacker)
        XCTAssertEqual(try DurableArtifactTestSupport.makeStore(at: root).loadCatalog(
            for: DurableArtifactTestSupport.family
        ), .familyDisabled)
    }

    func testQuotaAndMinimumDiskReserveRefusePersistenceWithoutCreatingObjects() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let quotaStore = try LocalDurableArtifactStore(
            applicationSupportURL: root,
            buildFlavor: "quota-tests",
            diskPolicy: DurableArtifactDiskPolicy(quotaBytes: 0, minimumFreeReserveBytes: 0)
        )
        let quota = try quotaStore.publishObject(
            family: DurableArtifactTestSupport.family,
            schemaVersion: 1,
            canonicalIdentity: Data(),
            admittedByteUpperBound: 1024
        ) { _ in }
        XCTAssertEqual(quota, .notAdmitted(.quota))

        let reserveStore = try LocalDurableArtifactStore(
            applicationSupportURL: root,
            buildFlavor: "reserve-tests",
            diskPolicy: DurableArtifactDiskPolicy(
                quotaBytes: UInt64.max,
                minimumFreeReserveBytes: UInt64.max
            )
        )
        let reserve = try reserveStore.publishObject(
            family: DurableArtifactTestSupport.family,
            schemaVersion: 1,
            canonicalIdentity: Data(),
            admittedByteUpperBound: 1024
        ) { _ in }
        XCTAssertEqual(reserve, .notAdmitted(.minimumFreeReserve))
    }
}
