import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class DurableArtifactCrashAndCatalogTests: XCTestCase {
    func testSubprocessCrashDuringObjectPublicationLeavesOnlyMissingOrAuthenticatedCompleteObject() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "object-crash", let rawPoint = worker.parameter else {
                return XCTFail("Unexpected worker action")
            }
            let point = try crashPoint(rawPoint)
            let store = try DurableArtifactTestSupport.makeStore(at: worker.root, crashExitPoint: point)
            _ = try DurableArtifactTestSupport.publish(
                store,
                identity: "crash-\(rawPoint)",
                records: ["a", "b"]
            )
            return XCTFail("Crash point was not reached")
        }

        let points: [(DurableArtifactCrashPoint, Bool)] = [
            (.afterObjectTemporaryWrite, false),
            (.afterObjectFileSync, false),
            (.beforeObjectInstall, false),
            (.afterObjectInstallBeforeValidation, true),
            (.afterObjectRename, true),
            (.afterObjectDirectorySync, true)
        ]
        for (point, expectsObject) in points {
            let root = try DurableArtifactTestSupport.makeApplicationSupport()
            defer { try? FileManager.default.removeItem(at: root) }
            let identity = "crash-\(String(describing: point))"

            let oracleRoot = try DurableArtifactTestSupport.makeApplicationSupport()
            let oracle = try DurableArtifactTestSupport.makeStore(at: oracleRoot)
            let expectedID = try DurableArtifactTestSupport.publish(
                oracle,
                identity: identity,
                records: ["a", "b"]
            )
            try FileManager.default.removeItem(at: oracleRoot)

            let child = try DurableArtifactSubprocess.spawn(
                testCase: Self.self,
                testName: #function,
                action: "object-crash",
                root: root,
                parameter: String(describing: point)
            )
            try DurableArtifactSubprocess.wait(child, expectedStatus: 86)

            let restarted = try DurableArtifactTestSupport.makeStore(at: root)
            let state = try restarted.openObject(
                DurableArtifactTestSupport.expectation(id: expectedID, identity: identity)
            )
            if expectsObject {
                guard case let .available(lease) = state else {
                    return XCTFail("\(point) must leave an authenticated complete object")
                }
                var records = [String]()
                try lease.forEachRecord { records.append(String(decoding: $0, as: UTF8.self)) }
                XCTAssertEqual(records, ["a", "b"])
                lease.close()
            } else {
                guard case .missing = state else {
                    return XCTFail("\(point) must not expose a partially published object")
                }
            }
        }
    }

    func testCatalogPredecessorCASRequiresCurrentRevisionAndRecordsPredecessor() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let first = try DurableArtifactTestSupport.publish(store, identity: "catalog-a", records: ["a"])
        let second = try DurableArtifactTestSupport.publish(store, identity: "catalog-b", records: ["b"])
        XCTAssertNotEqual(first, second)
        guard case let .published(initial) = try catalogCASWithBusyRetry({
            try store.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: nil,
                target: first,
                admittedByteUpperBound: 4096
            )
        }) else { return XCTFail("Expected initial catalog") }
        XCTAssertEqual(
            try store.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: nil,
                target: second,
                admittedByteUpperBound: 4096
            ),
            .conflict(currentRevision: initial.revision)
        )
        let replacement = try catalogCASWithBusyRetry {
            try store.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: initial.revision,
                target: second,
                admittedByteUpperBound: 4096
            )
        }
        guard case let .published(replaced) = replacement else {
            return XCTFail("Expected replacement catalog, got \(replacement)")
        }
        XCTAssertEqual(replaced.predecessorRevision, initial.revision)
        XCTAssertEqual(try store.loadCatalog(for: DurableArtifactTestSupport.family), .available(replaced))
    }

    func testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "catalog-cas-leader" || worker.action == "catalog-cas-contender",
                  let parts = worker.parameter?.split(separator: "|"),
                  parts.count == 2
            else { return XCTFail("Invalid catalog worker") }
            let expected = try DurableArtifactDigest(hex: String(parts[0]))
            let target = try DurableArtifactObjectID(
                family: DurableArtifactTestSupport.family,
                digest: DurableArtifactDigest(hex: String(parts[1]))
            )
            if worker.action == "catalog-cas-leader" {
                let store = try DurableArtifactTestSupport.makeStore(
                    at: worker.root,
                    crashAction: { point in
                        guard point == .beforeCatalogInstall else { return }
                        try DurableArtifactSubprocess.signal(worker.ready)
                        try DurableArtifactSubprocess.waitForSignal(worker.release)
                    }
                )
                let result = try store.compareAndSwapCatalog(
                    family: DurableArtifactTestSupport.family,
                    expectedRevision: expected,
                    target: target,
                    admittedByteUpperBound: 4096
                )
                guard case let .published(pointer) = result else {
                    return XCTFail("Gated catalog publisher must win: \(result)")
                }
                try DurableArtifactSubprocess.writeResult(
                    "published:\(pointer.revision.hex):\(pointer.predecessorRevision?.hex ?? "nil")",
                    to: worker.result
                )
            } else {
                let store = try DurableArtifactTestSupport.makeStore(at: worker.root)
                let firstAttempt = try store.compareAndSwapCatalog(
                    family: DurableArtifactTestSupport.family,
                    expectedRevision: expected,
                    target: target,
                    admittedByteUpperBound: 4096
                )
                guard firstAttempt == .busy else {
                    return XCTFail("Contender must overlap the checked CAS window: \(firstAttempt)")
                }
                try DurableArtifactSubprocess.signal(worker.ready)
                try DurableArtifactSubprocess.waitForSignal(worker.release)
                let secondAttempt = try store.compareAndSwapCatalog(
                    family: DurableArtifactTestSupport.family,
                    expectedRevision: expected,
                    target: target,
                    admittedByteUpperBound: 4096
                )
                guard case let .conflict(current) = secondAttempt, let current else {
                    return XCTFail("Contender must observe the committed winner: \(secondAttempt)")
                }
                try DurableArtifactSubprocess.writeResult("conflict:\(current.hex)", to: worker.result)
            }
            return
        }

        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DurableArtifactTestSupport.makeStore(at: root)
        let first = try DurableArtifactTestSupport.publish(store, identity: "catalog-base", records: ["a"])
        let second = try DurableArtifactTestSupport.publish(store, identity: "catalog-left", records: ["b"])
        let third = try DurableArtifactTestSupport.publish(store, identity: "catalog-right", records: ["c"])
        guard case let .published(initial) = try store.compareAndSwapCatalog(
            family: DurableArtifactTestSupport.family,
            expectedRevision: nil,
            target: first,
            admittedByteUpperBound: 4096
        ) else { return XCTFail("Expected initial catalog") }

        let leaderReady = root.appendingPathComponent(".cas-leader-ready")
        let leaderRelease = root.appendingPathComponent(".cas-leader-release")
        let leaderResult = root.appendingPathComponent(".cas-leader-result")
        let leader = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "catalog-cas-leader",
            root: root,
            ready: leaderReady,
            release: leaderRelease,
            result: leaderResult,
            parameter: "\(initial.revision.hex)|\(second.digest.hex)"
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(leader, release: leaderRelease) }
        try DurableArtifactSubprocess.waitForSignal(leaderReady)

        let contenderReady = root.appendingPathComponent(".cas-contender-ready")
        let contenderRelease = root.appendingPathComponent(".cas-contender-release")
        let contenderResult = root.appendingPathComponent(".cas-contender-result")
        let contender = try DurableArtifactSubprocess.spawn(
            testCase: Self.self,
            testName: #function,
            action: "catalog-cas-contender",
            root: root,
            ready: contenderReady,
            release: contenderRelease,
            result: contenderResult,
            parameter: "\(initial.revision.hex)|\(third.digest.hex)"
        )
        defer { DurableArtifactSubprocess.releaseAndTerminateIfRunning(contender, release: contenderRelease) }
        try DurableArtifactSubprocess.waitForSignal(contenderReady)
        try DurableArtifactSubprocess.signal(leaderRelease)
        try DurableArtifactSubprocess.wait(leader)
        try DurableArtifactSubprocess.signal(contenderRelease)
        try DurableArtifactSubprocess.wait(contender)

        let published = try DurableArtifactSubprocess.readResult(leaderResult).split(separator: ":")
        let conflict = try DurableArtifactSubprocess.readResult(contenderResult).split(separator: ":")
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published[0], "published")
        XCTAssertEqual(published[2], Substring(initial.revision.hex))
        XCTAssertEqual(conflict.count, 2)
        XCTAssertEqual(conflict[0], "conflict")
        XCTAssertEqual(conflict[1], published[1])
        guard case let .available(pointer) = try store.loadCatalog(for: DurableArtifactTestSupport.family) else {
            return XCTFail("Winner must leave a complete catalog")
        }
        XCTAssertEqual(pointer.target, second)
        XCTAssertEqual(pointer.revision.hex, String(published[1]))
        XCTAssertEqual(pointer.predecessorRevision, initial.revision)
    }

    func testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer() throws {
        if let worker = DurableArtifactSubprocess.context {
            guard worker.action == "catalog-crash",
                  let parts = worker.parameter?.split(separator: "|"),
                  parts.count == 3
            else { return XCTFail("Invalid catalog crash worker") }
            let point = try crashPoint(String(parts[0]))
            let expected = try DurableArtifactDigest(hex: String(parts[1]))
            let target = try DurableArtifactObjectID(
                family: DurableArtifactTestSupport.family,
                digest: DurableArtifactDigest(hex: String(parts[2]))
            )
            let store = try DurableArtifactTestSupport.makeStore(at: worker.root, crashExitPoint: point)
            _ = try store.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: expected,
                target: target,
                admittedByteUpperBound: 4096
            )
            return XCTFail("Crash point was not reached")
        }

        let points: [(DurableArtifactCrashPoint, Bool)] = [
            (.afterCatalogFileSync, false),
            (.beforeCatalogInstall, false),
            (.afterCatalogInstallBeforeValidation, true),
            (.afterCatalogRename, true),
            (.afterCatalogDirectorySync, true)
        ]
        for (point, expectsNew) in points {
            let root = try DurableArtifactTestSupport.makeApplicationSupport()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try DurableArtifactTestSupport.makeStore(at: root)
            let old = try DurableArtifactTestSupport.publish(store, identity: "old", records: ["a"])
            let new = try DurableArtifactTestSupport.publish(store, identity: "new", records: ["b"])
            guard case let .published(initial) = try store.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: nil,
                target: old,
                admittedByteUpperBound: 4096
            ) else { return XCTFail("Expected initial catalog") }

            let child = try DurableArtifactSubprocess.spawn(
                testCase: Self.self,
                testName: #function,
                action: "catalog-crash",
                root: root,
                parameter: "\(String(describing: point))|\(initial.revision.hex)|\(new.digest.hex)"
            )
            try DurableArtifactSubprocess.wait(child, expectedStatus: 86)

            guard case let .available(pointer) = try DurableArtifactTestSupport.makeStore(at: root)
                .loadCatalog(for: DurableArtifactTestSupport.family)
            else { return XCTFail("Crash must preserve a complete old or new catalog") }
            XCTAssertEqual(pointer.target, expectsNew ? new : old)
            if expectsNew {
                XCTAssertEqual(pointer.predecessorRevision, initial.revision)
            } else {
                XCTAssertEqual(pointer.revision, initial.revision)
            }
        }
    }

    func testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath() throws {
        let root = try DurableArtifactTestSupport.makeApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try DurableArtifactTestSupport.makeStore(at: root)
        let object = try DurableArtifactTestSupport.publish(base)
        guard case let .published(pointer) = try base.compareAndSwapCatalog(
            family: DurableArtifactTestSupport.family,
            expectedRevision: nil,
            target: object,
            admittedByteUpperBound: 4096
        ) else { return XCTFail("Expected catalog") }
        let catalog = base.rootURL.appendingPathComponent(
            "v1/catalogs/\(DurableArtifactTestSupport.family.rawValue).catalog"
        )
        let replacement = Data("attacker replacement".utf8)
        let attacking = try DurableArtifactTestSupport.makeStore(at: root, crashAction: { point in
            guard point == .beforeIdentitySafeRemoval else { return }
            XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path))
            guard FileManager.default.createFile(atPath: catalog.path, contents: replacement) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard chmod(catalog.path, 0o600) == 0 else {
                throw DurableArtifactStoreError.ioFailure(operation: "replacement-mode", code: errno)
            }
        })
        XCTAssertEqual(
            try attacking.compareAndSwapCatalog(
                family: DurableArtifactTestSupport.family,
                expectedRevision: pointer.revision,
                target: nil,
                admittedByteUpperBound: 0
            ),
            .busy
        )
        XCTAssertEqual(try Data(contentsOf: catalog), replacement)
        var replacementStatus = stat()
        XCTAssertEqual(lstat(catalog.path, &replacementStatus), 0)
        XCTAssertEqual(replacementStatus.st_mode & 0o777, 0o600)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: catalog.deletingLastPathComponent().path)
                .contains(where: { $0.hasPrefix(".captured.") })
        )
    }

    func testTruncationMutationTrailingBytesAndCountOverflowAreQuarantined() throws {
        enum Mutation: CaseIterable {
            case truncate
            case mutate
            case trail
            case countOverflow
        }
        for mutation in Mutation.allCases {
            let root = try DurableArtifactTestSupport.makeApplicationSupport()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try DurableArtifactTestSupport.makeStore(at: root)
            let id = try DurableArtifactTestSupport.publish(store)
            let path = DurableArtifactTestSupport.objectURL(store: store, id: id).path
            let descriptor = open(path, O_RDWR | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            var status = stat()
            XCTAssertEqual(fstat(descriptor, &status), 0)
            switch mutation {
            case .truncate:
                XCTAssertEqual(ftruncate(descriptor, status.st_size - 1), 0)
            case .mutate:
                var byte: UInt8 = 0
                XCTAssertEqual(pwrite(descriptor, &byte, 1, 0), 1)
            case .trail:
                var byte: UInt8 = 0
                XCTAssertEqual(pwrite(descriptor, &byte, 1, status.st_size), 1)
            case .countOverflow:
                var bytes = [UInt8](repeating: 0xFF, count: 8)
                XCTAssertEqual(pwrite(descriptor, &bytes, bytes.count, status.st_size - 48), bytes.count)
            }
            XCTAssertEqual(fsync(descriptor), 0)
            Darwin.close(descriptor)
            guard case .corruptQuarantined = try store.openObject(
                DurableArtifactTestSupport.expectation(id: id)
            ) else { return XCTFail("\(mutation) should quarantine") }
        }
    }

    private func catalogCASWithBusyRetry(
        _ operation: () throws -> DurableArtifactCatalogCASResult
    ) throws -> DurableArtifactCatalogCASResult {
        let deadline = Date().addingTimeInterval(1)
        var result = try operation()
        while result == .busy, Date() < deadline {
            usleep(10000)
            result = try operation()
        }
        return result
    }

    private func crashPoint(_ value: String) throws -> DurableArtifactCrashPoint {
        guard let point = DurableArtifactCrashPoint.allCases.first(where: {
            String(describing: $0) == value
        }) else { throw DurableArtifactStoreError.invalidFraming }
        return point
    }
}
