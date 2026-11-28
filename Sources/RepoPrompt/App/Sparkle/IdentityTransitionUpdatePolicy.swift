import Foundation
import RepoPromptSecureStorage

/// Client-side fence for the one-time Apple identity transition.
///
/// The transition (T) appcast item is a privileged `.pkg` whose only Sparkle
/// floor is the preparer build, so every client above that floor, including
/// clients that already crossed to the successor identity, is technically
/// eligible for it. Release tooling now refuses to publish a second T, but an
/// install that already runs the successor bundle identifier must never take an
/// identity-crossing installer again regardless of what a feed advertises:
/// later updates are ordinary successor `.zip` application updates.
enum IdentityTransitionUpdatePolicy {
    /// Sparkle installation types that run the macOS Installer with
    /// administrator authorization instead of replacing the app bundle.
    static let privilegedInstallationTypes: Set<String> = ["package", "interactive-package"]

    enum Selection<Item> {
        /// No privileged item is advertised; keep Sparkle's own selection.
        case sparkleDefault
        /// No application update newer than the installed build is eligible.
        case noUpdate
        case item(Item)
    }

    static func hasCompletedIdentityTransition(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier
    }

    static func requiresPrivilegedInstaller(installationType: String?) -> Bool {
        installationType.map(privilegedInstallationTypes.contains) ?? false
    }

    /// Picks the greatest-build application update strictly newer than the
    /// installed build for a client that already runs the successor identity,
    /// ignoring identity-transition packages. Items whose build cannot be
    /// ordered, or whose `minimumUpdateVersion` the client does not satisfy,
    /// are never selected, so an older preparer ZIP is never chosen.
    static func successorSelection<Item>(
        from items: [Item],
        currentBuild: String?,
        installationType: (Item) -> String?,
        buildVersion: (Item) -> String,
        meetsMinimumUpdateVersion: (Item) -> Bool
    ) -> Selection<Item> {
        guard items.contains(where: { requiresPrivilegedInstaller(installationType: installationType($0)) }) else {
            return .sparkleDefault
        }
        guard let installed = currentBuild.flatMap(SparkleBuildVersion.init) else { return .noUpdate }
        let best = items
            .filter { !requiresPrivilegedInstaller(installationType: installationType($0)) && meetsMinimumUpdateVersion($0) }
            .compactMap { item in SparkleBuildVersion(buildVersion(item)).map { (item: item, build: $0) } }
            .filter { $0.build > installed }
            .max { $0.build < $1.build }
        return best.map { .item($0.item) } ?? .noUpdate
    }
}
