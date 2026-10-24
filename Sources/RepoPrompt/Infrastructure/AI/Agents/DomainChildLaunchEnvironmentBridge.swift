import Foundation
import RepoPromptDomainRuntime

/// The app-side launch boundary for M5's single-use private-child carrier.
///
/// The bridge removes inherited carrier keys before adding the current task-local
/// values so a process can never receive stale launch authority from its parent.
/// Creation of a real private endpoint and token redemption remain M6B work.
enum DomainChildLaunchEnvironmentBridge {
    private static let carrierKeys: Set<String> = [
        DomainChildLaunchCarrier.endpointEnvironmentKey,
        DomainChildLaunchCarrier.launchTokenEnvironmentKey,
        DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey
    ]

    static func mergingCurrentCarrier(
        into environment: [String: String]
    ) -> [String: String] {
        var merged = environment
        for key in carrierKeys {
            merged.removeValue(forKey: key)
        }
        guard let carrier = DomainChildLaunchContext.current else { return merged }
        for key in carrierKeys {
            if let value = carrier.environment[key], !value.isEmpty {
                merged[key] = value
            }
        }
        return merged
    }
}
