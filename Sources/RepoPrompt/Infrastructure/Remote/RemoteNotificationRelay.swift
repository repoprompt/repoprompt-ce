import Foundation
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
    private let session: URLSession

    private(set) var lastAttemptAt: Date?
    private(set) var lastError: String?

    init(pairingManager: RemotePairingManager) {
        self.pairingManager = pairingManager
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
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
        guard Self.isAllowedRelayURL(relayURL) else {
            let message = "Notification relay URL must use HTTPS (HTTP is allowed only for loopback development URLs)."
            lastError = message
            return .failed(message)
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
            let requestBody = RelayDeliveryRequest(
                platform: registration.platform,
                deviceToken: registration.deviceToken,
                desktopInstanceID: pairingManager.desktopInstanceID,
                deviceID: deviceID,
                envelope: envelope
            )
            var request = URLRequest(url: relayURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode)
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let message = "Notification relay returned HTTP \(status)."
                lastError = message
                return .failed(message)
            }
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

    private static func isAllowedRelayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private struct RelayDeliveryRequest: Codable {
        let platform: RemoteNotificationPlatform
        let deviceToken: String
        let desktopInstanceID: String
        let deviceID: String
        let envelope: RemoteNotificationEnvelope
    }
}
