import Foundation
import RepoPromptDomainRuntime
import XCTest

final class HostResourceCapacityTests: XCTestCase {
    private func capacity(
        cores: Int = 8,
        performance: Int = 4,
        gib: UInt64 = 24,
        memory: HostResourceSample.Pressure = .normal,
        thermal: HostResourceSample.Pressure = .normal,
        descriptors: Int = 4096,
        open: Int = 64,
        availableMiB: UInt64? = nil,
        growthMiB: UInt64 = 0
    ) -> HostResourceCapacity {
        HostResourceCapacity.resolve(HostResourceSample(
            logicalCores: cores, performanceCores: performance, memoryBytes: gib * 1024 * 1024 * 1024,
            memoryPressure: memory, thermalPressure: thermal,
            descriptorLimit: descriptors, openDescriptors: open,
            availableMemoryBytes: availableMiB.map { $0 * 1024 * 1024 },
            memoryGrowthBytesPerSecond: growthMiB * 1024 * 1024
        ))
    }

    func testPolicyScalesWithResourcesAndReservesHostHeadroom() {
        let small = capacity()
        XCTAssertEqual(small.total, 8)
        XCTAssertEqual(small.cpu, 8)
        XCTAssertEqual(small.io, 8)
        XCTAssertEqual(small.subprocess, 8)
        XCTAssertEqual(small.background, 4)
        let large = capacity(cores: 24, performance: 16, gib: 64)
        XCTAssertEqual(large.total, 24)
        XCTAssertEqual(large.cpu, 24)
        XCTAssertEqual(large.background, 12)
        XCTAssertGreaterThan(large.io, small.io)
        let lowMemory = capacity(cores: 64, performance: 48, gib: 4)
        XCTAssertEqual(lowMemory.total, 7)
        XCTAssertEqual(lowMemory.cpu, 7)
    }

    func testPressureReducesWorkWithoutZeroingForegroundProgress() {
        for memory in [HostResourceSample.Pressure.normal, .warning, .critical] {
            for thermal in [HostResourceSample.Pressure.normal, .warning, .critical] {
                let value = capacity(memory: memory, thermal: thermal)
                XCTAssertGreaterThanOrEqual(value.total, 1)
                XCTAssertLessThanOrEqual(value.cpu, value.total)
                XCTAssertLessThanOrEqual(value.io, value.total)
                XCTAssertLessThanOrEqual(value.subprocess, value.cpu)
                XCTAssertLessThanOrEqual(value.background, value.total)
                if memory == .critical || thermal == .critical { XCTAssertEqual(value.total, 1) }
            }
        }
        XCTAssertEqual(capacity(memory: .warning), capacity())
        XCTAssertEqual(capacity(thermal: .warning).cpu, 4)
        XCTAssertEqual(capacity(cores: 1, performance: 1, gib: 1).total, 1)
    }

    func testMeasuredHeadroomAndGrowthNotWarningFlagShapeMemoryBackoff() {
        let nominal = capacity(availableMiB: 4096)
        XCTAssertEqual(nominal.total, 8)
        XCTAssertEqual(capacity(memory: .warning, availableMiB: 4096), nominal)
        // 1 GiB headroom minus the 768 MiB host reserve, half for 64 MiB workers.
        XCTAssertEqual(capacity(availableMiB: 1024).total, 2)
        XCTAssertEqual(capacity(availableMiB: 512).total, 1)
        // Compression/swapout growth of 1.5 GiB/s consumes the two-second headroom.
        XCTAssertEqual(capacity(availableMiB: 4096, growthMiB: 1536).total, 2)
        XCTAssertEqual(capacity(thermal: .warning, availableMiB: 4096).total, 8)
        XCTAssertEqual(capacity(thermal: .warning, availableMiB: 4096).cpu, 4)
        // Noncritical headroom backoff must not become a hard background pause.
        XCTAssertEqual(capacity(availableMiB: 512).background, 1)
        XCTAssertEqual(capacity(memory: .critical, availableMiB: 512).background, 0)
        // A hardware-limited single-core host must still make background progress.
        XCTAssertEqual(capacity(cores: 1, performance: 1).background, 1)
    }

