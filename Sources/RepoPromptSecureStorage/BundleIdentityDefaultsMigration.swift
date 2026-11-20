import CoreFoundation
import Foundation

package struct BundleIdentityDefaultsMigrationReport: Equatable {
    package enum Outcome: String {
        case skipped
        case alreadyCompleted = "already-completed"
        case migrated
        case verificationFailed = "verification-failed"
    }

    package let outcome: Outcome
    package let copiedKeyCount: Int
    package let preservedKeyCount: Int
}

/// Copies missing legacy application preferences to the successor bundle ID once.
/// Existing successor values always win, including Sparkle and window-state values.
package enum BundleIdentityDefaultsMigration {
    package static let completionMarker = "RepoPromptIdentityDefaultsMigrationV1Completed"

    package static func migrateIfNeeded(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
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

        let successor = successorDomainName as CFString
        let successorDomain = readDomain(successor)
        let preservedKeyCount = successorDomain.keys.count(where: { $0 != completionMarker })
        if successorDomain[completionMarker] as? Bool == true {
            return BundleIdentityDefaultsMigrationReport(
                outcome: .alreadyCompleted,
                copiedKeyCount: 0,
                preservedKeyCount: preservedKeyCount
            )
        }

        let missingValues = readDomain(legacyDomainName as CFString).filter {
            $0.key != completionMarker && successorDomain[$0.key] == nil
        }
        let failure = BundleIdentityDefaultsMigrationReport(
            outcome: .verificationFailed,
            copiedKeyCount: missingValues.count,
            preservedKeyCount: preservedKeyCount
        )

        // Replacing the active application domain can clear it if the bulk replacement fails.
        // Apply only missing keys to the exact domain and commit them before publishing completion.
        if !missingValues.isEmpty {
            // Bulk writes can reject long legacy SwiftUI window-frame names or leave values
            // readable only in the process cache. Set each value directly.
            for (key, value) in missingValues {
                CFPreferencesSetValue(key as CFString, value as CFPropertyList, successor, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            guard synchronize(successor) else { return failure }
            let persisted = readDomain(successor)
            let copied = persisted.filter { missingValues[$0.key] != nil }
            guard NSDictionary(dictionary: missingValues).isEqual(to: copied) else { return failure }
        }

        let marker = completionMarker as CFString
        CFPreferencesSetValue(marker, kCFBooleanTrue, successor, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard synchronize(successor), readDomain(successor)[completionMarker] as? Bool == true else {
            CFPreferencesSetValue(marker, nil, successor, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = synchronize(successor)
            return failure
        }

        return BundleIdentityDefaultsMigrationReport(
            outcome: .migrated,
            copiedKeyCount: missingValues.count,
            preservedKeyCount: preservedKeyCount
        )
    }

    private static func readDomain(_ name: CFString) -> [String: Any] {
        CFPreferencesCopyMultiple(nil, name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private static func synchronize(_ name: CFString) -> Bool {
        CFPreferencesSynchronize(name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
