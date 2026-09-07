import Foundation

/// Independent control channel. No v1 in-flight gate, base revoke, discovery,
/// enrollment default or capability persistence is shared with this channel.
actor SwitchboardAutomaticClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String {
        "SwitchboardAutomaticClient(redacted)"
    }

    nonisolated var debugDescription: String {
        description
    }

    nonisolated var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    struct Sync: SwitchboardAutomaticPrivateValue {
        let control: SwitchboardAutomaticControl
        let offer: SwitchboardAutomaticOffer?
        let enrollment: SwitchboardAutomaticEnrollment?
        let intent: SwitchboardAutomaticIntent?
    }

    private let pairing: SwitchboardPairingEnvelope
    private let scope: CodexAccountAdoptionScope
    private let exchange: SwitchboardBridgeClient.Exchange
    private var serverID: UUID?

    init(pairing: SwitchboardPairingEnvelope, scope: CodexAccountAdoptionScope, exchange: @escaping SwitchboardBridgeClient.Exchange = { pairing, request in
        try await Task.detached { try SwitchboardBridgeTransport.exchange(pairing: pairing, request: request, allowsArrays: true) }.value
    }) {
        self.pairing = pairing
        self.scope = scope
        self.exchange = exchange
    }

    func hello() async throws {
        let result = try await request("auto_hello")
        try result.requireKeys(["automation_protocol", "server_id"])
        guard try result.integer("automation_protocol") == 1 else { throw SwitchboardBridgeError.invalidRequest }
        let id = try result.uuid("server_id")
        guard serverID == nil || serverID == id else { throw SwitchboardBridgeError.identityMismatch }
        serverID = id
    }

    func sync(enrollmentID: UUID?, epoch: Int64, source: SwitchboardAutomaticSource?, manualGeneration: Int64) async throws -> Sync {
        let result = try await request("auto_sync", [
            "enrollment_id": enrollmentID.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
            "last_control_epoch": epoch, "applied_binding": source.map { $0.json as Any } ?? NSNull(),
            "manual_generation": manualGeneration
        ])
        try result.requireKeys(["control", "offer", "enrollment", "intent"])
        return try Sync(
            control: .init(result["control"]),
            offer: result["offer"] == .null ? nil : .init(result["offer"]),
            enrollment: result["enrollment"] == .null ? nil : .init(result["enrollment"]),
            intent: result["intent"] == .null ? nil : .init(result["intent"])
        )
    }

    func accept(_ offer: SwitchboardAutomaticOffer) async throws -> (SwitchboardAutomaticEnrollment, SwitchboardAutomaticControl) {
        let result = try await request("auto_accept", [
            "offer_id": offer.id.uuidString.lowercased(), "enrollment_epoch": offer.enrollment.epoch.uuidString.lowercased(),
            "rule_digest": offer.enrollment.ruleDigest, "rule_epoch": offer.enrollment.ruleEpoch
        ])
        try result.requireKeys(["enrollment", "control"])
        let enrollment = try SwitchboardAutomaticEnrollment(result["enrollment"])
        guard enrollment == offer.enrollment else { throw SwitchboardBridgeError.identityMismatch }
        return try (enrollment, .init(result["control"]))
    }

    func prepare(_ intent: SwitchboardAutomaticIntent) async throws -> SwitchboardAutomaticPrepared? {
        let result = try await request("auto_prepare", ["intent_id": intent.id.uuidString.lowercased(), "source_binding": intent.source.json, "manual_generation": intent.manualGeneration])
        try result.requireKeys(["state", "prepared", "reason"])
        let state = try result.text("state")
        try validateReason(result.text("reason"))
        guard ["preparing", "prepared", "rejected"].contains(state) else { throw SwitchboardBridgeError.invalidRequest }
        if state != "prepared" {
            guard result["prepared"] == .null else { throw SwitchboardBridgeError.invalidRequest }
            return nil
        }
        let prepared = try SwitchboardAutomaticPrepared(result["prepared"])
        guard prepared.intent == intent else { throw SwitchboardBridgeError.identityMismatch }
        return prepared
    }

    func begin(_ prepared: SwitchboardAutomaticPrepared, nativePeer: SwitchboardAutomaticNativePeer) async throws -> SwitchboardAutomaticIssued {
        let intent = prepared.intent
        let result = try await request("auto_begin", [
            "prepared_id": prepared.id.uuidString.lowercased(), "rule_revision": intent.ruleRevision,
            "control_epoch": intent.controlEpoch, "source_binding": intent.source.json,
            "manual_generation": intent.manualGeneration, "native_peer": nativePeer.json
        ])
        return try .init(result, now: Date())
    }

    func finish(permitID: UUID, receipt: SwitchboardAutomaticReceipt) async throws -> SwitchboardAutomaticControl {
        let result = try await request("auto_finish", ["permit_id": permitID.uuidString.lowercased(), "receipt": receipt.json])
        try result.requireKeys(["accepted", "control"])
        guard result["accepted"] == .bool(true) else { throw SwitchboardBridgeError.invalidRequest }
        return try .init(result["control"])
    }

    func revoke(_ enrollment: SwitchboardAutomaticEnrollment) async throws -> SwitchboardAutomaticControl {
        let result = try await request("auto_revoke", ["enrollment_id": enrollment.id.uuidString.lowercased(), "enrollment_epoch": enrollment.epoch.uuidString.lowercased()])
        try result.requireKeys(["revoked", "control"])
        guard result["revoked"] == .bool(true) else { throw SwitchboardBridgeError.invalidRequest }
        return try .init(result["control"])
    }

    private func request(_ op: String, _ fields: [String: Any] = [:]) async throws -> [String: SwitchboardJSONValue] {
        if op != "auto_hello", serverID == nil { throw SwitchboardBridgeError.unavailable }
        let requestID = UUID()
        var object: [String: Any] = [
            "v": 2,
            "id": requestID.uuidString.lowercased(),
            "capability": pairing.capability,
            "op": op,
            "consent_id": scope.consentID.uuidString.lowercased(),
            "session_id": scope.sessionID.uuidString.lowercased(),
            "controller_generation": scope.controllerGeneration.uuidString.lowercased(),
            "thread_id": scope.threadID
        ]
        if op != "auto_hello", let serverID { object["server_id"] = serverID.uuidString.lowercased() }
        object.merge(fields) { current, _ in current }
        let data = try SwitchboardBridgeWire.encodeFrame(object)
        do {
            // Reentrant actor is intentional: a sync/control response must be
            // deliverable while begin/native settlement is in flight elsewhere.
            let response = try await exchange(pairing, data)
            return try SwitchboardAutomaticWire.response(response, requestID: requestID)
        } catch let error as SwitchboardAutomaticError { throw error
        } catch { throw error as? SwitchboardBridgeError ?? .unavailable }
    }

    private func validateReason(_ reason: String) throws {
        guard SwitchboardAutomaticReceipt.reasons.contains(reason) else { throw SwitchboardBridgeError.invalidRequest }
    }
}

