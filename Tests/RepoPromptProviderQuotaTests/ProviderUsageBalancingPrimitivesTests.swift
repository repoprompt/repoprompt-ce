import Foundation
@testable import RepoPromptProviderQuota
import XCTest

final class ProviderUsageBalancingPrimitivesTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)

    private func reading(_ used: Double, duration: TimeInterval = 18000, age: TimeInterval = 0, resetIn: TimeInterval = 18000, reached: Bool? = nil) -> ProviderQuotaSnapshot {
        let bucketID = ProviderQuotaBucketID.synthesizedDefault
        let window = ProviderQuotaWindow(key: .init(bucketID: bucketID, nativeRole: "primary"), percent: .init(rawValue: used, sense: .used, declaredUpperBound: 100), windowDuration: duration, resetsAt: instant.addingTimeInterval(resetIn), observedAt: instant.addingTimeInterval(-age), isReached: reached)
        return .init(accountKey: .codex(accountID: "test"), buckets: [.init(bucketID: bucketID, displayLabel: nil, nativeModelAlias: nil, scope: .accountWide, reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])], facets: .empty, source: .codexAppServerRead, coverage: .accountWide, observedAt: window.observedAt)
    }

    func testFreshnessResetLimitsAndUnknownFallback() {
        func project(_ value: ProviderQuotaSnapshot) -> ProviderUsageBalancePolicy.Reading {
            ProviderUsageBalancePolicy.reading(value, now: instant)
        }
        XCTAssertFalse(project(reading(89)).nearLimit)
        XCTAssertTrue(project(reading(90)).nearLimit)
        for used in [5.0, 95.0] {
            XCTAssertFalse(project(reading(used, age: 901)).known)
            XCTAssertFalse(project(reading(used, resetIn: -1)).known)
        }
        XCTAssertTrue(project(reading(5, reached: true)).blocked)
        XCTAssertTrue(project(reading(95, resetIn: 100)).nearLimit)
        XCTAssertFalse(project(reading(101)).known)
        XCTAssertFalse(project(reading(80, age: -1)).known)
        for strategy in ProviderUsageBalancePolicy.Strategy.allCases {
            XCTAssertTrue(ProviderUsageBalancePolicy.preferPeer(base: project(reading(100)), peer: .init(), strategy: strategy))
            XCTAssertFalse(ProviderUsageBalancePolicy.preferPeer(base: project(reading(95)), peer: .init(), strategy: strategy))
            XCTAssertFalse(ProviderUsageBalancePolicy.preferPeer(base: project(reading(100)), peer: project(reading(90)), strategy: strategy))
        }
    }

    func testWeeklyPaceExpiryAndFreshnessWithoutCapacityInput() {
        let week: TimeInterval = 604_800
        let ahead = ProviderUsageBalancePolicy.reading(reading(55, duration: week, resetIn: week * 0.75), now: instant)
        let behind = ProviderUsageBalancePolicy.reading(reading(55, duration: week, resetIn: week * 0.25), now: instant)
        XCTAssertTrue(ProviderUsageBalancePolicy.preferPeer(base: ahead, peer: behind, strategy: .evenPace))
        XCTAssertFalse(ProviderUsageBalancePolicy.preferPeer(base: ahead, peer: behind, strategy: .nearLimits))
        XCTAssertTrue(ProviderUsageBalancePolicy.reading(reading(1, duration: week, age: 1800), now: instant).known)
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(reading(1, duration: week, age: 3601), now: instant).known)
        let expiring = ProviderUsageBalancePolicy.reading(reading(70, duration: week, resetIn: 36000), now: instant)
        XCTAssertTrue(ProviderUsageBalancePolicy.preferPeer(base: behind, peer: expiring, strategy: .expiringQuota))
        XCTAssertFalse(ProviderUsageBalancePolicy.preferPeer(base: behind, peer: expiring, strategy: .evenPace))
    }

    func testEvenPaceNaturallyAdaptsToDifferentPlanCapacities() {
        let capacities = [100.0, 400.0] // Simulation truth, never provided to policy.
        var counts = [0, 0]
        for _ in 0 ..< 200 {
            let values = (0 ..< 2).map { index in
                ProviderUsageBalancePolicy.reading(reading(Double(counts[index]) / capacities[index] * 100, duration: 604_800, resetIn: 302_400), now: instant)
            }
            let usePeer = ProviderUsageBalancePolicy.preferPeer(base: values[0], peer: values[1], strategy: .evenPace)
            counts[usePeer ? 1 : 0] += 1
        }
        XCTAssertTrue((30 ... 50).contains(counts[0]), "Capacity-weighted depletion should send roughly one fifth to the smaller plan: \(counts)")
        XCTAssertEqual(counts.reduce(0, +), 200)
    }

    func testMatchingModelLimitAndExhaustionRemainReachedNearReset() {
        let base = reading(10)
        let id = ProviderQuotaBucketID(rawValue: "scoped")
        let window = ProviderQuotaWindow(key: .init(bucketID: id, nativeRole: "weekly"), percent: .init(rawValue: 100, sense: .used, declaredUpperBound: 100), windowDuration: 604_800, resetsAt: instant.addingTimeInterval(60), observedAt: instant)
        let bucket = ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: "native-model", scope: .nativeModelAlias("native-model"), reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])
        let combined = ProviderQuotaSnapshot(accountKey: base.accountKey, buckets: base.buckets + [bucket], facets: .empty, source: base.source, coverage: .accountWide, observedAt: instant)
        XCTAssertTrue(ProviderUsageBalancePolicy.reading(combined, now: instant, modelAliases: ["native-model"]).blocked)
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(combined, now: instant, modelAliases: ["other-model"]).nearLimit)
        XCTAssertTrue(ProviderUsageBalancePolicy.reading(reading(100, duration: 604_800, resetIn: 60), now: instant).blocked)
    }

    func testBudgetSurvivesRestartGapDailyCapAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("budget.json")
        let clock = TestClock(instant)
        let budget = ProviderUsageRefreshBudget(url: url, now: { clock.now() })
        let first = await budget.reserve(profile: "fixture", minimumGap: 1800, dailyLimit: 12)
        XCTAssertTrue(first)
        let reopened = ProviderUsageRefreshBudget(url: url, now: { clock.now() })
        let duplicate = await reopened.reserve(profile: "fixture", minimumGap: 1800, dailyLimit: 12)
        XCTAssertFalse(duplicate)
        for _ in 1 ..< 12 {
            clock.advance(1800)
            let admitted = await reopened.reserve(profile: "fixture", minimumGap: 1800, dailyLimit: 12)
            XCTAssertTrue(admitted)
        }
        clock.advance(1800)
        let capped = await reopened.reserve(profile: "fixture", minimumGap: 1800, dailyLimit: 12)
        XCTAssertFalse(capped)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try Data("bad json".utf8).write(to: url)
        let corrupt = ProviderUsageRefreshBudget(url: url, now: { clock.now() })
        let refused = await corrupt.reserve(profile: "fixture", minimumGap: 1800, dailyLimit: 12)
        XCTAssertFalse(refused)
    }

    func testAdvisoryReadBypassesOnlyStartupLatchNotBackoffOrSingleFlight() async {
        let value = reading(10)
        let clock = TestClock(instant)
        let reads = Counter()
        let service = ProviderAccountQuotaService(periodicReads: false, now: { clock.now() }, read: { _ in
            await reads.increment()
            return value
        })
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        clock.advance(1800)
        await service.refreshOnForeground()
        let initial = await reads.count
        XCTAssertEqual(initial, 1)
        await service.refreshForAdvisory { false }
        let denied = await reads.count
        XCTAssertEqual(denied, 1)
        await service.refreshForAdvisory { true }
        let admitted = await reads.count
        XCTAssertEqual(admitted, 2)
        await service.refreshForAdvisory { true }
        let floored = await reads.count
        XCTAssertEqual(floored, 2)
        await service.shutdown()
        withExtendedLifetime(stream) {}
    }

    func testCancellingPendingAdvisoryNeverCancelsInterleavedManualRead() async {
        let value = reading(10)
        let manualValue = reading(20)
        let clock = TestClock(instant)
        let admission = Gate()
        let manualRead = Gate()
        let reads = Counter()
        let service = ProviderAccountQuotaService(periodicReads: false, now: { clock.now() }, read: { context in
            await reads.increment()
            if context.userInitiated { _ = await manualRead.wait()
                return manualValue
            }
            return value
        })
        await service.setEnabled(true)
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        while let status = await iterator.next() {
            if case .loaded = status { break }
        }
        clock.advance(1800)
        let requestID = UUID()
        let advisory = Task { await service.refreshForAdvisory(requestID: requestID) { await admission.wait() } }
        await admission.started()
        let manual = Task { await service.refreshNow() }
        await manualRead.started()
        await service.cancelAdvisoryRefresh(requestID: requestID)
        await admission.release()
        await advisory.value
        await manualRead.release()
        await manual.value
        let cached = await service.latestSnapshot()
        let count = await reads.count
        XCTAssertEqual(cached, manualValue)
        XCTAssertEqual(count, 2, "Only startup and the still-authorized manual read")
        await service.shutdown()
        withExtendedLifetime(stream) {}
    }

    private actor Gate {
        private var waiting: CheckedContinuation<Bool, Never>?
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        func wait() async -> Bool {
            hasStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            return await withCheckedContinuation { waiting = $0 }
        }

        func started() async {
            if hasStarted { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            waiting?.resume(returning: true)
            waiting = nil
        }
    }

    private actor Counter {
        var count = 0
        func increment() {
            count += 1
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) {
            self.date = date
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            date = date.addingTimeInterval(seconds)
        }
    }
}
