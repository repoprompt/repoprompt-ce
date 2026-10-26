import AppKit

/// Owns the interval before an overlay exists. The scheduler is injectable so
/// lifecycle races can be exercised without wall-clock delays or visible windows.
@MainActor
final class TooltipPendingPresentation {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> DispatchWorkItem

    private let scheduleWork: Scheduler
    private var work: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var wasKey = false
    private weak var owner: NSWindow?
    private var ownerID: ObjectIdentifier?
    private var onEnd: (() -> Void)?

    init(scheduleWork: @escaping Scheduler = { delay, action in
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }) {
        self.scheduleWork = scheduleWork
    }

    deinit {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        work?.cancel()
    }

    func schedule(
        owner: NSWindow?,
        after delay: TimeInterval,
        isEligible: @escaping (_ owner: NSWindow, _ wasKey: Bool) -> Bool,
        onEnd: @escaping () -> Void = {},
        show: @escaping () -> Void
    ) {
        cancel()
        self.onEnd = onEnd
        if let owner { observe(owner) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }))
        let token = generation
        work = scheduleWork(delay) { [weak self] in
            guard let self, generation == token else { return }
            let eligible = self.owner.map { isEligible($0, self.wasKey) } ?? false
            cancel()
            guard eligible else { return }
            show()
        }
    }

    /// The first geometry report may arrive after hover. Bind it without
    /// restarting the delay, but never carry a hover across owner transitions.
    func updateOwner(_ window: NSWindow?) {
        guard work != nil else { return }
        guard let window else {
            cancel()
            return
        }
        if let ownerID {
            if ownerID != ObjectIdentifier(window) { cancel() }
        } else {
            observe(window)
        }
    }

    func cancel() {
        generation &+= 1
        work?.cancel()
        work = nil
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        owner = nil
        ownerID = nil
        let ended = onEnd
        onEnd = nil
        ended?()
    }

    private func observe(_ owner: NSWindow) {
        self.owner = owner
        ownerID = ObjectIdentifier(owner)
        wasKey = owner.isKeyWindow
        for notification in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMoveNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didMiniaturizeNotification
        ] {
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: notification, object: owner, queue: .main) { [weak self] _ in
                // AppKit owner events are delivered on the main thread. Invalidate
                // synchronously: a queued Task could lose the race with the timer.
                MainActor.assumeIsolated { self?.cancel() }
            }))
        }
    }
}
