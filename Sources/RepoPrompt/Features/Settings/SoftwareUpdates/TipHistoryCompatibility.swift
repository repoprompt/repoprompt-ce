import Foundation
import RepoPromptSecureStorage

enum TipHistoryRunningIdentity: Equatable {
    case legacy, successor, nonOfficial

    static var current: Self {
        switch OfficialApplicationIdentity.currentRunningIdentity {
        case .legacy: .legacy
        case .successor: .successor
        case nil: .nonOfficial
        }
    }
}

struct TipHistoryInstallationContext: Equatable {
    let installedBuild: SparkleBuildVersion?
    let installedBuildString: String
    let runningIdentity: TipHistoryRunningIdentity
    let osVersion: SparkleBuildVersion
    let architecture: String
    let migrationBlockedMessage: String?
    let sparkleConfigurationValid: Bool
}

enum TipHistoryDirection: Equatable { case older, newer }
enum TipHistoryCaution: Equatable {
    case dataCompatibilityNotGuaranteed, barrierUnknownInstalledOutsideHistory, credentialMigrationPaused, downloadOnlyNonOfficial

    var message: String {
        switch self {
        case .dataCompatibilityNotGuaranteed:
            "Older builds may not read data or credentials written by newer builds. Back up your data before reinstalling."
        case .barrierUnknownInstalledOutsideHistory:
            "RepoPrompt cannot check data-format changes between these builds."
        case .credentialMigrationPaused:
            "Credential migration is paused on this Mac. Installing a different build does not complete it."
        case .downloadOnlyNonOfficial:
            "This is not an official release installation. You may save a verified official build, but this does not approve replacing this app or migrating its data or credentials."
        }
    }
}

enum TipHistoryUnavailableReason: Equatable {
    case transitionInstaller, crossesIdentityBackward, crossesIdentityForward
    case downgradeBarrier(atBuild: String, reasons: [String])
    case unsupportedOS(required: String), unsupportedArchitecture
    case invalidMetadata(TipHistoryMetadataProblem)
    case nonOfficialRunningBuild, updatesDisabled, unorderableInstalledBuild, historyBehindInstalled, missingAsset

    var message: String {
        switch self {
        case .transitionInstaller: "The identity-transition installer is an upgrade-only installer, not a rollback target."
        case .crossesIdentityBackward: "This build uses the previous application identity. Reinstalling across identities is not supported."
        case .crossesIdentityForward: "Use Check for Updates — the transition installer must run first."
        case let .downgradeBarrier(build, reasons): "Cannot go back across build \(build): \(reasons.joined(separator: "; "))."
        case let .unsupportedOS(required): "This build requires macOS \(required) or later."
        case .unsupportedArchitecture: "This build does not support this Mac’s architecture."
        case let .invalidMetadata(problem): problem.rawValue
        case .nonOfficialRunningBuild: "Verified history downloads require an official Developer ID build of RepoPrompt CE."
        case .updatesDisabled: "Downloads are disabled because the update configuration could not be verified."
        case .unorderableInstalledBuild: "The installed build cannot be compared with this history."
        case .historyBehindInstalled: "History is behind the installed build. Refresh before downloading an older build."
        case .missingAsset: "This build’s download is missing from the release server (HTTP 404/410). Explicitly refresh history to revalidate the entry before trying again."
        }
    }
}

enum TipHistoryAvailability: Equatable {
    case installed
    case available(direction: TipHistoryDirection, cautions: [TipHistoryCaution])
    case unavailable(TipHistoryUnavailableReason)

    var canDownload: Bool {
        if case .available = self { return true }
        return false
    }

    var badge: String {
        switch self {
        case .installed: "Installed"
        case let .available(_, cautions) where cautions.contains(.downloadOnlyNonOfficial): "Download only"
        case .available(.older, _): "Older"
        case .available(.newer, _): "Newer"
        case .unavailable: "Unavailable"
        }
    }
}

enum TipHistoryCompatibility {
    static func evaluate(_ entry: TipHistoryEntry, in loaded: [TipHistoryEntry], context: TipHistoryInstallationContext) -> TipHistoryAvailability {
        if let problem = entry.metadataProblem { return .unavailable(.invalidMetadata(problem)) }
        guard context.sparkleConfigurationValid else { return .unavailable(.updatesDisabled) }
        let matchesIdentity = (context.runningIdentity == .legacy && entry.signingIdentity == .legacy) ||
            (context.runningIdentity == .successor && entry.signingIdentity == .successor)
        if let installed = context.installedBuild, installed == entry.build, matchesIdentity { return .installed }
        let downloadOnly = context.runningIdentity == .nonOfficial && entry.origin == .githubRelease
        guard context.runningIdentity != .nonOfficial || downloadOnly else { return .unavailable(.nonOfficialRunningBuild) }
        guard entry.role != .transition, entry.installationType == .application, entry.download != nil else {
            return .unavailable(.transitionInstaller)
        }
        if context.runningIdentity == .successor, entry.signingIdentity == .legacy { return .unavailable(.crossesIdentityBackward) }
        if context.runningIdentity == .legacy, entry.signingIdentity == .successor { return .unavailable(.crossesIdentityForward) }
        guard let minimum = entry.minimumSystemVersion else { return .unavailable(.invalidMetadata(.constraints)) }
        guard minimum <= context.osVersion else {
            return .unavailable(.unsupportedOS(required: entry.minimumSystemVersionString))
        }
        guard entry.architectures.contains(context.architecture) else { return .unavailable(.unsupportedArchitecture) }
        guard let installed = context.installedBuild else { return .unavailable(.unorderableInstalledBuild) }
        var cautions: [TipHistoryCaution] = downloadOnly ? [.downloadOnlyNonOfficial, .dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory] : []
        let older = entry.build < installed
        if older {
            if let barrier = loaded.first(where: { $0.build > entry.build && $0.build <= installed && $0.downgradeBarrier }) {
                return .unavailable(.downgradeBarrier(atBuild: barrier.buildNumber, reasons: barrier.downgradeBarrierReasons))
            }
            // An invalid record in the covered interval cannot be used as proof
            // of absence of a migration barrier, even when its Boolean looked safe.
            if let unknown = loaded.first(where: { $0.build > entry.build && $0.build <= installed && $0.metadataProblem != nil }) {
                return .unavailable(.downgradeBarrier(atBuild: unknown.buildNumber, reasons: ["Safety metadata is invalid"]))
            }
            guard let head = loaded.first, downloadOnly || installed <= head.build else { return .unavailable(.historyBehindInstalled) }
            if !cautions.contains(.dataCompatibilityNotGuaranteed) { cautions.append(.dataCompatibilityNotGuaranteed) }
            if entry.origin == .githubRelease || !loaded.contains(where: { $0.build == installed }) {
                if !cautions.contains(.barrierUnknownInstalledOutsideHistory) { cautions.append(.barrierUnknownInstalledOutsideHistory) }
            }
        }
        if context.migrationBlockedMessage != nil { cautions.append(.credentialMigrationPaused) }
        return .available(direction: older ? .older : .newer, cautions: cautions)
    }
}
