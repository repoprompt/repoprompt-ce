import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapArtifactStoreTests: XCTestCase {
    func testInsertLookupAndRestartClassifyMissMemoryDiskAndIdempotence() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("lookup lifecycle")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact(name: "Lookup"))
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)

        try await assertMiss(store, key: key)
        let inserted = try await store.insert(key: key, deterministicOutcome: outcome)
        XCTAssertEqual(inserted, .inserted)
        let first = try await requireHit(store, key: key, source: .memory)
        XCTAssertEqual(first.outcome, outcome)
        let alreadyPresent = try await store.insert(key: key, deterministicOutcome: outcome)
        XCTAssertEqual(alreadyPresent, .alreadyPresent)

        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let disk = try await requireHit(restarted, key: key, source: .disk)
        XCTAssertEqual(disk.outcome, outcome)
        _ = try await requireHit(restarted, key: key, source: .memory)
    }

    func testEveryDeterministicOutcomePersistsWithExactPositiveAndNegativeAccounting() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(1000)
        let outcomes: [CodeMapSyntaxArtifactOutcome] = [
            .ready(makeArtifact(name: "Ready")),
            .readyNoSymbols,
            .oversize(.utf8Bytes(actual: 2, limit: 1)),
            .oversize(.utf16Units(actual: 3, limit: 2)),
            .oversize(.lines(actual: 4, limit: 3)),
            .decodeFailed(.undecodable),
            .parseFailed(.parserReturnedNilTree),
            .parseFailed(.parserReturnedNilRoot)
        ]
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        for (index, outcome) in outcomes.enumerated() {
            let result = try await store.insert(key: makeKey("outcome-\(index)"), deterministicOutcome: outcome)
            XCTAssertEqual(result, .inserted)
        }
        let accounting = await store.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 1)
        XCTAssertEqual(accounting.liveNegativeCount, 7)
        XCTAssertGreaterThan(accounting.livePositiveBytes, 0)
        XCTAssertGreaterThan(accounting.liveNegativeBytes, 0)

        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(restarted)
        let restartedAccounting = await restarted.accounting()
        XCTAssertEqual(restartedAccounting.livePositiveCount, 1)

        XCTAssertEqual(restartedAccounting.livePositiveBytes, accounting.livePositiveBytes)
        XCTAssertEqual(restartedAccounting.liveNegativeCount, 7)
        XCTAssertEqual(restartedAccounting.liveNegativeBytes, accounting.liveNegativeBytes)
    }

    func testEncodingFailureCreatesNoArtifactCatalogOrLeaseEntry() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = makePolicy(
            containerPolicy: CodeMapArtifactContainerPolicy(
                maximumPayloadByteCount: 1,
                maximumContainerByteCount: 64 * 1024
            )
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: TestClock(100).storeClock)
        let key = try makeKey("encode failure")

        await XCTAssertThrowsErrorAsync {
            try await store.insert(key: key, deterministicOutcome: .readyNoSymbols)
        }
        let namespace = root.appendingPathComponent("CodeMapArtifacts/v1")
        XCTAssertEqual(try regularFiles(at: namespace.appendingPathComponent("artifacts")), [])
        XCTAssertEqual(try regularFiles(at: namespace.appendingPathComponent("catalog")), [])
        XCTAssertEqual(try regularFiles(at: namespace.appendingPathComponent("leases")), [])
    }

    func testInsertPublishesSinglePreparedContainerAtExactConfiguredSizeLimits() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("single-prepared-container")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact(name: "ExactLimit"))
        let encoded = try CodeMapArtifactContainer.encode(key: key, outcome: outcome)
        let headerOffset = CodeMapArtifactContainer.magic.count + 4
        let headerByteCount = encoded[headerOffset ..< headerOffset + 4].reduce(into: UInt32(0)) {
            $0 = ($0 << 8) | UInt32($1)
        }
        let preflight = try CodeMapArtifactContainer.preflightHeader(
            Data(encoded.prefix(Int(headerByteCount))),
            expectedKey: key,
            filenameDigest: key.storageDigestHex,
            totalFileByteCount: encoded.count
        )
        let policy = CodeMapArtifactContainerPolicy(
            maximumHeaderByteCount: preflight.headerByteCount,
            maximumPayloadByteCount: preflight.payloadByteCount,
            maximumContainerByteCount: encoded.count
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: makePolicy(containerPolicy: policy))

        let firstInsert = try await store.insert(key: key, deterministicOutcome: outcome)
        let secondInsert = try await store.insert(key: key, deterministicOutcome: outcome)
        XCTAssertEqual(firstInsert, .inserted)
        XCTAssertEqual(secondInsert, .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: artifactURL(root: root, key: key)), encoded)
    }

    func testResidentCacheEvictsDeterministicallyAndKeepsPositiveNegativeLimitsIndependent() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = makePolicy(
            residentPositiveEntryLimit: 1,
            residentPositiveByteLimit: .max,
            residentNegativeEntryLimit: 1,
            residentNegativeByteLimit: .max
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: TestClock(100).storeClock)
        let positiveA = try makeKey("positive-a")
        let positiveB = try makeKey("positive-b")
        let negativeA = try makeKey("negative-a")
        let negativeB = try makeKey("negative-b")
        _ = try await store.insert(key: positiveA, deterministicOutcome: .ready(makeArtifact(name: "A")))
        _ = try await store.insert(key: positiveB, deterministicOutcome: .ready(makeArtifact(name: "B")))
        _ = try await store.insert(key: negativeA, deterministicOutcome: .readyNoSymbols)
        _ = try await store.insert(key: negativeB, deterministicOutcome: .decodeFailed(.undecodable))

        let accounting = await store.accounting()
        XCTAssertEqual(accounting.residentPositiveCount, 1)
        XCTAssertEqual(accounting.residentNegativeCount, 1)
        _ = try await requireHit(store, key: positiveA, source: .disk)
        _ = try await requireHit(store, key: positiveA, source: .memory)
        _ = try await requireHit(store, key: positiveB, source: .disk)
        _ = try await requireHit(store, key: negativeA, source: .disk)
        _ = try await requireHit(store, key: negativeA, source: .memory)
        _ = try await requireHit(store, key: negativeB, source: .disk)
    }

    func testResidentHitsBufferAndFlushAccessMetadataDurablyAcrossRestart() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("durable touch")
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await store.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Touch")))
        clock.set(500)
        _ = try await requireHit(store, key: key, source: .memory)
        var accounting = await store.accounting()
        XCTAssertEqual(accounting.pendingAccessTouchCount, 1)
        try await store.flushAccessMetadata(stepBudget: 1)
        accounting = await store.accounting()
        XCTAssertEqual(accounting.pendingAccessTouchCount, 0)

        let catalogURL = metadataURL(root: root, key: key)
        let record = try CodeMapArtifactCatalog.decodeRecord(Data(contentsOf: catalogURL))
        XCTAssertEqual(record.lastAccessEpochSeconds, 500)
        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(restarted)
        let restartedAccounting = await restarted.accounting()
        XCTAssertEqual(restartedAccounting.livePositiveCount, 1)

        clock.set(600)
        _ = try await requireHit(store, key: key, source: .memory)
        let collector = try CodeMapArtifactStore(
            rootURL: root,
            policy: makePolicy(softQuotaBytes: 0, hardQuotaBytes: 1, unreferencedGraceSeconds: 0),
            clock: clock.storeClock
        )
        let collection = try await drainGC(collector, stepBudget: 2)
        XCTAssertEqual(collection.reduce(0) { $0 + $1.quarantinedCount }, 1)
        try await store.flushAccessMetadata(stepBudget: 1)
        try await assertMiss(CodeMapArtifactStore(rootURL: root, clock: clock.storeClock), key: key)
    }

    func testFailedTouchFlushStopsAfterOneConservativelyChargedAttempt() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("failed-touch-flush")
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await store.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Touch")))
        clock.set(200)
        _ = try await requireHit(store, key: key, source: .memory)

        let maximumMetadataBytes = 64 * 1024
        try Data(count: maximumMetadataBytes).write(to: metadataURL(root: root, key: key))
        XCTAssertEqual(chmod(metadataURL(root: root, key: key).path, 0o600), 0)

        let attemptedFlushCount = try await store.flushAccessMetadata(stepBudget: 4096)
        XCTAssertEqual(attemptedFlushCount, 1)
        var accounting = await store.accounting()
        XCTAssertEqual(accounting.pendingAccessTouchCount, 1)
        let progress = try await store.refreshAccounting(stepBudget: 4096)
        XCTAssertEqual(progress.readByteCount, UInt64(maximumMetadataBytes))
        XCTAssertEqual(progress.writtenByteCount, UInt64(maximumMetadataBytes))
        XCTAssertEqual(progress.continuation?.phase, .flushTouches)
        accounting = await store.accounting()
        XCTAssertEqual(accounting.pendingAccessTouchCount, 1)
    }

    func testLeaseSurvivesResidentEvictionAndBlocksCrossStoreGCUntilIdempotentClose() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let policy = makePolicy(
            residentPositiveEntryLimit: 0,
            residentPositiveByteLimit: 0,
            softQuotaBytes: 0,
            hardQuotaBytes: 1,
            unreferencedGraceSeconds: 0
        )
        let key = try makeKey("leased")
        let compensatingKey = try makeKey("lease-compensation")
        let owner = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock)
        _ = try await owner.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Lease")))
        _ = try await owner.insert(
            key: compensatingKey,
            deterministicOutcome: .ready(makeArtifact(name: "Compensating"))
        )
        let handle = try await requireHit(owner, key: key, source: .disk)
        let lease = try await owner.lease(handle: handle)
        var ownerAccounting = await owner.accounting()
        XCTAssertEqual(ownerAccounting.activeLeaseCount, 1)
        XCTAssertEqual(ownerAccounting.activeLeaseBytes, handle.containerByteCount)

        let collector = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock)
        let blocked = try await drainGC(collector, stepBudget: 8)
        XCTAssertEqual(blocked.reduce(0) { $0 + $1.leasedSkipCount }, 1)
        XCTAssertEqual(blocked.reduce(0) { $0 + $1.quarantinedCount }, 1)
        _ = try await requireHit(collector, key: key, source: .disk)
        try await assertMiss(
            CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock),
            key: compensatingKey
        )

        await lease.close()
        await lease.close()
        ownerAccounting = await owner.accounting()
        XCTAssertEqual(ownerAccounting.activeLeaseCount, 0)
        XCTAssertEqual(ownerAccounting.activeLeaseBytes, 0)
        let collected = try await drainGC(collector, stepBudget: 2)
        XCTAssertEqual(collected.reduce(0) { $0 + $1.quarantinedCount }, 1)
        try await assertMiss(CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock), key: key)
    }

    func testLeaseAdmissionRejectsForeignHandleBeforeOpeningDescriptor() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("foreign-lease-handle")
        let issuer = try CodeMapArtifactStore(rootURL: root)
        _ = try await issuer.insert(
            key: key,
            deterministicOutcome: .ready(makeArtifact(name: "Foreign"))
        )
        let foreignHandle = try await requireHit(issuer, key: key, source: .memory)
        try FileManager.default.removeItem(at: leaseURL(root: root, key: key))
        let receiver = try CodeMapArtifactStore(rootURL: root)
        let receiverHandle = try await requireHit(receiver, key: key, source: .disk)

        do {
            _ = try await receiver.lease(handle: foreignHandle)
            XCTFail("A foreign-store handle must not acquire a lease.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .foreignHandle)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL(root: root, key: key).path))
        var accounting = await receiver.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)

        let lease = try await receiver.lease(handle: receiverHandle)
        XCTAssertEqual(lease.handle.key, key)
        await lease.close()
        accounting = await receiver.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testLeaseAdmissionBoundsCountAndBytesBeforeDescriptorsAndRecovers() async throws {
        let countRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: countRoot) }
        let countPolicy = makePolicy(
            maximumActiveLeaseCount: 1,
            maximumActiveLeaseBytes: .max
        )
        let countAdmission = CodeMapArtifactLeaseAdmission(
            maximumCount: countPolicy.maximumActiveLeaseCount,
            maximumBytes: countPolicy.maximumActiveLeaseBytes
        )
        let countStore = try CodeMapArtifactStore(
            rootURL: countRoot,
            policy: countPolicy,
            leaseAdmission: countAdmission
        )
        let firstKey = try makeKey("lease-count-first")
        let secondKey = try makeKey("lease-count-second")
        _ = try await countStore.insert(
            key: firstKey,
            deterministicOutcome: .ready(makeArtifact(name: "First"))
        )
        _ = try await countStore.insert(
            key: secondKey,
            deterministicOutcome: .ready(makeArtifact(name: "Second"))
        )
        let firstHandle = try await requireHit(countStore, key: firstKey, source: .memory)
        let secondHandle = try await requireHit(countStore, key: secondKey, source: .memory)
        try FileManager.default.removeItem(at: leaseURL(root: countRoot, key: firstKey))
        try FileManager.default.removeItem(at: leaseURL(root: countRoot, key: secondKey))
        let firstLease = try await countStore.lease(handle: firstHandle)
        do {
            _ = try await countStore.lease(handle: secondHandle)
            XCTFail("The count bound must reject before opening a second descriptor.")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactLeaseError,
                .busy(.activeLeaseCountLimit)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL(root: countRoot, key: secondKey).path))
        var accounting = await countStore.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 1)
        XCTAssertEqual(accounting.activeLeaseBytes, firstHandle.containerByteCount)
        await firstLease.close()
        let recovered = try await countStore.lease(handle: secondHandle)
        await recovered.close()
        accounting = await countStore.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)

        let byteRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: byteRoot) }
        let byteKey = try makeKey("lease-byte-bound")
        let writer = try CodeMapArtifactStore(rootURL: byteRoot)
        _ = try await writer.insert(
            key: byteKey,
            deterministicOutcome: .ready(makeArtifact(name: "Bytes"))
        )
        let writerHandle = try await requireHit(writer, key: byteKey, source: .memory)
        XCTAssertGreaterThan(writerHandle.containerByteCount, 1)
        try FileManager.default.removeItem(at: leaseURL(root: byteRoot, key: byteKey))
        let limitedPolicy = makePolicy(
            maximumActiveLeaseCount: 2,
            maximumActiveLeaseBytes: writerHandle.containerByteCount - 1
        )
        let limited = try CodeMapArtifactStore(
            rootURL: byteRoot,
            policy: limitedPolicy,
            leaseAdmission: CodeMapArtifactLeaseAdmission(
                maximumCount: limitedPolicy.maximumActiveLeaseCount,
                maximumBytes: limitedPolicy.maximumActiveLeaseBytes
            )
        )
        let limitedHandle = try await requireHit(limited, key: byteKey, source: .disk)
        do {
            _ = try await limited.lease(handle: limitedHandle)
            XCTFail("The byte bound must reject before opening a descriptor.")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactLeaseError,
                .busy(.activeLeaseByteLimit)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL(root: byteRoot, key: byteKey).path))
        accounting = await limited.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)

        let exactPolicy = makePolicy(
            maximumActiveLeaseCount: 1,
            maximumActiveLeaseBytes: writerHandle.containerByteCount
        )
        let exact = try CodeMapArtifactStore(
            rootURL: byteRoot,
            policy: exactPolicy,
            leaseAdmission: CodeMapArtifactLeaseAdmission(
                maximumCount: exactPolicy.maximumActiveLeaseCount,
                maximumBytes: exactPolicy.maximumActiveLeaseBytes
            )
        )
        let exactHandle = try await requireHit(exact, key: byteKey, source: .disk)
        let exactLease = try await exact.lease(handle: exactHandle)
        var exactAccounting = await exact.accounting()
        XCTAssertEqual(exactAccounting.activeLeaseBytes, writerHandle.containerByteCount)
        await exactLease.close()
        exactAccounting = await exact.accounting()
        XCTAssertEqual(exactAccounting.activeLeaseBytes, 0)
    }

    func testLeaseAcquisitionRejectsLateGCAndCorruptionWithoutFakeLease() async throws {
        let collectedRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: collectedRoot) }
        let collectionPolicy = makePolicy(
            residentPositiveEntryLimit: 0,
            residentPositiveByteLimit: 0,
            softQuotaBytes: 0,
            hardQuotaBytes: 1,
            unreferencedGraceSeconds: 0
        )
        let collectedKey = try makeKey("lease-after-gc")
        let owner = try CodeMapArtifactStore(rootURL: collectedRoot, policy: collectionPolicy)
        _ = try await owner.insert(
            key: collectedKey,
            deterministicOutcome: .ready(makeArtifact(name: "Collected"))
        )
        let staleHandle = try await requireHit(owner, key: collectedKey, source: .disk)
        let collector = try CodeMapArtifactStore(rootURL: collectedRoot, policy: collectionPolicy)
        let collection = try await drainGC(collector, stepBudget: 2)
        XCTAssertEqual(collection.reduce(0) { $0 + $1.quarantinedCount }, 1)
        do {
            _ = try await owner.lease(handle: staleHandle)
            XCTFail("A handle whose payload was collected must not produce a lease.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .artifactMissing)
        }
        var accounting = await owner.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)

        let corruptRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptKey = try makeKey("lease-corruption")
        let corruptStore = try CodeMapArtifactStore(rootURL: corruptRoot)
        _ = try await corruptStore.insert(
            key: corruptKey,
            deterministicOutcome: .ready(makeArtifact(name: "Corrupt"))
        )
        let corruptHandle = try await requireHit(corruptStore, key: corruptKey, source: .memory)
        try Data("corrupt payload".utf8).write(to: artifactURL(root: corruptRoot, key: corruptKey))
        XCTAssertEqual(chmod(artifactURL(root: corruptRoot, key: corruptKey).path, 0o600), 0)
        do {
            _ = try await corruptStore.lease(handle: corruptHandle)
            XCTFail("A corrupt payload must not produce a lease.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .artifactCorrupt)
        }
        accounting = await corruptStore.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testLeaseAdmissionIsBoundedUnderHighConcurrencyCancellationAndRecovery() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = makePolicy(
            maximumActiveLeaseCount: 4,
            maximumActiveLeaseBytes: .max
        )
        let store = try CodeMapArtifactStore(
            rootURL: root,
            policy: policy,
            leaseAdmission: CodeMapArtifactLeaseAdmission(
                maximumCount: policy.maximumActiveLeaseCount,
                maximumBytes: policy.maximumActiveLeaseBytes
            )
        )
        let key = try makeKey("concurrent-lease-admission")
        _ = try await store.insert(
            key: key,
            deterministicOutcome: .ready(makeArtifact(name: "Concurrent"))
        )
        let handle = try await requireHit(store, key: key, source: .memory)

        let attempts = await withTaskGroup(
            of: CodeMapLeaseAttempt.self,
            returning: [CodeMapLeaseAttempt].self
        ) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    do {
                        return try await .acquired(store.lease(handle: handle))
                    } catch let error as CodeMapArtifactLeaseError {
                        return .rejected(error)
                    } catch {
                        return .unexpected
                    }
                }
            }
            var values: [CodeMapLeaseAttempt] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        let leases = attempts.compactMap { attempt -> CodeMapArtifactLease? in
            guard case let .acquired(lease) = attempt else { return nil }
            return lease
        }
        let rejections = attempts.compactMap { attempt -> CodeMapArtifactLeaseError? in
            guard case let .rejected(error) = attempt else { return nil }
            return error
        }
        XCTAssertEqual(leases.count, 4)
        XCTAssertEqual(rejections.count, 60)
        XCTAssertTrue(rejections.allSatisfy { $0 == .busy(.activeLeaseCountLimit) })
        XCTAssertFalse(attempts.contains { if case .unexpected = $0 { true } else { false } })
        var accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 4)
        XCTAssertEqual(accounting.activeLeaseBytes, handle.containerByteCount * 4)

        let cancelled = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await store.lease(handle: handle)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled request must not retain an admission reservation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 4)

        await withTaskGroup(of: Void.self) { group in
            for lease in leases {
                group.addTask { await lease.close() }
                group.addTask { await lease.close() }
            }
        }
        accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)

        var deinitLease: CodeMapArtifactLease? = try await store.lease(handle: handle)
        XCTAssertNotNil(deinitLease)
        accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 1)
        deinitLease = nil
        accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testProcessWideAndInjectedMultiStoreAdmissionAggregateFDsAndRecover() async throws {
        let productionRootA = try makeSecureRoot()
        let productionRootB = try makeSecureRoot()
        defer {
            try? FileManager.default.removeItem(at: productionRootA)
            try? FileManager.default.removeItem(at: productionRootB)
        }
        let productionAdmission = CodeMapArtifactLeaseAdmission(
            maximumCount: CodeMapArtifactStorePolicy.default.maximumActiveLeaseCount,
            maximumBytes: CodeMapArtifactStorePolicy.default.maximumActiveLeaseBytes
        )
        let productionA = try CodeMapArtifactStore(rootURL: productionRootA, leaseAdmission: productionAdmission)
        let productionB = try CodeMapArtifactStore(rootURL: productionRootB, leaseAdmission: productionAdmission)
        let productionKeyA = try makeKey("process-wide-production-admission-a")
        let productionKeyB = try makeKey("process-wide-production-admission-b")
        _ = try await productionA.insert(key: productionKeyA, deterministicOutcome: .readyNoSymbols)
        _ = try await productionB.insert(key: productionKeyB, deterministicOutcome: .readyNoSymbols)
        let productionHandleA = try await requireHit(productionA, key: productionKeyA, source: .memory)
        let productionHandleB = try await requireHit(productionB, key: productionKeyB, source: .memory)
        let productionLimit = CodeMapArtifactStorePolicy.default.maximumActiveLeaseCount
        XCTAssertGreaterThan(productionLimit, 0)
        XCTAssertLessThanOrEqual(productionLimit, 256)
        var productionLeases: [CodeMapArtifactLease] = []
        for index in 0 ..< productionLimit {
            let lease: CodeMapArtifactLease = if index.isMultiple(of: 2) {
                try await productionA.lease(handle: productionHandleA)
            } else {
                try await productionB.lease(handle: productionHandleB)
            }
            productionLeases.append(lease)
        }
        var productionAccounting = await productionB.accounting()
        XCTAssertEqual(productionAccounting.activeLeaseCount, productionLimit)
        do {
            _ = try await productionA.lease(handle: productionHandleA)
            XCTFail("The production controller must cap aggregate descriptors across stores.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .busy(.activeLeaseCountLimit))
        }
        await productionLeases.removeLast().close()
        try await productionLeases.append(productionB.lease(handle: productionHandleB))
        for lease in productionLeases {
            await lease.close()
        }
        productionAccounting = await productionB.accounting()
        XCTAssertEqual(productionAccounting.activeLeaseCount, 0)
        XCTAssertEqual(productionAccounting.activeLeaseBytes, 0)

        let rootA = try makeSecureRoot()
        let rootB = try makeSecureRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let admission = CodeMapArtifactLeaseAdmission(maximumCount: 2, maximumBytes: .max)
        let storeA = try CodeMapArtifactStore(rootURL: rootA, leaseAdmission: admission)
        let storeB = try CodeMapArtifactStore(rootURL: rootB, leaseAdmission: admission)
        let firstKey = try makeKey("aggregate-first")
        let secondKey = try makeKey("aggregate-second")
        let thirdKey = try makeKey("aggregate-third")
        _ = try await storeA.insert(key: firstKey, deterministicOutcome: .readyNoSymbols)
        _ = try await storeB.insert(key: secondKey, deterministicOutcome: .readyNoSymbols)
        _ = try await storeA.insert(key: thirdKey, deterministicOutcome: .readyNoSymbols)
        let firstHandle = try await requireHit(storeA, key: firstKey, source: .memory)
        let secondHandle = try await requireHit(storeB, key: secondKey, source: .memory)
        let thirdHandle = try await requireHit(storeA, key: thirdKey, source: .memory)
        let firstLease = try await storeA.lease(handle: firstHandle)
        let secondLease = try await storeB.lease(handle: secondHandle)
        do {
            _ = try await storeA.lease(handle: thirdHandle)
            XCTFail("The shared controller must cap aggregate descriptors across stores.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .busy(.activeLeaseCountLimit))
        }
        var accountingA = await storeA.accounting()
        var accountingB = await storeB.accounting()
        XCTAssertEqual(accountingA.activeLeaseCount, 2)
        XCTAssertEqual(accountingB.activeLeaseCount, 2)
        XCTAssertEqual(
            accountingA.activeLeaseBytes,
            firstHandle.containerByteCount + secondHandle.containerByteCount
        )
        XCTAssertEqual(accountingB.activeLeaseBytes, accountingA.activeLeaseBytes)

        await secondLease.close()
        let recovered = try await storeA.lease(handle: thirdHandle)
        accountingA = await storeA.accounting()
        XCTAssertEqual(accountingA.activeLeaseCount, 2)
        await firstLease.close()
        await recovered.close()
        accountingB = await storeB.accounting()
        XCTAssertEqual(accountingB.activeLeaseCount, 0)
        XCTAssertEqual(accountingB.activeLeaseBytes, 0)
    }

    func testDescriptorExhaustionAndCancellationAfterOpenReleaseAdmission() async throws {
        for code in [EMFILE, ENFILE] {
            let root = try makeSecureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let admission = CodeMapArtifactLeaseAdmission(maximumCount: 1, maximumBytes: .max)
            let store = try CodeMapArtifactStore(
                rootURL: root,
                leaseAdmission: admission,
                leaseHooks: CodeMapArtifactLeaseHooks(beforeDescriptorOpen: {
                    throw CodeMapArtifactCatalogError.ioFailure(operation: "test-fd-limit", code: code)
                })
            )
            let key = try makeKey("fd-limit-\(code)")
            _ = try await store.insert(key: key, deterministicOutcome: .readyNoSymbols)
            let handle = try await requireHit(store, key: key, source: .memory)
            do {
                _ = try await store.lease(handle: handle)
                XCTFail("Descriptor exhaustion must map to typed backpressure.")
            } catch {
                XCTAssertEqual(error as? CodeMapArtifactLeaseError, .busy(.fileDescriptorLimit))
            }
            let accounting = await store.accounting()
            XCTAssertEqual(accounting.activeLeaseCount, 0)
            XCTAssertEqual(accounting.activeLeaseBytes, 0)
        }

        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LeaseAfterOpenGate()
        let admission = CodeMapArtifactLeaseAdmission(maximumCount: 1, maximumBytes: .max)
        let store = try CodeMapArtifactStore(
            rootURL: root,
            leaseAdmission: admission,
            leaseHooks: CodeMapArtifactLeaseHooks(afterDescriptorOpen: { gate.pauseFirstOpen() })
        )
        let key = try makeKey("cancel-after-open")
        _ = try await store.insert(key: key, deterministicOutcome: .readyNoSymbols)
        let handle = try await requireHit(store, key: key, source: .memory)
        let task = Task { try await store.lease(handle: handle) }
        XCTAssertEqual(gate.opened.wait(timeout: .now() + 2), .success)
        task.cancel()
        gate.resume.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation after descriptor open must not publish a lease.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        var accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
        let recovered = try await store.lease(handle: handle)
        await recovered.close()
        accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testLeaseRejectsSameSizeStructurallyValidPayloadMutationAsChanged() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("same-size-valid-mutation")
        let originalOutcome = CodeMapSyntaxArtifactOutcome.parseFailed(.parserReturnedNilTree)
        let replacementOutcome = CodeMapSyntaxArtifactOutcome.parseFailed(.parserReturnedNilRoot)
        let store = try CodeMapArtifactStore(rootURL: root)
        _ = try await store.insert(key: key, deterministicOutcome: originalOutcome)
        let staleHandle = try await requireHit(store, key: key, source: .memory)
        let originalBytes = try Data(contentsOf: artifactURL(root: root, key: key))
        let replacementBytes = try CodeMapArtifactContainer.encode(key: key, outcome: replacementOutcome)
        XCTAssertEqual(replacementBytes.count, originalBytes.count)
        XCTAssertNotEqual(replacementBytes, originalBytes)
        try replacementBytes.write(to: artifactURL(root: root, key: key))
        XCTAssertEqual(chmod(artifactURL(root: root, key: key).path, 0o600), 0)

        let verifier = try CodeMapArtifactStore(rootURL: root)
        let current = try await requireHit(verifier, key: key, source: .disk)
        XCTAssertEqual(current.outcome, replacementOutcome)
        do {
            _ = try await store.lease(handle: staleHandle)
            XCTFail("A same-size valid replacement must not match the stale handle.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactLeaseError, .artifactChanged)
        }
        let accounting = await store.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testRestartRepairsMissingAndCorruptSidecarsAndReconcilesMissingPayloadAndTemps() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("reconcile")
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await store.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Repair")))
        let meta = metadataURL(root: root, key: key)
        try FileManager.default.removeItem(at: meta)

        let orphanRestart = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(orphanRestart, stepBudget: 1)
        var restartAccounting = await orphanRestart.accounting()
        XCTAssertEqual(restartAccounting.observedOrphanArtifactCount, 1)
        _ = try await requireHit(orphanRestart, key: key, source: .disk)
        restartAccounting = await orphanRestart.accounting()
        XCTAssertEqual(restartAccounting.repairedOrphanArtifactCount, 1)

        try Data("bad metadata".utf8).write(to: meta)
        XCTAssertEqual(chmod(meta.path, 0o600), 0)
        let corruptRestart = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(corruptRestart, stepBudget: 1)
        restartAccounting = await corruptRestart.accounting()
        XCTAssertEqual(restartAccounting.corruptMetadataCount, 1)
        _ = try await requireHit(corruptRestart, key: key, source: .disk)

        let catalogShard = meta.deletingLastPathComponent()
        let temp = catalogShard.appendingPathComponent(
            ".tmp.\(Int32.max).00000000-0000-0000-0000-000000000001"
        )
        try Data("partial".utf8).write(to: temp)
        XCTAssertEqual(chmod(temp.path, 0o600), 0)
        let tempRestart = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(tempRestart, stepBudget: 1)
        restartAccounting = await tempRestart.accounting()
        XCTAssertEqual(restartAccounting.ignoredTemporaryCount, 1)
        XCTAssertEqual(restartAccounting.removedTemporaryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))

        try Data("corrupt payload".utf8).write(to: artifactURL(root: root, key: key))
        XCTAssertEqual(chmod(artifactURL(root: root, key: key).path, 0o600), 0)
        let payloadRestart = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(payloadRestart, stepBudget: 1)
        restartAccounting = await payloadRestart.accounting()
        XCTAssertEqual(restartAccounting.corruptPayloadCount, 1)
        XCTAssertGreaterThanOrEqual(restartAccounting.quarantinedCount, 1)
        try await assertMiss(payloadRestart, key: key)
        clock.set(100 + 24 * 60 * 60)
        let corruptSweep = try await drainGC(payloadRestart, stepBudget: 1)
        XCTAssertGreaterThanOrEqual(corruptSweep.reduce(0) { $0 + $1.sweptCount }, 1)
        _ = try await payloadRestart.insert(
            key: key,
            deterministicOutcome: .ready(makeArtifact(name: "Missing"))
        )
        try FileManager.default.removeItem(at: artifactURL(root: root, key: key))
        let missingRestart = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(missingRestart, stepBudget: 1)
        restartAccounting = await missingRestart.accounting()
        XCTAssertEqual(restartAccounting.missingPayloadCount, 1)
        try await assertMiss(missingRestart, key: key)
    }

    func testCatalogFramingChecksumAndConfiguredStartupBoundsFailClosed() async throws {
        let key = try makeKey("metadata framing")
        let record = CodeMapArtifactCatalogRecord(
            key: key,
            containerByteCount: 100,
            payloadByteCount: 10,
            outcomeClass: .positive,
            creationEpochSeconds: 1,
            lastAccessEpochSeconds: 2,
            lastAccessSequence: 3,
            state: .live
        )
        let encoded = try CodeMapArtifactCatalog.encodeRecord(record)
        XCTAssertEqual(try CodeMapArtifactCatalog.decodeRecord(encoded), record)
        var corrupted = encoded
        corrupted[corrupted.count - 1] ^= 0xFF
        XCTAssertThrowsError(try CodeMapArtifactCatalog.decodeRecord(corrupted))

        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let permissive = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await permissive.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "One")))
        _ = try await permissive.insert(
            key: makeKey("metadata framing 2"),
            deterministicOutcome: .ready(makeArtifact(name: "Two"))
        )
        let countBounded = try CodeMapArtifactStore(
            rootURL: root,
            policy: makePolicy(maximumCatalogRecordCount: 1),
            clock: clock.storeClock
        )
        await XCTAssertThrowsErrorAsync {
            for _ in 0 ..< 20 {
                _ = try await countBounded.refreshAccounting(stepBudget: 1)
            }
        }
        let byteBoundedCatalog = try CodeMapArtifactCatalog(
            rootURL: root,
            policy: makePolicy(maximumCatalogScanByteCount: 1)
        )
        let scan = try byteBoundedCatalog.beginScan(.liveCatalog)
        var requiredByteCount: UInt64?
        for _ in 0 ..< 1000 {
            if case let .needsMoreBytes(required, _) = try byteBoundedCatalog.nextScanStep(
                scan,
                maximumReadByteCount: 1,
                epochSeconds: 100
            ) {
                requiredByteCount = required
                break
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(requiredByteCount), 1)
    }

    func testSoftGCUsesAgeAndAccessOrderWithIncrementalContinuationThenDelayedSweep() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let policy = makePolicy(
            softQuotaBytes: 0,
            hardQuotaBytes: .max,
            unreferencedGraceSeconds: 10,
            quarantineDelaySeconds: 20,
            negativeQuotaBytes: .max,
            negativeMaximumAgeSeconds: .max
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock)
        let oldest = try makeKey("soft-oldest")
        let touched = try makeKey("soft-touched")
        let secondOldest = try makeKey("soft-second")
        let thirdOldest = try makeKey("soft-third")
        _ = try await store.insert(key: oldest, deterministicOutcome: .ready(makeArtifact(name: "Oldest")))
        clock.set(101)
        _ = try await store.insert(key: touched, deterministicOutcome: .ready(makeArtifact(name: "Touched")))
        clock.set(102)
        _ = try await store.insert(key: secondOldest, deterministicOutcome: .ready(makeArtifact(name: "Second")))
        clock.set(103)
        _ = try await store.insert(key: thirdOldest, deterministicOutcome: .ready(makeArtifact(name: "Third")))
        clock.set(200)
        _ = try await requireHit(store, key: touched, source: .memory)

        let collection = try await drainGC(store, stepBudget: 1)
        XCTAssertTrue(collection.allSatisfy { $0.examinedCount <= 1 })
        XCTAssertTrue(collection.allSatisfy { $0.visitedEntryCount <= 1 })
        XCTAssertEqual(collection.reduce(0) { $0 + $1.quarantinedCount }, 3)
        XCTAssertTrue(collection.dropLast().allSatisfy { $0.continuation != nil })
        try await assertMiss(CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock), key: oldest)
        _ = try await requireHit(store, key: touched, source: .memory)
        try await assertMiss(CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock), key: secondOldest)
        try await assertMiss(CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock), key: thirdOldest)

        clock.set(219)
        _ = try await requireHit(store, key: touched, source: .memory)
        let prematureSweep = try await drainGC(store, stepBudget: 1)
        XCTAssertEqual(prematureSweep.reduce(0) { $0 + $1.sweptCount }, 0)
        clock.set(220)
        let swept = try await drainGC(store, stepBudget: 1)
        XCTAssertEqual(swept.reduce(0) { $0 + $1.sweptCount }, 3)
        let finalAccounting = await store.accounting()
        XCTAssertEqual(finalAccounting.quarantinedCount, 0)
    }

    func testHardQuotaOverridesGraceAndNegativeQuotaRemainsIndependent() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = makePolicy(
            softQuotaBytes: 0,
            hardQuotaBytes: 1,
            unreferencedGraceSeconds: .max,
            quarantineDelaySeconds: .max,
            negativeQuotaBytes: 1,
            negativeMaximumAgeSeconds: .max
        )
        let clock = TestClock(100)
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock)
        _ = try await store.insert(
            key: makeKey("hard-positive"),
            deterministicOutcome: .ready(makeArtifact(name: "Hard"))
        )
        _ = try await store.insert(key: makeKey("hard-negative"), deterministicOutcome: .readyNoSymbols)

        let progress = try await drainGC(store, stepBudget: 2)
        XCTAssertEqual(progress.reduce(0) { $0 + $1.quarantinedCount }, 2)
        XCTAssertTrue(try XCTUnwrap(progress.last).isComplete)
        let accounting = await store.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 0)
        XCTAssertEqual(accounting.liveNegativeCount, 0)
        XCTAssertEqual(accounting.quarantinedCount, 2)
        let tooEarly = try await drainGC(store, stepBudget: 2)
        XCTAssertEqual(tooEarly.reduce(0) { $0 + $1.sweptCount }, 0)
    }

    func testIndependentStoresRacePublicationWithoutPartialCatalogOrPayloadVisibility() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("concurrent stores")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact(name: "Concurrent"))
        let clock = TestClock(100)
        let stores = try (0 ..< 8).map { _ in
            try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        }
        let results = try await withThrowingTaskGroup(of: CodeMapArtifactInsertResult.self) { group in
            for store in stores {
                group.addTask { try await store.insert(key: key, deterministicOutcome: outcome) }
            }
            var values: [CodeMapArtifactInsertResult] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(results.count(where: { $0 == .inserted }), 1)
        XCTAssertEqual(results.count(where: { $0 == .alreadyPresent }), 7)
        for store in stores {
            let handle = try await requireHit(store, key: key, source: .memory)
            XCTAssertEqual(handle.outcome, outcome)
        }
        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let restartedHandle = try await requireHit(restarted, key: key, source: .disk)
        XCTAssertEqual(restartedHandle.outcome, outcome)
    }

    func testPagedReconciliationChargesEveryVisitAndResumesWithoutStartupMaterialization() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let writer = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        for index in 0 ..< 5 {
            _ = try await writer.insert(
                key: makeKey("paged-\(index)"),
                deterministicOutcome: .ready(makeArtifact(name: "Paged\(index)"))
            )
        }

        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let initial = await restarted.accounting()
        XCTAssertEqual(initial.livePositiveCount, 0)
        XCTAssertFalse(initial.liveReconciliationComplete)

        let pages = try await drainRefresh(restarted, stepBudget: 1)
        XCTAssertGreaterThan(pages.count, 10)
        XCTAssertTrue(pages.allSatisfy { $0.visitedEntryCount <= 1 })
        XCTAssertTrue(pages.allSatisfy { $0.readByteCount <= UInt64(64 * 1024 * 1024) })
        let continuations = pages.compactMap(\.continuation)
        XCTAssertEqual(continuations.map(\.nextOffset), Array(1 ... continuations.count))
        let final = await restarted.accounting()
        XCTAssertEqual(final.livePositiveCount, 5)
        XCTAssertTrue(final.liveReconciliationComplete)
        XCTAssertTrue(final.quarantineInventoryComplete)
    }

    func testTypedCrashOrphansRepairInventoryAndSweepAfterInjectedEpoch() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let artifactOnly = try makeKey("crash-artifact-only")
        let metadataOnly = try makeKey("crash-metadata-only")
        _ = try await store.insert(
            key: artifactOnly,
            deterministicOutcome: .ready(makeArtifact(name: "ArtifactOnly"))
        )
        _ = try await store.insert(
            key: metadataOnly,
            deterministicOutcome: .ready(makeArtifact(name: "MetadataOnly"))
        )
        try FileManager.default.removeItem(at: metadataURL(root: root, key: artifactOnly))
        let token = "00000000-0000-0000-0000-000000000123"
        let quarantineShard = root.appendingPathComponent(
            "CodeMapArtifacts/v1/quarantine/100/artifacts/\(artifactOnly.shard)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantineShard,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(quarantineShard.path, 0o700), 0)
        try FileManager.default.moveItem(
            at: artifactURL(root: root, key: artifactOnly),
            to: quarantineShard.appendingPathComponent("\(artifactOnly.storageDigestHex).\(token)")
        )
        try FileManager.default.removeItem(at: artifactURL(root: root, key: metadataOnly))
        let quarantineCatalogShard = root.appendingPathComponent(
            "CodeMapArtifacts/v1/quarantine/100/catalog/\(artifactOnly.shard)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantineCatalogShard,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(quarantineCatalogShard.path, 0o700), 0)
        let quarantineTemp = quarantineCatalogShard.appendingPathComponent(
            ".tmp.\(Int32.max).00000000-0000-0000-0000-000000000789"
        )
        try Data("partial quarantine metadata".utf8).write(to: quarantineTemp)
        XCTAssertEqual(chmod(quarantineTemp.path, 0o600), 0)
        let catalog = try CodeMapArtifactCatalog(rootURL: root, policy: .default)
        let artifactOnlyLease = try catalog.acquireSharedLease(key: artifactOnly)
        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let leasedPages = try await drainRefresh(restarted, stepBudget: 1)
        let leasedAccounting = await restarted.accounting()
        XCTAssertTrue(leasedAccounting.quarantineInventoryComplete)
        XCTAssertGreaterThanOrEqual(leasedAccounting.quarantineOrphanCount, 1)
        XCTAssertGreaterThanOrEqual(leasedPages.reduce(0) { $0 + ($1.continuation?.phase == .repairQuarantine ? 1 : 0) }, 1)
        artifactOnlyLease.close()

        let pages = try await drainRefresh(restarted, stepBudget: 1)
        XCTAssertTrue(pages.allSatisfy { $0.visitedEntryCount <= 1 })
        let accounting = await restarted.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 0)
        XCTAssertEqual(accounting.quarantinedCount, 2)
        XCTAssertGreaterThan(accounting.quarantinedBytes, 0)
        XCTAssertEqual(accounting.missingPayloadCount, 1)
        XCTAssertGreaterThanOrEqual(accounting.quarantineOrphanCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineTemp.path))

        let quarantineCatalog = root.appendingPathComponent("CodeMapArtifacts/v1/quarantine/100/catalog")
        let tombstoneURLs = try regularFileURLs(at: quarantineCatalog).filter {
            $0.lastPathComponent.contains(".tomb.")
        }
        XCTAssertEqual(tombstoneURLs.count, 2)
        let reasons = try tombstoneURLs.map {
            try CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: $0)).reason
        }
        XCTAssertEqual(Set(reasons), Set([.recoveredArtifactOnly, .missingPayload]))
        let recoveredArtifact = try XCTUnwrap(tombstoneURLs.first { url in
            (try? CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: url)).reason) == .recoveredArtifactOnly
        })
        let existingBytes = try Data(contentsOf: recoveredArtifact).count
        XCTAssertEqual(
            try catalog.recoverArtifactOnlyTombstone(
                epochSeconds: 100,
                shard: artifactOnly.shard,
                artifactName: "\(artifactOnly.storageDigestHex).\(token)",
                byteCount: UInt64(
                    XCTUnwrap(
                        try (FileManager.default.attributesOfItem(
                            atPath: quarantineShard.appendingPathComponent(
                                "\(artifactOnly.storageDigestHex).\(token)"
                            ).path
                        )[.size]) as? NSNumber
                    ).uint64Value
                )
            ),
            .existing(metadataByteCount: existingBytes)
        )

        clock.set(100 + 24 * 60 * 60)
        let sweep = try await drainGC(restarted, stepBudget: 1)
        XCTAssertEqual(sweep.reduce(0) { $0 + $1.sweptCount }, 2)
        let sweptAccounting = await restarted.accounting()
        XCTAssertEqual(sweptAccounting.quarantinedCount, 0)
    }

    func testCorruptMetadataAndArtifactBecomeTypedTombstonesAndValidOrphanRepairs() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(500)
        let store = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let corruptMetadata = try makeKey("typed-corrupt-metadata")
        let corruptArtifact = try makeKey("typed-corrupt-artifact")
        _ = try await store.insert(
            key: corruptMetadata,
            deterministicOutcome: .ready(makeArtifact(name: "Metadata"))
        )
        _ = try await store.insert(
            key: corruptArtifact,
            deterministicOutcome: .ready(makeArtifact(name: "Artifact"))
        )
        try Data("corrupt metadata".utf8).write(to: metadataURL(root: root, key: corruptMetadata))
        XCTAssertEqual(chmod(metadataURL(root: root, key: corruptMetadata).path, 0o600), 0)
        try Data("corrupt artifact".utf8).write(to: artifactURL(root: root, key: corruptArtifact))
        XCTAssertEqual(chmod(artifactURL(root: root, key: corruptArtifact).path, 0o600), 0)

        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(restarted, stepBudget: 1)
        let accounting = await restarted.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 1)
        XCTAssertEqual(accounting.repairedOrphanArtifactCount, 1)
        XCTAssertEqual(accounting.corruptMetadataCount, 1)
        XCTAssertEqual(accounting.corruptPayloadCount, 1)
        let tombstones = try regularFileURLs(
            at: root.appendingPathComponent("CodeMapArtifacts/v1/quarantine/500/catalog")
        ).filter { $0.lastPathComponent.contains(".tomb.") }
        let reasons = try tombstones.map {
            try CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: $0)).reason
        }
        XCTAssertTrue(reasons.contains(.corruptMetadata))
        XCTAssertTrue(reasons.contains(.corruptPayload))
    }

    func testMaintenanceByteBudgetsChargeRepairQuarantineAndSweepAndHardEqualityCollects() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let writer = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        let key = try makeKey("finite-maintenance-budget")
        _ = try await writer.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Budget")))
        let exactBytes = await (writer.accounting()).livePositiveBytes
        XCTAssertGreaterThan(exactBytes, 0)

        let hardEqualityPolicy = makePolicy(
            softQuotaBytes: 0,
            hardQuotaBytes: exactBytes,
            unreferencedGraceSeconds: .max,
            quarantineDelaySeconds: 10
        )
        let collector = try CodeMapArtifactStore(
            rootURL: root,
            policy: hardEqualityPolicy,
            clock: clock.storeClock
        )
        let collection = try await drainGC(collector, stepBudget: 1)
        XCTAssertEqual(collection.reduce(0) { $0 + $1.quarantinedCount }, 1)
        XCTAssertGreaterThan(collection.reduce(UInt64(0)) { $0 + $1.readByteCount }, 0)
        XCTAssertGreaterThan(collection.reduce(UInt64(0)) { $0 + $1.writtenByteCount }, 0)
        XCTAssertTrue(collection.allSatisfy { $0.readByteCount <= 128 * 1024 * 1024 })
        XCTAssertTrue(collection.allSatisfy { $0.writtenByteCount <= 8 * 1024 * 1024 })
        let afterCollection = await collector.accounting()
        XCTAssertLessThan(afterCollection.livePositiveBytes, exactBytes)

        clock.set(110)
        let sweep = try await drainGC(collector, stepBudget: 1)
        XCTAssertEqual(sweep.reduce(0) { $0 + $1.sweptCount }, 1)
        XCTAssertGreaterThan(sweep.reduce(UInt64(0)) { $0 + $1.readByteCount }, 0)
    }

    func testKeylessOrphanTombstoneUsesDigestLeaseBeforeQuarantineAndSweep() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("keyless-lease")
        let owner = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await owner.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Lease")))
        let handle = try await requireHit(owner, key: key, source: .memory)
        let lease = try await owner.lease(handle: handle)
        try FileManager.default.removeItem(at: metadataURL(root: root, key: key))
        try Data("corrupt orphan".utf8).write(to: artifactURL(root: root, key: key))
        XCTAssertEqual(chmod(artifactURL(root: root, key: key).path, 0o600), 0)

        let reconciler = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await drainRefresh(reconciler, stepBudget: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL(root: root, key: key).path))
        await lease.close()

        _ = try await drainRefresh(reconciler, stepBudget: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL(root: root, key: key).path))
        let tombstones = try regularFileURLs(
            at: root.appendingPathComponent("CodeMapArtifacts/v1/quarantine/100/catalog")
        ).filter { $0.lastPathComponent.contains(".tomb.") }
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(
            try CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: XCTUnwrap(tombstones.first))).reason,
            .orphanArtifact
        )
    }

    func testCorruptQuarantineMetadataRepairsTypedAndSweepOrderIsDeterministic() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let policy = makePolicy(
            softQuotaBytes: 0,
            hardQuotaBytes: 1,
            unreferencedGraceSeconds: 0,
            quarantineDelaySeconds: 10
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock.storeClock)
        for index in 0 ..< 3 {
            _ = try await store.insert(
                key: makeKey("deterministic-sweep-\(index)"),
                deterministicOutcome: .ready(makeArtifact(name: "Sweep\(index)"))
            )
        }
        _ = try await drainGC(store, stepBudget: 1)
        let quarantineCatalog = root.appendingPathComponent("CodeMapArtifacts/v1/quarantine/100/catalog")
        let originalTombstones = try regularFileURLs(at: quarantineCatalog).filter {
            $0.lastPathComponent.contains(".tomb.")
        }
        XCTAssertEqual(originalTombstones.count, 3)
        let corruptURL = try XCTUnwrap(originalTombstones.first)
        let original = try CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: corruptURL))
        try Data("corrupt tombstone".utf8).write(to: corruptURL)
        XCTAssertEqual(chmod(corruptURL.path, 0o600), 0)

        _ = try await drainRefresh(store, stepBudget: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        let repaired = try CodeMapArtifactCatalog.decodeTombstone(Data(contentsOf: corruptURL))
        XCTAssertEqual(repaired.reason, .recoveredMetadataOnly)
        XCTAssertEqual(repaired.token, original.token)

        clock.set(110)
        let sweep = try await drainGC(store, stepBudget: 1)
        let sweptDigests = sweep.flatMap(\.sweptDigests)
        XCTAssertEqual(sweptDigests, sweptDigests.sorted())
        XCTAssertEqual(sweptDigests.count, 3)
    }

    func testMaintenanceIndexCompactionDropsHistoricalChurn() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = makePolicy(
            softQuotaBytes: 0,
            hardQuotaBytes: 1,
            unreferencedGraceSeconds: 0,
            quarantineDelaySeconds: .max
        )
        let store = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: TestClock(100).storeClock)
        for index in 0 ..< 12 {
            _ = try await store.insert(
                key: makeKey("compaction-\(index)"),
                deterministicOutcome: .ready(makeArtifact(name: "Compaction\(index)"))
            )
            _ = try await drainGC(store, stepBudget: 1)
        }
        _ = try await drainRefresh(store, stepBudget: 1)
        let indexes = await store.maintenanceIndexAccounting()
        XCTAssertEqual(indexes.recordOrderCount, 0)
        XCTAssertEqual(indexes.recordSetCount, 0)
        XCTAssertEqual(indexes.mutationGenerationCount, 0)
    }

    func testPagedReconciliationPreservesTouchAndInsertAfterCatalogPage() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let originalKey = try makeKey("reconciliation-overlay-original")
        let insertedKey = try makeKey("reconciliation-overlay-inserted")
        let writer = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await writer.insert(
            key: originalKey,
            deterministicOutcome: .ready(makeArtifact(name: "Original"))
        )

        let restarted = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        var progress = try await restarted.refreshAccounting(stepBudget: 1)
        while progress.continuation?.phase != .reconcileArtifacts {
            progress = try await restarted.refreshAccounting(stepBudget: 1)
        }
        clock.set(500)
        _ = try await requireHit(restarted, key: originalKey, source: .disk)
        _ = try await restarted.insert(
            key: insertedKey,
            deterministicOutcome: .ready(makeArtifact(name: "Inserted"))
        )
        _ = try await drainRefresh(restarted, stepBudget: 1)

        let accounting = await restarted.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 2)
        try await restarted.flushAccessMetadata(stepBudget: 1)
        let durableOriginal = try CodeMapArtifactCatalog.decodeRecord(
            Data(contentsOf: metadataURL(root: root, key: originalKey))
        )
        XCTAssertEqual(durableOriginal.lastAccessEpochSeconds, 500)
        _ = try await requireHit(restarted, key: insertedKey, source: .memory)
    }

    func testOrphanHeaderAndRepeatVerificationFitFiniteArtifactReadBudget() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(100)
        let key = try makeKey("orphan-read-budget")
        let writer = try CodeMapArtifactStore(rootURL: root, clock: clock.storeClock)
        _ = try await writer.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "Budget")))
        let artifact = artifactURL(root: root, key: key)
        try Data("corrupt expected orphan".utf8).write(to: artifact)
        XCTAssertEqual(chmod(artifact.path, 0o600), 0)
        let size = try XCTUnwrap(
            try (FileManager.default.attributesOfItem(atPath: artifact.path)[.size]) as? NSNumber
        ).uint64Value
        let knownRead = CodeMapArtifactFileStore.maintenanceVerificationReadByteCount(containerByteCount: size)
        let orphanRead = CodeMapArtifactFileStore.maintenanceOrphanReadByteCount(
            containerByteCount: size,
            containerPolicy: .default
        )
        let finiteLimit = knownRead + orphanRead
        let metadataLimit = 128 * 1024
        let store = try CodeMapArtifactStore(
            rootURL: root,
            policy: makePolicy(
                maximumCatalogScanByteCount: metadataLimit,
                maximumArtifactReconciliationByteCount: finiteLimit
            ),
            clock: clock.storeClock
        )
        let pages = try await drainRefresh(store, stepBudget: 1)
        XCTAssertTrue(pages.allSatisfy { $0.readByteCount <= finiteLimit + UInt64(metadataLimit) })
        let accounting = await store.accounting()
        XCTAssertEqual(accounting.corruptPayloadCount, 1)
    }

    func testDefaultPolicyBoundsLargeCardinalityContinuationState() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = CodeMapArtifactStorePolicy.default
        XCTAssertLessThan(policy.maximumCatalogRecordCount, .max)
        XCTAssertLessThan(policy.maximumArtifactScanCount, .max)

        let writer = try CodeMapArtifactStore(rootURL: root, policy: policy)
        for index in 0 ..< 256 {
            _ = try await writer.insert(
                key: makeKey("bounded-cardinality-\(index)"),
                deterministicOutcome: .ready(makeArtifact(name: "Bounded\(index)"))
            )
        }

        let restarted = try CodeMapArtifactStore(rootURL: root, policy: policy)
        let pages = try await drainRefresh(restarted, stepBudget: 3)
        XCTAssertGreaterThan(pages.count, 256)
        let indexes = await restarted.maintenanceIndexAccounting()
        XCTAssertLessThanOrEqual(indexes.recordOrderCount, policy.maximumCatalogRecordCount * 2)
        XCTAssertLessThanOrEqual(indexes.recordSetCount, policy.maximumCatalogRecordCount)
        XCTAssertLessThanOrEqual(indexes.mutationGenerationCount, policy.maximumCatalogRecordCount)
        let accounting = await restarted.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 256)
    }

    func testPendingScanReadBudgetUsesFreshDescriptorSizeAfterAtomicReplacement() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("fresh-scan-size")
        let store = try CodeMapArtifactStore(rootURL: root)
        _ = try await store.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "FreshSize")))

        let catalog = try CodeMapArtifactCatalog(rootURL: root, policy: .default)
        let scan = try catalog.beginScan(.liveCatalog)
        var originalRequired: UInt64?
        while originalRequired == nil {
            switch try catalog.nextScanStep(scan, maximumReadByteCount: 0, epochSeconds: 100) {
            case let .needsMoreBytes(required, _): originalRequired = required
            case .visit: continue
            case .complete: return XCTFail("Expected a pending metadata leaf.")
            }
        }
        let requiredBeforeReplacement = try XCTUnwrap(originalRequired)
        let replacement = Data(repeating: 0xA5, count: Int(requiredBeforeReplacement) + 97)
        try replacement.write(
            to: metadataURL(root: root, key: key),
            options: Data.WritingOptions.atomic
        )
        XCTAssertEqual(chmod(metadataURL(root: root, key: key).path, 0o600), 0)

        guard case let .needsMoreBytes(freshRequired, chargeEntry) = try catalog.nextScanStep(
            scan,
            maximumReadByteCount: requiredBeforeReplacement,
            epochSeconds: 100
        ) else { return XCTFail("Expected the grown replacement to remain pending.") }
        XCTAssertEqual(freshRequired, UInt64(replacement.count))
        XCTAssertFalse(chargeEntry)
    }

    func testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("same-descriptor-scan-size")
        let store = try CodeMapArtifactStore(rootURL: root)
        _ = try await store.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "SameDescriptor")))

        let metadata = metadataURL(root: root, key: key)
        let admittedByteCount = try UInt64(Data(contentsOf: metadata).count)
        let replacement = Data(repeating: 0xA5, count: Int(admittedByteCount) + 4096)
        let replacementHook = MetadataReplacementHook(
            expectedName: "\(key.storageDigestHex).meta",
            expectedAdmittedByteCount: admittedByteCount,
            replacement: replacement,
            metadataURL: metadata
        )
        let hooks = CodeMapArtifactCatalogScanHooks(afterMetadataAdmission: { _, name, admitted in
            try replacementHook.replace(name: name, admittedByteCount: admitted)
        })
        let catalog = try CodeMapArtifactCatalog(rootURL: root, policy: .default, scanHooks: hooks)
        let scan = try catalog.beginScan(.liveCatalog)

        var observedVisit: CodeMapArtifactCatalogScanVisit?
        while observedVisit == nil {
            switch try catalog.nextScanStep(
                scan,
                maximumReadByteCount: admittedByteCount,
                epochSeconds: 100
            ) {
            case let .visit(visit, _):
                if case .boundary = visit { continue }
                observedVisit = visit
            case let .needsMoreBytes(required, _):
                return XCTFail("Replacement size escaped admitted descriptor: \(required)")
            case .complete:
                return XCTFail("Expected metadata visit")
            }
        }

        XCTAssertEqual(replacementHook.replacementCount, 1)
        XCTAssertEqual(observedVisit?.readByteCount, admittedByteCount)
        XCTAssertLessThanOrEqual(try XCTUnwrap(observedVisit?.readByteCount), admittedByteCount)
        XCTAssertGreaterThan(UInt64(replacement.count), admittedByteCount)
    }

    func testRestartBoundedlyRecoversOnlyDeadValidatedPrivateDeletionsAndAccountsLiveBytes() async throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: root) }
        let key = try makeKey("private-deletion-restart")
        let writer = try CodeMapArtifactStore(rootURL: root)
        _ = try await writer.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "PrivateDelete")))
        let handle = try await requireHit(writer, key: key, source: .memory)

        let liveCatalogShard = metadataURL(root: root, key: key).deletingLastPathComponent()
        let liveArtifactShard = artifactURL(root: root, key: key).deletingLastPathComponent()
        let quarantineCatalogShard = root.appendingPathComponent(
            "CodeMapArtifacts/v1/quarantine/100/catalog/\(key.shard)",
            isDirectory: true
        )
        let quarantineArtifactShard = root.appendingPathComponent(
            "CodeMapArtifacts/v1/quarantine/100/artifacts/\(key.shard)",
            isDirectory: true
        )
        for directory in [quarantineCatalogShard, quarantineArtifactShard] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let deadPID = Int32.max
        let deadPayloads = [
            Data("dead-live-catalog".utf8),
            Data("dead-live-artifact".utf8),
            Data("dead-quarantine-catalog".utf8),
            Data("dead-quarantine-artifact".utf8)
        ]
        let deadDirectories = [
            liveCatalogShard,
            liveArtifactShard,
            quarantineCatalogShard,
            quarantineArtifactShard
        ]
        var deadURLs: [URL] = []
        for (index, pair) in zip(deadDirectories, deadPayloads).enumerated() {
            let url = pair.0.appendingPathComponent(
                ".delete.\(deadPID).00000000-0000-0000-0000-00000000000\(index + 1)"
            )
            try pair.1.write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            deadURLs.append(url)
        }

        let livePayload = Data(repeating: 0x7E, count: 64)
        let liveURL = liveArtifactShard.appendingPathComponent(
            ".delete.\(getpid()).00000000-0000-0000-0000-000000000005"
        )
        try livePayload.write(to: liveURL)
        XCTAssertEqual(chmod(liveURL.path, 0o600), 0)

        let malformedURL = liveArtifactShard.appendingPathComponent(".delete.\(deadPID).not-a-uuid")
        try Data("malformed".utf8).write(to: malformedURL)
        XCTAssertEqual(chmod(malformedURL.path, 0o600), 0)

        let symlinkURL = liveArtifactShard.appendingPathComponent(
            ".delete.\(deadPID).00000000-0000-0000-0000-000000000006"
        )
        XCTAssertEqual(symlink(liveURL.path, symlinkURL.path), 0)

        let wrongModeURL = liveArtifactShard.appendingPathComponent(
            ".delete.\(deadPID).00000000-0000-0000-0000-000000000007"
        )
        try Data("wrong-mode".utf8).write(to: wrongModeURL)
        XCTAssertEqual(chmod(wrongModeURL.path, 0o644), 0)

        let policy = makePolicy(
            softQuotaBytes: handle.containerByteCount + UInt64(livePayload.count),
            hardQuotaBytes: handle.containerByteCount + UInt64(livePayload.count),
            quarantineDelaySeconds: 1000
        )
        let restarted = try CodeMapArtifactStore(rootURL: root, policy: policy)
        let pages = try await drainGC(restarted, stepBudget: 1)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.allSatisfy { $0.examinedCount <= 1 && $0.visitedEntryCount <= 1 })

        XCTAssertTrue(deadURLs.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        XCTAssertTrue(fileManager.fileExists(atPath: liveURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: malformedURL.path))
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongModeURL.path))

        let accounting = await restarted.accounting()
        XCTAssertEqual(accounting.recoveredPrivateDeletionCount, deadPayloads.count)
        XCTAssertEqual(
            accounting.recoveredPrivateDeletionBytes,
            deadPayloads.reduce(0) { $0 + UInt64($1.count) }
        )
        XCTAssertEqual(accounting.retainedPrivateDeletionCount, 1)
        XCTAssertEqual(accounting.retainedPrivateDeletionBytes, UInt64(livePayload.count))
        XCTAssertEqual(accounting.livePositiveCount, 0, "Retained operation bytes must participate in hard quota")
        XCTAssertEqual(accounting.quarantinedCount, 1)

        let secondRestart = try CodeMapArtifactStore(rootURL: root, policy: policy)
        let restartPages = try await drainRefresh(secondRestart, stepBudget: 1)
        XCTAssertTrue(restartPages.allSatisfy { $0.visitedEntryCount <= 1 })
        let restartedAccounting = await secondRestart.accounting()
        XCTAssertEqual(restartedAccounting.recoveredPrivateDeletionCount, 0)
        XCTAssertEqual(restartedAccounting.retainedPrivateDeletionCount, 1)
        XCTAssertEqual(restartedAccounting.retainedPrivateDeletionBytes, UInt64(livePayload.count))
        XCTAssertTrue(fileManager.fileExists(atPath: liveURL.path))
    }

    func testSecureRemovalRetriesDirectoryFsyncAfterEINTR() throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: root) }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            return XCTFail("Unable to open secure test directory: \(errno)")
        }
        defer { Darwin.close(parent) }
        var parentStatus = stat()
        XCTAssertEqual(fstat(parent, &parentStatus), 0)
        let name = "fsync-retry"
        try Self.writeSecureFile(parentDescriptor: parent, name: name, data: Data("remove".utf8))

        var synchronizationCalls = 0
        let hooks = CodeMapSecureFileRemovalHooks(directorySynchronize: { descriptor in
            synchronizationCalls += 1
            if synchronizationCalls == 1 {
                errno = EINTR
                return -1
            }
            return fsync(descriptor)
        })
        XCTAssertTrue(try CodeMapSecureFileRemoval.remove(
            parentDescriptor: parent,
            expectedDevice: parentStatus.st_dev,
            name: name,
            hooks: hooks
        ))
        XCTAssertGreaterThanOrEqual(synchronizationCalls, 2)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    func testSecureRemovalDeletesMovedInodeAndPreservesReplacementAtOriginalPath() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("secure-remove-after-rename")
        let writer = try CodeMapArtifactStore(rootURL: root)
        _ = try await writer.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "AfterRename")))
        try FileManager.default.removeItem(at: artifactURL(root: root, key: key))
        let sentinel = Data("replacement-survives".utf8)
        let hooks = CodeMapSecureFileRemovalHooks(afterPrivateRename: { parent, original, _ in
            guard original == "\(key.storageDigestHex).meta" else { return }
            try Self.writeSecureFile(parentDescriptor: parent, name: original, data: sentinel)
        })
        let cleaner = try CodeMapArtifactStore(rootURL: root, removalHooks: hooks)

        guard case .miss = try await cleaner.lookup(key: key) else {
            return XCTFail("Expected missing payload cleanup to publish a miss.")
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL(root: root, key: key)), sentinel)
    }

    func testSecureRemovalNeverUnlinksAdversarialReplacementMovedToPrivateName() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try makeKey("secure-remove-before-rename")
        let writer = try CodeMapArtifactStore(rootURL: root)
        _ = try await writer.insert(key: key, deterministicOutcome: .ready(makeArtifact(name: "BeforeRename")))
        try FileManager.default.removeItem(at: artifactURL(root: root, key: key))
        let metadataName = "\(key.storageDigestHex).meta"
        let sentinel = Data("adversarial-replacement".utf8)
        let heldName = ".held.\(UUID().uuidString.lowercased())"
        let hooks = CodeMapSecureFileRemovalHooks(beforePrivateRename: { parent, original in
            guard original == metadataName else { return }
            guard renameat(parent, original, parent, heldName) == 0 else {
                throw CodeMapArtifactCatalogError.ioFailure(operation: "test-swap", code: errno)
            }
            try Self.writeSecureFile(parentDescriptor: parent, name: original, data: sentinel)
        })
        let cleaner = try CodeMapArtifactStore(rootURL: root, removalHooks: hooks)

        do {
            _ = try await cleaner.lookup(key: key)
            XCTFail("Expected moved-inode verification to reject the replacement.")
        } catch {
            XCTAssertEqual(error as? CodeMapArtifactCatalogError, .insecureEntry)
        }
        let shard = metadataURL(root: root, key: key).deletingLastPathComponent()
        let privateURLs = try FileManager.default.contentsOfDirectory(
            at: shard,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".delete.") }
        XCTAssertEqual(privateURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(privateURLs.first)), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard.appendingPathComponent(heldName).path))
    }

    // MARK: - Helpers

    private func makePolicy(
        residentPositiveEntryLimit: Int = 512,
        residentPositiveByteLimit: UInt64 = 64 * 1024 * 1024,
        residentNegativeEntryLimit: Int = 1024,
        residentNegativeByteLimit: UInt64 = 4 * 1024 * 1024,
        softQuotaBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        hardQuotaBytes: UInt64 = 3 * 1024 * 1024 * 1024,
        unreferencedGraceSeconds: UInt64 = 30 * 24 * 60 * 60,
        quarantineDelaySeconds: UInt64 = 24 * 60 * 60,
        negativeQuotaBytes: UInt64 = 64 * 1024 * 1024,
        negativeMaximumAgeSeconds: UInt64 = 30 * 24 * 60 * 60,
        maximumCatalogRecordCount: Int = 65536,
        maximumCatalogScanByteCount: Int = 64 * 1024 * 1024,
        maximumArtifactScanCount: Int = 65536,
        maximumArtifactReconciliationByteCount: UInt64 = 128 * 1024 * 1024,
        maximumMaintenanceWriteByteCount: UInt64 = 8 * 1024 * 1024,
        maximumGCStepBudget: Int = 4096,
        maximumActiveLeaseCount: Int = 16384,
        maximumActiveLeaseBytes: UInt64 = 1024 * 1024 * 1024,
        containerPolicy: CodeMapArtifactContainerPolicy = .default
    ) -> CodeMapArtifactStorePolicy {
        CodeMapArtifactStorePolicy(
            residentPositiveEntryLimit: residentPositiveEntryLimit,
            residentPositiveByteLimit: residentPositiveByteLimit,
            residentNegativeEntryLimit: residentNegativeEntryLimit,
            residentNegativeByteLimit: residentNegativeByteLimit,
            softQuotaBytes: softQuotaBytes,
            hardQuotaBytes: hardQuotaBytes,
            unreferencedGraceSeconds: unreferencedGraceSeconds,
            quarantineDelaySeconds: quarantineDelaySeconds,
            negativeQuotaBytes: negativeQuotaBytes,
            negativeMaximumAgeSeconds: negativeMaximumAgeSeconds,
            maximumCatalogRecordCount: maximumCatalogRecordCount,
            maximumCatalogScanByteCount: maximumCatalogScanByteCount,
            maximumArtifactScanCount: maximumArtifactScanCount,
            maximumArtifactReconciliationByteCount: maximumArtifactReconciliationByteCount,
            maximumMaintenanceWriteByteCount: maximumMaintenanceWriteByteCount,
            maximumGCStepBudget: maximumGCStepBudget,
            maximumActiveLeaseCount: maximumActiveLeaseCount,
            maximumActiveLeaseBytes: maximumActiveLeaseBytes,
            containerPolicy: containerPolicy
        )
    }

    private func drainRefresh(
        _ store: CodeMapArtifactStore,
        stepBudget: Int = 64,
        maximumCalls: Int = 10000
    ) async throws -> [CodeMapArtifactReconciliationProgress] {
        var result: [CodeMapArtifactReconciliationProgress] = []
        for _ in 0 ..< maximumCalls {
            let progress = try await store.refreshAccounting(stepBudget: stepBudget)
            result.append(progress)
            if progress.isComplete { return result }
        }
        XCTFail("Reconciliation did not complete")
        throw CodeMapArtifactCatalogError.boundedScanExceeded
    }

    private func drainGC(
        _ store: CodeMapArtifactStore,
        stepBudget: Int = 64,
        maximumCalls: Int = 10000
    ) async throws -> [CodeMapArtifactGCProgress] {
        var result: [CodeMapArtifactGCProgress] = []
        for _ in 0 ..< maximumCalls {
            let progress = try await store.runGC(stepBudget: stepBudget)
            result.append(progress)
            if progress.isComplete { return result }
        }
        XCTFail("GC did not complete")
        throw CodeMapArtifactCatalogError.boundedScanExceeded
    }

    private func makeKey(_ text: String) throws -> CodeMapArtifactKey {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let data = Data(text.utf8)
        let fingerprint = FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: Int64(data.count),
            modificationSeconds: 3,
            modificationNanoseconds: 0,
            statusChangeSeconds: 4,
            statusChangeNanoseconds: 0
        )
        let source = CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )
        return try CodeMapArtifactKey(source: source, pipelineIdentity: identity)
    }

    private func makeArtifact(name: String) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            classes: [ClassInfo(name: name, methods: [], properties: [])],
            functions: [
                FunctionInfo(
                    name: "run",
                    parameters: [],
                    returnType: "Void",
                    definitionLine: "func run() -> Void",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: [name]
        )
    }

    private func requireHit(
        _ store: CodeMapArtifactStore,
        key: CodeMapArtifactKey,
        source expectedSource: CodeMapArtifactHitSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> CodeMapArtifactHandle {
        switch try await store.lookup(key: key) {
        case .miss:
            XCTFail("Expected hit", file: file, line: line)
            throw CodeMapArtifactCatalogError.invalidMetadata
        case let .hit(source, handle):
            XCTAssertEqual(source, expectedSource, file: file, line: line)
            return handle
        }
    }

    private func assertMiss(
        _ store: CodeMapArtifactStore,
        key: CodeMapArtifactKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard case .miss = try await store.lookup(key: key) else {
            XCTFail("Expected miss", file: file, line: line)
            return
        }
    }

    private func makeSecureRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(base.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }

    private func artifactURL(root: URL, key: CodeMapArtifactKey) -> URL {
        root.appendingPathComponent("CodeMapArtifacts/v1/artifacts/\(key.shard)/\(key.storageDigestHex)")
    }

    private func metadataURL(root: URL, key: CodeMapArtifactKey) -> URL {
        root.appendingPathComponent("CodeMapArtifacts/v1/catalog/\(key.shard)/\(key.storageDigestHex).meta")
    }

    private func leaseURL(root: URL, key: CodeMapArtifactKey) -> URL {
        root.appendingPathComponent("CodeMapArtifacts/v1/leases/\(key.shard)/\(key.storageDigestHex).lock")
    }

    private static func writeSecureFile(
        parentDescriptor: Int32,
        name: String,
        data: Data
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CodeMapArtifactCatalogError.ioFailure(operation: "test-create", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw CodeMapArtifactCatalogError.ioFailure(operation: "test-mode", code: errno)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw CodeMapArtifactCatalogError.ioFailure(operation: "test-write", code: errno)
                }
                offset += written
            }
        }
    }

    private func regularFiles(at root: URL) throws -> [String] {
        try regularFileURLs(at: root).map {
            String($0.path.dropFirst(root.path.count + 1))
        }.sorted()
    }

    private func regularFileURLs(at root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }
}

