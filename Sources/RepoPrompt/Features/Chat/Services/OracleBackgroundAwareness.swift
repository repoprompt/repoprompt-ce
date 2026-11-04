import Foundation
import RepoPromptDomainRuntime

/// Provider-only, process-local reservation/acceptance. No transcript row, disk read or wake.
@MainActor
final class OracleBackgroundAwareness {
    struct Context: Equatable {
        let owner: OracleBackgroundInvocationRegistry.Owner
        let runID: UUID
        let providerID: ObjectIdentifier?
        let generation: UUID
    }

    struct Reservation {
        let id: UUID
        let context: Context
        let epoch: UUID?
        let revision: UInt64
        let text: String
        func decorating(_ base: String) -> String {
            base.isEmpty ? text : base + "\n\n" + text
        }

        func decorating(_ base: AgentMessage) -> AgentMessage {
            var message = base
            message.userMessage = decorating(base.userMessage)
            return message
        }
    }

    private var contextGeneration = UUID()
    private var currentContext: Context?
    private var cachedEpoch: UUID?
    private var cachedRevision: UInt64?
    private var cachedText: String?
    private var accepted: (UUID?, UInt64)?
    private var inFlight: Reservation?

    func resetContext() {
        contextGeneration = UUID()
        currentContext = nil
        accepted = nil
        inFlight = nil
    }

    func reserve(session: AgentTabSession, providerID: ObjectIdentifier?, registry: OracleBackgroundInvocationRegistry? = nil) -> Reservation? {
        guard let owner = session.oracleBackgroundOwner, let runID = session.runID,
              owner.binding == session.persistentSessionBindingIdentity,
              !session.bindingTransitionInProgress else { return nil }
        let registry = registry ?? AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
        guard !registry.admissionIsClosed(for: owner) else { return nil }
        let context = Context(owner: owner, runID: runID, providerID: providerID, generation: contextGeneration)
        if currentContext != context {
            currentContext = context
            accepted = nil
            inFlight = nil
        }
        let version = registry.awarenessVersion(for: owner)
        if cachedRevision != version.generation || cachedEpoch != version.epoch {
            cachedEpoch = version.epoch
            cachedRevision = version.generation
            let open = registry.snapshot(for: owner, includeFinished: false).invocations
            if let first = open.last {
                let ready = open.reduce(0) { $0 + $1.laneOutcomes.values.count(where: { $0 == .completed }) }
                let remaining = open.count - 1
                cachedText = "Oracle: \(open.count) open, \(ready) answers ready [g:\(first.reference.groupID.rawValue.uuidString)/t:\(first.reference.turnID.rawValue.uuidString)\(remaining == 0 ? "" : "; +\(remaining)")]"
            } else { cachedText = nil }
        }
        guard let text = cachedText, inFlight == nil,
              accepted?.0 != version.epoch || accepted?.1 != version.generation else { return nil }
        let reservation = Reservation(id: UUID(), context: context, epoch: version.epoch, revision: version.generation, text: text)
        inFlight = reservation
        return reservation
    }

    func release(_ reservation: Reservation?) {
        guard let reservation, inFlight?.id == reservation.id else { return }
        inFlight = nil
    }

    func accept(_ reservation: Reservation?, registry: OracleBackgroundInvocationRegistry? = nil) {
        guard let reservation, inFlight?.id == reservation.id, currentContext == reservation.context else { return }
        let registry = registry ?? AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
        guard registry.awarenessVersion(for: reservation.context.owner).epoch == reservation.epoch else {
            inFlight = nil
            return
        }
        accepted = (reservation.epoch, reservation.revision)
        inFlight = nil
    }
}

extension AgentModeViewModel {
    @discardableResult
    func closeOracleBackground(for session: AgentTabSession) -> Task<Void, Never>? {
        guard let owner = session.oracleBackgroundOwner else { return nil }
        let drain = AppDomainRuntimeComposition.shared.oracleBackgroundInvocations.close(owner)
        session.oracleBackgroundDrain = drain
        session.oracleBackgroundAwareness.resetContext()
        return drain
    }

    @discardableResult
    func awaitOracleBackgroundDrain(for session: AgentTabSession, timeout: TimeInterval = 30) async -> Bool {
        guard let owner = session.oracleBackgroundOwner else { return true }
        let registry = AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
        guard let drain = closeOracleBackground(for: session) else { return true }
        if registry.isDrained(owner) { return true }
        let settled = await OracleBackgroundInvocationRegistry.awaitDrain(drain, timeout: timeout)
        return settled && sessions[session.tabID] === session && session.persistentSessionBindingIdentity == owner.binding
    }

    func closeOracleBackgroundWindowAdmission() {
        for session in sessions.values {
            closeOracleBackground(for: session)
        }
    }

    func joinOracleBackgroundWindowDrain() async {
        let drains = sessions.values.compactMap { closeOracleBackground(for: $0) }
        for drain in drains {
            await drain.value
        }
    }
}
