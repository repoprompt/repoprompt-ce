//
//  SparkleUpdateManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-28.
//

import AppKit
import Combine
import Sparkle
import SwiftUI

enum SparkleAppcastCheckState: Equatable {
    case notChecked
    case checking
    case succeeded
    case failed
}

enum SparkleUserInitiatedUpdateAction: Equatable {
    case unavailable
    case appcastDiscovery
    case sparkle
}

enum SparkleUpdaterStartDecision: Equatable {
    case ignore
    case discoveryOnly
    case start
}

#if DEBUG
    private var sparkleUpdaterManagerDebugLoggingEnabled = false
    private func sparkleUpdaterManagerDebugLog(_ message: @autoclosure () -> String) {
        guard sparkleUpdaterManagerDebugLoggingEnabled else { return }
        print("[SparkleUpdaterManager] \(message())")
    }
#else
    private func sparkleUpdaterManagerDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Class to monitor updates and provide UI notifications
@MainActor
final class SparkleUpdaterManager: ObservableObject {
    /// Singleton instance - set by AppDelegate on launch
    static var shared: SparkleUpdaterManager!
    private nonisolated static let stableFeedURL = SecurityObfuscation.decode(SecurityObfuscation.stableFeedURLEncoded)
    private nonisolated static let tipFeedURL = SecurityObfuscation.decode(SecurityObfuscation.tipFeedURLEncoded)
    private nonisolated static let expectedPublicEdKey = SecurityObfuscation.decode(SecurityObfuscation.expectedPublicEdKeyEncoded)
    nonisolated static let stableRecoveryDownloadsURL = URL(
        string: "https://github.com/repoprompt/repoprompt-ce-updates/releases"
    )
    nonisolated static let recoveryDownloadsCaveat =
        "Opening this page only provides recovery downloads; it does not verify that manually installing or downgrading a build is safe for this Mac."

    private struct CanonicalURL: Hashable {
        let scheme: String
        let host: String
        let port: Int?
        let path: String
    }

    private struct AcceptedSparkleConfiguration {
        let feed: CanonicalURL
        let publicEdKey: String
    }

    private struct AppcastUpdateInfo {
        let latestVersion: String
        let latestBuildNumber: String?
        let title: String?
        let date: Date?
        let releaseNotes: String?
        let downloadURL: URL?
    }

