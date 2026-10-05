import Foundation
import MCP
import RepoPromptDomainRuntime

/// One self-only MCP surface. Caller authority comes exclusively from server-owned run routing and
/// the immutable registration-time run attempt; tool arguments cannot name a target.
@MainActor
struct AgentSelfMCPToolService {
    typealias RequestMetadata = MCPRequestMetadata
    typealias Endpoint = DomainAgentSessionLinkEndpointIdentity
    typealias ObserverEndpointResolver = AgentSessionTargetOperationGuard.ObserverEndpointResolver

    enum Admission {
        case scheduled(AgentSelfCompactAttempt)
        case duplicate(requestID: UUID, status: AgentSelfCompactStatus?)
        case blocked(reason: String)
        case unavailable
    }

    let captureRequestMetadata: () async -> MCPRequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveObserverEndpoint: ObserverEndpointResolver
    let captureCallOrigin: () -> AgentSelfMCPCallOrigin?
    let readSelf: (WindowState, Endpoint, AgentSelfMCPCallOrigin) -> AgentSelfContextSnapshot?
    let scheduleCompact: (WindowState, Endpoint, AgentSelfMCPCallOrigin, String, String) async -> Admission
    var isToolEnabled: () -> Bool = { ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.agentSelf) }

    static let unavailableError = MCPError.invalidParams(
        "self_compact is available only to the calling Agent Mode session with a resolved live binding; no target selector grants access."
    )

    func execute(args: [String: Value]) async throws -> Value {
        guard isToolEnabled() else { throw MCPError.invalidParams("self_compact is disabled.") }
        guard let op = AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased() else {
            throw MCPError.invalidParams("self_compact op is required: context or compact.")
        }
        let allowed: Set<String> = switch op {
        case "context": ["op"]
        case "compact": ["op", "note", "idempotency_key"]
        default: throw MCPError.invalidParams("Unknown self_compact op '\(op)'.")
        }
        for key in args.keys.sorted() where !allowed.contains(key) {
            throw MCPError.invalidParams("self_compact \(op) does not support '\(key)'.")
        }
        // Registration-time origin must exist before any await. The exact endpoint is resolved
        // independently from live server routing, and must still equal that captured incarnation.
        guard let origin = captureCallOrigin() else { throw Self.unavailableError }
        let metadata = await captureRequestMetadata()
        let window = try requireTargetWindow()
        guard !window.isClosing,
              let endpoint = await AgentSessionTargetOperationGuard.resolveObserverEndpoint(
                  metadata: metadata, targetWindow: window, resolveObserverEndpoint: resolveObserverEndpoint
              ), endpoint == origin.endpoint, endpoint.hasResolvedPersistentBinding
        else { throw Self.unavailableError }

        switch op {
        case "context":
            guard let snapshot = readSelf(window, endpoint, origin) else { throw Self.unavailableError }
            return .object([
                "result": .string("ok"),
                "context": AgentSessionLinkResponseRenderer.contextLoadValue(snapshot.context),
                "self_compact": Self.statusValue(snapshot.selfCompact)
            ])
        case "compact":
            guard case let .string(note)? = args["note"] else {
                throw MCPError.invalidParams("self_compact compact note is required as a string.")
            }
            let bytes: Int
            switch AgentSessionSelfCompactNotePolicy.validation(of: note) {
            case let .valid(byteCount): bytes = byteCount
            case .empty: throw MCPError.invalidParams("self_compact compact note must not be empty or whitespace-only.")
            case let .tooLong(byteCount, maximum):
                throw MCPError.invalidParams("self_compact compact note is \(byteCount) UTF-8 bytes; maximum \(maximum).")
            case .invalidScalar:
                throw MCPError.invalidParams("self_compact compact note contains a disallowed control character.")
            }
            guard case let .string(key)? = args["idempotency_key"],
                  AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(key),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MCPError.invalidParams("self_compact compact idempotency_key is required (1...200 UTF-8 bytes).")
            }
            let admission = await scheduleCompact(window, endpoint, origin, note, key)
            switch admission {
            case let .scheduled(attempt):
                return .object([
                    "result": .string("scheduled"),
                    "request_id": .string(attempt.id.uuidString),
                    "provider": attempt.admittedSupport.map { .string($0.rawValue) } ?? .null,
                    "note_bytes": .int(bytes),
                    "duplicate": .bool(false),
                    "phase": .string(attempt.phase.rawValue),
                    "guidance": .string("No compaction has run yet; finish this turn normally. Do not park in wait_for_next_user_instruction or send a verification prompt.")
                ])
            case let .duplicate(requestID, status):
                return .object([
                    "result": .string(status?.phase == nil ? "settled" : "scheduled"),
                    "request_id": .string(requestID.uuidString),
                    "duplicate": .bool(true),
                    "self_compact": Self.statusValue(status),
                    "detail": .string("Identical retry of the active request or latest retained settlement; no new compaction was scheduled. Only these retained records are deduplicated.")
                ])
            case let .blocked(reason):
                return .object([
                    "result": .string("blocked"),
                    "reason": .string(reason),
                    "detail": .string(Self.blockedDetail(for: reason))
                ])
            case .unavailable:
                throw Self.unavailableError
            }
        default:
            preconditionFailure("Validated self_compact operation")
        }
    }

    private static func blockedDetail(for reason: String) -> String {
        switch reason {
        case "idempotency_conflict":
            "This key belongs to a different note in the active request or latest settlement. Use a fresh key; older keys are not retained for deduplication."
        case "compact_already_pending":
            "Another compact request is active. Deduplication covers only the active request and latest settlement; retry that request with its original key and note."
        case "not_supported":
            "RepoPrompt-driven compaction requires Claude Code, Codex, or a live ACP session advertising /compact."
        case "no_provider_session":
            "No live provider conversation is bound to this session."
        case "pending_interaction":
            "Resolve the pending prompt, approval, elicitation, or review before compacting."
        case "persistence_pending":
            "Durable session state is still being written; retry after it settles."
        case "persistence_indeterminate":
            "Durable session state could not be confirmed; no compaction was dispatched."
        case "session_not_exclusive":
            "Exclusive durable ownership could not be confirmed; compaction is refused."
        case "busy":
            "This session is not dispatchable now; retry after the turn settles."
        default:
            "Compaction was not scheduled."
        }
    }

    static func statusValue(_ status: AgentSelfCompactStatus?) -> Value {
        guard let status else { return .null }
        var value: [String: Value] = [
            "request_id": status.requestID.map { .string($0.uuidString) } ?? .null,
            "phase": status.phase.map { .string($0) } ?? .null,
            "outcome": status.outcome.map { .string($0.rawValue) } ?? .null,
            "completion_verified": status.completionVerified.map { .bool($0) } ?? .null,
            "note_delivery": status.noteDelivery.map { .string($0.rawValue) } ?? .null,
            "recovery_note": status.recoveryNote.map { .string($0) } ?? .null
        ]
        var details: [String] = []
        if status.phase == AgentSelfCompactAttempt.Phase.acpSettling.rawValue {
            details.append("ACP /compact may still be running; the note waits for a safe settle boundary.")
        }
        if status.outcome == .completionUnverified {
            details.append("Compaction completion is not verified.")
        }
        if status.noteDelivery == .parked {
            details.append("The note will be prepended to the next ordinary send; do not issue a verification prompt.")
        }
        if status.noteDelivery == .deliveryUnknown {
            details.append("Note delivery is unknown and is not automatically retried.")
        }
        if status.outcome == .recoveryRequired {
            details.append("The interrupted note is retained for explicit recovery, not automatically sent.")
        }
        if !details.isEmpty {
            value["detail"] = .string(details.joined(separator: " "))
        }
        return .object(value)
    }
}
