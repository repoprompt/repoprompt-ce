import Foundation

/// Transport-local input ownership. Resolved inputs leave this owner before idle deferral.
struct ClaudeNativeTurnCorrelation {
    private struct Execution {
        let id: UUID
        let providerInitiated: Bool
        var inputIDs: Set<UUID>
        /// Provider-owned inputs identify this execution but never settle host work.
        var observedForeignInputIDs: Set<UUID> = []
    }

    enum CorrelationError: Error {
        case invalidInputIdentity
        case missingAnswerIdentity
    }

    private var order: [UUID] = []
    private var head = 0
    private var outstanding: Set<UUID> = []
    private(set) var enabled = false
    private var execution: Execution?
    /// Unstamped deltas follow the last observed main-thread message, not just an active host execution.
    private var messageHasHostOwner = false
    private struct Interrupt {
        let token: UUID
        var executionID: UUID?
        var cancellationDisarmed = false
    }

    private var interrupt: Interrupt?

    var hasOutstanding: Bool {
        !outstanding.isEmpty
    }

    var providerTurnID: UUID? {
        execution.flatMap { $0.providerInitiated ? $0.id : nil }
    }

    var ownsProviderOutput: Bool {
        execution?.providerInitiated == true && execution?.inputIDs.isEmpty == true
    }

    var ownsOutput: Bool {
        guard messageHasHostOwner, let execution else { return false }
        return !execution.inputIDs.isDisjoint(with: outstanding)
    }

    mutating func observeInit(_ payload: [String: Any]) {
        guard !enabled,
              let version = payload["claude_code_version"] as? String,
              let capabilities = payload["capabilities"] as? [String],
              capabilities.contains("msg_lifecycle_v1")
        else { return }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard components.count == 3, parts.count == 3 else { return }
        enabled = !parts.lexicographicallyPrecedes([2, 1, 292])
    }

    mutating func register(_ id: UUID) {
        outstanding.insert(id)
        order.append(id)
    }

    /// Preserve context across unstamped later blocks; a pickup adds inputs to the same execution.
    @discardableResult
    mutating func observeActivity(_ payload: [String: Any]) throws -> Bool {
        guard enabled else { return true }
        let ids = try Self.inputIDs(payload)
        if let ids {
            let known = Set(ids).intersection(outstanding)
            guard !known.isEmpty else {
                // A foreign identity may start or identify provider work; it cannot
                // reidentify an active host execution or clear that host's interrupt.
                if execution == nil { execution = Execution(id: UUID(), providerInitiated: true, inputIDs: []) }
                if execution?.providerInitiated == true, execution?.inputIDs.isEmpty == true {
                    execution?.observedForeignInputIDs.formUnion(ids)
                    bindInterruptToObservedExecution()
                }
                messageHasHostOwner = false
                return ownsProviderOutput
            }
            messageHasHostOwner = true
            if execution == nil { execution = Execution(id: UUID(), providerInitiated: false, inputIDs: known) }
            else { execution?.inputIDs.formUnion(known) }
        } else if execution == nil {
            execution = Execution(id: UUID(), providerInitiated: true, inputIDs: [])
        }
        bindInterruptToObservedExecution()
        return ownsOutput || ownsProviderOutput
    }

    /// Accepted inputs are not execution evidence. A pre-reply interrupt stays unresolved
    /// until activity or an answering result identifies what the CLI was executing.
    mutating func beginInterrupt() -> UUID {
        let token = UUID()
        interrupt = Interrupt(token: token, executionID: execution?.id)
        return token
    }

    func isInterruptPending(_ token: UUID) -> Bool {
        interrupt?.token == token
    }

    mutating func acknowledgeInterrupt(_ token: UUID) {
        // Retain evidence that an unobserved execution may still report its abort,
        // but do not bind this ACK to work that starts later.
        if interrupt?.token == token, interrupt?.executionID == nil {
            interrupt?.cancellationDisarmed = true
        }
    }

    mutating func abandonInterrupt(_ token: UUID) {
        guard interrupt?.token == token else { return }
        // A missing ACK does not prove the CLI ignored the request. Retain only
        // possible abort evidence, never a cancellation binding for a later input.
        interrupt?.executionID = nil
        interrupt?.cancellationDisarmed = true
    }

