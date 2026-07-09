//
//  SparkleUpdateManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-28.
//

import Combine
import Sparkle
import SwiftUI

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
final class SparkleUpdaterManager: ObservableObject {
    /// Singleton instance - set by AppDelegate on launch
    static var shared: SparkleUpdaterManager!
    private static let stableFeedURL = SecurityObfuscation.decode(SecurityObfuscation.stableFeedURLEncoded)
    private static let tipFeedURL = SecurityObfuscation.decode(SecurityObfuscation.tipFeedURLEncoded)
    private static let expectedPublicEdKey = SecurityObfuscation.decode(SecurityObfuscation.expectedPublicEdKeyEncoded)

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
        let date: Date?
        let releaseNotes: String?
    }

    private static func canonicalizeFeedURL(_ raw: String) -> CanonicalURL? {
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

    private static var acceptedConfigurations: [AcceptedSparkleConfiguration] {
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
    private var periodicCheckTimer: Timer?
    private var appcastCheckTask: Task<AppcastUpdateInfo?, Never>?
    private var userInitiatedSparkleCheckInProgress = false
    private var pendingUserInitiatedPassiveVersion: String?
    private var pendingUserInitiatedPassiveBuildNumber: String?
    private var userCheckResetWorkItem: DispatchWorkItem?
    private var passivelySuppressedUpdateVersion: String?
    private let httpClient: HTTPClient = DefaultHTTPClient.uiCriticalClient

    /// How often to check for updates (12 hours in seconds)
    private static let updateCheckInterval: TimeInterval = 12 * 60 * 60

    /// UserDefaults key for last passive appcast check timestamp
    private static let lastCheckKey = "SparkleLastUpdateCheck"

    /// UserDefaults key for RepoPrompt's passive appcast-check preference.
    private static let passiveAppcastChecksKey = "RepoPromptPassiveAppcastChecksEnabled"

    /// Expose updater for settings UI
    var updater: SPUUpdater {
        updaterController.updater
    }

    @Published var canCheckForUpdates = false
    @Published var updateAvailable = false
    @Published private(set) var sparkleConfigurationValid = true
    @Published private(set) var updatesDisabledMessage: String? = nil
    @Published private(set) var updateChannel: UpdateChannel

    /// Tracks whether we detected an update via our custom appcast parser
    /// This prevents Sparkle's "no update" notification from overriding our detection
    private var customParserFoundUpdate = false

    // Update information
    @Published var updateVersion: String?
    @Published var updateBuildNumber: String?
    @Published var updateDate: Date?
    @Published var updateDescription: String?

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.passiveAppcastChecksKey)
            forceSparkleAutomaticChecksOff()
            if automaticallyChecksForUpdates {
                setupPeriodicUpdateCheck()
            } else {
                periodicCheckTimer?.invalidate()
                periodicCheckTimer = nil
                appcastCheckTask?.cancel()
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
        guard sparkleConfigurationValid, !updaterStarted else { return }

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
        guard updaterStarted, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
        Task {
            await performPassiveAppcastCheck()
        }
    }

    /// Sets up a timer to periodically check for updates
    private func setupPeriodicUpdateCheck() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
        guard updaterStarted, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
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
    static func performPassiveAppcastCheck(
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
        guard updaterStarted, sparkleConfigurationValid else { return false }
        let feedURL = updateChannel.feedURLString
        guard let url = URL(string: feedURL) else {
            sparkleUpdaterManagerDebugLog("Invalid update feed URL for channel \(updateChannel.rawValue): \(feedURL)")
            return false
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let currentBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let client = httpClient
        appcastCheckTask?.cancel()
        let task = Task.detached(priority: .utility) {
            await Self.fetchAndParseAppcast(feedURL: url, httpClient: client)
        }
        appcastCheckTask = task
        let appcastInfo = await task.value
        guard !Task.isCancelled else { return false }
        await MainActor.run {
            self.apply(
                appcastInfo: appcastInfo,
                currentVersion: currentVersion,
                currentBuildNumber: currentBuildNumber
            )
        }
        return appcastInfo != nil
    }

    static func makePassiveAppcastRequest(feedURL: URL) -> URLRequest {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    static func testFetchAndParseAppcastVersion(feedURL: URL, httpClient: HTTPClient) async -> String? {
        await fetchAndParseAppcast(feedURL: feedURL, httpClient: httpClient)?.latestVersion
    }

    private static func fetchAndParseAppcast(feedURL: URL, httpClient: HTTPClient) async -> AppcastUpdateInfo? {
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
                guard let latestVersion = parser.parse(data: data) else {
                    sparkleUpdaterManagerDebugLog("Failed to parse appcast - no versions found")
                    return nil
                }
                return AppcastUpdateInfo(
                    latestVersion: latestVersion.version,
                    latestBuildNumber: latestVersion.buildNumber,
                    date: latestVersion.date,
                    releaseNotes: latestVersion.releaseNotesURL
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
        currentBuildNumber: String
    ) {
        guard let appcastInfo else {
            sparkleUpdaterManagerDebugLog("Appcast check failed; preserving previous update state")
            return
        }

        let isNewer = appcastInfo.latestBuildNumber.flatMap { latestBuild in
            isBuildNumber(latestBuild, newerThan: currentBuildNumber)
        } ?? isVersion(appcastInfo.latestVersion, newerThan: currentVersion)

        if isNewer {
            let sanitizedLatestVersion = sanitizeVersionString(appcastInfo.latestVersion)
            let suppressionIdentifier = passiveSuppressionIdentifier(
                version: sanitizedLatestVersion,
                buildNumber: appcastInfo.latestBuildNumber
            )
            if passivelySuppressedUpdateVersion == suppressionIdentifier {
                customParserFoundUpdate = false
                clearUpdateState()
                sparkleUpdaterManagerDebugLog("Passive update \(suppressionIdentifier) suppressed for this session after manual Sparkle check")
                return
            }

            customParserFoundUpdate = true
            applyAvailableUpdateState(
                version: sanitizedLatestVersion,
                buildNumber: appcastInfo.latestBuildNumber,
                date: appcastInfo.date,
                description: appcastInfo.releaseNotes
            )
            sparkleUpdaterManagerDebugLog("Update available: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>") (current: \(currentVersion) build \(currentBuildNumber))")
        } else {
            customParserFoundUpdate = false
            passivelySuppressedUpdateVersion = nil
            clearUpdateState()
            sparkleUpdaterManagerDebugLog("No update available. Current: \(currentVersion) build \(currentBuildNumber), Latest: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>")")
        }
    }

    /// Compares two version strings to determine if the first is newer than the second
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Components = v1.split(separator: ".").compactMap { Int($0) }
        let v2Components = v2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(v1Components.count, v2Components.count)

        for i in 0 ..< maxLength {
            let v1Part = i < v1Components.count ? v1Components[i] : 0
            let v2Part = i < v2Components.count ? v2Components[i] : 0

            if v1Part > v2Part { return true }
            if v1Part < v2Part { return false }
        }
        return false
    }

    private func isBuildNumber(_ lhs: String, newerThan rhs: String) -> Bool? {
        guard let lhsValue = SparkleBuildVersion(lhs),
              let rhsValue = SparkleBuildVersion(rhs)
        else { return nil }
        return lhsValue > rhsValue
    }

    private func passiveSuppressionIdentifier(version: String, buildNumber: String?) -> String {
        guard let buildNumber, SparkleBuildVersion(buildNumber) != nil else { return version }
        return "\(version) (build \(buildNumber))"
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

        // Listen for update notifications
        NotificationCenter.default.publisher(for: .init("SUUpdaterDidFindValidUpdateNotification"))
            .sink { [weak self] notification in
                guard let appcastItem = notification.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem else { return }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishUserInitiatedSparkleCheck()
                    self.passivelySuppressedUpdateVersion = nil
                    self.customParserFoundUpdate = true // Sparkle agrees, mark as found
                    self.applyAvailableUpdateState(
                        version: self.sanitizeVersionString(appcastItem.displayVersionString),
                        buildNumber: nil,
                        date: appcastItem.date,
                        description: appcastItem.itemDescription
                    )
                }
            }
            .store(in: &cancellables)

        // Listen for "no update available" notifications.
        // User-initiated Sparkle results are authoritative for the current session.
        NotificationCenter.default.publisher(for: .init("SUUpdaterDidNotFindUpdateNotification"))
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.userInitiatedSparkleCheckInProgress || self.pendingUserInitiatedPassiveVersion != nil {
                        let suppressedVersion = self.pendingUserInitiatedPassiveVersion ?? self.updateVersion
                        let suppressedBuildNumber = self.pendingUserInitiatedPassiveBuildNumber ?? self.updateBuildNumber
                        self.finishUserInitiatedSparkleCheck()
                        self.passivelySuppressedUpdateVersion = suppressedVersion.map { version in
                            self.passiveSuppressionIdentifier(
                                version: version,
                                buildNumber: suppressedBuildNumber
                            )
                        }
                        self.customParserFoundUpdate = false
                        self.clearUpdateState()
                    } else if !self.customParserFoundUpdate {
                        self.clearUpdateState()
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

    private func sanitizeVersionString(_ version: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return version.components(separatedBy: allowedCharacters.inverted).joined()
    }

    private func applyAvailableUpdateState(
        version: String,
        buildNumber: String?,
        date: Date?,
        description: String?
    ) {
        if updateVersion != version {
            updateVersion = version
        }
        if updateBuildNumber != buildNumber {
            updateBuildNumber = buildNumber
        }
        if updateDate != date {
            updateDate = date
        }
        if updateDescription != description {
            updateDescription = description
        }
        if !updateAvailable {
            updateAvailable = true
        }
    }

    private func clearUpdateState() {
        if updateAvailable {
            updateAvailable = false
        }
        if updateVersion != nil {
            updateVersion = nil
        }
        if updateBuildNumber != nil {
            updateBuildNumber = nil
        }
        if updateDate != nil {
            updateDate = nil
        }
        if updateDescription != nil {
            updateDescription = nil
        }
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard updateChannel != channel else { return }
        updateChannel = channel
        UpdateChannel.store(channel)
        passivelySuppressedUpdateVersion = nil
        customParserFoundUpdate = false
        clearUpdateState()
        updaterController.updater.resetUpdateCycle()
        setupPeriodicUpdateCheck()
    }

    func checkForUpdates(silent: Bool = false) {
        guard updaterStarted, sparkleConfigurationValid else { return }
        if silent {
            // Passive checks are appcast-only by design; Sparkle UI remains user-initiated.
            guard automaticallyChecksForUpdates else { return }
            Task {
                await performPassiveAppcastCheck()
            }
        } else {
            beginUserInitiatedSparkleCheck()
        }
    }

    func installUpdate() {
        guard updaterStarted, sparkleConfigurationValid else { return }
        beginUserInitiatedSparkleCheck()
    }

    private func beginUserInitiatedSparkleCheck() {
        // Manual check: reset custom parser flag so Sparkle's response is authoritative.
        customParserFoundUpdate = false
        userInitiatedSparkleCheckInProgress = true
        pendingUserInitiatedPassiveVersion = updateVersion
        pendingUserInitiatedPassiveBuildNumber = updateBuildNumber
        scheduleUserInitiatedSparkleCheckReset()
        updaterController.checkForUpdates(nil)
    }

    private func finishUserInitiatedSparkleCheck(clearPendingVersion: Bool = true) {
        userInitiatedSparkleCheckInProgress = false
        if clearPendingVersion {
            pendingUserInitiatedPassiveVersion = nil
            pendingUserInitiatedPassiveBuildNumber = nil
        }
        userCheckResetWorkItem?.cancel()
        userCheckResetWorkItem = nil
    }

    private func scheduleUserInitiatedSparkleCheckReset() {
        userCheckResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishUserInitiatedSparkleCheck(clearPendingVersion: false)
        }
        userCheckResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: workItem)
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
        customParserFoundUpdate = false
        passivelySuppressedUpdateVersion = nil
        finishUserInitiatedSparkleCheck()
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
        static var debugLastCheckKey: String {
            lastCheckKey
        }

        static var debugPassiveAppcastChecksKey: String {
            passiveAppcastChecksKey
        }

        static var debugExpectedFeedURL: String {
            stableFeedURL
        }

        static var debugTipFeedURL: String {
            tipFeedURL
        }

        static func debugFeedURLMatchesExpected(_ raw: String) -> Bool {
            guard let canonical = canonicalizeFeedURL(raw) else { return false }
            return acceptedConfigurations.contains { $0.feed == canonical }
        }

        static func debugIsVersion(_ lhs: String, newerThan rhs: String) -> Bool {
            let lhsComponents = lhs.split(separator: ".").compactMap { Int($0) }
            let rhsComponents = rhs.split(separator: ".").compactMap { Int($0) }
            let maxLength = max(lhsComponents.count, rhsComponents.count)

            for index in 0 ..< maxLength {
                let lhsPart = index < lhsComponents.count ? lhsComponents[index] : 0
                let rhsPart = index < rhsComponents.count ? rhsComponents[index] : 0
                if lhsPart > rhsPart { return true }
                if lhsPart < rhsPart { return false }
            }
            return false
        }

        @MainActor
        func debugPublishedSnapshot() -> [String: Any] {
            var snapshot: [String: Any] = [
                "sparkle_configuration_valid": sparkleConfigurationValid,
                "selected_update_channel": updateChannel.rawValue,
                "active_feed_url": updateChannel.feedURLString,
                "accepted_feed_urls": UpdateChannel.allCases.map(\.feedURLString),
                "updater_started": updaterStarted,
                "updates_disabled_message": updatesDisabledMessage ?? NSNull(),
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
