import Foundation
import RepoPromptRemoteNetworking
import RepoPromptRemoteProtocol

enum RemoteNotificationDeliveryResult: Equatable {
    case notConfigured
    case delivered
    case failed(String)
}

/// Produces opaque, authenticated notification envelopes and forwards them to
/// an explicitly configured relay. The relay receives the device routing data
/// and encrypted bytes only; it never receives a prompt, path, command, or
/// transcript in plaintext.
@MainActor
final class RemoteNotificationRelay {
    private weak var pairingManager: RemotePairingManager?
    private let client = RemoteNotificationRelayClient()

    private(set) var lastAttemptAt: Date?
    private(set) var lastError: String?

    init(pairingManager: RemotePairingManager) {
        self.pairingManager = pairingManager
    }

    var isConfigured: Bool {
        guard let registration = pairingManager?.registeredNotification else { return false }
        return registration.relayURL?.isEmpty == false
    }

    func deliver(
        category: RemoteNotificationCategory,
        sessionID: UUID?
    ) async -> RemoteNotificationDeliveryResult {
        lastAttemptAt = Date()
        lastError = nil
        guard let pairingManager,
              let registration = pairingManager.registeredNotification,
              let relayString = registration.relayURL,
              let relayURL = URL(string: relayString),
              let credential = pairingManager.pairedCredential,
              let deviceID = pairingManager.pairedDeviceID
        else {
            return .notConfigured
        }
        let payload = RemoteNotificationPayload(
            category: category,
            desktopInstanceID: pairingManager.desktopInstanceID,
            sessionID: sessionID,
            title: title(for: category),
            body: body(for: category)
        )
        do {
            let envelope = try RemoteNotificationCrypto.seal(
                payload,
                credential: credential,
                desktopInstanceID: pairingManager.desktopInstanceID,
                deviceID: deviceID
            )
            try await client.deliver(
                to: relayURL, registration: registration,
                desktopInstanceID: pairingManager.desktopInstanceID, deviceID: deviceID,
                envelope: envelope
            )
            return .delivered
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    private func title(for category: RemoteNotificationCategory) -> String {
        switch category {
        case .agentNeedsInput: "RepoPrompt needs your input"
        case .approvalRequired: "RepoPrompt needs approval"
        case .completed: "RepoPrompt run completed"
        case .failed: "RepoPrompt run failed"
        }
    }

    private func body(for category: RemoteNotificationCategory) -> String {
        switch category {
        case .agentNeedsInput: "Open RepoPrompt Remote to continue."
        case .approvalRequired: "Review the pending approval on your paired Mac."
        case .completed: "A remote run is complete."
        case .failed: "A remote run needs attention."
        }
    }
}
