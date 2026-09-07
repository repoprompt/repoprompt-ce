import Foundation

/// Additional, automatic-login-only authority. Base session consent is separate.
final class CodexAutomaticAdoptionPermit: SwitchboardAutomaticPrivateValue, @unchecked Sendable {
    enum Publication: String { case none, prefix, complete }
    struct Snapshot: Equatable {
        let publication: Publication
        let bytesWritten: Int
        let fenced: Bool
    }

    let id: UUID
    let controlEpoch: Int64
    let manualGeneration: Int64
    let nativePeer: SwitchboardAutomaticNativePeer?
    let destination: SwitchboardAutomaticSource?
    private let deadline: UInt64
    private let lock = NSLock()
    private var fenced = false
    private var bytesWritten = 0
    private var complete = false

    init(id: UUID, controlEpoch: Int64, manualGeneration: Int64, beginStartedAt: UInt64, ttlMilliseconds: Int, nativePeer: SwitchboardAutomaticNativePeer? = nil, destination: SwitchboardAutomaticSource? = nil) throws {
        guard controlEpoch >= 0, manualGeneration >= 0, (1 ... 5000).contains(ttlMilliseconds),
              beginStartedAt <= UInt64.max - UInt64(ttlMilliseconds) * 1_000_000
        else { throw CodexAccountAdoptionReason.revoked }
        self.id = id
        self.controlEpoch = controlEpoch
        self.manualGeneration = manualGeneration
        self.nativePeer = nativePeer
        self.destination = destination
        deadline = beginStartedAt + UInt64(ttlMilliseconds) * 1_000_000
    }

    @discardableResult
    func fence() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        fenced = true
        return snapshotLocked()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func publishChunk(offset: Int, count: Int, isFinal: Bool, _ write: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !fenced, !complete, DispatchTime.now().uptimeNanoseconds < deadline,
              offset == bytesWritten, count > 0, bytesWritten <= Int.max - count
        else { throw CodexAccountAdoptionReason.revoked }
        try write()
        // This receipt is recorded before releasing the syscall's authority
        // lock. A concurrent Pause can never classify a published LF as absent.
        bytesWritten += count
        complete = isFinal
    }

    func authorizesLogin(_ params: [String: Any]?) -> Bool {
        guard let destination, params?["type"] as? String == "chatgptAuthTokens",
              params?["chatgptAccountId"] as? String == destination.accountID,
              let token = params?["accessToken"] as? String else { return false }
        return SwitchboardAutomaticSource.fingerprint(token) == destination.fingerprint
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(publication: complete ? .complete : bytesWritten == 0 ? .none : .prefix, bytesWritten: bytesWritten, fenced: fenced)
    }
}

/// Epoch updates use a different lane from installation and fence even a
/// delayed begin response. Unknown cancellation IDs never produce receipts.
final class CodexAutomaticAdoptionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: Int64 = 0
    private var enabled = false
    private var manualGeneration: Int64 = 0
    private var cancelled: Set<UUID> = []
    private var seen: Set<UUID> = []
    private var active: CodexAutomaticAdoptionPermit?
    private var revoked = false

    @discardableResult
    func update(epoch: Int64, enabled: Bool, cancelled: [UUID]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, epoch >= self.epoch else { return false }
        if epoch > self.epoch || !enabled { active?.fence() }
        self.epoch = epoch
        self.enabled = enabled
        self.cancelled.formUnion(cancelled)
        if let active, self.cancelled.contains(active.id) { active.fence() }
        if self.cancelled.count > 4096 { revoked = true
            active?.fence()
        }
        return !revoked
    }

    func manualChanged(generation: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation > manualGeneration else { return }
        manualGeneration = generation
        active?.fence()
    }

    func arm(id: UUID, epoch: Int64, manualGeneration: Int64, beginStartedAt: UInt64, ttlMilliseconds: Int, nativePeer: SwitchboardAutomaticNativePeer? = nil, destination: SwitchboardAutomaticSource? = nil) throws -> CodexAutomaticAdoptionPermit {
        lock.lock()
        defer { lock.unlock() }
        guard !seen.contains(id), seen.count < 4096, active == nil else { throw CodexAccountAdoptionReason.revoked }
        seen.insert(id)
        let permit = try CodexAutomaticAdoptionPermit(id: id, controlEpoch: epoch, manualGeneration: manualGeneration, beginStartedAt: beginStartedAt, ttlMilliseconds: ttlMilliseconds, nativePeer: nativePeer, destination: destination)
        if revoked || !enabled || epoch != self.epoch || manualGeneration != self.manualGeneration || cancelled.contains(id) { permit.fence() }
        active = permit
        return permit
    }

    func finish(_ permit: CodexAutomaticAdoptionPermit) {
        lock.lock()
        defer { lock.unlock() }
        permit.fence()
        if active === permit { active = nil }
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
        enabled = false
        active?.fence()
    }
}