/// The lock protects the replacement counter while immutable fixture data is
/// safely captured by the catalog's checked `@Sendable` hook.
private final class MetadataReplacementHook: @unchecked Sendable {
    private let expectedName: String
    private let expectedAdmittedByteCount: UInt64
    private let replacement: Data
    private let metadataURL: URL
    private let lock = NSLock()
    private var count = 0

    var replacementCount: Int {
        lock.withLock { count }
    }

    init(
        expectedName: String,
        expectedAdmittedByteCount: UInt64,
        replacement: Data,
        metadataURL: URL
    ) {
        self.expectedName = expectedName
        self.expectedAdmittedByteCount = expectedAdmittedByteCount
        self.replacement = replacement
        self.metadataURL = metadataURL
    }

    func replace(name: String, admittedByteCount: UInt64) throws {
        guard name == expectedName else { return }
        XCTAssertEqual(admittedByteCount, expectedAdmittedByteCount)
        lock.withLock { count += 1 }
        try replacement.write(to: metadataURL, options: .atomic)
        guard chmod(metadataURL.path, 0o600) == 0 else {
            throw CodeMapArtifactCatalogError.ioFailure(operation: "test-mode", code: errno)
        }
    }
}

/// The lock protects the one-shot branch; semaphores make the post-open
/// cancellation point deterministic without sharing mutable state unsafely.
private final class LeaseAfterOpenGate: @unchecked Sendable {
    let opened = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isFirst = true

    func pauseFirstOpen() {
        let shouldPause = lock.withLock {
            defer { isFirst = false }
            return isFirst
        }
        guard shouldPause else { return }
        opened.signal()
        resume.wait()
    }
}

private enum CodeMapLeaseAttempt {
    case acquired(CodeMapArtifactLease)
    case rejected(CodeMapArtifactLeaseError)
    case unexpected
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    var storeClock: CodeMapArtifactStoreClock {
        CodeMapArtifactStoreClock { [self] in
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
