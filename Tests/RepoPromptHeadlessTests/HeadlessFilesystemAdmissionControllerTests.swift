@testable import RepoPromptHeadless
import XCTest

final class HeadlessFilesystemAdmissionControllerTests: XCTestCase {
    func testPolicyWeightsOnlyConcurrentFilesystemTools() {
        let expectedWeights: [String: Int] = [
            "file_search": 4,
            "get_file_tree": 1,
            "get_code_structure": 1,
            "read_file": 1
        ]

        XCTAssertEqual(HeadlessFilesystemAdmissionPolicy.capacity, 4)
        for registration in HeadlessToolRegistry.registrations {
            XCTAssertEqual(
                HeadlessFilesystemAdmissionPolicy.weight(forToolNamed: registration.name),
                expectedWeights[registration.name],
                "Unexpected filesystem admission policy for \(registration.name)"
            )
        }
    }

    func testWeightedCapacityUsesStrictFIFOWithoutBypassingHeavyWaiter() async throws {
        let controller = HeadlessFilesystemAdmissionController(capacity: 4)
        let active = try await controller.acquire(weight: 3)

        let heavy = Task { try await controller.acquire(weight: 2) }
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 3,
                activeLeaseCount: 1,
                waitingWeights: [2]
            ),
            controller: controller
        )

        let light = Task { try await controller.acquire(weight: 1) }
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 3,
                activeLeaseCount: 1,
                waitingWeights: [2, 1]
            ),
            controller: controller
        )

        XCTAssertTrue(active.release())
        XCTAssertFalse(active.release(), "A lease must release its weight exactly once")
        let heavyLease = try await heavy.value
        let lightLease = try await light.value
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 3,
                activeLeaseCount: 2,
                waitingWeights: []
            ),
            controller: controller
        )

        XCTAssertTrue(heavyLease.release())
        XCTAssertTrue(lightLease.release())
        try await waitUntilIdle(controller)
    }

    func testQueuedCancellationRemovesWaiterWithoutConsumingWeight() async throws {
        let controller = HeadlessFilesystemAdmissionController(capacity: 4)
        let active = try await controller.acquire(weight: 3)
        let queued = Task { try await controller.acquire(weight: 2) }
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 3,
                activeLeaseCount: 1,
                waitingWeights: [2]
            ),
            controller: controller
        )
        let following = Task { try await controller.acquire(weight: 1) }
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 3,
                activeLeaseCount: 1,
                waitingWeights: [2, 1]
            ),
            controller: controller
        )

        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Expected queued admission cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let followingLease = try await following.value
        let snapshot = await controller.snapshotForTesting()
        XCTAssertEqual(
            snapshot,
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 4,
                activeLeaseCount: 2,
                waitingWeights: []
            )
        )

        active.release()
        followingLease.release()
        try await waitUntilIdle(controller)
    }

    func testInvalidWeightsFailWithoutChangingAdmissionState() async {
        let controller = HeadlessFilesystemAdmissionController(capacity: 4)

        for weight in [-1, 0, 5] {
            do {
                _ = try await controller.acquire(weight: weight)
                XCTFail("Expected weight \(weight) to fail")
            } catch let error as HeadlessFilesystemAdmissionController.AdmissionError {
                XCTAssertEqual(error, .invalidWeight(weight, capacity: 4))
            } catch {
                XCTFail("Unexpected error for weight \(weight): \(error)")
            }
        }

        let snapshot = await controller.snapshotForTesting()
        XCTAssertEqual(
            snapshot,
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 0,
                activeLeaseCount: 0,
                waitingWeights: []
            )
        )
    }

    private func waitUntilIdle(_ controller: HeadlessFilesystemAdmissionController) async throws {
        try await waitForSnapshot(
            HeadlessFilesystemAdmissionController.Snapshot(
                activeWeight: 0,
                activeLeaseCount: 0,
                waitingWeights: []
            ),
            controller: controller
        )
    }

    private func waitForSnapshot(
        _ expected: HeadlessFilesystemAdmissionController.Snapshot,
        controller: HeadlessFilesystemAdmissionController
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await controller.snapshotForTesting() == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for admission snapshot \(expected)")
    }
}