    private mutating func bindInterruptToObservedExecution() {
        if interrupt?.executionID == nil, interrupt?.cancellationDisarmed == false {
            interrupt?.executionID = execution?.id
        }
    }

    mutating func resolve(_ payload: [String: Any]) throws -> (executionID: UUID, inputIDs: [UUID], providerTurnID: UUID?, interrupted: Bool) {
        let ids = try Self.inputIDs(payload) ?? []
        // A session-scoped error before any execution evidence cannot answer a particular
        // input. Retire the failed transport rather than leave accepted inputs hanging.
        if ids.isEmpty, execution == nil, hasOutstanding, payload["is_error"] as? Bool == true, interrupt == nil {
            throw CorrelationError.missingAnswerIdentity
        }
        let matched = ids.filter { outstanding.contains($0) }
        if let execution {
            let answering = execution.inputIDs.intersection(outstanding)
            if ids.isEmpty || !matched.isEmpty, !answering.isSubset(of: Set(matched)) {
                throw CorrelationError.missingAnswerIdentity
            }
        }
        // An observed provider-owned foreign answer retires its interrupt;
        // an unrelated late result cannot retire a different execution.
        let answersObservedProviderExecution = execution.map {
            $0.providerInitiated && $0.inputIDs.isEmpty && !$0.observedForeignInputIDs.isDisjoint(with: ids)
        } ?? false
        let closesExecution = ids.isEmpty || !matched.isEmpty || answersObservedProviderExecution
        let executionID = closesExecution ? (execution?.id ?? matched.first ?? UUID()) : UUID()
        if closesExecution, interrupt?.executionID == nil, interrupt?.cancellationDisarmed == false {
            interrupt?.executionID = executionID
        }
        let interrupted = interrupt?.executionID == executionID
        let providerID = closesExecution ? providerTurnID : nil
        if closesExecution {
            execution = nil
            messageHasHostOwner = false
            interrupt = nil
        }
        for id in matched {
            outstanding.remove(id)
        }
        compact()
        return (executionID, matched, providerID, interrupted)
    }

    mutating func takeFirst() -> UUID? {
        guard let id = firstOutstanding else { return nil }
        outstanding.remove(id)
        compact()
        return id
    }

    /// Only transport retirement calls this: eligibility and interrupt bindings retire too.
    mutating func drain() -> [UUID] {
        let ids = order[head...].filter { outstanding.contains($0) } + (providerTurnID.map { [$0] } ?? [])
        self = Self()
        return ids
    }

    private var firstOutstanding: UUID? {
        order[head...].first { outstanding.contains($0) }
    }

    private mutating func compact() {
        while head < order.count, !outstanding.contains(order[head]) {
            head += 1
        }
        if head > 4, head >= order.count / 2 {
            order.removeFirst(head)
            head = 0
        }
    }

    /// Singular is the last input, not a substitute for a malformed plural group.
    static func inputIDs(_ payload: [String: Any]) throws -> [UUID]? {
        let singular: UUID?
        if let raw = payload["user_message_uuid"], !(raw is NSNull) {
            guard let text = raw as? String, let id = UUID(uuidString: text) else {
                throw CorrelationError.invalidInputIdentity
            }
            singular = id
        } else { singular = nil }
        if let raw = payload["user_message_uuids"], !(raw is NSNull) {
            guard let values = raw as? [String], values.count <= 64 else {
                throw CorrelationError.invalidInputIdentity
            }
            if values.isEmpty {
                guard singular == nil else { throw CorrelationError.invalidInputIdentity }
                return nil
            }
            var ids: [UUID] = []
            var seen: Set<UUID> = []
            for value in values {
                guard let id = UUID(uuidString: value) else { throw CorrelationError.invalidInputIdentity }
                if seen.insert(id).inserted { ids.append(id) }
            }
            if let singular, singular != ids.last { throw CorrelationError.invalidInputIdentity }
            return ids
        }
        return singular.map { [$0] }
    }
}
