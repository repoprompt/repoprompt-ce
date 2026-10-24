import Foundation

final class GrokBuildDirectEffortWireState: @unchecked Sendable {
    enum Lookup {
        case uninitialized
        case exact(String)
        case unavailable
    }

    private struct Advertisement {
        let wireValues: [CodexReasoningEffort: String]
        let effortsByID: [String: CodexReasoningEffort]
    }

    private let lock = NSLock()
    private var hasParsedSnapshot = false
    private var advertisementsBySessionID: [String: [String: Advertisement]] = [:]

    func replace(
        sessionID: String?,
        valuesByModelRaw: [String: [CodexReasoningEffort: String]],
        effortsByIDByModelRaw: [String: [String: CodexReasoningEffort]]
    ) {
        lock.withLock {
            hasParsedSnapshot = true
            guard let sessionID else { return }
            var advertisements: [String: Advertisement] = [:]
            for (modelRaw, wireValues) in valuesByModelRaw {
                advertisements[modelRaw] = Advertisement(
                    wireValues: wireValues,
                    effortsByID: effortsByIDByModelRaw[modelRaw] ?? [:]
                )
            }
            advertisementsBySessionID[sessionID] = advertisements
        }
    }

    func markUnavailable(sessionID: String?) {
        lock.withLock {
            hasParsedSnapshot = true
            if let sessionID {
                advertisementsBySessionID.removeValue(forKey: sessionID)
            }
        }
    }

    func reportedEffort(sessionID: String, baseModelRaw: String, idRaw: String?) -> CodexReasoningEffort? {
        lock.withLock {
            guard let idRaw else { return nil }
            return advertisementsBySessionID[sessionID]?[baseModelRaw.lowercased()]?
                .effortsByID[idRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }
    }

    func lookup(
        sessionID: String,
        baseModelRaw: String,
        effort: CodexReasoningEffort
    ) -> Lookup {
        lock.withLock {
            guard hasParsedSnapshot else { return .uninitialized }
            guard let value = advertisementsBySessionID[sessionID]?[baseModelRaw.lowercased()]?.wireValues[effort] else {
                return .unavailable
            }
            return .exact(value)
        }
    }
}
