import Combine
import Foundation

/// Metadata/preparation never reserves the native backend. A separate sync
/// task can fence the writer while the installation task awaits native I/O.
@MainActor
final class CodexSwitchboardAutomaticControl: ObservableObject {
    @Published private(set) var offer: SwitchboardAutomaticOffer?
    @Published private(set) var enrollment: SwitchboardAutomaticEnrollment?
    @Published private(set) var statusText = "Automatic rotation is off."
    private(set) var controlEpoch: Int64 = 0
    private(set) var manualGeneration: Int64 = 0
    let fence = CodexAutomaticAdoptionEpoch()
    let client: SwitchboardAutomaticClient
    private let source: () -> SwitchboardAutomaticSource?
    private let perform: (SwitchboardAutomaticPrepared, SwitchboardAutomaticEnrollment) async -> Void
    private var task: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var stopped = false
    private var acceptanceGeneration = UUID()
    private var pendingReceipts: [UUID: SwitchboardAutomaticReceipt] = [:]
    var isWorkInFlight: Bool {
        work != nil
    }

    init(client: SwitchboardAutomaticClient, source: @escaping () -> SwitchboardAutomaticSource?, perform: @escaping (SwitchboardAutomaticPrepared, SwitchboardAutomaticEnrollment) async -> Void) {
        self.client = client
        self.source = source
        self.perform = perform
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self, client] in
            do { try await client.hello() } catch {
                self?.statusText = "Automatic rotation is unavailable; manual pairing is unchanged."
                return
            }
            while !Task.isCancelled {
                guard self?.stopped == false else { return }
                await self?.syncOnce()
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    func syncOnce() async {
        guard !stopped else { return }
        do {
            let response = try await client.sync(enrollmentID: enrollment?.id, epoch: controlEpoch, source: source(), manualGeneration: manualGeneration)
            guard !stopped, apply(response.control) else { return }
            offer = (response.offer?.expiresAt ?? .distantPast) > Date() ? response.offer : nil
            if let enrollment, response.enrollment != enrollment {
                self.enrollment = nil
                fence.revoke()
                statusText = "Automatic approval changed; approve a new pairing to continue."
            }
            // Remote metadata can never enroll a root on the user's behalf.
            if let enrollment, let intent = response.intent, work == nil,
               response.control.state == .enabled,
               intent.enrollmentID == enrollment.id, intent.controlEpoch == controlEpoch,
               intent.manualGeneration == manualGeneration, intent.source == source(), intent.expiresAt > Date()
            {
                work = Task { [weak self, client] in
                    defer { self?.work = nil }
                    do {
                        guard let prepared = try await client.prepare(intent), let self,
                              !stopped, self.enrollment == enrollment, controlEpoch == intent.controlEpoch,
                              manualGeneration == intent.manualGeneration, source() == intent.source,
                              prepared.expiresAt > Date() else { return }
                        await perform(prepared, enrollment)
                    } catch { self?.statusText = "Automatic destination unavailable; current account is unchanged." }
                }
            }
            for (id, receipt) in pendingReceipts {
                if let control = try? await client.finish(permitID: id, receipt: receipt) {
                    pendingReceipts[id] = nil
                    _ = apply(control)
                }
            }
        } catch {
            stop()
            statusText = "Automatic control unavailable; in-flight outcome may be unknown."
            // Base consent remains intact; automatic authority requires repair.
        }
    }

    /// Called only by an explicit root action after displaying this exact offer.
    func accept(offerID: UUID) async throws {
        guard !stopped, let offer, offer.id == offerID, offer.expiresAt > Date(), source() != nil else { throw SwitchboardAutomaticError.notEnrolled }
        let generation = acceptanceGeneration
        do {
            let (approved, control) = try await client.accept(offer)
            guard !stopped, acceptanceGeneration == generation, self.offer == offer,
                  apply(control) else { throw SwitchboardAutomaticError.policyChanged }
            enrollment = approved
            self.offer = nil
            _ = apply(control)
        } catch {
            // A canceled/lost acknowledgment may have accepted remotely. Revoke
            // the exact offered enrollment, never a later approval or base cap.
            _ = try? await client.revoke(offer.enrollment)
            throw SwitchboardAutomaticError.policyChanged
        }
    }

    func manualChanged() {
        guard manualGeneration < 9_007_199_254_740_991 else { stop()
            return
        }
        manualGeneration += 1
        fence.manualChanged(generation: manualGeneration)
    }

    @discardableResult
    func apply(_ control: SwitchboardAutomaticControl) -> Bool {
        guard !stopped, control.epoch >= controlEpoch else { return false }
        controlEpoch = control.epoch
        let accepted = fence.update(epoch: control.epoch, enabled: control.state == .enabled && !control.desiredPaused, cancelled: control.cancelPermitIDs)
        switch control.state {
        case .enabled: statusText = enrollment == nil ? "Automatic rotation is off; explicit approval required." : "Automatic rotation enabled for this rule."
        case .paused: statusText = "Automatic rotation paused; current account and manual controls remain available."
        case .pausing: statusText = "Pausing automatic rotation; waiting for in-flight acknowledgment."
        case .pausingUnknown: statusText = "Pausing automatic rotation; an in-flight outcome is unknown."
        }
        return accepted
    }

    func record(_ receipt: SwitchboardAutomaticReceipt, permitID: UUID) async throws {
        pendingReceipts[permitID] = receipt
        let control = try await client.finish(permitID: permitID, receipt: receipt)
        pendingReceipts[permitID] = nil
        _ = apply(control)
    }

    func stop() {
        guard !stopped else { return }
        fence.revoke()
        stopped = true
        statusText = "Automatic approval revoked; waiting for any in-flight acknowledgment."
        acceptanceGeneration = UUID()
        task?.cancel()
        // Do not cancel the installation task: it must report exact publication
        // and native settlement. Fencing prevents further automatic writes.
        let enrollment = enrollment
        self.enrollment = nil
        if let enrollment { Task { [client] in _ = try? await client.revoke(enrollment) } }
    }

    deinit { fence.revoke()
        task?.cancel()
    }
}