    func testShrinkingCapturedContentReturnsUnusedReservationWithoutAnUpgradeWait() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let first = try await budget.reserveContent()
        let next = Task { try await budget.reserveContent() }
        try await waitForWaiters(1, budget: budget)
        XCTAssertEqual(budget.snapshot().activeContentUnits, 8)
        first.captured(utf8Bytes: 1000)
        XCTAssertEqual(budget.snapshot().activeContentUnits, 1)
        // The conservative 8-unit next capture still waits, rather than overspending.
        XCTAssertEqual(budget.snapshot().waiting, 1)
        first.release()
        first.captured(utf8Bytes: 0) // late shrink must neither release twice nor go negative
        let second = try await next.value
        XCTAssertEqual(budget.snapshot().activeContentUnits, 8)
        second.captured(utf8Bytes: 1000)
        let small = try await budget.acquire(.io)
        small.release()
        second.release()
        XCTAssertEqual(budget.snapshot().activeContentUnits, 0)
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testDescriptorExhaustionSuspendsOnlyDescriptorWork() {
        let exhausted = capacity(descriptors: 256, open: 256)
        XCTAssertEqual(exhausted.io, 0)
        XCTAssertEqual(exhausted.subprocess, 0)
        XCTAssertGreaterThan(exhausted.cpu, 0)
        XCTAssertGreaterThan(exhausted.connections, 0)
    }

    func testPressureShrinkDoesNotRevokeAndRecoveryWakesIdleQueue() async throws {
        let budget = HostResourceBudget(capacity: capacity())
        let first = try await budget.acquire(.cpu)
        let second = try await budget.acquire(.subprocess)
        budget.updateCapacity(capacity(memory: .critical))
        let next = Task { try await budget.acquire(.cpu) }
        try await waitForWaiters(1, budget: budget)
        XCTAssertEqual(budget.snapshot().active, 2)
        first.release()
        XCTAssertEqual(budget.snapshot().active, 1)
        XCTAssertEqual(budget.snapshot().waiting, 1)
        second.release()
        let lease = try await next.value
        XCTAssertEqual(budget.snapshot().active, 1)
        lease.release()
        XCTAssertEqual(budget.snapshot().active, 0)

        budget.updateCapacity(capacity(descriptors: 256, open: 256))
        let io = Task { try await budget.acquire(.io) }
        try await waitForWaiters(1, budget: budget)
        let cpu = try await budget.acquire(.cpu) // blocked I/O must not head-of-line block CPU
        cpu.release()
        XCTAssertEqual(budget.snapshot().active, 0)
        budget.updateCapacity(capacity())
        let ioLease = try await io.value
        ioLease.release()
        XCTAssertEqual(budget.snapshot().waiting, 0)
    }

