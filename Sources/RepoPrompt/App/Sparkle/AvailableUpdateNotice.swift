import Foundation

struct AppcastCheckRequestIdentity: Equatable {
    let id: UUID
    let channel: UpdateChannel

    init(id: UUID = UUID(), channel: UpdateChannel) {
        self.id = id
        self.channel = channel
    }
}

/// Immutable identity and presentation for a detected app update.
///
/// The channel is captured when the update is detected so a live notice never
/// changes identity when the user's channel preference changes.
struct AvailableUpdateNotice: Equatable {
    let channel: UpdateChannel
    let version: String
    let buildNumber: String?
    let date: Date?
    let releaseNotes: String?

    var versionLabel: String {
        let version = normalizedVersion
        guard !version.isEmpty else { return "Update" }
        return "v\(version)"
    }

    var channelVersionLabel: String {
        switch channel {
        case .stable: versionLabel
        case .tip: "Tip build \(versionLabel)"
        }
    }

    var detailedVersionLabel: String {
        guard channel == .tip, let buildNumber = normalizedBuildNumber else {
            return channelVersionLabel
        }
        return "\(channelVersionLabel) (\(buildNumber))"
    }

    var toolbarLabel: String {
        switch channel {
        case .stable: "Update \(versionLabel)"
        case .tip: channelVersionLabel
        }
    }

    var availabilityStatus: String {
        switch channel {
        case .stable:
            let version = normalizedVersion
            return "Version \(version.isEmpty ? "Unknown" : version) is available"
        case .tip:
            return "\(detailedVersionLabel) is available"
        }
    }

    var availableTooltip: String {
        switch channel {
        case .stable: "Update available: \(versionLabel) — click for release notes"
        case .tip: "\(detailedVersionLabel) is available — click for release notes"
        }
    }

    var notReadyTooltip: String {
        switch channel {
        case .stable: "Update available: \(versionLabel), but Sparkle is not ready to check for updates yet"
        case .tip: "\(detailedVersionLabel) is available, but Sparkle is not ready to check for updates yet"
        }
    }

    var accessibilityLabel: String {
        switch channel {
        case .stable: "Update available, version \(versionLabel)"
        case .tip: "\(detailedVersionLabel) update available"
        }
    }

    var menuInstallTitle: String {
        switch channel {
        case .stable:
            let version = normalizedVersion
            return "Install Update \(version)…"
        case .tip:
            return "Install \(channelVersionLabel)…"
        }
    }

    var installButtonTitle: String {
        switch channel {
        case .stable: "Install Update"
        case .tip: "Install Tip Build"
        }
    }

    private var normalizedVersion: String {
        var version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        return version
    }

    private var normalizedBuildNumber: String? {
        guard let buildNumber = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !buildNumber.isEmpty
        else { return nil }
        return buildNumber
    }
}
