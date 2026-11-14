import Darwin
import Foundation
import RepoPromptShared

extension DebugStateBootstrap {
    enum PreparationAction: String {
        case reused, imported, reset, recoveredPreferences
    }

    struct Preparation {
        let lease: DebugProfileAccessLease
        let action: PreparationAction
        let receipt: DebugStateSnapshot.Receipt?
    }

    /// Testable pre-store boundary. Reuse does only fixed-path checks: no production
    /// access, receipt/corpus scan, profile publication, or stale preference replay.
    /// A first ordinary launch starts empty; only `.fresh` imports production.
    static func prepareProfile(
        mode: Mode,
        locations: AppProfileLocations,
        defaults: UserDefaults,
        preferencesDomain: String,
        preferenceSourceURL: URL? = nil,
        synchronize: (UserDefaults) -> Bool = { $0.synchronize() },
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

        if mode == .reuse, let reused = try reuseProfile(locations: locations) {
            return reused
        }

        let lease = try DebugProfileAccessLease.acquire(locations: locations, exclusive: true)
        try cancellation?.check()
        if mode == .reuse {
            let recovered = try installPendingPreferences(locations: locations, defaults: defaults, domain: preferencesDomain, synchronize: synchronize)
            try lease.allowWriters()
            return Preparation(lease: lease, action: recovered ? .recoveredPreferences : .reused, receipt: nil)
        }

        let clean = mode == .clean
        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: locations.homeDirectory)
        let receipt = try seed(
            locations: locations,
            cleanSlate: clean,
            releasePreferences: nil,
            previousPreferences: defaults.persistentDomain(forName: preferencesDomain) ?? [:],
            preferenceSourceURL: clean ? nil : (preferenceSourceURL ?? preferenceDirectory.appendingPathComponent(release.preferencesDomain + ".plist")),
            previousPreferenceFileURL: previousPreferencesURL,
            profileLease: lease,
            cancellation: cancellation
        )
        try installPendingPreferences(locations: locations, defaults: defaults, domain: preferencesDomain, synchronize: synchronize)
        try lease.allowWriters()
        return Preparation(lease: lease, action: clean ? .reset : .imported, receipt: receipt)
    }

    /// A shared lease lets a headless writer keep running. Pending preferences need the
    /// exclusive path, so this declines and lets the caller install them.
    private static func reuseProfile(locations: AppProfileLocations) throws -> Preparation? {
        let lease = try DebugProfileAccessLease.acquire(locations: locations, exclusive: false)
        let root = locations.applicationSupportRoot
        try locations.validateWritableRoot(root)
        if FileManager.default.fileExists(atPath: root.path) {
            try DebugStateSnapshot.requireDirectory(root)
        }
        var info = stat()
        let marker = root.appendingPathComponent(DebugStateSnapshot.pendingPreferencesMarkerName)
        guard lstat(marker.path, &info) != 0, errno == ENOENT else { return nil }
        return Preparation(lease: lease, action: .reused, receipt: nil)
    }

    /// Publication stages this fence atomically with the files. A crash after the
    /// swap is repaired once, before stores open; legacy seedPreferences without a
    /// fence are never reapplied over the user's current debug preferences.
    @discardableResult
    private static func installPendingPreferences(
        locations: AppProfileLocations, defaults: UserDefaults, domain: String,
        synchronize: (UserDefaults) -> Bool
    ) throws -> Bool {
        let marker = locations.applicationSupportRoot.appendingPathComponent(DebugStateSnapshot.pendingPreferencesMarkerName)
        var info = stat()
        guard lstat(marker.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw PendingPreferencesFailure(underlyingDescription: "Could not inspect the pending-preferences marker.")
        }
        do {
            _ = try DebugStateSnapshot.stamp(marker)
            let url = locations.applicationSupportRoot.appendingPathComponent(DebugStateSnapshot.seedPreferencesFileName)
            try locations.validateMetadataFile(url)
            _ = try DebugStateSnapshot.stamp(url)
            guard let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
                throw PendingPreferencesFailure(underlyingDescription: "The staged preferences are not a property-list dictionary.")
            }
            defaults.setPersistentDomain(preferences, forName: domain)
            guard synchronize(defaults) else {
                throw PendingPreferencesFailure(underlyingDescription: "Preference synchronization did not complete.")
            }
            try FileManager.default.removeItem(at: marker)
            return true
        } catch let error as PendingPreferencesFailure {
            throw error
        } catch {
            throw PendingPreferencesFailure(underlyingDescription: error.localizedDescription)
        }
    }
}
