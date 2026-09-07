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

    var json: [String: Any] {
        ["pid": pid, "start": ["seconds": start.seconds, "microseconds": start.microseconds]]
    }
}
