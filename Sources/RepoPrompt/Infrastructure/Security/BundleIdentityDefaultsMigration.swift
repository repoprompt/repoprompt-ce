import Foundation

struct BundleIdentityDefaultsMigrationReport: Equatable {
    enum Outcome: String {
        case skipped
        case alreadyCompleted = "already-completed"
        case migrated
        case verificationFailed = "verification-failed"
    }

    let outcome: Outcome
    let copiedKeyCount: Int
    let preservedKeyCount: Int
}

/// Moves the legacy application preference domain to the successor bundle ID once.
/// Existing successor values always win, including Sparkle and window-state values.
enum BundleIdentityDefaultsMigration {
    static let completionMarker = "RepoPromptIdentityDefaultsMigrationV1Completed"

    static func migrateIfNeeded(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        legacyDomainName: String = RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
        successorDomainName: String = RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier
    ) -> BundleIdentityDefaultsMigrationReport {
        guard bundleIdentifier == RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier else {
            return BundleIdentityDefaultsMigrationReport(
                outcome: .skipped,
                copiedKeyCount: 0,
                preservedKeyCount: 0
            )
        }

        let successorDomain = defaults.persistentDomain(forName: successorDomainName) ?? [:]
        if successorDomain[completionMarker] as? Bool == true {
            return BundleIdentityDefaultsMigrationReport(
                outcome: .alreadyCompleted,
                copiedKeyCount: 0,
                preservedKeyCount: successorDomain.count
            )
        }

        let legacyDomain = defaults.persistentDomain(forName: legacyDomainName) ?? [:]
        var mergedDomain = legacyDomain
        mergedDomain.removeValue(forKey: completionMarker)
        for (key, value) in successorDomain {
            mergedDomain[key] = value
        }
        mergedDomain[completionMarker] = true

        let copiedKeyCount = legacyDomain.keys.count(where: {
            $0 != completionMarker && successorDomain[$0] == nil
        })
        let preservedKeyCount = successorDomain.keys.count(where: { $0 != completionMarker })

        defaults.setPersistentDomain(mergedDomain, forName: successorDomainName)
        let persistedDomain = defaults.persistentDomain(forName: successorDomainName) ?? [:]
        guard domainsMatch(expected: mergedDomain, actual: persistedDomain) else {
            return BundleIdentityDefaultsMigrationReport(
                outcome: .verificationFailed,
                copiedKeyCount: copiedKeyCount,
                preservedKeyCount: preservedKeyCount
            )
        }

        return BundleIdentityDefaultsMigrationReport(
            outcome: .migrated,
            copiedKeyCount: copiedKeyCount,
            preservedKeyCount: preservedKeyCount
        )
    }

    private static func domainsMatch(expected: [String: Any], actual: [String: Any]) -> Bool {
        NSDictionary(dictionary: expected).isEqual(to: actual)
    }
}
