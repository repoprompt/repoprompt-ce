@testable import RepoPromptApp
import XCTest

final class FileToolLookupResolutionWaiterTests: XCTestCase {
    @MainActor
    func testCancellingOneCallerWaiterDoesNotCancelSharedResolutionTask() async throws {
        let gate = CacheResolutionGate()
        let sharedTask: Task<MCPServerViewModel.FileToolLookupResolution, Never> = Task { @MainActor in
            await gate.wait()
            return .success(.visibleWorkspace)
        }
        let cancelledWaiter = Task { @MainActor in
            try await MCPServerViewModel.FileToolLookupResolutionWaiter().value(from: sharedTask)
        }
        let survivingWaiter = Task { @MainActor in
            try await MCPServerViewModel.FileToolLookupResolutionWaiter().value(from: sharedTask)
        }

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Cancelling one caller must end only that caller's await")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(sharedTask.isCancelled)

        await gate.release()

        let survivingValue = try await survivingWaiter.value
        XCTAssertEqual(try survivingValue.get(), .visibleWorkspace)
        XCTAssertFalse(sharedTask.isCancelled)
    }
}

private actor CacheResolutionGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
