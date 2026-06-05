import Foundation

/// Neutral input for verifying that a connected peer is the app-bundled helper.
package struct BundledHelperPeerVerificationInput: Equatable {
    package let expectedExecutableURL: URL
    package let peerPID: Int

    package init(expectedExecutableURL: URL, peerPID: Int) {
        self.expectedExecutableURL = expectedExecutableURL
        self.peerPID = peerPID
    }
}

package protocol BundledHelperPeerVerifying: Sendable {
    func matches(_ input: BundledHelperPeerVerificationInput) -> Bool
}
