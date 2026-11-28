import AppKit

/// One irreversible, bounded shutdown shared by AppKit and update installation.
/// Never cancel an updater's termination request: Sparkle owns installation and relaunch.
@MainActor
final class AppTerminationCoordinator {
    private(set) var isReady = false
    private var started = false
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTimer: Timer?
    private var pendingReply: (() -> Void)?
    private var installationContinuation: (() -> Void)?
    private let timeout: TimeInterval
    private let freeze: () -> Void
    private let cleanup: () async -> Void
    private let requestTermination: () -> Void

    init(
        timeout: TimeInterval = 15,
        freeze: @escaping () -> Void,
        cleanup: @escaping () async -> Void,
        requestTermination: @escaping () -> Void
    ) {
        self.timeout = timeout
        self.freeze = freeze
        self.cleanup = cleanup
        self.requestTermination = requestTermination
    }

    func shouldTerminate(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        if isReady {
            invalidateDeadline()
            pendingReply = nil
            return .terminateNow
        }
        pendingReply = reply
        start()
        return .terminateLater
    }

    /// Sparkle's continuation, not a second independent quit, resumes installation.
    func postponeInstallation(resume: @escaping () -> Void) -> Bool {
        if isReady { return false }
        // Sparkle promises one outstanding installation. Do not replace its continuation.
        guard installationContinuation == nil else { return true }
        installationContinuation = resume
        start()
        return true
    }

    private func start() {
        guard !started else { return }
        started = true
        freeze()
        // A main-queue timer/task cannot rescue termination entered from a main-queue
        // callback: AppKit's nested termination loop holds that queue. A run-loop timer can.
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deadlineExceeded() }
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        cleanupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await cleanup()
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    private func finish() {
        guard !isReady else { return }
        isReady = true
        cleanupTask = nil
        if let resume = installationContinuation {
            installationContinuation = nil
            // Installation owns the handoff even if an ordinary quit arrived meanwhile.
            // Give Sparkle a separate bounded interval; never race resume with another quit.
            invalidateDeadline()
            let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handoffDeadlineExceeded() }
            }
            deadlineTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { resume() }
            }
        } else {
            approveTermination()
        }
    }

    private func deadlineExceeded() {
        print("Application shutdown deadline exceeded; proceeding with best-effort cleanup")
        cleanupTask?.cancel()
        finish()
    }

    private func handoffDeadlineExceeded() {
        print("Sparkle shutdown handoff deadline exceeded; completing committed quit")
        approveTermination()
    }

    private func approveTermination() {
        invalidateDeadline()
        if let reply = pendingReply {
            pendingReply = nil
            reply()
        } else {
            requestTermination()
        }
    }

    private func invalidateDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
    }
}
