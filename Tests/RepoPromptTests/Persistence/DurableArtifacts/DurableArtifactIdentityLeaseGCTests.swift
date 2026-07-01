import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class DurableArtifactIdentityLeaseGCTests: XCTestCase {
    func testSubprocessCrashDuringSaltPublicationRecoversOneCompleteStableSalt() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "salt-crash",
                  let parts = worker.parameter?.split(separator: "|"), parts.count == 2,
                  let seed = UInt8(parts[1], radix: 16),
                  let rawPoint = parts.first.map(String.init),
                  let point = DurableArtifactCrashPoint.allCases.first(where: {
                      String(describing: $0) == rawPoint
                  })
            else { return XCTFail("Invalid salt worker") }
            let store = try DurableArtifactTestSupport.makeStore(
                at: worker.root,
                crashExitPoint: point,
                randomBytes: { Data(repeating: seed, count: $0) }
            )
            _ = try store.repositoryNamespace(for: DurableArtifactCommonDirectoryIdentity(
                resolvedPathBytes: Data("/private/repository/.git".utf8),
                device: 1,
                inode: 2
            ))
            return XCTFail("Salt crash point was not reached")
        }

        for point in [DurableArtifactCrashPoint.afterSaltFileSync, .afterSaltRename] {
            let root = try DurableArtifactTestSupport.makeApplicationSupport()
            defer { try? FileManager.default.removeItem(at: root) }
            let child = try DurableArtifactSubprocess.spawn(
                testCase: Self.self,
                testName: #function,
                action: "salt-crash",
                root: root,
                parameter: "\(String(describing: point))|a1"
            )
            try DurableArtifactSubprocess.wait(child, expectedStatus: 86)

            let identity = DurableArtifactCommonDirectoryIdentity(
                resolvedPathBytes: Data("/private/repository/.git".utf8),
                device: 1,
                inode: 2
            )
            let restarted = try DurableArtifactTestSupport.makeStore(
                at: root,
                randomBytes: { Data(repeating: 0xB2, count: $0) }
            )
            let restartedNamespace = try restarted.repositoryNamespace(for: identity)
            let expectedSeed: UInt8 = point == .afterSaltRename ? 0xA1 : 0xB2
            let oracleRoot = try DurableArtifactTestSupport.makeApplicationSupport()
            let oracle = try DurableArtifactTestSupport.makeStore(
                at: oracleRoot,
                randomBytes: { Data(repeating: expectedSeed, count: $0) }
            )
            XCTAssertEqual(try oracle.repositoryNamespace(for: identity), restartedNamespace)
            try FileManager.default.removeItem(at: oracleRoot)
            let secondRestart = try DurableArtifactTestSupport.makeStore(
                at: root,
                randomBytes: { Data(repeating: 0xC3, count: $0) }
            )
            XCTAssertEqual(try secondRestart.repositoryNamespace(for: identity), restartedNamespace)
            let salt = restarted.rootURL.appendingPathComponent("installation.salt")
            XCTAssertEqual(try Data(contentsOf: salt), Data(repeating: expectedSeed, count: 32))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: restarted.rootURL.path).contains {
                $0.hasPrefix(".salt.tmp.")
            })
        }
    }

    func testInstallationSaltIsPrivateStableAndNamespacesBindFreshDirectoryIdentity() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DurableArtifactTestSupport.makeStore(
            at: root,
            randomBytes: { Data(repeating: 0xA1, count: $0) }
        )
        let identity = DurableArtifactCommonDirectoryIdentity(
            resolvedPathBytes: Data("/private/repository/.git".utf8),
            device: 41,
            inode: 97
        )
        let namespace = try first.repositoryNamespace(for: identity)
        let restarted = try DurableArtifactTestSupport.makeStore(
            at: root,
            randomBytes: { Data(repeating: 0xB2, count: $0) }
        )
        XCTAssertEqual(try restarted.repositoryNamespace(for: identity), namespace)
        XCTAssertNotEqual(
            try restarted.repositoryNamespace(for: DurableArtifactCommonDirectoryIdentity(
                resolvedPathBytes: identity.resolvedPathBytes,
                device: identity.device,
                inode: identity.inode + 1
            )),
            namespace
        )
        XCTAssertEqual(first.rootURL.lastPathComponent, "WorkspaceDurableArtifacts-tests")
        for directory in [first.rootURL, first.rootURL.appendingPathComponent("v1", isDirectory: true)] {
            var directoryStatus = stat()
            XCTAssertEqual(lstat(directory.path, &directoryStatus), 0)
            XCTAssertEqual(directoryStatus.st_uid, geteuid())
            XCTAssertEqual(directoryStatus.st_mode & 0o777, 0o700)
        }
        let salt = first.rootURL.appendingPathComponent("installation.salt")
        var status = stat()
        XCTAssertEqual(lstat(salt.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertEqual(status.st_size, 32)
        XCTAssertEqual(try Data(contentsOf: salt), Data(repeating: 0xA1, count: 32))

        let otherRoot = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let other = try LocalDurableArtifactStore(
            applicationSupportURL: otherRoot,
            buildFlavor: "tests",
            framingPolicy: .default,
            diskPolicy: .default,
            hooks: DurableArtifactStoreHooks(
                now: { 1 },
                randomBytes: { count in Data(repeating: 0xC3, count: count) },
                token: { UUID().uuidString.lowercased() },
                crash: { _ in },
                transformDigest: { $0 }
            )
        )
        XCTAssertNotEqual(try other.repositoryNamespace(for: identity), namespace)
    }

    func testConcurrentCloseDuringReadReleasesLeaseImmediatelyAfterReadCompletes() throws {
        final class ReadState: @unchecked Sendable {
            let lease: DurableArtifactReadLease
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var error: Error?

            init(lease: DurableArtifactReadLease) {
                self.lease = lease
            }
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let id = try DurableArtifactTestSupport.publish(store)
        let state = try ReadState(lease: requireLease(store, id: id))
        DispatchQueue.global().async {
            defer { state.finished.signal() }
            do {
                var first = true
                try state.lease.forEachRecord { _ in
                    if first {
                        first = false
                        state.entered.signal()
                        state.resume.wait()
                    }
                }
            } catch {
                state.lock.lock()
                state.error = error
                state.lock.unlock()
            }
        }
        XCTAssertEqual(state.entered.wait(timeout: .now() + 5), .success)
        state.lease.close()
        state.resume.signal()
        XCTAssertEqual(state.finished.wait(timeout: .now() + 5), .success)
        state.lock.lock()
        let readError = state.error
        state.lock.unlock()
        XCTAssertNil(readError)

        let lockParent = try XCTUnwrap(try store.objectLockDirectory(for: id, create: false))
        let exclusive = try DurableArtifactSecureIO.lockDescriptor(
            parent: lockParent,
            name: "\(id.digest.hex).lock",
            exclusive: true,
            nonBlocking: true
        )
        XCTAssertNotNil(exclusive)
        exclusive?.close()
    }

    func testStableLockBindingPublicationIsAtomicAcrossCrashAndConcurrentPublishers() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "lock-binding-crash" || worker.action == "lock-binding-publisher",
                  let lockName = worker.parameter
            else { return XCTFail("Invalid lock-binding worker") }
            let store = try DurableArtifactTestSupport.makeStore(at: worker.root)
            let descriptor = try DurableArtifactSecureIO.openOrCreateFile(
                parent: store.layout.catalogLocks,
                name: lockName,
                beforeLockBindingPublish: {
                    if worker.action == "lock-binding-crash" { _exit(86) }
                    try DurableArtifactSubprocess.signal(worker.ready)
                    try DurableArtifactSubprocess.waitForSignal(worker.release)
                }
            )
            defer { descriptor.close() }
            let identity = try DurableArtifactSecureIO.identity(descriptor.rawValue)
            try DurableArtifactSubprocess.writeResult(
                "\(identity.device):\(identity.inode)",
                to: worker.result
            )
            return
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let lockName = "atomic-binding.lock"
        let lock = try DurableArtifactSecureIO.createExclusiveFile(
            parent: store.layout.catalogLocks,
            name: lockName
        )
        let lockIdentity = try DurableArtifactSecureIO.identity(lock.rawValue)
        lock.close()
        let lockDirectory = store.rootURL.appendingPathComponent("v1/locks/catalogs", isDirectory: true)

        let crashing = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "lock-binding-crash",
            root: root,
            parameter: lockName
        )
        try DurableArtifactSubprocess.wait(crashing, expectedStatus: 86)
        let afterCrash = try FileManager.default.contentsOfDirectory(atPath: lockDirectory.path)
        XCTAssertFalse(afterCrash.contains { $0.hasPrefix(".lock-binding.") && !$0.hasPrefix(".lock-binding.tmp.") })
        XCTAssertTrue(afterCrash.contains { $0.hasPrefix(".lock-binding.tmp.") })

        let release = root.appendingPathComponent(".binding-release")
        var workers = [(Process, URL, URL)]()
        for index in 0 ..< 2 {
            let ready = root.appendingPathComponent(".binding-ready-\(index)")
            let result = root.appendingPathComponent(".binding-result-\(index)")
            try workers.append((
                DurableArtifactSubprocess.spawn(
                    testCase: Self.self,
                    testName: #function,
                    action: "lock-binding-publisher",
                    root: root,
                    ready: ready,
                    release: release,
                    result: result,
                    parameter: lockName
                ),
                ready,
                result
            ))
        }
        defer {
            for worker in workers {
                DurableArtifactSubprocess.releaseAndTerminateIfRunning(worker.0, release: release)
            }
        }
        for worker in workers {
            try DurableArtifactSubprocess.waitForSignal(worker.1)
        }
        try DurableArtifactSubprocess.signal(release)
        for worker in workers {
            try DurableArtifactSubprocess.wait(worker.0)
        }
        let identities = try workers.map { try DurableArtifactSubprocess.readResult($0.2) }
        XCTAssertEqual(Set(identities), ["\(lockIdentity.device):\(lockIdentity.inode)"])

        let bindingNames = try FileManager.default.contentsOfDirectory(atPath: lockDirectory.path).filter {
            $0.hasPrefix(".lock-binding.") && !$0.hasPrefix(".lock-binding.tmp.")
        }
        XCTAssertEqual(bindingNames.count, 1)
        let binding = try Data(contentsOf: lockDirectory.appendingPathComponent(bindingNames[0]))
        var expected = DurableArtifactBinaryWriter()
        expected.append(Data("RPDLOCK1".utf8))
        expected.append(UInt64(bitPattern: Int64(lockIdentity.device)))
        expected.append(UInt64(lockIdentity.inode))
        XCTAssertEqual(binding, expected.data)
    }

    func testSubprocessReadLeaseBlocksGCAndProcessDeathReleasesObjectForCollection() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "hold-read-lease", let digest = worker.parameter else {
                return XCTFail("Invalid reader worker")
            }
            let store = try DurableArtifactTestSupport.makeStore(at: worker.root)
            let id = try DurableArtifactObjectID(
                family: DurableArtifactTestSupport.family,
                digest: DurableArtifactDigest(hex: digest)
            )
            let lease = try requireLease(store, id: id)
            try DurableArtifactSubprocess.signal(worker.ready)
            try DurableArtifactSubprocess.waitForSignal(worker.release, timeout: 60)
            lease.close()
            return
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let id = try DurableArtifactTestSupport.publish(store)
        let ready = root.appendingPathComponent(".reader-ready")
        let release = root.appendingPathComponent(".reader-release")
        let reader = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "hold-read-lease",
            root: root,
            ready: ready,
            release: release,
            parameter: id.digest.hex
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(reader, release: release) }
        try DurableArtifactSubprocess.waitForSignal(ready)
        let blocked = try store.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(quotaBytes: 0, minimumOrphanAgeSeconds: 0)
        )
        XCTAssertEqual(blocked.busyObjectCount, 1)
        XCTAssertEqual(blocked.quarantinedObjectCount, 0)

        XCTAssertEqual(kill(reader.processIdentifier, SIGKILL), 0)
        try DurableArtifactSubprocess.wait(reader, expectedStatus: SIGKILL)
        let collected = try store.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(
                quotaBytes: 0,
                minimumOrphanAgeSeconds: 0,
                quarantineGraceSeconds: 0
            )
        )
        XCTAssertEqual(collected.quarantinedObjectCount, 1)
        XCTAssertEqual(collected.deletedQuarantineCount, 1)
    }

    func testReplacingLockPathCannotBypassLiveSubprocessReadLeaseOrEnableGC() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "hold-replaced-lock-lease", let digest = worker.parameter else {
                return XCTFail("Invalid replacement reader worker")
            }
            let store = try DurableArtifactTestSupport.makeStore(at: worker.root)
            let id = try DurableArtifactObjectID(
                family: DurableArtifactTestSupport.family,
                digest: DurableArtifactDigest(hex: digest)
            )
            let lease = try requireLease(store, id: id)
            try DurableArtifactSubprocess.signal(worker.ready)
            try DurableArtifactSubprocess.waitForSignal(worker.release)
            lease.close()
            return
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let id = try DurableArtifactTestSupport.publish(store)
        let ready = root.appendingPathComponent(".replacement-reader-ready")
        let release = root.appendingPathComponent(".replacement-reader-release")
        let reader = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "hold-replaced-lock-lease",
            root: root,
            ready: ready,
            release: release,
            parameter: id.digest.hex
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(reader, release: release) }
        try DurableArtifactSubprocess.waitForSignal(ready)

        let lock = store.rootURL
            .appendingPathComponent("v1/locks/objects")
            .appendingPathComponent(id.family.rawValue)
            .appendingPathComponent(String(id.digest.hex.prefix(2)))
            .appendingPathComponent("\(id.digest.hex).lock")
        let displaced = lock.deletingLastPathComponent().appendingPathComponent("displaced.lock")
        try FileManager.default.moveItem(at: lock, to: displaced)
        XCTAssertTrue(FileManager.default.createFile(atPath: lock.path, contents: Data()))
        XCTAssertEqual(chmod(lock.path, 0o600), 0)

        XCTAssertThrowsError(try store.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(quotaBytes: 0, minimumOrphanAgeSeconds: 0)
        )) { error in
            XCTAssertEqual(error as? DurableArtifactStoreError, .insecureEntry)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DurableArtifactTestSupport.objectURL(store: store, id: id).path
        ))
        try DurableArtifactSubprocess.signal(release)
        try DurableArtifactSubprocess.wait(reader)
    }

    func testCatalogMarksProtectObjectsAndMarkLossOnlyProducesCacheMiss() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let id = try DurableArtifactTestSupport.publish(store)
        guard case let .published(pointer) = try store.compareAndSwapCatalog(
            family: id.family,
            expectedRevision: nil,
            target: id,
            admittedByteUpperBound: 4096
        ) else { return XCTFail("Expected catalog pointer") }
        let retained = try store.garbageCollect(
            protecting: [],
            referenceEnumerator: DurableArtifactReferenceEnumerator { source in
                XCTAssertEqual(source, id)
                return []
            },
            policy: DurableArtifactGCPolicy(quotaBytes: 0, minimumOrphanAgeSeconds: 0)
        )
        XCTAssertEqual(retained.markedCount, 1)
        XCTAssertEqual(retained.quarantinedObjectCount, 0)

        XCTAssertEqual(
            try store.compareAndSwapCatalog(
                family: id.family,
                expectedRevision: pointer.revision,
                target: nil,
                admittedByteUpperBound: 0
            ),
            .deleted
        )
        let removed = try store.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(
                quotaBytes: 0,
                minimumOrphanAgeSeconds: 0,
                quarantineGraceSeconds: 0
            )
        )
        XCTAssertEqual(removed.quarantinedObjectCount, 1)
        guard case .missing = try store.openObject(DurableArtifactTestSupport.expectation(id: id)) else {
            return XCTFail("Mark loss may only produce a cache miss")
        }
    }

    func testObsoleteVersionDeletionStreamsSpilledCandidates() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "obsolete-rename-crash" else {
                return XCTFail("Invalid obsolete-version worker")
            }
            let store = try DurableArtifactTestSupport.makeStore(
                at: worker.root,
                crashExitPoint: .afterObsoleteVersionRename
            )
            _ = try store.deleteObsoleteVersions()
            return XCTFail("Obsolete rename crash point was not reached")
        }

        let crashRoot = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: crashRoot) }
        let crashStore = try DurableArtifactTestSupport.makeStore(at: crashRoot)
        let crashVersion = crashStore.rootURL.appendingPathComponent("v2", isDirectory: true)
        try FileManager.default.createDirectory(at: crashVersion, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(crashVersion.path, 0o700), 0)
        let child = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "obsolete-rename-crash",
            root: crashRoot
        )
        try DurableArtifactSubprocess.wait(child, expectedStatus: 86)
        let afterCrashNames = try FileManager.default.contentsOfDirectory(atPath: crashStore.rootURL.path)
        XCTAssertFalse(afterCrashNames.contains("v2"))
        XCTAssertEqual(afterCrashNames.count(where: { $0.hasPrefix(".obsolete.v2.") }), 1)
        let resumed = try DurableArtifactTestSupport.makeStore(at: crashRoot).deleteObsoleteVersions()
        XCTAssertEqual(resumed.candidateCount, 1)
        XCTAssertEqual(resumed.renamedVersionCount, 0)
        XCTAssertEqual(resumed.deletedVersionCount, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: crashStore.rootURL.path).contains {
            $0 == "v2" || $0.hasPrefix(".obsolete.v2.")
        })

        let spillRoot = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: spillRoot) }
        let spillStore = try DurableArtifactTestSupport.makeStore(at: spillRoot)
        for version in 1000 ... 1511 {
            let directory = spillStore.rootURL.appendingPathComponent("v\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        let report = try DurableArtifactGarbageCollector(store: spillStore)
            .deleteObsoleteVersions(candidateMemoryByteBudget: 14)
        XCTAssertEqual(report.candidateCount, 512)
        XCTAssertEqual(report.renamedVersionCount, 512)
        XCTAssertEqual(report.deletedVersionCount, 512)
        XCTAssertEqual(report.unsafeVersionCount, 0)
        XCTAssertGreaterThan(report.candidateSpillRunCount, 1)
        XCTAssertLessThanOrEqual(report.peakResidentCandidateByteCount, 14)
        XCTAssertLessThanOrEqual(report.peakResidentCandidateCount, 2)
        XCTAssertLessThan(report.peakResidentCandidateCount, report.candidateCount)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: spillStore.rootURL.path).contains {
            $0.hasPrefix("v") && $0 != "v1"
        })
        let work = spillStore.rootURL.appendingPathComponent("v1/work", isDirectory: true)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: work.path).contains {
            $0.hasPrefix(".obsolete-list.")
        })
    }

    func testQuarantineGraceAbandonedWorkCleanupAndDirectOldVersionDeletion() throws {
        let now = UInt64(Date().timeIntervalSince1970)
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root, now: now)
        _ = try DurableArtifactTestSupport.publish(store)
        let firstGC = try store.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(
                quotaBytes: 0,
                minimumOrphanAgeSeconds: 0,
                quarantineGraceSeconds: 50
            )
        )
        XCTAssertEqual(firstGC.quarantinedObjectCount, 1)
        XCTAssertEqual(firstGC.deletedQuarantineCount, 0)
        let later = try DurableArtifactTestSupport.makeStore(at: root, now: now + 51)
        let secondGC = try later.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(quarantineGraceSeconds: 50, abandonedWorkAgeSeconds: 0)
        )
        XCTAssertEqual(secondGC.deletedQuarantineCount, 1)

        let workDirectory = later.rootURL.appendingPathComponent("v1/work", isDirectory: true)
        for name in [".tmp.abandoned", "manual.work", "manual.raw-spool"] {
            let url = workDirectory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("abandoned".utf8)))
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }
        let cleanup = try later.garbageCollect(
            protecting: [],
            referenceEnumerator: nil,
            policy: DurableArtifactGCPolicy(abandonedWorkAgeSeconds: 0)
        )
        XCTAssertEqual(cleanup.abandonedWorkRemovedCount, 3)

        let oldVersion = later.rootURL.appendingPathComponent("v0", isDirectory: true)
        try FileManager.default.createDirectory(at: oldVersion, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(oldVersion.path, 0o700), 0)
        let oldFile = oldVersion.appendingPathComponent("legacy")
        XCTAssertTrue(FileManager.default.createFile(atPath: oldFile.path, contents: Data("old".utf8)))
        XCTAssertEqual(chmod(oldFile.path, 0o600), 0)
        let deletion = try later.deleteObsoleteVersions()
        XCTAssertEqual(deletion.renamedVersionCount, 1)
        XCTAssertEqual(deletion.deletedVersionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldVersion.path))

        let unsafeVersion = later.rootURL.appendingPathComponent("v2", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeVersion, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(unsafeVersion.path, 0o700), 0)
        XCTAssertEqual(symlink("/tmp", unsafeVersion.appendingPathComponent("unsafe").path), 0)
        let unsafe = try later.deleteObsoleteVersions()
        XCTAssertEqual(unsafe.unsafeVersionCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: later.rootURL.path).contains {
            $0.hasPrefix(".obsolete.v2.")
        })
    }
}
