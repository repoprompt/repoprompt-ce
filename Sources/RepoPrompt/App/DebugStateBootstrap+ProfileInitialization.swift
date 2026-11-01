import Foundation
import RepoPromptShared

extension DebugStateBootstrap {
    static let preferencesIDKey = "DebugStateBootstrapPreferencesID"

    enum PreparationAction: String {
        case reused, imported, reset, recoveredPreferences
    }

    struct Preparation {
        let lease: DebugProfileAccessLease
        let action: PreparationAction
        let receipt: DebugStateSnapshot.Receipt?
    }

    private enum ProfileState {
        case empty, existing, pendingPreferences(DebugStateSnapshot.Receipt)
    }

    static func prepareProfile(
        locations: AppProfileLocations,
        defaults: UserDefaults,
        preferencesDomain: String,
        cleanSlate: Bool = false,
        preferenceSourceURL: URL? = nil,
        cancellation: DebugStateSnapshot.Cancellation? = nil
    ) throws -> Preparation {
        guard locations.identity.buildFlavor == .debug else { throw DebugStateSnapshot.Failure.unsafeDestination }
        try cancellation?.check()
        let preferenceDirectory = locations.homeDirectory.appendingPathComponent("Library/Preferences")
        let previousPreferencesURL = preferenceDirectory.appendingPathComponent(locations.preferencesDomain + ".plist")
        try locations.validateMetadataFile(previousPreferencesURL)
        if FileManager.default.fileExists(atPath: previousPreferencesURL.path) {
            _ = try DebugStateSnapshot.stamp(previousPreferencesURL)
            guard try ((FileManager.default.attributesOfItem(atPath: previousPreferencesURL.path)[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
                throw DebugStateSnapshot.Failure.unsafeDestination
            }
        }

        if !cleanSlate, let reused = try reuseProfile(locations: locations, defaults: defaults, preferencesDomain: preferencesDomain) {
            return reused
        }

        let lease = try DebugProfileAccessLease.acquire(locations: locations, exclusive: true)
        let prior = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
        try cancellation?.check()
        if !cleanSlate {
            switch try profileState(locations: locations, preferences: prior) {
            case .existing:
                try lease.allowWriters()
                return Preparation(lease: lease, action: .reused, receipt: nil)
            case let .pendingPreferences(receipt):
                try applyPreferences(receipt: receipt, locations: locations, defaults: defaults, preferencesDomain: preferencesDomain)
                try lease.allowWriters()
                return Preparation(lease: lease, action: .recoveredPreferences, receipt: receipt)
            case .empty:
                break
            }
        }

        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: locations.homeDirectory)
        let receipt = try seed(
            locations: locations,
            cleanSlate: cleanSlate,
            releasePreferences: nil,
            previousPreferences: prior,
            preferenceSourceURL: cleanSlate ? nil : (preferenceSourceURL ?? preferenceDirectory.appendingPathComponent(release.preferencesDomain + ".plist")),
            previousPreferenceFileURL: previousPreferencesURL,
            profileLease: lease,
            cancellation: cancellation
        )
        try applyPreferences(receipt: receipt, locations: locations, defaults: defaults, preferencesDomain: preferencesDomain)
        try lease.allowWriters()
        return Preparation(lease: lease, action: cleanSlate ? .reset : .imported, receipt: receipt)
    }

    private static func reuseProfile(locations: AppProfileLocations, defaults: UserDefaults, preferencesDomain: String) throws -> Preparation? {
        let lease = try DebugProfileAccessLease.acquire(locations: locations, exclusive: false)
        let preferences = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
        guard case .existing = try profileState(locations: locations, preferences: preferences) else { return nil }
        return Preparation(lease: lease, action: .reused, receipt: nil)
    }

    private static func profileState(locations: AppProfileLocations, preferences: [String: Any]) throws -> ProfileState {
        let root = locations.applicationSupportRoot
        let fm = FileManager.default
        try locations.validateWritableRoot(root)
        if fm.fileExists(atPath: root.path) {
            try DebugStateSnapshot.requireDirectory(root)
            let receiptURL = root.appendingPathComponent("debugSeed.json")
            try locations.validateMetadataFile(receiptURL)
            if fm.fileExists(atPath: receiptURL.path) {
                _ = try DebugStateSnapshot.stamp(receiptURL)
                guard let receipt = try? JSONDecoder().decode(DebugStateSnapshot.Receipt.self, from: Data(contentsOf: receiptURL)),
                      receipt.version == 1, receipt.profile == locations.preferencesDomain
                else {
                    throw DebugStateSnapshot.Failure.unsafeDestination
                }
                if let id = receipt.preferencesID, preferences[preferencesIDKey] as? String != id.uuidString {
                    return .pendingPreferences(receipt)
                }
                return .existing
            }
            if try fm.contentsOfDirectory(atPath: root.path).contains(where: { $0 != ".DS_Store" }) {
                return .existing
            }
        }
        return preferences.isEmpty ? .empty : .existing
    }

    private static func applyPreferences(receipt: DebugStateSnapshot.Receipt, locations: AppProfileLocations, defaults: UserDefaults, preferencesDomain: String) throws {
        let url = locations.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")
        try locations.validateMetadataFile(url)
        _ = try DebugStateSnapshot.stamp(url)
        guard let id = receipt.preferencesID,
              var preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        else {
            throw DebugStateSnapshot.Failure.unsafeDestination
        }
        preferences[preferencesIDKey] = id.uuidString
        defaults.setPersistentDomain(preferences, forName: preferencesDomain)
    }
}
