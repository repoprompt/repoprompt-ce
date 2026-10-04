import Foundation

/// A quit reply must not depend on cooperative cancellation of shutdown work.
/// In particular, a task-group timeout would still join a stuck losing child.
@MainActor
final class AppTerminationCoordinator {
    private var started = false
    private var completed = false
    private var emergencyCleanupStarted = false
    private var deadlineTask: Task<Void, Never>?

    func start(
        gracefulDeadline: Duration = .seconds(5),
        cleanupAllowance: Duration = .seconds(1),
        operation: @escaping @MainActor () async -> Void,
        emergencyCleanup: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            await operation()
            guard !self.emergencyCleanupStarted else { return }
            self.finish(reply: reply)
        }
        deadlineTask = Task { @MainActor in
            do { try await Task.sleep(for: gracefulDeadline) } catch { return }
            guard !self.completed else { return }
            self.emergencyCleanupStarted = true
            // Let in-flight persistence finish if it can; the reply never joins this task.
            Task { @MainActor in
                await emergencyCleanup()
                self.finish(reply: reply)
            }
            // Do not await cleanup: even cleanup itself must not hold the quit reply hostage.
            do { try await Task.sleep(for: cleanupAllowance) } catch { return }
            self.finish(reply: reply)
        }
    }

    private func finish(reply: @MainActor () -> Void) {
        guard !completed else { return }
        completed = true
        deadlineTask?.cancel()
        reply()
        deadlineTask = nil
    }
}
