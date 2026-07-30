import Foundation

struct AppcastCheckRequestIdentity: Equatable {
    let id: UUID
    let channel: UpdateChannel

    init(id: UUID = UUID(), channel: UpdateChannel) {
        self.id = id
        self.channel = channel
    }
}

struct SparkleUserInitiatedObserverState: Equatable {
    struct Request: Equatable {
        let id: UUID
        let channel: UpdateChannel
    }

    enum UncorrelatedNoUpdateDisposition: Equatable {
        case preserveNoticeAndRequest
    }

    private(set) var activeRequest: Request?

    mutating func begin(channel: UpdateChannel, requestID: UUID = UUID()) -> Request {
        let request = Request(id: requestID, channel: channel)
        activeRequest = request
        return request
    }

    @discardableResult
    mutating func finish(request: Request) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        return true
    }

    mutating func cancel() {
        activeRequest = nil
    }

    func receiveUncorrelatedNoUpdate() -> UncorrelatedNoUpdateDisposition {
        .preserveNoticeAndRequest
    }

    func requestToSettle(afterPositiveResultFor channel: UpdateChannel) -> Request? {
        guard let activeRequest, activeRequest.channel == channel else { return nil }
        return activeRequest
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
    let shortCommitSHA: String?
    let date: Date?
    let releaseNotes: String?

    var versionLabel: String {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return "Unknown" }
        return trimmedVersion.lowercased().hasPrefix("v") ? trimmedVersion : "v\(trimmedVersion)"
    }

    var detailedVersionLabel: String {
        switch channel {
        case .stable:
            var components = ["Version \(versionLabel)"]
            if let normalizedBuildNumber {
                components.append("Build \(normalizedBuildNumber)")
            }
            return components.joined(separator: " · ")
        case .tip:
            var components = [normalizedBuildNumber.map { "Tip build \($0)" } ?? "Tip update"]
            components.append("Version \(versionLabel)")
            if let normalizedShortCommitSHA {
                components.append("Commit \(normalizedShortCommitSHA)")
            }
            return components.joined(separator: " · ")
        }
    }

    var toolbarLabel: String {
        switch channel {
        case .stable:
            "Update \(versionLabel)"
        case .tip:
            normalizedBuildNumber.map { "Tip build \($0)" } ?? "Tip \(versionLabel)"
        }
    }

    var availabilityStatus: String {
        "\(detailedVersionLabel) is available"
    }

    var availableTooltip: String {
        let action = hasUpdateDetails ? "click for update details" : "click to install"
        return "\(detailedVersionLabel) is available — \(action)"
    }

    var notReadyTooltip: String {
        "\(detailedVersionLabel) is available, but Sparkle is not ready to check for updates yet"
    }

    var accessibilityLabel: String {
        "\(detailedVersionLabel) update available"
    }

    var accessibilityHint: String {
        if hasUpdateDetails {
            return "Opens Sparkle's update details and install dialog."
        }
        return "Opens Sparkle's update and install dialog."
    }

    var menuInstallTitle: String {
        switch channel {
        case .stable:
            guard let normalizedBuildNumber else { return "Install Update \(versionLabel)…" }
            return "Install Update \(versionLabel) (build \(normalizedBuildNumber))…"
        case .tip:
            var context = [versionLabel]
            if let normalizedShortCommitSHA {
                context.append("commit \(normalizedShortCommitSHA)")
            }
            let tipBuild = normalizedBuildNumber.map { "Tip Build \($0)" } ?? "Tip Update"
            return "Install \(tipBuild) (\(context.joined(separator: ", ")))…"
        }
    }

    var installButtonTitle: String {
        switch channel {
        case .stable:
            "Install Update"
        case .tip:
            normalizedBuildNumber.map { "Install Tip Build \($0)" } ?? "Install Tip Update"
        }
    }

    static func marketingVersion(fromTipTitle title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.lowercased().hasPrefix("tip build "),
              let versionSeparator = title.range(of: " · v", options: .caseInsensitive),
              let commitSeparator = title.range(
                  of: " · commit ",
                  options: .caseInsensitive,
                  range: versionSeparator.upperBound ..< title.endIndex
              )
        else { return nil }

        let candidate = title[versionSeparator.upperBound ..< commitSeparator.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
        else { return nil }
        return candidate
    }

    static func shortCommitSHA(fromTipTitle title: String?) -> String? {
        guard let title,
              let separator = title.range(of: " · commit ", options: .caseInsensitive)
        else { return nil }

        let candidate = title[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard (7 ... 40).contains(candidate.count),
              candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { return nil }
        return candidate
    }

    private var normalizedBuildNumber: String? {
        guard let buildNumber = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !buildNumber.isEmpty else { return nil }
        return buildNumber
    }

    private var normalizedShortCommitSHA: String? {
        guard let shortCommitSHA = shortCommitSHA?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shortCommitSHA.isEmpty else { return nil }
        return shortCommitSHA
    }

    private var hasUpdateDetails: Bool {
        guard let releaseNotes = releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !releaseNotes.isEmpty
    }
}
