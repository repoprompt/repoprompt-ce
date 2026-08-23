import Foundation
import RepoPromptRuntimeModel
@testable import RepoPromptServerHost
import XCTest

final class AuthorityHostShutdownDeadlineTests: XCTestCase {
    func testFirstShutdownBudgetCannotBeShortenedOrExtendedByLaterCallers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-shutdown-budget-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "shutdown-budget-owner",
            servingMode: .server
        )
        let clock = InjectedMonotonicClock()
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: descriptor)
        )
        let first = AuthorityHostShutdownBudget(total: .seconds(30), now: { clock.now() })
        _ = await host.beginShutdown(using: first)
        let laterShorter = AuthorityHostShutdownBudget(total: .zero, now: { clock.now() })
        let report = await host.shutdown(reason: "same-budget", using: laterShorter)

        XCTAssertTrue(report.clean)
        XCTAssertFalse(report.budgetExhausted)
        XCTAssertTrue(report.leaseReleased)
        XCTAssertEqual(report.actions.last, .leaseReleased)
    }

    func testEveryShutdownPhaseConsumesOneInjectedMonotonicDeadline() async throws {
        for target in AuthorityHostShutdownPhase.allCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rp-shutdown-deadline-\(target.rawValue)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let descriptor = try AuthorityNamespaceDescriptor(
                storageRoot: directory.path,
                databasePath: directory.appendingPathComponent("state.sqlite").path,
                profile: "shutdown-\(target.rawValue)",
                servingMode: .server
            )
            let clock = InjectedMonotonicClock()
            let hooks = AuthorityHostShutdownHooks(
                beforePhase: { phase in
                    if phase == target { clock.advance(by: .seconds(30)) }
                },
                operationOverride: { phase in
                    switch phase {
                    case .providerQuiesce, .directRuntimeDrain, .durabilityStop, .durabilitySweep, .eventOutboxDrain:
                        { @Sendable in }
                    default:
                        nil
                    }
                }
            )
            let host = try await RepoPromptAuthorityHostFactory.start(
                configuration: .init(namespace: descriptor, shutdownHooks: hooks)
            )
            let budget = AuthorityHostShutdownBudget(
                total: .seconds(30),
                now: { clock.now() }
            )
            let report = await host.shutdown(
                reason: "injected-\(target.rawValue)",
                using: budget,
                childDrainTimedOut: target == .processFencing
            )

            XCTAssertFalse(report.clean, "phase=\(target)")
            XCTAssertTrue(report.budgetExhausted, "phase=\(target)")
            XCTAssertTrue(report.timedOutPhases.contains(target), "phase=\(target) report=\(report)")
            XCTAssertEqual(report.elapsed, .seconds(30), "phase=\(target)")
            XCTAssertFalse(report.leaseReleased, "phase=\(target)")
            XCTAssertNotEqual(report.actions.last, .leaseReleased, "phase=\(target)")

            await host.forceCleanupAfterFailedShutdownForTesting()
        }
    }

    func testUncooperativeAdmittedReadAndMutationRetainLeaseWithLaterPhaseBudgetRemaining() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-shutdown-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "shutdown-mutation",
            servingMode: .server
        )
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(
                namespace: descriptor,
                mutationDrainMaximum: .milliseconds(20),
                admittedWorkDrainMaximum: .milliseconds(20)
            )
        )
        let mutationBlocker = UncooperativeOperationBlocker()
        let readBlocker = UncooperativeOperationBlocker()
        let capability = await host.mutationGate.capability()
        let readCapability = await host.mutationGate.readCapability()
        let mutation = Task {
            try await capability.perform {
                await mutationBlocker.waitIgnoringCancellation()
                return 1
            }
        }
        let read = Task {
            try await readCapability.perform {
                await readBlocker.waitIgnoringCancellation()
                return 1
            }
        }
        while true {
            let snapshot = await host.mutationGate.snapshot()
            if snapshot.inFlightMutations == 1, snapshot.inFlightReads == 1 { break }
            await Task.yield()
        }

        let report = await host.shutdown(reason: "uncooperative-admitted-work", deadline: .seconds(1))
        XCTAssertFalse(report.clean)
        XCTAssertTrue(report.timedOutPhases.contains(.mutationDrain))
        XCTAssertTrue(report.timedOutPhases.contains(.admittedWorkDrain))
        XCTAssertFalse(report.budgetExhausted)
        XCTAssertFalse(report.leaseReleased)
        XCTAssertNotEqual(report.actions.last, .leaseReleased)
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }
        do {
            _ = try await capability.perform { 2 }
            XCTFail("stale capability unexpectedly admitted after forced close")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        }

        await mutationBlocker.release()
        await readBlocker.release()
        _ = try? await mutation.value
        _ = try? await read.value
        await host.forceCleanupAfterFailedShutdownForTesting()
        let reacquired = try AuthorityNamespaceLease.acquire(descriptor).lease
        reacquired.release()
    }

    func testProviderQuiesceFailureRetainsLease() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-provider-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "provider-failure",
            servingMode: .server
        )
        let hooks = AuthorityHostShutdownHooks(operationOverride: { phase in
            guard phase == .providerQuiesce else { return nil }
            return { @Sendable in throw ProviderQuiesceTestError.failed }
        })
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: descriptor, shutdownHooks: hooks)
        )

        let report = await host.shutdown(reason: "provider-failure", deadline: .seconds(1))
        XCTAssertFalse(report.clean)
        XCTAssertFalse(report.leaseReleased)
        XCTAssertTrue(report.timedOutPhases.contains(.providerQuiesce))
        XCTAssertThrowsError(try AuthorityNamespaceLease.acquire(descriptor)) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .authorityHostConflict)
        }

        await host.forceCleanupAfterFailedShutdownForTesting()
    }
}

private enum ProviderQuiesceTestError: Error {
    case failed
}

private final class InjectedMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 1

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return ticks
    }

    func advance(by duration: Duration) {
        let components = duration.components
        let nanos = UInt64(max(0, components.seconds)) * 1_000_000_000
            + UInt64(max(0, components.attoseconds / 1_000_000_000))
        lock.lock()
        ticks &+= nanos
        lock.unlock()
    }
}

private actor UncooperativeOperationBlocker {
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
