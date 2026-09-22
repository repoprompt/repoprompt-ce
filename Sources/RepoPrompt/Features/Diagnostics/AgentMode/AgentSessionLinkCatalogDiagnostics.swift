import CryptoKit
import Foundation
import OSLog

/// Low-volume, always-on local diagnostics for oversight catalog convergence.
/// Accepts only closed enums, booleans, generations, revisions, and hashed identifiers.
enum AgentSessionLinkCatalogDiagnostics {
    enum Presence: String, Equatable {
        case present
        case absent
        case unknown

        init(_ value: Bool?) {
            switch value {
            case true: self = .present
            case false: self = .absent
            case nil: self = .unknown
            }
        }
    }

    enum Event: String, Equatable {
        case catalogPublished = "catalog-published"
        case projectionEvaluated = "projection-evaluated"
        case repairTransition = "repair-transition"
        case toolCallReceived = "tool-call-received"
    }

    enum Outcome: String, Equatable {
        case accepted
        case rejectedEndpointMismatch = "rejected-endpoint-mismatch"
        case rejectedMissingSession = "rejected-missing-session"
        case rejectedEndpointRebind = "rejected-endpoint-rebind"
        case rejectedRunMismatch = "rejected-run-mismatch"
        case rejectedStaleRevision = "rejected-stale-revision"
        case coalescedDuplicate = "coalesced-duplicate"
        case opened
        case closedCatalogPresent = "closed-catalog-present"
        case closedOutboundLost = "closed-outbound-lost"
        case closedProviderChanged = "closed-provider-changed"
        case closedToolDisabled = "closed-tool-disabled"
        case spentReplaced = "spent-replaced"
        case spentStrandedRunRetired = "spent-stranded-run-retired"
    }

    struct Record: Equatable {
        let event: Event
        let outcome: Outcome?
        let run: String
        let tab: String
        let connection: String
        let revision: UInt64?
        let routingGeneration: UInt64?
        let lifecycleGeneration: UInt64?
        let routePresent: Bool?
        let catalog: Presence?
        let outbound: Presence?

        var renderedLine: String {
            let outcomeValue = outcome?.rawValue ?? "nil"
            let revisionValue = revision.map(String.init) ?? "nil"
            let routingGenerationValue = routingGeneration.map(String.init) ?? "nil"
            let lifecycleGenerationValue = lifecycleGeneration.map(String.init) ?? "nil"
            let routePresentValue = routePresent.map(String.init) ?? "nil"
            let catalogValue = catalog?.rawValue ?? "nil"
            let outboundValue = outbound?.rawValue ?? "nil"
            return [
                "event=\(event.rawValue)",
                "outcome=\(outcomeValue)",
                "run=\(run)",
                "tab=\(tab)",
                "connection=\(connection)",
                "revision=\(revisionValue)",
                "routingGeneration=\(routingGenerationValue)",
                "lifecycleGeneration=\(lifecycleGenerationValue)",
                "routePresent=\(routePresentValue)",
                "catalog=\(catalogValue)",
                "outbound=\(outboundValue)"
            ].joined(separator: " ")
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "AgentSessionLinkCatalog"
    )

    #if DEBUG
        private final class TestCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var isCapturing = false
            private var records: [Record] = []

            func begin() {
                lock.lock()
                records.removeAll(keepingCapacity: true)
                isCapturing = true
                lock.unlock()
            }

            func append(_ record: Record) {
                lock.lock()
                if isCapturing {
                    records.append(record)
                }
                lock.unlock()
            }

            func end() -> [Record] {
                lock.lock()
                defer { lock.unlock() }
                isCapturing = false
                return records
            }
        }

        private static let testCapture = TestCapture()

        static func beginCaptureForTesting() {
            testCapture.begin()
        }

        static func endCaptureForTesting() -> [Record] {
            testCapture.end()
        }
    #endif

    static func catalogPublished(
        runID: UUID,
        routeToken: AgentSessionLinkRunCatalogRouteToken?,
        revision: UInt64,
        catalog: Bool?,
        outbound: Bool?
    ) {
        emit(Record(
            event: .catalogPublished,
            outcome: nil,
            run: hashedID(runID),
            tab: hashedID(routeToken?.observerEndpoint.tabID),
            connection: hashedID(routeToken?.connectionID),
            revision: revision,
            routingGeneration: routeToken?.routingAuthorityGeneration,
            lifecycleGeneration: routeToken?.connectionLifecycleGeneration,
            routePresent: routeToken != nil,
            catalog: Presence(catalog),
            outbound: Presence(outbound)
        ))
    }

    static func projectionEvaluated(
        runID: UUID,
        tabID: UUID,
        revision: UInt64,
        catalog: Bool?,
        outbound: Bool?,
        outcome: Outcome
    ) {
        emit(Record(
            event: .projectionEvaluated,
            outcome: outcome,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: "nil",
            revision: revision,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: Presence(catalog),
            outbound: Presence(outbound)
        ))
    }

    static func repairTransition(runID: UUID?, tabID: UUID, outcome: Outcome) {
        emit(Record(
            event: .repairTransition,
            outcome: outcome,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: "nil",
            revision: nil,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: nil,
            outbound: nil
        ))
    }

    static func toolCallReceived(runID: UUID?, tabID: UUID?, connectionID: UUID) {
        emit(Record(
            event: .toolCallReceived,
            outcome: nil,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: hashedID(connectionID),
            revision: nil,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: nil,
            outbound: nil
        ))
    }

    private static func emit(_ record: Record) {
        logger.notice("\(record.renderedLine, privacy: .public)")
        #if DEBUG
            testCapture.append(record)
        #endif
    }

    private static func hashedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
