import Foundation

struct SwitchboardBridgeScope: Equatable {
    let consentID: UUID
    let sessionID: UUID
    let controllerGeneration: UUID
    var threadID: String?
}

/// One explicitly imported capability belongs to one consent/session/controller.
/// There is no discovery, persistence, generic MCP entry point or inherited scope.
actor SwitchboardBridgeClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    typealias Exchange = @Sendable (SwitchboardPairingEnvelope, Data) async throws -> Data

    private var pairing: SwitchboardPairingEnvelope?
    private var scope: SwitchboardBridgeScope
    private let now: @Sendable () -> Date
    private let exchange: Exchange
    private var registered = false
    private var inFlight = false
    private var highestDeliveredRevision: Int64 = 0

    nonisolated var description: String {
        "SwitchboardBridgeClient(redacted)"
    }

    nonisolated var debugDescription: String {
        description
    }

    nonisolated var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    init(
        pairing: SwitchboardPairingEnvelope,
        scope: SwitchboardBridgeScope,
        now: @escaping @Sendable () -> Date = { Date() },
        exchange: @escaping Exchange = { pairing, request in
            try await Task.detached {
                try SwitchboardBridgeTransport.exchange(pairing: pairing, request: request)
            }.value
        }
    ) {
        self.pairing = pairing
        self.scope = scope
        self.now = now
        self.exchange = exchange
    }

    func register(threadID: String?) async throws {
        guard scope.threadID == nil || scope.threadID == threadID else { throw SwitchboardBridgeError.identityMismatch }
        if let threadID { try validateText(threadID) }
        guard let attemptedPairing = pairing else { throw SwitchboardBridgeError.revoked }
        let result = try await request(op: "register", threadID: threadID)
        do {
            guard pairing != nil else { throw SwitchboardBridgeError.revoked }
            try result.requireKeys(["registered"])
            guard result["registered"] == .bool(true) else { throw SwitchboardBridgeError.invalidRequest }
            try Task.checkCancellation()
            // Only the first registration must complete within this deadline.
            if !registered, attemptedPairing.expiresAt <= now() { throw SwitchboardBridgeError.expired }
            registered = true
            scope.threadID = threadID
        } catch {
            // The server may already have bound even a rejected acknowledgment.
            // Invalidate locally before awaiting exact-attempt remote cleanup.
            pairing = nil
            await sendRevocation(attemptedPairing, threadID: threadID)
            throw error as? SwitchboardBridgeError ?? .unavailable
        }
    }

    func poll(lastSeenRevision: Int64) async throws -> CodexAccountAdoptionGrant? {
        try validateRevision(lastSeenRevision, allowZero: true)
        let lastSeen = max(lastSeenRevision, highestDeliveredRevision)
        let result = try await request(op: "poll", additional: ["last_seen_revision": lastSeen])
        try result.requireKeys(["selection"])
        if result["selection"] == .null { return nil }
        let grant = try SwitchboardBridgeWire.selection(result["selection"], now: now())
        guard grant.revision > lastSeen else { throw SwitchboardBridgeError.staleRevision }
        highestDeliveredRevision = grant.revision
        return grant
    }

    func refresh(previousGrant: CodexAccountAdoptionGrant) async throws -> CodexAccountAdoptionGrant {
        try validateRevision(previousGrant.revision)
        try validateText(previousGrant.accountID)
        let result = try await request(op: "refresh", additional: [
            "adoption_id": previousGrant.adoptionID.uuidString.lowercased(),
            "expected_revision": previousGrant.revision,
            "previous_account_id": previousGrant.accountID
        ])
        try result.requireKeys(["selection"])
        let grant = try SwitchboardBridgeWire.selection(result["selection"], now: now())
        guard grant.selectionID == previousGrant.selectionID,
              grant.adoptionID == previousGrant.adoptionID,
              grant.revision == previousGrant.revision,
              grant.accountID == previousGrant.accountID,
              grant.email == previousGrant.email,
              grant.accessToken != previousGrant.accessToken
        else { throw SwitchboardBridgeError.identityMismatch }
        return grant
    }

    func status(adoptionID: UUID, expectedRevision: Int64, state: String, reason: String) async throws {
        try validateRevision(expectedRevision)
        let states: Set = ["waiting_idle", "applying", "applied_unverified", "failed_unknown", "revoked"]
        let reasons: Set = [
            "none", "busy", "pending_interaction", "active_tools", "active_children", "queued_dispatch",
            "runtime_unavailable", "unsupported_runtime", "transport_unverified", "identity_changed",
            "grant_expired", "bridge_unavailable", "mutation_unconfirmed", "revoked"
        ]
        guard states.contains(state), reasons.contains(reason) else { throw SwitchboardBridgeError.invalidRequest }
        let result = try await request(op: "status", additional: [
            "adoption_id": adoptionID.uuidString.lowercased(), "expected_revision": expectedRevision,
            "state": state, "reason": reason
        ])
        try result.requireKeys(["accepted"])
        guard result["accepted"] == .bool(true) else { throw SwitchboardBridgeError.invalidRequest }
    }

    /// Local revocation takes effect before any suspension, including while a
    /// prior socket exchange is in flight. Remote acknowledgment is best effort.
    func revoke() async {
        guard let previous = pairing else { return }
        pairing = nil
        guard registered else { return }
        await sendRevocation(previous, threadID: scope.threadID)
    }

    private func sendRevocation(_ previous: SwitchboardPairingEnvelope, threadID: String?) async {
        let requestID = UUID()
        do {
            let data = try makeRequest(op: "revoke", requestID: requestID, pairing: previous, threadID: threadID, additional: [:])
            let response = try await exchange(previous, data)
            let result = try SwitchboardBridgeWire.response(response, requestID: requestID)
            try result.requireKeys(["revoked"])
            guard result["revoked"] == .bool(true) else { return }
        } catch {
            // Local authority remains revoked; never surface remote error text.
        }
    }

    private func request(op: String, threadID: String? = nil, additional: [String: Any] = [:]) async throws -> [String: SwitchboardJSONValue] {
        guard let pairing else { throw SwitchboardBridgeError.revoked }
        guard !inFlight else { throw SwitchboardBridgeError.unavailable }
        if !registered {
            guard op == "register" else { throw SwitchboardBridgeError.unauthorized }
            guard pairing.expiresAt > now() else {
                self.pairing = nil
                throw SwitchboardBridgeError.expired
            }
        }
        let nativeID = op == "register" ? threadID : scope.threadID
        if op != "register", nativeID == nil { throw SwitchboardBridgeError.identityMismatch }
        if let nativeID { try validateText(nativeID) }
        let requestID = UUID()
        let pinnedScope = scope
        let data = try makeRequest(op: op, requestID: requestID, pairing: pairing, threadID: nativeID, additional: additional)
        inFlight = true
        defer { inFlight = false }
        do {
            let response = try await exchange(pairing, data)
            guard self.pairing != nil, scope == pinnedScope else { throw SwitchboardBridgeError.revoked }
            try Task.checkCancellation()
            return try SwitchboardBridgeWire.response(response, requestID: requestID)
        } catch {
            let stable = self.pairing == nil ? .revoked : (error as? SwitchboardBridgeError ?? .unavailable)
            if op == "register" || [.unauthorized, .revoked, .unavailable, .invalidRequest].contains(stable) {
                self.pairing = nil
                // Cancellation, lost replies, and explicit revocation can all
                // abandon a registration that completed on the server.
                if op == "register" { await sendRevocation(pairing, threadID: nativeID) }
            }
            throw stable
        }
    }

    private func makeRequest(
        op: String,
        requestID: UUID,
        pairing: SwitchboardPairingEnvelope,
        threadID: String?,
        additional: [String: Any]
    ) throws -> Data {
        var object: [String: Any] = [
            "v": 1, "id": requestID.uuidString.lowercased(), "capability": pairing.capability, "op": op,
            "consent_id": scope.consentID.uuidString.lowercased(),
            "session_id": scope.sessionID.uuidString.lowercased(),
            "controller_generation": scope.controllerGeneration.uuidString.lowercased(),
            "thread_id": threadID.map { $0 as Any } ?? NSNull()
        ]
        object.merge(additional) { current, _ in current }
        return try SwitchboardBridgeWire.encodeFrame(object)
    }

    private func validateRevision(_ revision: Int64, allowZero: Bool = false) throws {
        guard revision >= (allowZero ? 0 : 1), revision <= 9_007_199_254_740_991
        else { throw SwitchboardBridgeError.invalidRequest }
    }

    private func validateText(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SwitchboardBridgeError.invalidRequest }
    }
}
