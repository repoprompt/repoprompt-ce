import CryptoKit
import Foundation

/// Protocol 2 is an additional authority, never a replacement for base pairing.
/// All typed values deliberately hide reflective/debug representations.
protocol SwitchboardAutomaticPrivateValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
extension SwitchboardAutomaticPrivateValue {
    var description: String {
        "SwitchboardAutomatic(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

enum SwitchboardAutomaticError: String, Error {
    case notEnrolled = "not_enrolled", policyChanged = "policy_changed", manualPriority = "manual_priority"
    case sourceChanged = "source_changed", ineligible, permitExpired = "permit_expired", permitUnknown = "permit_unknown"
}

struct SwitchboardAutomaticSource: Equatable, SwitchboardAutomaticPrivateValue {
    let selectionID: UUID
    let adoptionID: UUID
    let revision: Int64
    let accountID: String
    let fingerprint: String

    init(grant: CodexAccountAdoptionGrant) {
        selectionID = grant.selectionID
        adoptionID = grant.adoptionID
        revision = grant.revision
        accountID = grant.accountID
        fingerprint = Self.fingerprint(grant.accessToken)
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(_ value: SwitchboardJSONValue?) throws {
        let o = try SwitchboardAutomaticWire.object(value, keys: ["selection_id", "adoption_id", "selection_revision", "account_id", "grant_fingerprint"])
        selectionID = try o.uuid("selection_id")
        adoptionID = try o.uuid("adoption_id")
        revision = try o.integer("selection_revision", minimum: 1)
        accountID = try o.text("account_id")
        fingerprint = try o.hex("grant_fingerprint", count: 64)
    }

    var json: [String: Any] {
        [
            "selection_id": selectionID.lowercase,
            "adoption_id": adoptionID.lowercase,
            "selection_revision": revision,
            "account_id": accountID,
            "grant_fingerprint": fingerprint
        ]
    }
}

struct SwitchboardAutomaticNativePeer: Equatable, SwitchboardAutomaticPrivateValue {
    let pid: Int32
    let start: SwitchboardPairingEnvelope.ProcessStart
    init(pid: Int32, start: SwitchboardPairingEnvelope.ProcessStart) {
        self.pid = pid
        self.start = start
    }

    init(_ value: SwitchboardJSONValue?) throws {
        let o = try SwitchboardAutomaticWire.object(value, keys: ["pid", "start"])
        pid = try Int32(o.integer("pid", minimum: 1, maximum: Int64(Int32.max)))
        let s = try SwitchboardAutomaticWire.object(o["start"], keys: ["seconds", "microseconds"])
        start = try .init(seconds: s.integer("seconds"), microseconds: s.integer("microseconds", maximum: 999_999))
    }

    var json: [String: Any] {
        ["pid": pid, "start": ["seconds": start.seconds, "microseconds": start.microseconds]]
    }
}

struct SwitchboardAutomaticEnrollment: Equatable, SwitchboardAutomaticPrivateValue {
    let id: UUID
    let epoch: UUID
    let ruleID: String
    let ruleDigest: String
    let ruleEpoch: String
    let approvalRevision: Int64
    init(_ value: SwitchboardJSONValue?) throws {
        let o = try SwitchboardAutomaticWire.object(value, keys: ["enrollment_id", "enrollment_epoch", "rule_id", "rule_digest", "rule_epoch", "approval_revision"])
        id = try o.uuid("enrollment_id")
        epoch = try o.uuid("enrollment_epoch")
        ruleID = try o.text("rule_id", maxBytes: 64)
        guard ruleID.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw SwitchboardBridgeError.invalidRequest }
        ruleDigest = try o.hex("rule_digest", count: 64)
        ruleEpoch = try o.hex("rule_epoch", count: 32)
        approvalRevision = try o.integer("approval_revision")
    }
}

struct SwitchboardAutomaticControl: Equatable, SwitchboardAutomaticPrivateValue {
    enum State: String { case enabled, pausing, paused, pausingUnknown = "pausing_unknown" }
    let epoch: Int64
    let desiredPaused: Bool
    let state: State
    let cancelPermitIDs: [UUID]
    init(_ value: SwitchboardJSONValue?) throws {
        let o = try SwitchboardAutomaticWire.object(value, keys: ["control_epoch", "desired_paused", "effective_state", "cancel_permit_ids"])
        epoch = try o.integer("control_epoch")
        guard case let .bool(paused) = o["desired_paused"], let state = try State(rawValue: o.text("effective_state"))
        else { throw SwitchboardBridgeError.invalidRequest }
        desiredPaused = paused
        self.state = state
        cancelPermitIDs = try o.array("cancel_permit_ids", maximum: 64).map { try ["id": $0].uuid("id") }
        guard Set(cancelPermitIDs).count == cancelPermitIDs.count,
              state != .enabled || !paused,
              state != .paused || paused,
              state != .paused || cancelPermitIDs.isEmpty else { throw SwitchboardBridgeError.invalidRequest }
    }
}

enum SwitchboardAutomaticWire {
    static func object(_ value: SwitchboardJSONValue?, keys: Set<String>) throws -> [String: SwitchboardJSONValue] {
        guard case let .object(o) = value else { throw SwitchboardBridgeError.invalidRequest }
        try o.requireKeys(keys)
        return o
    }

    static func response(_ data: Data, requestID: UUID) throws -> [String: SwitchboardJSONValue] {
        let root = try SwitchboardBridgeWire.decodeFrame(data, allowsArrays: true)
        guard try root.integer("v") == 2, try root.uuid("id") == requestID else { throw SwitchboardBridgeError.invalidRequest }
        if root["error"] != nil {
            try root.requireKeys(["v", "id", "error"])
            let e = try object(root["error"], keys: ["code"])
            let code = try e.text("code")
            if let error = SwitchboardAutomaticError(rawValue: code) { throw error }
            throw SwitchboardBridgeError(rawValue: code) ?? .invalidRequest
        }
        try root.requireKeys(["v", "id", "result"])
        return try root.object("result")
    }
}

extension [String: SwitchboardJSONValue] {
    func array(_ key: String, maximum: Int) throws -> [SwitchboardJSONValue] {
        guard case let .array(values) = self[key], values.count <= maximum else { throw SwitchboardBridgeError.invalidRequest }
        return values
    }

    func hex(_ key: String, count: Int) throws -> String {
        let value = try text(key, maxBytes: count)
        guard value.utf8.count == count, value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
        else { throw SwitchboardBridgeError.invalidRequest }
        return value
    }
}

private extension UUID {
    var lowercase: String {
        uuidString.lowercased()
    }
}
