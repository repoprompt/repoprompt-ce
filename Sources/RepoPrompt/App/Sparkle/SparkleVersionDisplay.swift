import Foundation
import Sparkle

struct SparkleVersionIdentities: Equatable {
    let available: String
    let installed: String
}

/// Supplies Sparkle's stock user driver with complete available and installed
/// identities while leaving update comparison on the underlying build versions.
final class SparkleVersionDisplay: NSObject, SPUStandardUserDriverDelegate, SUVersionDisplay {
    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        self
    }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        let identities = Self.formattedIdentities(
            availableDisplayVersion: update.displayVersionString,
            availableBuildNumber: update.versionString,
            availableTitle: update.title,
            installedDisplayVersion: inOutBundleDisplayVersion.pointee as String,
            installedBuildNumber: bundleVersion
        )
        return Self.apply(
            identities,
            toInstalledDisplayVersion: inOutBundleDisplayVersion
        )
    }

    static func apply(
        _ identities: SparkleVersionIdentities,
        toInstalledDisplayVersion installedDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>
    ) -> String {
        installedDisplayVersion.pointee = identities.installed as NSString
        return identities.available
    }

    static func formattedIdentities(
        availableDisplayVersion: String,
        availableBuildNumber: String,
        availableTitle: String?,
        installedDisplayVersion: String,
        installedBuildNumber: String
    ) -> SparkleVersionIdentities {
        let availableMarketingVersion = AvailableUpdateNotice.marketingVersion(
            fromTipTitle: availableTitle
        ) ?? SparkleUpdaterManager.sanitizeVersionString(availableDisplayVersion)
        let installedMarketingVersion = SparkleUpdaterManager.sanitizeVersionString(
            installedDisplayVersion
        )

        return SparkleVersionIdentities(
            available: formatIdentity(
                marketingVersion: availableMarketingVersion,
                buildNumber: availableBuildNumber,
                prefixesMarketingVersion: true
            ),
            installed: formatIdentity(
                marketingVersion: installedMarketingVersion,
                buildNumber: installedBuildNumber,
                prefixesMarketingVersion: false
            )
        )
    }

    private static func formatIdentity(
        marketingVersion: String,
        buildNumber: String,
        prefixesMarketingVersion: Bool
    ) -> String {
        let marketingVersion = marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildNumber = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        if !marketingVersion.isEmpty, !buildNumber.isEmpty {
            let prefix = prefixesMarketingVersion ? "v" : ""
            return "\(prefix)\(marketingVersion) (\(buildNumber))"
        }
        if !marketingVersion.isEmpty {
            return prefixesMarketingVersion ? "v\(marketingVersion)" : marketingVersion
        }
        return buildNumber
    }
}
