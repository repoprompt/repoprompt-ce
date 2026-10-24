import Foundation

/// Observes process signals on behalf of `AppTerminationSignalRouter`.
///
/// Disposition suppression is a router responsibility rather than an implementation detail so
/// that its ordering against observation stays verifiable without delivering real signals.
protocol TerminationSignalObserving: AnyObject {
    /// Suppresses `signal`'s default disposition. Without this the kernel terminates the process
    /// the moment the signal arrives, before any observer can run.
    func ignoreDefaultDisposition(for signal: Int32)

    /// Delivers subsequent occurrences of `signal` to `handler`.
    func observe(_ signal: Int32, handler: @escaping () -> Void)
}

/// Bridges POSIX signals onto the main queue where AppKit lifecycle work is serialized.
final class DispatchTerminationSignalObserver: TerminationSignalObserving {
    /// Dispatch sources only remain active while retained, so the observer owns them for its
    /// lifetime rather than relying on the caller to preserve an implementation detail.
    private var sources: [Int32: any DispatchSourceSignal] = [:]

    func ignoreDefaultDisposition(for signal: Int32) {
        Darwin.signal(signal, SIG_IGN)
    }

    func observe(_ signal: Int32, handler: @escaping () -> Void) {
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
        source.setEventHandler(handler: handler)
        sources[signal] = source
        source.activate()
    }
}

/// Routes externally delivered termination signals into the app's graceful quit sequence, so
/// tooling that stops the app with a signal still runs `applicationShouldTerminate` — the only
/// path that joins in-flight agent processes and releases their launch-config leases.
final class AppTerminationSignalRouter {
    /// Signals ordinary process tooling uses to stop the app.
    static let routedSignals: [Int32] = [SIGTERM]

    private let observer: any TerminationSignalObserving
    private let requestGracefulTermination: () -> Void
    private var isInstalled = false
    private var hasRequestedTermination = false

    init(
        observer: any TerminationSignalObserving,
        requestGracefulTermination: @escaping () -> Void
    ) {
        self.observer = observer
        self.requestGracefulTermination = requestGracefulTermination
    }

    /// Suppresses each routed signal's default disposition, then routes its delivery into
    /// graceful termination.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        for signal in Self.routedSignals {
            observer.ignoreDefaultDisposition(for: signal)
            observer.observe(signal) { [weak self] in
                guard let self, !hasRequestedTermination else { return }
                hasRequestedTermination = true
                requestGracefulTermination()
            }
        }
    }
}