    private nonisolated static func canonicalizeFeedURL(_ raw: String) -> CanonicalURL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }

        // Normalize trailing slash
        var path = url.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let port = url.port
        return CanonicalURL(scheme: scheme, host: host, port: port, path: path)
    }

    private nonisolated static var acceptedConfigurations: [AcceptedSparkleConfiguration] {
        [stableFeedURL, tipFeedURL].compactMap { rawFeed in
            guard let canonical = canonicalizeFeedURL(rawFeed) else { return nil }
            return AcceptedSparkleConfiguration(feed: canonical, publicEdKey: expectedPublicEdKey)
        }
    }

    /// Cleans corrupt Sparkle preferences that may cause crashes
    /// Call this BEFORE initializing SPUStandardUpdaterController
    static func cleanCorruptPreferences() {
        let versionKeys = ["SUSkippedVersion", "SUSkippedMinorVersion"]
        for key in versionKeys {
            if let value = UserDefaults.standard.object(forKey: key), !(value is String) {
                UserDefaults.standard.removeObject(forKey: key)
                sparkleUpdaterManagerDebugLog("Removed corrupt preference '\(key)': was \(type(of: value)), expected String")
            }
        }
    }

    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private var updaterStarted = false
    private var discoveryEnabled = false
    private var periodicCheckTimer: Timer?
    private var appcastCheckTask: Task<AppcastUpdateInfo?, Never>?
    private var activeAppcastCheckRequest: AppcastCheckRequestIdentity?
    private var userInitiatedObserverState = SparkleUserInitiatedObserverState()
    private var userCheckResetWorkItem: DispatchWorkItem?
    private let httpClient: HTTPClient = DefaultHTTPClient.uiCriticalClient

    /// How often to check for updates (12 hours in seconds)
    private nonisolated static let updateCheckInterval: TimeInterval = 12 * 60 * 60

    /// UserDefaults key for last passive appcast check timestamp
    private nonisolated static let lastCheckKey = "SparkleLastUpdateCheck"

    /// UserDefaults key for RepoPrompt's passive appcast-check preference.
    private nonisolated static let passiveAppcastChecksKey = "RepoPromptPassiveAppcastChecksEnabled"

    /// Expose updater for settings UI
    var updater: SPUUpdater {
        updaterController.updater
    }

    @Published var canCheckForUpdates = false
    @Published private(set) var availableUpdate: AvailableUpdateNotice?
    @Published private(set) var sparkleConfigurationValid = true
    @Published private(set) var updatesDisabledMessage: String? = nil
    @Published private(set) var updateInstallationBlockedMessage: String? = nil
    @Published private(set) var appcastCheckState = SparkleAppcastCheckState.notChecked
    @Published private(set) var updateChannel: UpdateChannel

    /// Compatibility projections for diagnostics and callers. The notice
    /// remains the sole authority for update identity and presentation.
    var updateAvailable: Bool {
        availableUpdate != nil
    }

    var updateVersion: String? {
        availableUpdate?.version
    }

    var updateBuildNumber: String? {
        availableUpdate?.buildNumber
    }

    var updateDate: Date? {
        availableUpdate?.date
    }

    var updateDescription: String? {
        availableUpdate?.releaseNotes
    }

    var updateWarningMessage: String? {
        updatesDisabledMessage ?? updateInstallationBlockedMessage
    }

    var canDiscoverUpdates: Bool {
        discoveryEnabled && sparkleConfigurationValid &&
            (updateInstallationBlockedMessage != nil || canCheckForUpdates)
    }

    var canInstallAvailableUpdate: Bool {
        updaterStarted && sparkleConfigurationValid && updateInstallationBlockedMessage == nil
    }

    var migrationRecoveryDownloadsURL: URL? {
        Self.recoveryDownloadsURL(
            identityMigrationBlockedMessage: updateInstallationBlockedMessage
        )
    }

    var isDiscoveryOnly: Bool {
        discoveryEnabled && !updaterStarted && updateInstallationBlockedMessage != nil
    }

    var canInitiateUpdateCheck: Bool {
        canDiscoverUpdates && appcastCheckState != .checking
    }

    var updateCheckMenuTitle: String {
        Self.updateCheckMenuTitle(checkState: appcastCheckState)
    }

    var manualUpdateDownloadURL: URL? {
        Self.manualDownloadURL(
            for: availableUpdate,
            identityMigrationBlockedMessage: updateInstallationBlockedMessage
        )
    }

    var updateStatusText: String {
        Self.updateStatusText(
            availableUpdate: availableUpdate,
            checkState: appcastCheckState
        )
    }

    nonisolated static func recoveryDownloadsURL(
        identityMigrationBlockedMessage: String?
    ) -> URL? {
        guard identityMigrationBlockedMessage != nil else { return nil }
        return stableRecoveryDownloadsURL
    }

    nonisolated static func updateCheckMenuTitle(
        checkState: SparkleAppcastCheckState
    ) -> String {
        switch checkState {
        case .notChecked:
            "Check for Updates…"
        case .checking:
            "Checking for Updates…"
        case .succeeded:
            "Check for Updates… (Up to Date)"
        case .failed:
            "Check for Updates… (Last Check Failed)"
        }
    }

    nonisolated static func checkStateAfterCancellation(
        currentState: SparkleAppcastCheckState,
        hadActiveRequest: Bool
    ) -> SparkleAppcastCheckState {
        hadActiveRequest ? .notChecked : currentState
    }

    nonisolated static func manualDownloadURL(
        for notice: AvailableUpdateNotice?,
        identityMigrationBlockedMessage: String?
    ) -> URL? {
        guard identityMigrationBlockedMessage != nil,
              let notice,
              updateChannel(forAppcastItemURL: notice.downloadURL) == notice.channel
        else { return nil }
        return notice.downloadURL
    }

    nonisolated static func updateStatusText(
        availableUpdate: AvailableUpdateNotice?,
        checkState: SparkleAppcastCheckState
    ) -> String {
        if let availableUpdate {
            return availableUpdate.availabilityStatus
        }
        switch checkState {
        case .notChecked:
            return "Updates have not been checked yet"
        case .checking:
            return "Checking for updates…"
        case .succeeded:
            return "You have the latest version"
        case .failed:
            return "Unable to check for updates"
        }
    }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.passiveAppcastChecksKey)
            forceSparkleAutomaticChecksOff()
            if automaticallyChecksForUpdates {
                setupPeriodicUpdateCheck()
            } else {
                periodicCheckTimer?.invalidate()
                periodicCheckTimer = nil
                invalidateActiveAppcastCheck()
            }
        }
    }

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
        updateChannel = UpdateChannel.load()
        automaticallyChecksForUpdates = Self.loadPassiveAppcastChecksPreference(
            defaultingTo: updaterController.updater.automaticallyChecksForUpdates
        )
        UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.passiveAppcastChecksKey)
        updaterController.updater.automaticallyChecksForUpdates = false

        let validation = validateSparkleConfiguration()
        sparkleConfigurationValid = validation.isValid
        updatesDisabledMessage = validation.message

        if !sparkleConfigurationValid {
            disableUpdatesForIntegrityFailure()
        }
    }

    func startUpdater() {
        updateInstallationBlockedMessage = IdentityMigrationRuntimeState.shared.updatesBlockedMessage()
        switch Self.startDecision(
            sparkleConfigurationValid: sparkleConfigurationValid,
            discoveryEnabled: discoveryEnabled,
            identityMigrationBlockedMessage: updateInstallationBlockedMessage
        ) {
        case .ignore:
            return
        case .discoveryOnly:
            discoveryEnabled = true
            forceSparkleAutomaticChecksOff()
            setupPeriodicUpdateCheck()
            return
        case .start:
            discoveryEnabled = true
        }

        // Install observers before activation so no Sparkle event can race registration.
        setupObservers()
        updaterController.startUpdater()
        updaterStarted = true
        forceSparkleAutomaticChecksOff()
        canCheckForUpdates = updaterController.updater.canCheckForUpdates

        // Schedule a background check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.performInitialUpdateCheck()
        }

        // Setup periodic passive update checking if enabled.
        setupPeriodicUpdateCheck()
    }

    nonisolated static func startDecision(
        sparkleConfigurationValid: Bool,
        discoveryEnabled: Bool,
        identityMigrationBlockedMessage: String?
    ) -> SparkleUpdaterStartDecision {
        guard sparkleConfigurationValid, !discoveryEnabled else { return .ignore }
        return identityMigrationBlockedMessage == nil ? .start : .discoveryOnly
    }

    nonisolated static func userInitiatedUpdateAction(
        discoveryEnabled: Bool,
        sparkleConfigurationValid: Bool,
        identityMigrationBlockedMessage: String?
    ) -> SparkleUserInitiatedUpdateAction {
        guard discoveryEnabled, sparkleConfigurationValid else { return .unavailable }
        return identityMigrationBlockedMessage == nil ? .sparkle : .appcastDiscovery
    }

    private static func loadPassiveAppcastChecksPreference(defaultingTo sparkleAutomaticChecks: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: passiveAppcastChecksKey) != nil {
            return UserDefaults.standard.bool(forKey: passiveAppcastChecksKey)
        }
        return sparkleAutomaticChecks
    }

    deinit {
        periodicCheckTimer?.invalidate()
        appcastCheckTask?.cancel()
        userCheckResetWorkItem?.cancel()
    }

    /// Performs initial passive update check using appcast parsing only.
    private func performInitialUpdateCheck() {
        guard discoveryEnabled, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
        Task {
            await performPassiveAppcastCheck()
        }
    }

    /// Sets up a timer to periodically check for updates
    private func setupPeriodicUpdateCheck() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
        guard discoveryEnabled, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
        forceSparkleAutomaticChecksOff()
        // Check if we need to do an immediate check based on last check time
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        let timeSinceLastCheck = now - lastCheck

        if lastCheck == 0 || timeSinceLastCheck >= Self.updateCheckInterval {
            // Either first run or enough time has passed, check now
            Task {
                await performPassiveAppcastCheck()
            }
        }

        // Schedule periodic passive checks every 12 hours using appcast parsing only.
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.performPassiveAppcastCheck()
            }
        }
    }

    @discardableResult
    private func performPassiveAppcastCheck() async -> Bool {
        await Self.performPassiveAppcastCheck {
            await self.checkAppcastDirectly()
        }
    }

    @discardableResult
    nonisolated static func performPassiveAppcastCheck(
        check: () async -> Bool,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async -> Bool {
        let succeeded = await check()
        if succeeded {
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
        }
        return succeeded
    }

    /// Directly fetches and parses the appcast.xml to check for updates.
    /// Returns true only when the appcast fetch and parse produced update info.
    @discardableResult
    func checkAppcastDirectly() async -> Bool {
        guard discoveryEnabled, sparkleConfigurationValid, userInitiatedObserverState.activeRequest == nil else {
            return false
        }

        invalidateActiveAppcastCheck()
        appcastCheckState = .checking

        let checkedChannel = updateChannel
        let requestIdentity = AppcastCheckRequestIdentity(channel: checkedChannel)
        let feedURL = checkedChannel.feedURLString
        guard let url = URL(string: feedURL) else {
            sparkleUpdaterManagerDebugLog("Invalid update feed URL for channel \(checkedChannel.rawValue): \(feedURL)")
            return false
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let currentBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let eligibilityContext = Self.currentEligibilityContext(
            currentBuildNumber: currentBuildNumber
        )
        let client = httpClient
        activeAppcastCheckRequest = requestIdentity
        let task = Task.detached(priority: .utility) {
            await Self.fetchAndParseAppcast(feedURL: url, httpClient: client, context: eligibilityContext)
        }
        appcastCheckTask = task
        let appcastInfo = await task.value

        guard Self.appcastResultIsCurrent(
            request: requestIdentity,
            activeRequest: activeAppcastCheckRequest,
            selectedChannel: updateChannel
        ), userInitiatedObserverState.activeRequest == nil else {
            sparkleUpdaterManagerDebugLog("Discarding stale appcast result for channel \(checkedChannel.rawValue)")
            return false
        }

        defer {
            activeAppcastCheckRequest = nil
            appcastCheckTask = nil
        }

        guard !task.isCancelled else { return false }
        apply(
            appcastInfo: appcastInfo,
            currentVersion: currentVersion,
            currentBuildNumber: currentBuildNumber,
            checkedChannel: checkedChannel
        )
        appcastCheckState = appcastInfo == nil ? .failed : .succeeded
        return appcastInfo != nil
    }

    nonisolated static func appcastResultIsCurrent(
        request: AppcastCheckRequestIdentity,
        activeRequest: AppcastCheckRequestIdentity?,
        selectedChannel: UpdateChannel
    ) -> Bool {
        request == activeRequest && request.channel == selectedChannel
    }

    nonisolated static func updateChannel(forAppcastItemURL url: URL?) -> UpdateChannel? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return nil }

        return UpdateChannel.allCases.first { channel in
            guard let feedURL = URL(string: channel.feedURLString),
                  feedURL.scheme?.lowercased() == url.scheme?.lowercased(),
                  feedURL.host?.lowercased() == url.host?.lowercased(),
                  let releasesRange = feedURL.path.range(of: "/releases/")
            else { return false }

            let repositoryPath = String(feedURL.path[..<releasesRange.lowerBound])
            let downloadPrefix = "\(repositoryPath)/releases/download/"
            guard url.path.hasPrefix(downloadPrefix) else { return false }
            let downloadComponents = url.path
                .dropFirst(downloadPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            return downloadComponents.count == 2 && downloadComponents.allSatisfy { !$0.isEmpty }
        }
    }

    nonisolated static func makePassiveAppcastRequest(feedURL: URL) -> URLRequest {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    nonisolated static func testFetchAndParseAppcastVersion(feedURL: URL, httpClient: HTTPClient) async -> String? {
        let currentBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return await fetchAndParseAppcast(
            feedURL: feedURL,
            httpClient: httpClient,
            context: currentEligibilityContext(currentBuildNumber: currentBuildNumber)
        )?.latestVersion
    }

    nonisolated static func currentEligibilityContext(
        currentBuildNumber: String
    ) -> AppcastEligibilityContext {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return AppcastEligibilityContext(
            currentBuildNumber: currentBuildNumber,
            osVersion: SparkleBuildVersion(
                major: osVersion.majorVersion,
                minor: osVersion.minorVersion,
                patch: osVersion.patchVersion
            )
        )
    }

    private nonisolated static func fetchAndParseAppcast(
        feedURL: URL,
        httpClient: HTTPClient,
        context: AppcastEligibilityContext
    ) async -> AppcastUpdateInfo? {
        let request = makePassiveAppcastRequest(feedURL: feedURL)

        do {
            guard !Task.isCancelled else { return nil }
            let response = try await httpClient.data(for: request)
            guard response.http.statusCode == 200 else {
                sparkleUpdaterManagerDebugLog("Failed to fetch appcast: \(response.http.statusCode)")
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let data = response.data
            return await Task.detached(priority: .utility) {
                let parser = AppcastParser()
                guard let latestVersion = parser.parse(data: data, context: context) else {
                    sparkleUpdaterManagerDebugLog("Failed to parse appcast - no eligible versions found")
                    return nil
                }
                return AppcastUpdateInfo(
                    latestVersion: latestVersion.version,
                    latestBuildNumber: latestVersion.buildNumber,
                    title: latestVersion.title,
                    date: latestVersion.date,
                    releaseNotes: latestVersion.releaseNotesURL ?? latestVersion.description,
                    downloadURL: latestVersion.downloadURL.flatMap(URL.init(string:))
                )
            }.value
        } catch {
            sparkleUpdaterManagerDebugLog("Failed to fetch/parse appcast: \(error)")
            return nil
        }
    }

    @MainActor
    private func apply(
        appcastInfo: AppcastUpdateInfo?,
        currentVersion: String,
        currentBuildNumber: String,
        checkedChannel: UpdateChannel
    ) {
        guard let appcastInfo else {
            sparkleUpdaterManagerDebugLog("Appcast check failed; preserving previous update state")
            return
        }

        let isNewer = appcastInfo.latestBuildNumber.flatMap { latestBuild in
            isBuildNumber(latestBuild, newerThan: currentBuildNumber)
        } ?? SparkleVersionComparison.isVersion(appcastInfo.latestVersion, newerThan: currentVersion)

        if isNewer {
            let presentationVersion = Self.presentationVersion(
                channel: checkedChannel,
                displayVersion: appcastInfo.latestVersion,
                title: appcastInfo.title
            )
            applyAvailableUpdateState(
                channel: checkedChannel,
                version: presentationVersion,
                buildNumber: appcastInfo.latestBuildNumber,
                shortCommitSHA: AvailableUpdateNotice.shortCommitSHA(fromTipTitle: appcastInfo.title),
                date: appcastInfo.date,
                description: appcastInfo.releaseNotes,
                downloadURL: Self.updateChannel(forAppcastItemURL: appcastInfo.downloadURL) == checkedChannel
                    ? appcastInfo.downloadURL
                    : nil
            )
            sparkleUpdaterManagerDebugLog("Update available: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>") (current: \(currentVersion) build \(currentBuildNumber))")
        } else {
            clearUpdateState()
            sparkleUpdaterManagerDebugLog("No update available. Current: \(currentVersion) build \(currentBuildNumber), Latest: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>")")
        }
    }

    private func isBuildNumber(_ lhs: String, newerThan rhs: String) -> Bool? {
        guard let lhsValue = SparkleBuildVersion(lhs),
              let rhsValue = SparkleBuildVersion(rhs)
        else { return nil }
        return lhsValue > rhsValue
    }

    private func setupObservers() {
        // Observe canCheckForUpdates changes
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                DispatchQueue.main.async { [weak self] in
                    guard let self, canCheckForUpdates != canCheck else { return }
                    canCheckForUpdates = canCheck
                }
            }
            .store(in: &cancellables)

        // Sparkle notifications do not carry a request token we can correlate with
        // user-initiated cycles. Positive results are safe to apply only for the
        // selected channel and may not downgrade a newer known build. A no-update
        // result is never allowed to clear a notice or finish a request.
        NotificationCenter.default.publisher(for: .init("SUUpdaterDidFindValidUpdateNotification"))
            .sink { [weak self] notification in
                guard let appcastItem = notification.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem else { return }

                DispatchQueue.main.async {
                    guard let self,
                          let resultChannel = Self.updateChannel(forAppcastItemURL: appcastItem.fileURL),
                          resultChannel == self.updateChannel,
                          Self.sparkleResultIsNotOlderThanKnownUpdate(
                              candidateBuildNumber: appcastItem.versionString,
                              knownBuildNumber: self.availableUpdate?.buildNumber
                          )
                    else {
                        sparkleUpdaterManagerDebugLog("Discarding mismatched or older Sparkle update result")
                        return
                    }

                    self.applyAvailableUpdateState(
                        channel: resultChannel,
                        version: Self.presentationVersion(
                            channel: resultChannel,
                            displayVersion: appcastItem.displayVersionString,
                            title: appcastItem.title
                        ),
                        buildNumber: appcastItem.versionString,
                        shortCommitSHA: AvailableUpdateNotice.shortCommitSHA(fromTipTitle: appcastItem.title),
                        date: appcastItem.date,
                        description: appcastItem.releaseNotesURL?.absoluteString ?? appcastItem.itemDescription,
                        downloadURL: appcastItem.fileURL
                    )
                    self.appcastCheckState = .succeeded
                    if let request = self.userInitiatedObserverState.requestToSettle(
                        afterPositiveResultFor: resultChannel
                    ) {
                        self.scheduleUserInitiatedSparkleCheckReset(for: request, after: 0)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .init("SUUpdaterDidNotFindUpdateNotification"))
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch self.userInitiatedObserverState.receiveUncorrelatedNoUpdate() {
                    case .preserveNoticeAndRequest:
                        sparkleUpdaterManagerDebugLog("Ignoring uncorrelatable Sparkle no-update result; preserving notice and request state")
                    }
                }
            }
            .store(in: &cancellables)

        // Listen for app restart notifications
        NotificationCenter.default.publisher(for: .init("SUUpdaterWillRestartNotification"))
            .sink { _ in
                sparkleUpdaterManagerDebugLog("Sparkle is about to restart the application for update installation")
                NotificationCenter.default.post(name: .appWillRestartForUpdate, object: nil)
            }
            .store(in: &cancellables)
    }

    nonisolated static func sparkleResultIsNotOlderThanKnownUpdate(
        candidateBuildNumber: String,
        knownBuildNumber: String?
    ) -> Bool {
        guard let knownBuildNumber,
              let knownBuild = SparkleBuildVersion(knownBuildNumber)
        else { return true }
        guard let candidateBuild = SparkleBuildVersion(candidateBuildNumber) else { return false }
        return candidateBuild >= knownBuild
    }

    nonisolated static func presentationVersion(
        channel: UpdateChannel,
        displayVersion: String,
        title: String?
    ) -> String {
        let fallbackVersion = sanitizeVersionString(displayVersion)
        guard channel == .tip else { return fallbackVersion }
        return AvailableUpdateNotice.marketingVersion(fromTipTitle: title) ?? fallbackVersion
    }

    nonisolated static func sanitizeVersionString(_ version: String) -> String {
        var version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("tip build") {
            version.removeFirst("tip build".count)
            version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return version.components(separatedBy: allowedCharacters.inverted).joined()
    }

    private func applyAvailableUpdateState(
        channel: UpdateChannel,
        version: String,
        buildNumber: String?,
        shortCommitSHA: String?,
        date: Date?,
        description: String?,
        downloadURL: URL?
    ) {
        let notice = AvailableUpdateNotice(
            channel: channel,
            version: version,
            buildNumber: buildNumber,
            shortCommitSHA: shortCommitSHA,
            date: date,
            releaseNotes: description,
            downloadURL: downloadURL
        )
        if availableUpdate != notice {
            availableUpdate = notice
        }
    }

    private func clearUpdateState() {
        if availableUpdate != nil {
            availableUpdate = nil
        }
    }

    private func invalidateActiveAppcastCheck() {
        let hadActiveRequest = appcastCheckTask != nil || activeAppcastCheckRequest != nil
        appcastCheckTask?.cancel()
        appcastCheckTask = nil
        activeAppcastCheckRequest = nil
        appcastCheckState = Self.checkStateAfterCancellation(
            currentState: appcastCheckState,
            hadActiveRequest: hadActiveRequest
        )
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard updateChannel != channel else { return }
        invalidateActiveAppcastCheck()
        if userInitiatedObserverState.activeRequest == nil,
           updaterController.updater.sessionInProgress
        {
            let request = userInitiatedObserverState.begin(channel: updateChannel)
            scheduleUserInitiatedSparkleCheckReset(for: request)
        }
        updateChannel = channel
        UpdateChannel.store(channel)
        clearUpdateState()
        appcastCheckState = .notChecked
        updaterController.updater.resetUpdateCycle()
        setupPeriodicUpdateCheck()
    }

    func checkForUpdates(silent: Bool = false) {
        guard discoveryEnabled, sparkleConfigurationValid else { return }
        if silent {
            // Passive checks are appcast-only by design; Sparkle UI remains user-initiated.
            guard automaticallyChecksForUpdates else { return }
            Task {
                await performPassiveAppcastCheck()
            }
        } else {
            switch Self.userInitiatedUpdateAction(
                discoveryEnabled: discoveryEnabled,
                sparkleConfigurationValid: sparkleConfigurationValid,
                identityMigrationBlockedMessage: updateInstallationBlockedMessage
            ) {
            case .appcastDiscovery:
                Task {
                    await checkAppcastDirectly()
                }
            case .sparkle:
                beginUserInitiatedSparkleCheck()
            case .unavailable:
                return
            }
        }
    }

    func installUpdate() {
        guard Self.userInitiatedUpdateAction(
            discoveryEnabled: discoveryEnabled,
            sparkleConfigurationValid: sparkleConfigurationValid,
            identityMigrationBlockedMessage: updateInstallationBlockedMessage
        ) == .sparkle else { return }
        beginUserInitiatedSparkleCheck()
    }

    func performAvailableUpdateAction() {
        if canInstallAvailableUpdate {
            installUpdate()
        } else if let manualUpdateDownloadURL {
            NSWorkspace.shared.open(manualUpdateDownloadURL)
        }
    }

    func openMigrationRecoveryDownloads() {
        guard let migrationRecoveryDownloadsURL else { return }

        let alert = NSAlert()
        alert.messageText = "Open Stable recovery downloads?"
        alert.informativeText = Self.recoveryDownloadsCaveat
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.open(migrationRecoveryDownloadsURL)
    }

    private func beginUserInitiatedSparkleCheck() {
        if let activeRequest = userInitiatedObserverState.activeRequest {
            guard !updaterController.updater.sessionInProgress else { return }
            finishUserInitiatedSparkleCheck(request: activeRequest)
        }

        invalidateActiveAppcastCheck()

        let request = userInitiatedObserverState.begin(channel: updateChannel)
        scheduleUserInitiatedSparkleCheckReset(for: request)
        updaterController.checkForUpdates(nil)
    }

    private func finishUserInitiatedSparkleCheck(request: SparkleUserInitiatedObserverState.Request) {
        guard userInitiatedObserverState.finish(request: request) else { return }
        userCheckResetWorkItem?.cancel()
        userCheckResetWorkItem = nil
    }

    private func cancelUserInitiatedSparkleCheck() {
        userInitiatedObserverState.cancel()
        userCheckResetWorkItem?.cancel()
        userCheckResetWorkItem = nil
    }

    private func scheduleUserInitiatedSparkleCheckReset(
        for request: SparkleUserInitiatedObserverState.Request,
        after delay: TimeInterval = 300
    ) {
        userCheckResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  userInitiatedObserverState.activeRequest == request
            else { return }
            if updaterController.updater.sessionInProgress {
                scheduleUserInitiatedSparkleCheckReset(for: request, after: 5)
            } else {
                finishUserInitiatedSparkleCheck(request: request)
            }
        }
        userCheckResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func forceSparkleAutomaticChecksOff() {
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.automaticallyChecksForUpdates = false
        }
    }

    // MARK: - Sparkle Integrity

    private func validateSparkleConfiguration() -> (isValid: Bool, message: String?) {
        guard let edKeyRaw = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String else {
            return (false, "Updates are disabled because the Sparkle signing key is missing from Info.plist.")
        }

        guard let canonical = Self.canonicalizeFeedURL(updateChannel.feedURLString) else {
            return (false, "Updates are disabled because the selected Sparkle feed URL is invalid.")
        }

        let edKey = edKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        let matches = Self.acceptedConfigurations.contains { accepted in
            accepted.feed == canonical && accepted.publicEdKey == edKey
        }

        if matches {
            return (true, nil)
        }

        return (false, "Updates are disabled because the update feed/signing key failed integrity validation. Please reinstall from the official website.")
    }

    private func disableUpdatesForIntegrityFailure() {
        clearUpdateState()
        cancelUserInitiatedSparkleCheck()
        canCheckForUpdates = false
        automaticallyChecksForUpdates = false
        updaterController.updater.automaticallyChecksForUpdates = false

        // Ensure there is always a user-visible reason if we disable updates
        if updatesDisabledMessage == nil {
            updatesDisabledMessage = "Updates are disabled due to an integrity validation failure."
        }
    }
}

#if DEBUG
    extension SparkleUpdaterManager {
        static func debugMainActorIsolationProbe() -> Bool {
            Thread.isMainThread
        }

        nonisolated static var debugLastCheckKey: String {
            lastCheckKey
        }

        nonisolated static var debugPassiveAppcastChecksKey: String {
            passiveAppcastChecksKey
        }

        nonisolated static var debugExpectedFeedURL: String {
            stableFeedURL
        }

        nonisolated static var debugTipFeedURL: String {
            tipFeedURL
        }

        nonisolated static func debugFeedURLMatchesExpected(_ raw: String) -> Bool {
            guard let canonical = canonicalizeFeedURL(raw) else { return false }
            return acceptedConfigurations.contains { $0.feed == canonical }
        }

        nonisolated static func debugIsVersion(_ lhs: String, newerThan rhs: String) -> Bool {
            SparkleVersionComparison.isVersion(lhs, newerThan: rhs)
        }

        @MainActor
        func debugPublishedSnapshot() -> [String: Any] {
            var snapshot: [String: Any] = [
                "sparkle_configuration_valid": sparkleConfigurationValid,
                "selected_update_channel": updateChannel.rawValue,
                "active_feed_url": updateChannel.feedURLString,
                "accepted_feed_urls": UpdateChannel.allCases.map(\.feedURLString),
                "updater_started": updaterStarted,
                "discovery_enabled": discoveryEnabled,
                "updates_disabled_message": updatesDisabledMessage ?? NSNull(),
                "update_installation_blocked_message": updateInstallationBlockedMessage ?? NSNull(),
                "appcast_check_state": String(describing: appcastCheckState),
                "can_check_for_updates": canCheckForUpdates,
                "sparkle_can_check_for_updates": updaterController.updater.canCheckForUpdates,
                "passive_appcast_checks_enabled": automaticallyChecksForUpdates,
                "sparkle_automatically_checks_for_updates": updaterController.updater.automaticallyChecksForUpdates,
                "update_available": updateAvailable,
                "update_version": updateVersion ?? NSNull(),
                "update_build_number": updateBuildNumber ?? NSNull(),
                "update_date_present": updateDate != nil,
                "update_description_present": updateDescription != nil,
                "appcast_task_present": appcastCheckTask != nil
            ]
            if let updateDate {
                snapshot["update_date_epoch"] = updateDate.timeIntervalSince1970
            } else {
                snapshot["update_date_epoch"] = NSNull()
            }
            if let appcastCheckTask {
                snapshot["appcast_task_cancelled"] = appcastCheckTask.isCancelled
            } else {
                snapshot["appcast_task_cancelled"] = NSNull()
            }
            return snapshot
        }

        @discardableResult
        func debugTriggerPassiveCheck() async -> Bool {
            await performPassiveAppcastCheck()
        }
    }
#endif