    func testCPUAndSubprocessesShareOneCPUCeiling() async throws {
        let budget = HostResourceBudget(capacity: capacity(thermal: .warning))
        let leases = try await (0 ..< 4).asyncLeases(budget)
        let process = Task { try await budget.acquire(.subprocess) }
        try await waitForWaiters(1, budget: budget)
        let io = try await budget.acquire(.io)
        XCTAssertEqual(budget.snapshot().active, 5)
        io.release()
        leases[0].release()
        let processLease = try await process.value
        XCTAssertEqual(budget.snapshot().activeByKind[.subprocess], 1)
        leases.forEach { $0.release() }
        processLease.release()
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testIOAndGitCannotSpendTheSameDescriptorHeadroom() async throws {
        for (open, processCount) in [(180, 2), (249, 1)] {
            let envelope = capacity(descriptors: 256, open: open)
            let budget = HostResourceBudget(capacity: envelope)
            var processes: [HostResourceBudget.Lease] = []
            for _ in 0 ..< processCount {
                try await processes.append(budget.acquire(.subprocess))
            }
            let io = Task { try await budget.acquire(.io) }
            try await waitForWaiters(1, budget: budget)
            XCTAssertEqual(budget.snapshot().activeDescriptorUnits, processCount * HostResourceCapacity.subprocessDescriptorCost)
            // Pure CPU can still advance without spending descriptor headroom.
            let cpu = try await budget.acquire(.cpu)
            cpu.release()
            XCTAssertEqual(budget.snapshot().waiting, 1)
            processes[0].release()
            let ioLease = try await io.value
            XCTAssertLessThanOrEqual(budget.snapshot().activeDescriptorUnits, envelope.descriptorBudget)
            processes.forEach { $0.release() }
            ioLease.release()
            XCTAssertEqual(budget.snapshot().active, 0)
        }
    }

    func testCancellationStormLeavesNoWaitersOrPrematurelyReleasedOwners() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let owner = try await budget.acquire(.cpu)
        let queued = (0 ..< 1000).map { _ in Task { try await budget.acquire(.io) } }
        try await waitForWaiters(1000, budget: budget)
        queued.forEach { $0.cancel() }
        for task in queued {
            switch await task.result {
            case .success: XCTFail("Cancelled queued work must not acquire")
            case let .failure(error): XCTAssertTrue(error is CancellationError)
            }
        }
        XCTAssertEqual(budget.snapshot().waiting, 0)
        XCTAssertEqual(budget.snapshot().active, 1)
        owner.release()
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testRunningCancellationRetainsLeaseUntilPhysicalSettlement() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let entered = expectation(description: "physical worker entered")
        let gate = HostResourceSettlementGate()
        let worker = Task {
            try await budget.withPermit(.cpu) {
                entered.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        worker.cancel()
        XCTAssertEqual(budget.snapshot().active, 1)
        await gate.release()
        _ = try await worker.value
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testBackgroundCannotOccupyForegroundReserveAndReleaseIsIdempotent() async throws {
        let budget = HostResourceBudget(capacity: capacity(thermal: .warning))
        let first = try await budget.acquire(.cpu, background: true)
        let second = try await budget.acquire(.io, background: true)
        let background = Task { try await budget.acquire(.io, background: true) }
        try await waitForWaiters(1, budget: budget)
        let foreground = try await budget.acquire(.io)
        XCTAssertEqual(budget.snapshot().activeBackground, 2)
        XCTAssertEqual(budget.snapshot().active, 3)
        first.release()
        XCTAssertFalse(first.release())
        let third = try await background.value
        second.release()
        third.release()
        foreground.release()
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testRetainedContentIsBoundedWithoutDeadlockingItsPhysicalChildren() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let reservation = try await budget.acquire(.retainedContent)
        let overflow = Task { try await budget.acquire(.retainedContent) }
        try await waitForWaiters(1, budget: budget)
        let io = try await budget.acquire(.io)
        io.release()
        let cpu = try await budget.acquire(.cpu)
        cpu.release()
        XCTAssertEqual(budget.snapshot().active, 0)
        XCTAssertEqual(budget.snapshot().activeByKind[.retainedContent], 1)
        overflow.cancel()
        _ = await overflow.result
        reservation.release()
        XCTAssertTrue(budget.snapshot().activeByKind.isEmpty)
    }

    func testDeadlineExpiresWithoutExecutingOrLeakingAQueuedGrant() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let owner = try await budget.acquire(.cpu)
        let expiry = HostResourceSettlementGate()
        let deadline = MCPDomainAdmissionDeadline(
            instant: .seconds(1), now: { .zero }, sleep: { _ in await expiry.wait() }
        )
        let queued = Task { try await budget.acquire(.io, deadline: deadline) }
        try await waitForWaiters(1, budget: budget)
        await expiry.release()
        switch await queued.result {
        case .success: XCTFail("Expired queued work must not acquire")
        case let .failure(error): XCTAssertTrue(error is MCPDomainAdmissionDeadline.Expired)
        }
        XCTAssertEqual(budget.snapshot().waiting, 0)
        XCTAssertEqual(budget.snapshot().active, 1)
        owner.release()
    }

    func testDefaultGUIHeadroomRetainsProgressAndConnectionCompatibility() {
        for open in [100, 150, 177, 185, 192, 248] {
            let value = capacity(descriptors: 256, open: open)
            XCTAssertGreaterThan(value.io, 0, "open=\(open)")
            XCTAssertGreaterThan(value.subprocess, 0, "open=\(open)")
            XCTAssertEqual(value.connections, 128)
        }
        XCTAssertEqual(capacity(descriptors: 256, open: 255).io, 0)
    }

    func testTrueQueueOverflowIsExplicitAndKeepsPhysicalOwnership() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical), maximumWaiters: 0)
        let owner = try await budget.acquire(.cpu)
        do {
            _ = try await budget.acquire(.io)
            XCTFail("Overload must not look like an empty successful operation")
        } catch { XCTAssertTrue(error is HostResourceBudget.AdmissionError) }
        XCTAssertEqual(budget.snapshot().active, 1)
        XCTAssertEqual(budget.snapshot().waiting, 0)
        owner.release()
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testCriticalPressureSuspendsBackgroundButNotForeground() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let background = Task { try await budget.acquire(.cpu, background: true) }
        try await waitForWaiters(1, budget: budget)
        let foreground = try await budget.acquire(.io)
        XCTAssertEqual(budget.snapshot().activeBackground, 0)
        foreground.release()
        budget.updateCapacity(capacity())
        let backgroundLease = try await background.value
        backgroundLease.release()
        XCTAssertEqual(budget.snapshot().active, 0)
    }

    func testFreeCapacityDoesNotReapplyAnAlreadyAdmittedStartDeadline() async throws {
        let budget = HostResourceBudget(capacity: capacity(memory: .critical))
        let pausedBackground = Task { try await budget.acquire(.cpu, background: true) }
        defer { pausedBackground.cancel() }
        try await waitForWaiters(1, budget: budget)
        let expired = MCPDomainAdmissionDeadline(instant: .zero, now: { .seconds(1) }, sleep: { _ in })
        let lease = try await budget.acquire(.subprocess, deadline: expired)
        lease.release()
        pausedBackground.cancel()
        _ = await pausedBackground.result
        XCTAssertEqual(budget.snapshot().active, 0)
        XCTAssertEqual(budget.snapshot().waiting, 0)
    }

    func testRecoveryDebouncesIncreasesNotDropsAndToleratesFDJitter() {
        var recovery = HostResourceRecovery()
        let normal = capacity()
        let critical = capacity(memory: .critical)
        XCTAssertEqual(recovery.ingest(normal, now: 0), normal)
        XCTAssertEqual(recovery.ingest(critical, now: 1), critical)
        XCTAssertEqual(recovery.ingest(normal, now: 2).cpu, critical.cpu)
        let jitter = capacity(descriptors: 256, open: 180)
        XCTAssertEqual(recovery.ingest(jitter, now: 1_000_000_002).cpu, critical.cpu)
        let recovered = recovery.ingest(normal, now: 2_000_000_002)
        XCTAssertEqual(recovered.cpu, normal.cpu)
        XCTAssertEqual(recovered.io, jitter.io)
        // CPU/memory drop immediately while the simultaneous fd-headroom increase
        // remains debounced. Assert the entire mixed envelope, not just one field.
        let criticalWithConservativeFDs = capacity(memory: .critical, descriptors: 256, open: 180)
        XCTAssertEqual(recovery.ingest(critical, now: 2_000_000_003), criticalWithConservativeFDs)
        XCTAssertEqual(recovery.ingest(critical, now: 4_000_000_003), critical)
    }

    private func waitForWaiters(_ count: Int, budget: HostResourceBudget) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while budget.snapshot().waiting != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(budget.snapshot().waiting, count)
    }
}

private extension Range<Int> {
    func asyncLeases(_ budget: HostResourceBudget) async throws -> [HostResourceBudget.Lease] {
        var leases: [HostResourceBudget.Lease] = []
        for _ in self {
            try await leases.append(budget.acquire(.cpu))
        }
        return leases
    }
}

private actor HostResourceSettlementGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