struct SwitchboardAutomaticReceipt: Equatable, SwitchboardAutomaticPrivateValue {
    static let reasons: Set<String> = ["none", "paused", "not_enrolled", "busy", "pending_interaction", "active_tools", "active_children", "queued_dispatch", "recovery", "below_threshold", "cooldown", "no_destination", "quota_unavailable", "auth_required", "policy_changed", "source_changed", "manual_priority", "expired", "revoked", "transport_unverified", "native_unavailable", "mutation_unconfirmed", "publication_fenced"]
    enum Outcome: String { case applied, fencedUnpublished = "fenced_unpublished", fencedPrefixNativeEnded = "fenced_prefix_native_ended", publishedUnknownNativeEnded = "published_unknown_native_ended", unknown }
    let outcome: Outcome
    let publication: CodexAutomaticAdoptionPermit.Publication
    let nativeEnded: Bool
    let permitFenced: Bool
    let appliedBinding: SwitchboardAutomaticSource?
    let reason: String
    var json: [String: Any] {
        [
            "outcome": outcome.rawValue,
            "publication": publication.rawValue,
            "native_ended": nativeEnded,
            "permit_fenced": permitFenced,
            "applied_binding": appliedBinding.map { $0.json as Any } ?? NSNull(),
            "reason": reason
        ]
    }
}
