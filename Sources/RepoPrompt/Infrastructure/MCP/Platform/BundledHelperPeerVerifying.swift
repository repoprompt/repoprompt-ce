import Foundation

/// Neutral input for verifying that a connected peer is the app-bundled helper.
struct BundledHelperPeerVerificationInput: Equatable {
    let expectedExecutableURL: URL
    let peerPID: Int
}

protocol BundledHelperPeerVerifying: Sendable {
    func matches(_ input: BundledHelperPeerVerificationInput) -> Bool
}
