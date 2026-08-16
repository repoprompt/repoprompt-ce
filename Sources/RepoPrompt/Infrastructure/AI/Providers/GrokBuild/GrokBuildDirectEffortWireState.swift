import Foundation

final class GrokBuildDirectEffortWireState: @unchecked Sendable {
    enum Lookup {
        case uninitialized
        case exact(String)
        case unavailable
    }

    private let lock = NSLock()
    private var hasParsedSnapshot = false
    private var valuesBySessionID: [String: [String: [CodexReasoningEffort: String]]] = [:]

    func replace(
        sessionID: String?,
        valuesByModelRaw: [String: [CodexReasoningEffort: String]]
    ) {
        lock.withLock {
            hasParsedSnapshot = true
            guard let sessionID else { return }
            valuesBySessionID[sessionID] = valuesByModelRaw
        }
    }

    func markUnavailable(sessionID: String?) {
        lock.withLock {
            hasParsedSnapshot = true
            if let sessionID {
                valuesBySessionID.removeValue(forKey: sessionID)
            }
        }
    }

    func lookup(
        sessionID: String,
        baseModelRaw: String,
        effort: CodexReasoningEffort
    ) -> Lookup {
        lock.withLock {
            guard hasParsedSnapshot else { return .uninitialized }
            guard let value = valuesBySessionID[sessionID]?[baseModelRaw.lowercased()]?[effort] else {
                return .unavailable
            }
            return .exact(value)
        }
    }
}
