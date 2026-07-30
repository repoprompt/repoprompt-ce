import Foundation
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case tip

    static let userDefaultsKey = "RepoPromptUpdateChannel"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .tip: "Tip Builds"
        }
    }

    var shortDescription: String {
        switch self {
        case .stable: "Curated releases only."
        case .tip: "Latest signed and notarized main build."
        }
    }

    var feedURLString: String {
        switch self {
        case .stable:
            SecurityObfuscation.decode(SecurityObfuscation.stableFeedURLEncoded)
        case .tip:
            SecurityObfuscation.decode(SecurityObfuscation.tipFeedURLEncoded)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> UpdateChannel {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let channel = UpdateChannel(rawValue: rawValue)
        else {
            return .stable
        }
        return channel
    }

    static func store(_ channel: UpdateChannel, defaults: UserDefaults = .standard) {
        defaults.set(channel.rawValue, forKey: userDefaultsKey)
    }
}

final class SparkleUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateChannel.load().feedURLString
    }
}
