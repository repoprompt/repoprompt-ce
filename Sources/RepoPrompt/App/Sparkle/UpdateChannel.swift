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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record(stage: "update-found", outcome: .succeeded, item: item)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        record(
            stage: "user-choice-\(choice.diagnosticName)-\(state.stage.diagnosticName)",
            outcome: .selected,
            item: item
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        record(stage: "download-started", outcome: .started, item: item)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        record(stage: "download-finished", outcome: .succeeded, item: item)
    }

    func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: Error
    ) {
        record(
            stage: "download-finished",
            outcome: .failed,
            item: item,
            errorClass: Self.errorClass(error)
        )
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        record(stage: "download-finished", outcome: .cancelled)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        record(stage: "install-started", outcome: .started, item: item)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        record(stage: "relaunch-started", outcome: .started)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        // Routine no-update checks are high-volume and would evict the one-time
        // identity-migration milestones from the bounded diagnostic ledger.
        guard let error else { return }
        record(
            stage: "update-cycle-finished",
            outcome: .failed,
            errorClass: Self.errorClass(error)
        )
    }

    private func record(
        stage: String,
        outcome: IdentityTransitionDiagnosticEvent.Outcome,
        item: SUAppcastItem? = nil,
        errorClass: String? = nil
    ) {
        IdentityTransitionDiagnostics.shared.record(
            subsystem: .sparkle,
            stage: stage,
            outcome: outcome,
            targetDisplayVersion: item?.displayVersionString,
            targetBuildVersion: item?.versionString,
            errorClass: errorClass
        )
    }

    private static func errorClass(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? "cancelled" : "network"
        }
        return nsError.domain.localizedCaseInsensitiveContains("sparkle")
            ? "sparkle"
            : "other"
    }
}

private extension SPUUserUpdateChoice {
    var diagnosticName: String {
        switch self {
        case .skip: "skip"
        case .install: "install"
        case .dismiss: "dismiss"
        @unknown default: "unknown"
        }
    }
}

private extension SPUUserUpdateStage {
    var diagnosticName: String {
        switch self {
        case .notDownloaded: "not-downloaded"
        case .downloaded: "downloaded"
        case .installing: "installing"
        @unknown default: "unknown"
        }
    }
}
