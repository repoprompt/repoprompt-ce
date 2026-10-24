import Combine
import Compression
import CryptoKit
import Darwin
import Foundation
import os
@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

final class AppPlatformUtilityRecoveryTests: XCTestCase {
    func testSparkleUpdaterManagerRunsOnMainActorFromDetachedCaller() async {
        let (detachedCallerWasOnMainThread, managerRanOnMainThread) = await Task.detached {
            let detachedCallerWasOnMainThread = Thread.isMainThread
            let managerRanOnMainThread = await SparkleUpdaterManager.debugMainActorIsolationProbe()
            return (detachedCallerWasOnMainThread, managerRanOnMainThread)
        }.value

        XCTAssertFalse(detachedCallerWasOnMainThread)
        XCTAssertTrue(managerRanOnMainThread)
    }

    func testPassiveAppcastPredicateRunsOnMainActorFromDetachedCaller() async throws {
        let suiteName = "PassiveAppcastActorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1234)

        let (callerWasOnMainThread, predicateWasOnMainThread) = await Task.detached {
            let callerWasOnMainThread = Thread.isMainThread
            // Leave isolation contextual: an explicit @MainActor closure would mask
            // a regression that removes the helper parameter's actor annotation.
            let predicateWasOnMainThread = await SparkleUpdaterManager.performPassiveAppcastCheck(
                check: { Thread.isMainThread },
                now: now,
                defaults: defaults
            )
            return (callerWasOnMainThread, predicateWasOnMainThread)
        }.value

        XCTAssertFalse(callerWasOnMainThread)
        XCTAssertTrue(predicateWasOnMainThread)
        XCTAssertEqual(defaults.double(forKey: SparkleUpdaterManager.debugLastCheckKey), now.timeIntervalSince1970)
    }

    func testPassiveAppcastCheckRecordsTimestampOnlyAfterSuccess() async throws {
        let suiteName = "PassiveAppcastSettlementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SparkleUpdaterManager.debugLastCheckKey
        let previousCheck = 1234.0
        let now = Date(timeIntervalSince1970: 5678)

        for succeeds in [false, true] {
            defaults.set(previousCheck, forKey: key)
            let result = await SparkleUpdaterManager.performPassiveAppcastCheck(
                check: {
                    XCTAssertEqual(defaults.double(forKey: key), previousCheck)
                    return succeeds
                },
                now: now,
                defaults: defaults
            )

            XCTAssertEqual(result, succeeds)
            XCTAssertEqual(defaults.double(forKey: key), succeeds ? now.timeIntervalSince1970 : previousCheck)
        }
    }

    func testSparkleUpdaterStartDecisionKeepsDiscoveryAvailableDuringIdentityMigrationBlock() {
        XCTAssertEqual(
            SparkleUpdaterManager.startDecision(
                sparkleConfigurationValid: true,
                discoveryEnabled: false,
                identityMigrationBlockedMessage: "migration blocked"
            ),
            .discoveryOnly
        )
        XCTAssertEqual(
            SparkleUpdaterManager.startDecision(
                sparkleConfigurationValid: true,
                discoveryEnabled: false,
                identityMigrationBlockedMessage: nil
            ),
            .start
        )
        XCTAssertEqual(
            SparkleUpdaterManager.startDecision(
                sparkleConfigurationValid: false,
                discoveryEnabled: false,
                identityMigrationBlockedMessage: "migration blocked"
            ),
            .ignore
        )
        XCTAssertEqual(
            SparkleUpdaterManager.startDecision(
                sparkleConfigurationValid: true,
                discoveryEnabled: true,
                identityMigrationBlockedMessage: "migration blocked"
            ),
            .ignore
        )
    }

    func testAgentSessionDeepLinkURLRoundTripsAndRejectsInvalidScopedRoutes() throws {
        let route = try AgentSessionDeepLinkRoute(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        XCTAssertEqual(route.url.scheme, AppDeepLinkURLScheme.canonical)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: route.url), .route(.agentSession(route)))

        let sessionID = try XCTUnwrap(route.sessionID)
        let legacyAgentRoute = try XCTUnwrap(URL(string: "repoprompt://agent/session?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)&session_id=\(sessionID.uuidString)&window_id=7"))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyAgentRoute), .route(.agentSession(route)))

        let missingWorkspace = try XCTUnwrap(URL(string: "repoprompt-ce://agent/session?tab_id=\(route.tabID.uuidString)"))
        let malformedSession = try XCTUnwrap(URL(string: "repoprompt-ce://agent/session?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)&session_id=not-a-uuid"))
        let unsupportedAgentPath = try XCTUnwrap(URL(string: "repoprompt-ce://agent/other?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)"))

        XCTAssertEqual(AppDeepLinkRoute.parse(url: missingWorkspace), .invalidScopedRoute)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: malformedSession), .invalidScopedRoute)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: unsupportedAgentPath), .invalidScopedRoute)
    }

    func testCanonicalAndLegacySchemesRouteOpeners() throws {
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("repoprompt-ce"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("REPOPROMPT-CE"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("repoprompt"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("REPOPROMPT"))
        XCTAssertFalse(AppDeepLinkURLScheme.isSupported("https"))
        XCTAssertFalse(AppDeepLinkURLScheme.isSupported(nil))

        let ceOpen = try XCTUnwrap(URL(string: "repoprompt-ce://open//Users/example/Project?workspace=Review&files=Sources/App.swift,README.md&prompt=Review%20this&focus=true&ephemeral=true"))
        let legacyOpen = try XCTUnwrap(URL(string: "repoprompt://open//Users/example/Project?persist=false"))
        let cePrompt = try XCTUnwrap(URL(string: "repoprompt-ce://prompt?title=Review&content=Review%20the%20selection&focus=true"))
        let legacyPrompt = try XCTUnwrap(URL(string: "repoprompt://prompt?title=Review&content=Review%20the%20selection&focus=true"))
        let unsupportedScheme = try XCTUnwrap(URL(string: "https://open//Users/example/Project"))

        XCTAssertEqual(AppDeepLinkRoute.parse(url: ceOpen), .route(.legacyURL(ceOpen)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyOpen), .route(.legacyURL(legacyOpen)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: cePrompt), .route(.legacyURL(cePrompt)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyPrompt), .route(.legacyURL(legacyPrompt)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: unsupportedScheme), .unsupported)
    }

    @MainActor
    func testAgentSessionURLQueuesWhenNoLiveWindowsAreRegistered() async throws {
        let manager = WindowStatesManager.shared
        let originalWindows = manager.allWindows
        let originalPendingURLs = manager.pendingURLs
        manager.allWindows = []
        manager.pendingURLs = []
        defer {
            manager.allWindows = originalWindows
            manager.pendingURLs = originalPendingURLs
        }

        let route = try AgentSessionDeepLinkRoute(
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        await AppDeepLinkRouter(windowStatesManager: manager).route(url: route.url)

        XCTAssertEqual(manager.pendingURLs, [route.url])
    }

    @MainActor
    func testInAppAgentSessionRouteReturnsResultWithoutQueueingURL() async throws {
        let manager = WindowStatesManager.shared
        let originalWindows = manager.allWindows
        let originalPendingURLs = manager.pendingURLs
        manager.allWindows = []
        manager.pendingURLs = []
        defer {
            manager.allWindows = originalWindows
            manager.pendingURLs = originalPendingURLs
        }

        let route = try AgentSessionDeepLinkRoute(
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        let result = await AppDeepLinkRouter(windowStatesManager: manager).route(agentSession: route)

        XCTAssertEqual(result, .workspaceUnavailable)
        XCTAssertEqual(manager.pendingURLs, [])
    }

    func testAppcastParserSelectsHighestInlineVersionAndKeepsMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <title>Version 2.1.9</title>
                    <sparkle:shortVersionString>2.1.9</sparkle:shortVersionString>
                    <sparkle:version>319</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-2.1.9.zip" />
                </item>
                <item>
                    <title>Tip build 320 · v2.1.20 · commit abc1234def56</title>
                    <sparkle:shortVersionString>2.1.20</sparkle:shortVersionString>
                    <sparkle:version>320</sparkle:version>
                    <pubDate>Tue, 21 Apr 2026 12:28:34 +0000</pubDate>
                    <sparkle:releaseNotesLink>https://example.com/release-notes.html</sparkle:releaseNotesLink>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <enclosure url="https://example.com/RepoPrompt-2.1.20.zip" />
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8), context: Self.permissiveAppcastContext))

        XCTAssertEqual(version.version, "2.1.20")
        XCTAssertEqual(version.buildNumber, "320")
        XCTAssertEqual(version.title, "Tip build 320 · v2.1.20 · commit abc1234def56")
        XCTAssertEqual(AvailableUpdateNotice.marketingVersion(fromTipTitle: version.title), "2.1.20")
        XCTAssertEqual(AvailableUpdateNotice.shortCommitSHA(fromTipTitle: version.title), "abc1234def56")
        XCTAssertEqual(version.releaseNotesURL, "https://example.com/release-notes.html")
        XCTAssertEqual(version.downloadURL, "https://example.com/RepoPrompt-2.1.20.zip")
        XCTAssertEqual(version.minimumSystemVersion, "14.0")
        XCTAssertNotNil(version.date)
    }

    func testUpdateChannelDefaultsToStableAndPersistsTipSelection() throws {
        let suiteName = "UpdateChannelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .stable)

        UpdateChannel.store(.tip, defaults: defaults)

        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .tip)
        XCTAssertTrue(UpdateChannel.stable.feedURLString.contains("repoprompt-ce-updates"))
        XCTAssertTrue(UpdateChannel.tip.feedURLString.contains("repoprompt-ce-tip-updates"))
    }

    func testAppcastParserPrefersHighestBuildNumberForSameMarketingVersion() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>28</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-1.0.27-28.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>412</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-1.0.27-412.zip" />
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8), context: Self.permissiveAppcastContext))

        XCTAssertEqual(version.version, "1.0.27")
        XCTAssertEqual(version.buildNumber, "412")
    }

    private static let permissiveAppcastContext = AppcastEligibilityContext(
        currentBuildNumber: "1",
        osVersion: SparkleBuildVersion(major: 99, minor: 0, patch: 0)
    )

    func testTipBuildVersionSortsBetweenAdjacentStableBuilds() throws {
        let currentStable = try XCTUnwrap(SparkleBuildVersion("28"))
        let tip = try XCTUnwrap(SparkleBuildVersion("28.7.95"))
        let nextStable = try XCTUnwrap(SparkleBuildVersion("29"))

        XCTAssertGreaterThan(tip, currentStable)
        XCTAssertGreaterThan(nextStable, tip)
        XCTAssertEqual(SparkleBuildVersion("28"), SparkleBuildVersion("28.0.0"))
        XCTAssertNil(SparkleBuildVersion("28.7.95.1"))
    }

    func testMigrationRecoveryDownloadsRemainAvailableWithoutDetectedUpdate() throws {
        let blockedMessage = "migration blocked"
        let recoveryURL = try XCTUnwrap(SparkleUpdaterManager.recoveryDownloadsURL(
            identityMigrationBlockedMessage: blockedMessage
        ))

        XCTAssertEqual(
            recoveryURL.absoluteString,
            "https://github.com/repoprompt/repoprompt-ce-updates/releases"
        )
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: recoveryURL))
        XCTAssertNil(SparkleUpdaterManager.manualDownloadURL(
            for: nil,
            identityMigrationBlockedMessage: blockedMessage
        ))
        XCTAssertEqual(
            SparkleUpdaterManager.userInitiatedUpdateAction(
                discoveryEnabled: true,
                sparkleConfigurationValid: true,
                identityMigrationBlockedMessage: blockedMessage
            ),
            .appcastDiscovery
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: nil,
                checkState: .failed
            ),
            "Unable to check for updates"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateCheckMenuTitle(checkState: .failed),
            "Check for Updates… (Last Check Failed)"
        )
        XCTAssertTrue(SparkleUpdaterManager.recoveryDownloadsCaveat.contains("does not verify"))
        XCTAssertNil(SparkleUpdaterManager.recoveryDownloadsURL(
            identityMigrationBlockedMessage: nil
        ))
    }

    func testCancelledManualDiscoveryDoesNotClaimCurrentResult() {
        XCTAssertEqual(
            SparkleUpdaterManager.checkStateAfterCancellation(
                currentState: .checking,
                hadActiveRequest: true
            ),
            .notChecked
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: nil,
                checkState: .notChecked
            ),
            "Updates have not been checked yet"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.checkStateAfterCancellation(
                currentState: .failed,
                hadActiveRequest: false
            ),
            .failed
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateCheckMenuTitle(checkState: .checking),
            "Checking for Updates…"
        )
    }

    func testBlockedMigrationDiscoversNewerUpdateButRejectsSparkleInstallation() throws {
        let downloadURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/download/tip-repair/RepoPrompt.zip"
        ))
        let notice = AvailableUpdateNotice(
            channel: .tip,
            version: "1.4.2",
            buildNumber: "38.1.2",
            shortCommitSHA: "abcdef123456",
            date: nil,
            releaseNotes: "Repair release",
            downloadURL: downloadURL
        )

        XCTAssertEqual(
            SparkleUpdaterManager.userInitiatedUpdateAction(
                discoveryEnabled: true,
                sparkleConfigurationValid: true,
                identityMigrationBlockedMessage: "migration blocked"
            ),
            .appcastDiscovery
        )
        XCTAssertEqual(
            SparkleUpdaterManager.manualDownloadURL(
                for: notice,
                identityMigrationBlockedMessage: "migration blocked"
            ),
            downloadURL
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: notice,
                checkState: .succeeded
            ),
            notice.availabilityStatus
        )
        XCTAssertEqual(
            SparkleUpdaterManager.userInitiatedUpdateAction(
                discoveryEnabled: true,
                sparkleConfigurationValid: true,
                identityMigrationBlockedMessage: nil
            ),
            .sparkle
        )
    }

    func testUpdateStatusDoesNotClaimLatestBeforeSuccessfulCheck() {
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: nil,
                checkState: .notChecked
            ),
            "Updates have not been checked yet"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: nil,
                checkState: .failed
            ),
            "Unable to check for updates"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.updateStatusText(
                availableUpdate: nil,
                checkState: .succeeded
            ),
            "You have the latest version"
        )
    }

    func testAvailableUpdateNoticeKeepsDetectedChannelAndCentralizesTipCopy() {
        let notice = AvailableUpdateNotice(
            channel: .tip,
            version: "1.0.28",
            buildNumber: "29.8.52",
            shortCommitSHA: "abc1234def56",
            date: nil,
            releaseNotes: "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/tag/tip-abc1234def56"
        )

        XCTAssertEqual(notice.toolbarLabel, "Tip build 29.8.52")
        XCTAssertEqual(notice.availabilityStatus, "Tip build 29.8.52 · Version v1.0.28 · Commit abc1234def56 is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Tip Build 29.8.52 (v1.0.28, commit abc1234def56)…")
        XCTAssertEqual(notice.installButtonTitle, "Install Tip Build 29.8.52")
        XCTAssertEqual(notice.accessibilityLabel, "Tip build 29.8.52 · Version v1.0.28 · Commit abc1234def56 update available")
        XCTAssertEqual(notice.availableTooltip, "Tip build 29.8.52 · Version v1.0.28 · Commit abc1234def56 is available — click for update details")
        XCTAssertEqual(notice.accessibilityHint, "Opens Sparkle's update details and install dialog.")
        XCTAssertEqual(notice.channel, .tip)
    }

    func testStableUpdateNoticeUsesStableCopyWithoutTipLabel() {
        let notice = AvailableUpdateNotice(
            channel: .stable,
            version: "v1.0.29",
            buildNumber: "30",
            shortCommitSHA: nil,
            date: nil,
            releaseNotes: nil
        )

        XCTAssertEqual(notice.toolbarLabel, "Update v1.0.29")
        XCTAssertEqual(notice.availabilityStatus, "Version v1.0.29 · Build 30 is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Update v1.0.29 (build 30)…")
        XCTAssertEqual(notice.installButtonTitle, "Install Update")
        XCTAssertEqual(notice.availableTooltip, "Version v1.0.29 · Build 30 is available — click to install")
        XCTAssertEqual(notice.accessibilityHint, "Opens Sparkle's update and install dialog.")
        XCTAssertFalse(notice.availableTooltip.localizedCaseInsensitiveContains("release notes"))
        XCTAssertFalse(notice.availabilityStatus.contains("Tip"))
    }

    func testUncorrelatedSparkleNoUpdatePreservesNewerRequestAndNoticeDisposition() throws {
        var observerState = SparkleUserInitiatedObserverState()
        let olderRequestID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let newerRequestID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let olderRequest = observerState.begin(channel: .tip, requestID: olderRequestID)
        XCTAssertTrue(observerState.finish(request: olderRequest))
        let newerRequest = observerState.begin(channel: .tip, requestID: newerRequestID)

        let disposition = observerState.receiveUncorrelatedNoUpdate()

        XCTAssertEqual(disposition, .preserveNoticeAndRequest)
        XCTAssertEqual(observerState.activeRequest, newerRequest)
        XCTAssertFalse(observerState.finish(request: olderRequest))
        XCTAssertEqual(observerState.activeRequest, newerRequest)
    }

    func testSparklePositiveResultTargetsOnlyMatchingActiveRequestForSettlement() throws {
        var observerState = SparkleUserInitiatedObserverState()
        let requestID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        XCTAssertNil(observerState.requestToSettle(afterPositiveResultFor: .tip))
        let tipRequest = observerState.begin(channel: .tip, requestID: requestID)
        XCTAssertEqual(observerState.requestToSettle(afterPositiveResultFor: .tip), tipRequest)
        XCTAssertNil(observerState.requestToSettle(afterPositiveResultFor: .stable))
        XCTAssertEqual(observerState.activeRequest, tipRequest)
    }

    func testSparklePositiveResultsCannotDowngradeKnownBuilds() {
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.52",
            knownBuildNumber: nil
        ))
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.52",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.53",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertFalse(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.51",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertFalse(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "not-a-build",
            knownBuildNumber: "29.8.52"
        ))
    }

    func testSparkleDisplayVersionNormalizationRemovesTipDecoration() {
        let enrichedTipTitle = "Tip build 29.8.52 · v1.0.28 · commit abc1234def56"

        XCTAssertEqual(
            AvailableUpdateNotice.marketingVersion(fromTipTitle: enrichedTipTitle),
            "1.0.28"
        )
        XCTAssertNil(AvailableUpdateNotice.marketingVersion(fromTipTitle: "Tip build v1.0.27"))
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .tip,
                displayVersion: "1.0.28",
                title: enrichedTipTitle
            ),
            "1.0.28"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .tip,
                displayVersion: "Tip build v1.0.27",
                title: "Tip build v1.0.27"
            ),
            "1.0.27"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .stable,
                displayVersion: "v1.0.29",
                title: enrichedTipTitle
            ),
            "1.0.29"
        )

        let tipIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "1.1.0",
            availableBuildNumber: "31.11.89",
            availableTitle: "Tip build 31.11.89 · v1.1.0 · commit abc1234def56",
            installedDisplayVersion: "1.1.0",
            installedBuildNumber: "31.10.88"
        )
        XCTAssertEqual(tipIdentities.available, "v1.1.0 (31.11.89)")
        XCTAssertEqual(tipIdentities.installed, "1.1.0 (31.10.88)")

        var installedDisplayVersion: NSString = "1.1.0"
        let availableDisplayVersion = SparkleVersionDisplay.apply(
            tipIdentities,
            toInstalledDisplayVersion: &installedDisplayVersion
        )
        XCTAssertEqual(availableDisplayVersion, "v1.1.0 (31.11.89)")
        XCTAssertEqual(installedDisplayVersion, "1.1.0 (31.10.88)")

        let stableIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "1.2.0",
            availableBuildNumber: "32",
            availableTitle: "Version 1.2.0",
            installedDisplayVersion: "1.1.0",
            installedBuildNumber: "31"
        )
        XCTAssertEqual(stableIdentities.available, "v1.2.0 (32)")
        XCTAssertEqual(stableIdentities.installed, "1.1.0 (31)")

        let legacyTipIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "Tip build v1.0.27",
            availableBuildNumber: "29.8.51",
            availableTitle: "Tip build v1.0.27",
            installedDisplayVersion: "v1.0.26",
            installedBuildNumber: "29.8.50"
        )
        XCTAssertEqual(legacyTipIdentities.available, "v1.0.27 (29.8.51)")
        XCTAssertEqual(legacyTipIdentities.installed, "1.0.26 (29.8.50)")
    }

    func testAppcastRequestIdentityRejectsDelayedAndOverlappingResults() throws {
        let delayedTipRequest = try AppcastCheckRequestIdentity(
            id: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            channel: .tip
        )
        let latestStableRequest = try AppcastCheckRequestIdentity(
            id: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            channel: .stable
        )

        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: delayedTipRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))
        XCTAssertTrue(SparkleUpdaterManager.appcastResultIsCurrent(
            request: latestStableRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))

        let supersededStableRequest = AppcastCheckRequestIdentity(channel: .stable)
        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: supersededStableRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))
        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: latestStableRequest,
            activeRequest: nil,
            selectedChannel: .stable
        ))
    }

    func testSparkleAppcastItemURLIdentifiesOnlyExactTrustedUpdateChannels() throws {
        let tipURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/download/tip-abc/RepoPrompt.zip"
        ))
        let stableURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-updates/releases/download/v1.0.29/RepoPrompt.zip"
        ))
        let lookalikeRepositoryURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-updates-evil/releases/download/v1/RepoPrompt.zip"
        ))
        let queryURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-updates/releases/download/v1/RepoPrompt.zip?mirror=1"
        ))
        let insecureURL = try XCTUnwrap(URL(
            string: "http://github.com/repoprompt/repoprompt-ce-updates/releases/download/v1/RepoPrompt.zip"
        ))
        let malformedDownloadURL = try XCTUnwrap(URL(
            string: "https://github.com/repoprompt/repoprompt-ce-updates/releases/download/v1"
        ))

        XCTAssertEqual(SparkleUpdaterManager.updateChannel(forAppcastItemURL: tipURL), .tip)
        XCTAssertEqual(SparkleUpdaterManager.updateChannel(forAppcastItemURL: stableURL), .stable)
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: lookalikeRepositoryURL))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: queryURL))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: insecureURL))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: malformedDownloadURL))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: nil))
    }
}

// MARK: - TipHistoryArchiveTests

final class TipHistoryArchiveTests: XCTestCase {
    func testCancelledAdmissionStopsBeforeArchiveProcessing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        // A valid minimal stored ZIP with one entry; cancellation must be
        // observed even when there is no inflation work to check it.
        let bytes = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAAAAIQD8L29GBgAAAAYAAAAWAAAAUmVwb1Byb21wdCBDRS5hcHAvbGlua3RhcmdldFBLAQIUAxQAAAAAAAAAIQD8L29GBgAAAAYAAAAWAAAAAAAAAAAAAAD/oQAAAABSZXBvUHJvbXB0IENFLmFwcC9saW5rUEsFBgAAAAABAAEARAAAADoAAAAAAA=="))
        try bytes.write(to: url)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try TipHistoryArchive.validate(at: url, declaredExpandedSize: 6)
        }
        do { _ = try await task.value
            XCTFail("cancelled admission succeeded")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testCompressedSymlinkRequiresCompleteSingleStream() throws {
        let fixtures: [(String, String)] = [
            ("valid", "UEsDBBQAAAAIAAAAIQD8L29GCAAAAAYAAAAWAAAAUmVwb1Byb21wdCBDRS5hcHAvbGluaytJLEpPLQEAUEsBAhQDFAAAAAgAAAAhAPwvb0YIAAAABgAAABYAAAAAAAAAAAAAAP+hAAAAAFJlcG9Qcm9tcHQgQ0UuYXBwL2xpbmtQSwUGAAAAAAEAAQBEAAAAPAAAAAAA"),
            ("trailing", "UEsDBBQAAAAIAAAAIQD8L29GDAAAAAYAAAAWAAAAUmVwb1Byb21wdCBDRS5hcHAvbGluaytJLEpPLQEAanVua1BLAQIUAxQAAAAIAAAAIQD8L29GDAAAAAYAAAAWAAAAAAAAAAAAAAD/oQAAAABSZXBvUHJvbXB0IENFLmFwcC9saW5rUEsFBgAAAAABAAEARAAAAEAAAAAAAA=="),
            ("truncated", "UEsDBBQAAAAIAAAAIQD8L29GBwAAAAYAAAAWAAAAUmVwb1Byb21wdCBDRS5hcHAvbGluaytJLEpPLQFQSwECFAMUAAAACAAAACEA/C9vRgcAAAAGAAAAFgAAAAAAAAAAAAAA/6EAAAAAUmVwb1Byb21wdCBDRS5hcHAvbGlua1BLBQYAAAAAAQABAEQAAAA7AAAAAAA=")
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        for (name, encoded) in fixtures {
            try XCTUnwrap(Data(base64Encoded: encoded)).write(to: url)
            if name == "valid" {
                XCTAssertNoThrow(try TipHistoryArchive.validate(at: url, declaredExpandedSize: 6))
            } else {
                XCTAssertThrowsError(try TipHistoryArchive.validate(at: url, declaredExpandedSize: 6), name)
            }
        }
    }
}

// MARK: - TipHistoryDownloaderTests

private enum TipHistoryZIPFixture {
    struct Item {
        let name: String
        var data = Data()
        var link = false
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var declaredSize: UInt32?
        var extra = Data()
    }

    static func integer(_ value: some FixedWidthInteger) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    static let arm64: (UInt32, UInt32) = (0x0100_000C, 0)
    static let x86_64: (UInt32, UInt32) = (0x0100_0007, 3)

    /// Synthetic Mach-O header bytes only (never a runnable binary): one 32-byte
    /// MH_MAGIC_64 header per slice, wrapped in a fat header when requested.
    static func machO(_ slices: [(UInt32, UInt32)], fat: Bool = true) -> Data {
        func slice(_ cpu: UInt32, _ subtype: UInt32) -> Data {
            integer(UInt32(0xFEED_FACF)) + integer(cpu) + integer(subtype) + Data(count: 20)
        }
        guard fat else { return slice(slices[0].0, slices[0].1) }
        var data = integer(UInt32(0xCAFE_BABE).byteSwapped) + integer(UInt32(slices.count).byteSwapped)
        for (index, item) in slices.enumerated() {
            for value in [item.0, item.1, UInt32(4096 * (index + 1)), 32, 12] {
                data += integer(value.byteSwapped)
            }
        }
        data += Data(count: 4096 - data.count)
        for item in slices {
            data += slice(item.0, item.1) + Data(count: 4096 - 32)
        }
        return data
    }

    static func deflate(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let capacity = output.count
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(output.prefix(count))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0 ..< 8 {
                value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        return value ^ UInt32.max
    }

    static func archive(_ items: [Item]) -> Data {
        var local = Data()
        var central = Data()
        for item in items {
            let name = Data(item.name.utf8)
            let compressed = item.method == 8 ? deflate(item.data) : item.data
            let size = item.declaredSize ?? UInt32(item.data.count)
            let offset = UInt32(local.count)
            local += integer(UInt32(0x0403_4B50)) + integer(UInt16(20)) + integer(item.flags) + integer(item.method)
            local += integer(UInt16(0)) + integer(UInt16(0)) + integer(crc32(item.data))
            local += integer(UInt32(compressed.count)) + integer(size) + integer(UInt16(name.count)) + integer(UInt16(item.extra.count))
            local += name + item.extra + compressed
            central += integer(UInt32(0x0201_4B50)) + integer(UInt16(0x0314)) + integer(UInt16(20))
            central += integer(item.flags) + integer(item.method) + integer(UInt16(0)) + integer(UInt16(0)) + integer(crc32(item.data))
            central += integer(UInt32(compressed.count)) + integer(size) + integer(UInt16(name.count)) + integer(UInt16(item.extra.count))
            central += integer(UInt16(0)) + integer(UInt16(0)) + integer(UInt16(0))
            central += integer(UInt32(item.link ? 0xA1FF_0000 : 0x81A4_0000)) + integer(offset)
            central += name + item.extra
        }
        let end = integer(UInt32(0x0605_4B50)) + integer(UInt16(0)) + integer(UInt16(0)) + integer(UInt16(items.count)) + integer(UInt16(items.count)) + integer(UInt32(central.count)) + integer(UInt32(local.count)) + integer(UInt16(0))
        return local + central + end
    }
}

final class TipHistoryDownloaderTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func validate(_ items: [TipHistoryZIPFixture.Item], expanded: Int64 = 1_000_000) throws {
        let root = try temporaryDirectory()
        let zip = root.appendingPathComponent("fixture.zip")
        try TipHistoryZIPFixture.archive(items).write(to: zip)
        try TipHistoryArchive.validate(at: zip, declaredExpandedSize: expanded)
    }

    func testArchiveAllowsInAppFrameworkSymlinksAndRawDeflate() throws {
        let base = "RepoPrompt CE.app/Contents/Frameworks/Demo.framework/"
        try validate([
            .init(name: base + "Versions/A/Demo", data: Data(repeating: 7, count: 100_000), method: 8),
            .init(name: base + "Versions/Current", data: Data("A".utf8), link: true),
            .init(name: base + "Demo", data: Data("Versions/Current/Demo".utf8), link: true, method: 8)
        ])
    }

    func testArchiveRejectsTraversalAliasesCyclesDuplicatesAndPathOverrides() throws {
        let root = "RepoPrompt CE.app/"
        let cases: [[TipHistoryZIPFixture.Item]] = [
            [.init(name: "/tmp/escape")],
            [.init(name: root + "../escape")],
            [.init(name: "Other.app/file")],
            [.init(name: root + "bad\u{0}name")],
            [.init(name: root + "file"), .init(name: root + "FILE")],
            [.init(name: root + "Contents/escape", data: Data("../../outside".utf8), link: true)],
            [.init(name: root + "a", data: Data("b".utf8), link: true), .init(name: root + "b", data: Data("a".utf8), link: true)],
            [.init(name: root + "A", data: Data("Dir/b/../..".utf8), link: true), .init(name: root + "Dir/B", data: Data("..".utf8), link: true)],
            [.init(name: root + "A", data: Data("Dir".utf8), link: true), .init(name: root + "A/file"), .init(name: root + "Dir/file")],
            [.init(name: root + "file", extra: Data([0x75, 0x70, 0, 0]))],
            [.init(name: root + "file", flags: 1)],
            [.init(name: root + "file", flags: 0x40)],
            [.init(name: root + "file", flags: 0x2000)]
        ]
        for items in cases {
            XCTAssertThrowsError(try validate(items), "\(items.map(\.name))")
        }
    }

    func testForgedUncompressedSizesCannotBecomeFilesystemBombs() throws {
        // /usr/bin/unzip -t accepts this form when CRC matches the real output;
        // the pre-extraction discard decoder must independently enforce length.
        XCTAssertThrowsError(try validate([.init(name: "RepoPrompt CE.app/Contents/data", data: Data(repeating: 120, count: 100_000), method: 8, declaredSize: 1)], expanded: 1)) { XCTAssertEqual($0 as? TipHistoryDownloadError, .archiveLimitExceeded) }
        XCTAssertThrowsError(try validate([.init(name: "RepoPrompt CE.app/file", data: Data([1, 2]), declaredSize: 1)]))
    }

    func testGatekeeperDisabledOverridesLocalAllowsAndMalformedOutputAreNotSuccess() throws {
        func encoded(_ authority: [String: Any], verdict: Bool = true) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["assessment:verdict": verdict, "assessment:authority": authority], format: .xml, options: 0)
        }
        let notarized: [String: Any] = ["assessment:authority:source": "Notarized Developer ID"]
        try TipHistoryAcquisitionServices.validateAssessment(encoded(notarized))
        XCTAssertThrowsError(try TipHistoryAcquisitionServices.validateAssessment(encoded(notarized, verdict: false)))
        XCTAssertThrowsError(try TipHistoryAcquisitionServices.validateAssessment(encoded(["assessment:authority:source": "Local User Rule"])))
        XCTAssertThrowsError(try TipHistoryAcquisitionServices.validateAssessment(encoded(["assessment:authority:source": "Notarized Developer ID", "assessment:authority:override": "security disabled"])))
        XCTAssertThrowsError(try TipHistoryAcquisitionServices.validateAssessment(Data("accepted".utf8)))
    }

    func testUnsignedBundleCannotPassEitherPinnedOfficialIdentity() throws {
        let root = try temporaryDirectory().appendingPathComponent("RepoPrompt CE.app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": OfficialApplicationIdentity.legacy.bundleIdentifier, "CFBundleVersion": "5", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertFalse(OfficialApplicationIdentity.legacy.validatesOfficialApplication(at: root))
        XCTAssertFalse(OfficialApplicationIdentity.successor.validatesOfficialApplication(at: root))
    }

    private func validInfo(_ identity: OfficialApplicationIdentity = .legacy) -> [String: Any] {
        [
            "CFBundleIdentifier": identity.bundleIdentifier,
            "CFBundleVersion": "5",
            "CFBundleShortVersionString": "1.6.0",
            "LSMinimumSystemVersion": "14.0",
            "CFBundleExecutable": "RepoPrompt",
            "CFBundlePackageType": "APPL"
        ]
    }

    private func bundle(info: Data?, executable: Data?, mutate: (URL) throws -> Void = { _ in }) throws -> URL {
        let root = try temporaryDirectory().appendingPathComponent("RepoPrompt CE.app")
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try info?.write(to: root.appendingPathComponent("Contents/Info.plist"))
        try executable?.write(to: macOS.appendingPathComponent("RepoPrompt"))
        try mutate(root)
        return root
    }

    func testBundleMetadataIsBoundedAndBoundToTheAdmittedEntry() throws {
        let entry = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(5)]).entries[0]
        XCTAssertEqual(entry.marketingVersion, "1.6.0")
        XCTAssertEqual(entry.architectures, ["arm64", "x86_64"])
        let universal = TipHistoryZIPFixture.machO([TipHistoryZIPFixture.x86_64, TipHistoryZIPFixture.arm64])
        func encoded(_ plist: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }
        func check(_ info: [String: Any]? = nil, raw: Data? = nil, executable: Data? = nil, mutate: (URL) throws -> Void = { _ in }) throws {
            let root = try bundle(info: raw ?? encoded(info ?? validInfo()), executable: executable ?? universal, mutate: mutate)
            try TipHistoryBundleMetadata.validate(root: root, entry: entry)
        }
        try check()
        var numericEquivalent = validInfo()
        numericEquivalent["LSMinimumSystemVersion"] = "14"
        try check(numericEquivalent)

        func changed(_ key: String, _ value: Any?) -> [String: Any] {
            var info = validInfo()
            info[key] = value
            return info
        }
        let oversized = try encoded(changed("Padding", String(repeating: "x", count: TipHistoryBundleMetadata.maximumInfoPlistBytes)))
        XCTAssertGreaterThan(oversized.count, TipHistoryBundleMetadata.maximumInfoPlistBytes)
        let cases: [(String, () throws -> Void)] = [
            ("missing marketing", { try check(changed("CFBundleShortVersionString", nil)) }),
            ("marketing mismatch", { try check(changed("CFBundleShortVersionString", "1.5.0")) }),
            ("bundle mismatch", { try check(changed("CFBundleIdentifier", OfficialApplicationIdentity.successor.bundleIdentifier)) }),
            ("build mismatch", { try check(changed("CFBundleVersion", "6")) }),
            ("missing minimum OS", { try check(changed("LSMinimumSystemVersion", nil)) }),
            ("minimum OS mismatch", { try check(changed("LSMinimumSystemVersion", "15.0")) }),
            ("per-architecture minimum OS", { try check(changed("LSMinimumSystemVersionByArchitecture", ["arm64": "15.0"])) }),
            ("executable traversal", { try check(changed("CFBundleExecutable", "../RepoPrompt")) }),
            ("missing executable name", { try check(changed("CFBundleExecutable", nil)) }),
            ("thin arm64 only", { try check(executable: TipHistoryZIPFixture.machO([TipHistoryZIPFixture.arm64], fat: false)) }),
            ("fat arm64 only", { try check(executable: TipHistoryZIPFixture.machO([TipHistoryZIPFixture.arm64])) }),
            ("arm64e slice", { try check(executable: TipHistoryZIPFixture.machO([TipHistoryZIPFixture.x86_64, (0x0100_000C, 2)])) }),
            ("duplicate slice", { try check(executable: TipHistoryZIPFixture.machO([TipHistoryZIPFixture.arm64, TipHistoryZIPFixture.arm64, TipHistoryZIPFixture.x86_64])) }),
            ("not Mach-O", { try check(executable: Data("#!/bin/sh\necho hi\n".utf8)) }),
            ("oversized plist", { try check(raw: oversized) }),
            ("plist not a dictionary", { try check(raw: encoded(["CFBundleIdentifier"])) }),
            ("missing executable file", { try check(mutate: { try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/MacOS/RepoPrompt")) }) }),
            ("executable symlink", { try check(mutate: { root in
                let macOS = root.appendingPathComponent("Contents/MacOS")
                try FileManager.default.moveItem(at: macOS.appendingPathComponent("RepoPrompt"), to: macOS.appendingPathComponent("Real"))
                try FileManager.default.createSymbolicLink(atPath: macOS.appendingPathComponent("RepoPrompt").path, withDestinationPath: "Real")
            }) }),
            ("plist symlink", { try check(mutate: { root in
                let contents = root.appendingPathComponent("Contents")
                try FileManager.default.moveItem(at: contents.appendingPathComponent("Info.plist"), to: contents.appendingPathComponent("Real.plist"))
                try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("Info.plist").path, withDestinationPath: "Real.plist")
            }) }),
            ("MacOS symlink", { try check(mutate: { root in
                let contents = root.appendingPathComponent("Contents")
                try FileManager.default.moveItem(at: contents.appendingPathComponent("MacOS"), to: contents.appendingPathComponent("Real"))
                try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("MacOS").path, withDestinationPath: "Real")
            }) })
        ]
        for (label, run) in cases {
            XCTAssertThrowsError(try run(), label) { XCTAssertEqual($0 as? TipHistoryDownloadError, .bundleMismatch, label) }
        }
    }

    func testDestinationRejectsApplicationsAliasesAndExistingBundles() throws {
        let root = try temporaryDirectory()
        XCTAssertEqual(try TipHistoryOwnedStaging.validatedDestination(root), root.resolvingSymlinksInPath())
        let contents = root.appendingPathComponent("Existing.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TipHistoryOwnedStaging.validatedDestination(contents))
        let alias = root.appendingPathComponent("app-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: contents)
        XCTAssertThrowsError(try TipHistoryOwnedStaging.validatedDestination(alias))
        let applications = URL(fileURLWithPath: "/Applications")
        XCTAssertThrowsError(try TipHistoryOwnedStaging.validatedDestination(applications))
        let applicationsAlias = root.appendingPathComponent("applications-alias")
        try FileManager.default.createSymbolicLink(at: applicationsAlias, withDestinationURL: applications)
        XCTAssertThrowsError(try TipHistoryOwnedStaging.validatedDestination(applicationsAlias))
        XCTAssertThrowsError(try TipHistoryOwnedStaging(destination: applicationsAlias, id: UUID()))
    }

    func testExclusiveCommitDoesNotOverwriteOrPermitPathInjection() throws {
        let destination = try temporaryDirectory()
        let payload = destination.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let existing = destination.appendingPathComponent("RepoPrompt CE Tip 5 (000000000005)")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep")
        try Data("user data".utf8).write(to: sentinel)
        XCTAssertThrowsError(try TipHistoryOwnedStaging.commit(payload: payload, destination: destination, build: "../../escape", shortSHA: "000000000005"))
        let final = try TipHistoryOwnedStaging.commit(payload: payload, destination: destination, build: "5", shortSHA: "000000000005")
        XCTAssertEqual(final.lastPathComponent, "RepoPrompt CE Tip 5 (000000000005) 2")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "user data")
    }

    func testStaleCleanupRequiresAgeOwnershipAndAnExclusiveAttemptLock() async throws {
        let destination = try temporaryDirectory()
        let registry = TipHistoryStagingRegistry(directory: destination.appendingPathComponent("registry"))
        var stage: TipHistoryOwnedStaging? = try TipHistoryOwnedStaging(destination: destination, id: UUID())
        let record = try XCTUnwrap(stage?.record)
        try await registry.register(record)
        await registry.removeStaleStaging(now: Date().addingTimeInterval(90000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "active locked attempt was deleted")
        stage = nil
        await registry.removeStaleStaging(now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "fresh attempt was deleted")
        await registry.removeStaleStaging(now: Date().addingTimeInterval(90000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testVerifiedAcquisitionCommitsAQuarantinedAppWithoutExecutingIt() async throws {
        let destination = try temporaryDirectory()
        let registry = TipHistoryStagingRegistry(directory: destination.appendingPathComponent("registry"))
        let identity = OfficialApplicationIdentity.legacy
        // Matches TipHistoryTestFixture.entry(5): marketing 1.6.0, macOS 14.0, universal.
        let info = try PropertyListSerialization.data(fromPropertyList: validInfo(identity), format: .xml, options: 0)
        let executable = TipHistoryZIPFixture.machO([TipHistoryZIPFixture.x86_64, TipHistoryZIPFixture.arm64])
        let bytes = TipHistoryZIPFixture.archive([
            .init(name: "RepoPrompt CE.app/Contents/Info.plist", data: info),
            .init(name: "RepoPrompt CE.app/Contents/MacOS/RepoPrompt", data: executable)
        ])
        let key = Curve25519.Signing.PrivateKey()
        var raw = TipHistoryTestFixture.entry(5)
        var metadata = try XCTUnwrap(raw["download"] as? [String: Any])
        metadata["size"] = bytes.count
        metadata["expandedSize"] = info.count + executable.count
        metadata["sha256"] = TipHistorySignatureVerifier.sha256(bytes)
        metadata["edSignature"] = try key.signature(for: bytes).base64EncodedString()
        raw["download"] = metadata
        let entry = try TipHistoryTestFixture.page([raw]).entries[0]
        let services = TipHistoryAcquisitionServices(download: { _, target, _, _ in
            try bytes.write(to: target)
        }, run: TipHistoryAcquisitionServices.live.run, validatesCode: { _, selected in
            selected == identity
        }, assess: { _, _ in })
        // Only identity/assessment are test doubles: real ditto must preserve
        // quarantine and the worker must complete layout/hash/signature checks.
        let result = try await TipHistoryDownloader(services: services, registry: registry).obtain(entry, destination: destination, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), progress: { _ in }, commit: { payload in
            try TipHistoryOwnedStaging.commit(payload: payload, destination: destination, build: entry.buildNumber, shortSHA: entry.shortSHA)
        })
        let app = result.appendingPathComponent("RepoPrompt CE.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertGreaterThan(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.path), ["RepoPrompt CE.app"])
    }

    /// Opt-in local integration: the maintainer prepares these ignored artifacts
    /// from an exact official release. CI has no fixture and performs no network
    /// access. No application is launched and all acquisition output is temporary.
    func testOfficialSignedArchiveFixtureWhenPrepared() async throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = checkout.appendingPathComponent(".build/TipHistoryOfficialFixture")
        let metadata = fixture.appendingPathComponent("entry.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { throw XCTSkip("Official signed acquisition fixture was not prepared") }
        let handle = try FileHandle(forReadingFrom: metadata)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 65537) ?? Data()
        guard bytes.count <= 65536 else { throw TipHistoryDownloadError.fileSystem }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entry = try TipHistoryTestFixture.page([raw]).entries[0]
        XCTAssertNil(entry.metadataProblem)
        let source = fixture.appendingPathComponent("archive.zip")
        let destination = try temporaryDirectory()
        let registry = TipHistoryStagingRegistry(directory: destination.appendingPathComponent("registry"))
        let services = TipHistoryAcquisitionServices(download: { _, target, _, _ in
            try FileManager.default.copyItem(at: source, to: target)
        }, run: TipHistoryAcquisitionServices.live.run, validatesCode: TipHistoryAcquisitionServices.live.validatesCode, assess: TipHistoryAcquisitionServices.live.assess)
        let result = try await TipHistoryDownloader(services: services, registry: registry).obtain(entry, destination: destination, publicKey: SparkleUpdaterManager.pinnedPublicEdKey, progress: { _ in }, commit: { payload in
            try TipHistoryOwnedStaging.commit(payload: payload, destination: destination, build: entry.buildNumber, shortSHA: entry.shortSHA)
        })
        let app = result.appendingPathComponent("RepoPrompt CE.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertGreaterThan(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }

    func testCancellationWaitsForTransportExitBeforeRemovingItsStaging() async throws {
        let destination = try temporaryDirectory()
        let registry = TipHistoryStagingRegistry(directory: destination.appendingPathComponent("registry"))
        let state = OSAllocatedUnfairLock(initialState: (path: URL?.none, exited: false, stillOwnedAtExit: false))
        let started = expectation(description: "Transport owns its staging path")
        let entry = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(5)]).entries[0]
        let services = TipHistoryAcquisitionServices(download: { _, target, _, _ in
            state.withLock { $0.path = target }
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                state.withLock {
                    $0.stillOwnedAtExit = FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path)
                    $0.exited = true
                }
                throw CancellationError()
            }
        }, run: { _, _, _ in XCTFail("cancelled transfer reached extraction") }, validatesCode: { _, _ in false }, assess: { _, _ in XCTFail("cancelled transfer reached assessment") })
        let worker = TipHistoryDownloader(services: services, registry: registry)
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let task = Task {
            try await worker.obtain(entry, destination: destination, publicKey: key, progress: { _ in }, commit: { _ in
                XCTFail("cancelled transfer reached commit")
                throw TipHistoryDownloadError.fileSystem
            })
        }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertNotNil(state.withLock { $0.path })
        task.cancel()
        do { _ = try await task.value
            XCTFail("cancelled acquisition succeeded")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let result = state.withLock { $0 }
        XCTAssertTrue(result.exited)
        XCTAssertTrue(result.stillOwnedAtExit, "staging was removed before the transport stopped writing")
        if let path = result.path { XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path)) }
    }

    func testDigestAndSignatureFailuresDeleteOwnedStagingBeforeReturning() async throws {
        for badDigest in [true, false] {
            let destination = try temporaryDirectory()
            let registry = TipHistoryStagingRegistry(directory: destination.appendingPathComponent("registry"))
            let bytes = Data("not an archive".utf8)
            let key = Curve25519.Signing.PrivateKey()
            let wrongKey = Curve25519.Signing.PrivateKey()
            var raw = TipHistoryTestFixture.entry(5)
            var download = try XCTUnwrap(raw["download"] as? [String: Any])
            download["size"] = bytes.count
            download["expandedSize"] = 4096
            download["sha256"] = badDigest ? String(repeating: "0", count: 64) : TipHistorySignatureVerifier.sha256(bytes)
            download["edSignature"] = try wrongKey.signature(for: bytes).base64EncodedString()
            raw["download"] = download
            let entry = try TipHistoryTestFixture.page([raw]).entries[0]
            let paths = OSAllocatedUnfairLock(initialState: [URL]())
            let services = TipHistoryAcquisitionServices(download: { _, target, _, _ in
                paths.withLock { $0.append(target) }
                try bytes.write(to: target)
            }, run: { _, _, _ in XCTFail("unverified bytes reached extraction") }, validatesCode: { _, _ in XCTFail("unverified bytes reached code validation")
                return false
            }, assess: { _, _ in XCTFail("unverified bytes reached Gatekeeper") })
            let worker = TipHistoryDownloader(services: services, registry: registry)
            do {
                _ = try await worker.obtain(entry, destination: destination, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), progress: { _ in }, commit: { _ in XCTFail("unverified bytes reached commit")
                    throw TipHistoryDownloadError.fileSystem
                })
                XCTFail("verification unexpectedly succeeded")
            } catch {
                XCTAssertEqual(error as? TipHistoryDownloadError, badDigest ? .digestMismatch : .invalidSparkleSignature)
            }
            for path in paths.withLock({ $0 }) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
            }
        }
    }
}

// MARK: - TipHistoryStoreTests

private actor TipHistoryControlledFetcher: TipHistoryCatalogFetching {
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private(set) var urls: [URL] = []

    func fetch(_ url: URL, repository: TipHistoryRepository, olderPage: Bool) async throws -> Data {
        let index = urls.count
        urls.append(url)
        // Deliberately ignore cancellation to prove store request fences even
        // when transport completion was already in flight.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func count() -> Int {
        urls.count
    }

    func succeed(_ index: Int, _ data: Data) {
        pending.removeValue(forKey: index)?.resume(returning: data)
    }

    func fail(_ index: Int, _ error: Error) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }
}

private actor TipHistoryControlledDownloader: TipHistoryArtifactDownloading {
    struct Request {
        let progress: @Sendable (TipHistoryAcquisitionProgress) -> Void
        let commit: @MainActor @Sendable (URL) throws -> URL
    }

    private var requests: [Request] = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var failures: [Int: TipHistoryTransferFailure] = [:]

    func obtain(_ entry: TipHistoryEntry, destination: URL, publicKey: String, progress: @escaping @Sendable (TipHistoryAcquisitionProgress) -> Void, commit: @escaping @MainActor @Sendable (URL) throws -> URL) async throws -> URL {
        let index = requests.count
        requests.append(Request(progress: progress, commit: commit))
        await withCheckedContinuation { gates[index] = $0 }
        if let failure = failures.removeValue(forKey: index) { throw failure }
        return try await commit(destination.appendingPathComponent("private-payload"))
    }

    func count() -> Int {
        requests.count
    }

    func sendProgress(_ index: Int) {
        requests[index].progress(.verifying)
    }

    func finish(_ index: Int) {
        gates.removeValue(forKey: index)?.resume()
    }

    func fail(_ index: Int, httpStatus: Int) {
        failures[index] = TipHistoryTransferFailure(.network, httpStatus: httpStatus)
        gates.removeValue(forKey: index)?.resume()
    }
}

private actor TipHistoryControlledChooser {
    private var pending: [Int: CheckedContinuation<URL?, Never>] = [:]
    private var requests = 0
    func choose() async -> URL? {
        let index = requests
        requests += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }

    func count() -> Int {
        requests
    }

    func finish(_ index: Int, destination: URL?) {
        pending.removeValue(forKey: index)?.resume(returning: destination)
    }
}

@MainActor
final class TipHistoryStoreTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var channel = UpdateChannel.tip
    private var context = TipHistoryInstallationContext(installedBuild: SparkleBuildVersion("5"), installedBuildString: "5", runningIdentity: .legacy, osVersion: SparkleBuildVersion("15")!, architecture: "arm64", migrationBlockedMessage: nil, sparkleConfigurationValid: true)
    private var now = Date(timeIntervalSince1970: 1000)
    private var notice: AvailableUpdateNotice?

    private func makeStore(_ fetcher: TipHistoryControlledFetcher, downloader: any TipHistoryArtifactDownloading = TipHistoryControlledDownloader(), commit: @escaping @MainActor (URL, URL, TipHistoryEntry) throws -> URL = { _, destination, _ in destination.appendingPathComponent("saved") }) -> TipHistoryStore {
        TipHistoryStore(
            repository: TipHistoryTestFixture.repository,
            fetcher: fetcher,
            downloader: downloader,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            contextProvider: { self.context },
            channelProvider: { self.channel },
            latestNoticeProvider: { self.notice },
            clock: { self.now },
            chooseDestination: { URL(fileURLWithPath: "/tmp/tip-history-store-test") },
            cancelDestination: {},
            commitApplication: commit
        )
    }

    private func envelope(_ numbers: [Int], older: (tag: String, data: Data)? = nil, changes: [Int: [String: Any]] = [:], pageChanges: [String: Any] = [:]) throws -> Data {
        var entries = numbers.map { number in
            var entry = TipHistoryTestFixture.entry(number)
            entry.merge(changes[number] ?? [:]) { _, value in value }
            return entry
        }
        var page: [String: Any] = [:]
        if let older {
            let digest = TipHistorySignatureVerifier.sha256(older.data)
            page["olderPage"] = ["tag": older.tag, "sha256": digest]
            if entries.last?["tag"] as? String == older.tag { entries[entries.count - 1]["historyCatalogSha256"] = digest }
        }
        page.merge(pageChanges) { _, new in new }
        return try TipHistoryTestFixture.envelope(entries, key: key, changes: page)
    }

    private func tag(_ number: Int) -> String {
        "tip-" + String(format: "%012llx", UInt64(number))
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 1000 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for controlled task", file: file, line: line)
    }

    private func assertCount(_ fetcher: TipHistoryControlledFetcher, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let count = await fetcher.count()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private func load(_ store: TipHistoryStore, fetcher: TipHistoryControlledFetcher, data: Data, request: Int = 0) async {
        store.refresh()
        await waitUntil { await fetcher.count() == request + 1 }
        await fetcher.succeed(request, data)
        await waitUntil { store.catalogState != .loading }
    }

    func testDisclosureOnlyCacheExplicitRefreshAndFailureKeepSelection() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        await assertCount(fetcher, 0)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        store.selectedTag = tag(2)
        store.loadIfNeeded()
        XCTAssertEqual(store.catalogState, .loaded(refreshedAt: now))
        await assertCount(fetcher, 1)
        store.refresh()
        XCTAssertEqual(store.rows.count, 3)
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.network)
        await waitUntil { store.catalogState == .failed(.network) }
        XCTAssertEqual(store.selectedTag, tag(2))
        XCTAssertEqual(store.rows.count, 3)
        try await load(store, fetcher: fetcher, data: envelope([7, 6]), request: 2)
        XCTAssertNil(store.selectedTag)
        now.addTimeInterval(601)
        store.loadIfNeeded()
        await waitUntil { await fetcher.count() == 4 }
        await fetcher.fail(3, TipHistoryLoadError.timeout)
        await store.shutdown()
    }

    func testOutOfOrderHeadAndChannelCancellationCannotPublish() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        store.refresh()
        await waitUntil { await fetcher.count() == 1 }
        store.refresh()
        await waitUntil { await fetcher.count() == 2 }
        try await fetcher.succeed(1, envelope([8, 5]))
        await waitUntil { store.rows.first?.entry.buildNumber == "8" }
        try await fetcher.succeed(0, envelope([6, 5]))
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "8")
        store.refresh()
        await waitUntil { await fetcher.count() == 3 }
        channel = .stable
        store.channelDidChange(.stable)
        try await fetcher.succeed(2, envelope([9, 8]))
        await store.shutdown()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.catalogState, .idle)
    }

    func testReturningToTipAllowsPriorBarrierHeadDigestWithoutDroppingItsSafetyFence() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        let barrier: [String: Any] = ["downgradeBarrier": true, "downgradeBarrierReasons": ["Reviewed persistence boundary"]]
        let original = try envelope([6, 5], changes: [6: barrier])
        await load(store, fetcher: fetcher, data: original)
        channel = .stable
        store.channelDidChange(.stable)
        XCTAssertTrue(store.rows.isEmpty)
        channel = .tip
        store.channelDidChange(.tip)
        var retained = barrier
        retained["historyCatalogSha256"] = TipHistorySignatureVerifier.sha256(original)
        let newer = try envelope([7, 6, 5], changes: [6: retained])
        await load(store, fetcher: fetcher, data: newer, request: 1)
        if case .loaded = store.catalogState {} else { XCTFail("Previous head digest enrichment failed: \(store.catalogState)") }
        XCTAssertEqual(store.rows.first?.id, tag(7))
        XCTAssertTrue(store.rows.first(where: { $0.id == tag(6) })?.entry.downgradeBarrier == true)
        channel = .stable
        store.channelDidChange(.stable)
        channel = .tip
        store.channelDidChange(.tip)
        try await load(store, fetcher: fetcher, data: envelope([8, 7, 6, 5], changes: [
            7: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(newer)],
            6: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(original), "downgradeBarrier": false, "downgradeBarrierReasons": []]
        ]), request: 2)
        XCTAssertEqual(store.catalogState, .failed(.integrityMismatch), "Leaving Tip must not erase authenticated barriers")
        await store.shutdown()
    }

    func testRegressingAndRewrittenHeadFailWithoutReplacingRows() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([8, 5]))
        try await load(store, fetcher: fetcher, data: envelope([7, 5]), request: 1)
        XCTAssertEqual(store.catalogState, .failed(.integrityMismatch))
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "8")
        try await load(store, fetcher: fetcher, data: envelope([8, 5], changes: [8: ["title": "Rewritten"]]), request: 2)
        XCTAssertEqual(store.catalogState, .failed(.integrityMismatch))
        XCTAssertEqual(store.rows.first?.entry.title, "Readable build 8")
        await store.shutdown()
    }

    func testNewerHeadCannotRewriteAnyPreviouslyAuthenticatedOverlap() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        let original = try envelope([6, 5, 2], changes: [5: ["historyCatalogSha256": String(repeating: "a", count: 64)]])
        await load(store, fetcher: fetcher, data: original)
        let expectedRows = store.rows
        let changes: [[Int: [String: Any]]] = [
            [5: ["title": "Rewritten notes title"]],
            [5: ["notes": [["text": "Rewritten authenticated notes", "source": "reviewed"]]]],
            [5: ["downgradeBarrier": true, "downgradeBarrierReasons": ["Rewritten barrier"]]],
            [5: ["historyCatalogSha256": String(repeating: "b", count: 64)]],
            [2: ["historyCatalogSha256": String(repeating: "b", count: 64)]]
        ]
        for (offset, mutation) in changes.enumerated() {
            var merged: [Int: [String: Any]] = [5: ["historyCatalogSha256": String(repeating: "a", count: 64)]]
            for (number, fields) in mutation {
                merged[number, default: [:]].merge(fields) { _, new in new }
            }
            try await load(store, fetcher: fetcher, data: envelope([7, 6, 5, 2], changes: merged), request: offset + 1)
            XCTAssertEqual(store.catalogState, .failed(.integrityMismatch))
            XCTAssertEqual(store.rows, expectedRows)
        }
        // The previous head alone may acquire its immutable envelope digest.
        try await load(store, fetcher: fetcher, data: envelope([7, 6, 5, 2], changes: [6: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(original)], 5: ["historyCatalogSha256": String(repeating: "a", count: 64)]]), request: changes.count + 1)
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "7")
        await store.shutdown()
    }

    func testNumericallyEqualHeadCannotSubstituteAnotherReleaseTag() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([6, 5]))
        var substitute = TipHistoryTestFixture.entry(7)
        substitute["buildNumber"] = "6.0.0"
        let data = try TipHistoryTestFixture.envelope([substitute, TipHistoryTestFixture.entry(5)], key: key)
        await load(store, fetcher: fetcher, data: data, request: 1)
        XCTAssertEqual(store.catalogState, .failed(.integrityMismatch))
        XCTAssertEqual(store.rows.first?.id, tag(6))
        await store.shutdown()
    }

    func testOlderPageAfterRefreshIsDiscardedAndTerminalHistoryIsTruthful() async throws {
        let old = try envelope([3, 2])
        let head = try envelope([6, 5, 3], older: (tag(3), old), changes: [3: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(old)]])
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        await load(store, fetcher: fetcher, data: head)
        XCTAssertNil(store.historyStartBuild)
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        try await load(store, fetcher: fetcher, data: envelope([7, 6]), request: 2)
        await fetcher.succeed(1, old)
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
        XCTAssertEqual(store.rows.map(\.entry.buildNumber), ["7", "6"])
        XCTAssertEqual(store.historyStartBuild, "6")
        await store.shutdown()
    }

    func testPageOverlapEnrichmentAppendsFullInterval() async throws {
        let old = try envelope([3, 2])
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 3], older: (tag(3), old), changes: [3: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(old)]]))
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, old)
        await waitUntil { store.pageCount == 2 }
        XCTAssertEqual(store.rows.map(\.entry.buildNumber), ["6", "5", "3", "2"])
        XCTAssertEqual(store.historyStartBuild, "2")
        XCTAssertTrue(try XCTUnwrap(store.rows.last?.availability.canDownload))
        await store.shutdown()
    }

    func testOlderPageCannotRewriteAnOverlappedBarrier() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        let changedOld = try envelope([3, 2], changes: [3: ["downgradeBarrier": true, "downgradeBarrierReasons": ["Unknown format"]]])
        try await load(store, fetcher: fetcher, data: envelope([7, 5, 3], older: (tag(3), changedOld)))
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, changedOld)
        await waitUntil { store.olderPageState == .failed(.integrityMismatch) }
        XCTAssertEqual(store.rows.count, 3)
        await store.shutdown()
    }

    func testPageCapStopsAtTenWithoutInventingTerminalHistory() async throws {
        var pages: [Int: Data] = [:]
        pages[10] = try envelope([90])
        for index in stride(from: 9, through: 0, by: -1) {
            pages[index] = try envelope([100 - index, 99 - index], older: (tag(99 - index), XCTUnwrap(pages[index + 1])))
        }
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: XCTUnwrap(pages[0]))
        for index in 1 ..< 10 {
            store.loadOlderPage()
            await waitUntil { await fetcher.count() == index + 1 }
            try await fetcher.succeed(index, XCTUnwrap(pages[index]))
            await waitUntil { store.pageCount == index + 1 }
        }
        XCTAssertEqual(store.olderPageState, .pageLimitReached)
        XCTAssertNil(store.historyStartBuild)
        store.loadOlderPage()
        await assertCount(fetcher, 10)
        await store.shutdown()
    }

    func testExactLatestActionNeedsNoticeNumericBuildTrustedURLAndInstallPermission() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        let head = store.rows[0].entry
        func notice(_ build: String, _ url: URL?) -> AvailableUpdateNotice {
            AvailableUpdateNotice(channel: .tip, version: "1.6.0", buildNumber: build, shortCommitSHA: nil, date: nil, releaseNotes: nil, downloadURL: url)
        }
        XCTAssertFalse(store.canCheckLatest(head, notice: nil, canInstall: true))
        XCTAssertFalse(try store.canCheckLatest(head, notice: notice("6", XCTUnwrap(head.download?.url)), canInstall: false))
        XCTAssertTrue(try store.canCheckLatest(head, notice: notice("6.0.0", XCTUnwrap(head.download?.url)), canInstall: true))
        XCTAssertFalse(try store.canCheckLatest(head, notice: notice("7", XCTUnwrap(head.download?.url)), canInstall: true))
        XCTAssertFalse(store.canCheckLatest(head, notice: notice("6", URL(string: "https://evil.invalid/a.zip")), canInstall: true))
        self.notice = notice("7", nil)
        store.contextDidChange()
        XCTAssertTrue(store.historyBehindLatestNotice)
        XCTAssertFalse(try XCTUnwrap(store.rows.last?.availability.canDownload))
        await store.shutdown()
    }

    func testOlderConsentUnknownCoverageAndNonofficialGate() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        let store = makeStore(fetcher, downloader: worker)
        try await load(store, fetcher: fetcher, data: envelope([6, 2]))
        store.beginDownload(tag: tag(2))
        XCTAssertEqual(store.downloadState, .idle)
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        XCTAssertEqual(store.downloadState, .idle)
        store.beginDownload(tag: tag(2), acknowledgedBackup: true, acknowledgedUnknownCoverage: true)
        await waitUntil { await worker.count() == 1 }
        store.cancelDownload()
        await worker.finish(0)
        await store.shutdown()
        XCTAssertEqual(store.downloadState, .idle)
    }

    func testCancelledAttemptCannotOverwriteRestartAndCommitSurvivesChannelLeave() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        var commits = 0
        let store = makeStore(fetcher, downloader: worker) { _, destination, _ in commits += 1
            return destination.appendingPathComponent("saved")
        }
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        store.cancelDownload()
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        await waitUntil { await worker.count() == 2 }
        await worker.sendProgress(1)
        await waitUntil { store.downloadState == .verifying(tag: self.tag(2)) }
        await worker.sendProgress(0)
        await worker.finish(0)
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 1 }
        XCTAssertEqual(store.downloadState, .verifying(tag: tag(2)))
        XCTAssertEqual(commits, 0)
        await worker.finish(1)
        await waitUntil { if case .ready = store.downloadState { return true }
            return false
        }
        XCTAssertEqual(commits, 1)
        channel = .stable
        store.channelDidChange(.stable)
        await store.shutdown()
        if case .ready = store.downloadState {} else { XCTFail("Committed result was erased") }
    }

    func testSynchronousSubscriberCancellationOnCommittingPreventsRename() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        var commits = 0
        var cancelledOnCommit = false
        let store = makeStore(fetcher, downloader: worker) { _, destination, _ in
            commits += 1
            return destination
        }
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        let subscription = store.$downloadState.sink { state in
            guard case .committing = state else { return }
            cancelledOnCommit = true
            store.cancelDownload()
        }
        defer { subscription.cancel() }
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        await worker.finish(0)
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
        XCTAssertTrue(cancelledOnCommit)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(store.downloadState, .idle)
        await store.shutdown()
    }

    func testNewBarrierOrContextChangeWinsBeforeCommit() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        var commits = 0
        let store = makeStore(fetcher, downloader: worker) { _, destination, _ in commits += 1
            return destination
        }
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        await waitUntil { await worker.count() == 1 }
        try await load(store, fetcher: fetcher, data: envelope([7, 5, 4, 2], changes: [4: ["downgradeBarrier": true, "downgradeBarrierReasons": ["Database changed"]]]), request: 1)
        XCTAssertEqual(store.downloadState, .idle)
        await worker.finish(0)
        await store.shutdown()
        XCTAssertEqual(commits, 0)
    }

    func testCycleAndNonHeadDigestEnrichmentAreIntegrityFailures() async throws {
        let cycle = try envelope([3, 2], older: (tag(6), Data("not-an-authenticated-head".utf8)))
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 3], older: (tag(3), cycle)))
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, cycle)
        await waitUntil { store.olderPageState == .failed(.integrityMismatch) }
        XCTAssertEqual(store.rows.count, 3)
        await store.shutdown()
    }

    func testNonHeadDigestEnrichmentInSeedTailIsAnIntegrityFailure() async throws {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        let enrichedNonHead = try envelope([4, 3, 2], changes: [3: ["origin": "seed", "historyCatalogSha256": String(repeating: "a", count: 64)]])
        let reference: [String: Any] = ["tag": tag(4), "sha256": TipHistorySignatureVerifier.sha256(enrichedNonHead)]
        let head = try envelope([7, 5, 4, 3], older: (tag(4), enrichedNonHead), changes: [4: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(enrichedNonHead)], 3: ["origin": "seed"]], pageChanges: ["archiveTail": reference])
        await load(store, fetcher: fetcher, data: head)
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, enrichedNonHead)
        await waitUntil { store.olderPageState == .failed(.integrityMismatch) }
        XCTAssertEqual(store.rows.count, 4)
        await store.shutdown()
    }

    func testTerminalOverlapStopsWithoutDuplicatingRows() async throws {
        let old = try envelope([3])
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 3], older: (tag(3), old), changes: [3: ["historyCatalogSha256": TipHistorySignatureVerifier.sha256(old)]]))
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, old)
        await waitUntil { store.olderPageState == .exhausted }
        XCTAssertEqual(store.rows.count, 3)
        XCTAssertEqual(store.historyStartBuild, "3")
        await store.shutdown()
    }

    func testContextChangeCancelsAcquisitionAndNonofficialBuildCannotAcquire() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        var commits = 0
        let store = makeStore(fetcher, downloader: worker) { _, destination, _ in commits += 1
            return destination
        }
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        context = TipHistoryInstallationContext(
            installedBuild: context.installedBuild,
            installedBuildString: "5",
            runningIdentity: .nonOfficial,
            osVersion: context.osVersion,
            architecture: context.architecture,
            migrationBlockedMessage: nil,
            sparkleConfigurationValid: true
        )
        store.contextDidChange()
        XCTAssertEqual(store.downloadState, .idle)
        XCTAssertTrue(store.rows.allSatisfy { !$0.availability.canDownload })
        store.beginDownload(tag: tag(6))
        XCTAssertEqual(store.downloadState, .idle)
        await worker.finish(0)
        await store.shutdown()
        XCTAssertEqual(commits, 0)
    }

    func testDestinationCancellationAndLateChooserCannotStartAnOldAcquisition() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader(), chooser = TipHistoryControlledChooser()
        let store = TipHistoryStore(
            repository: TipHistoryTestFixture.repository,
            fetcher: fetcher,
            downloader: worker,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            contextProvider: { self.context },
            channelProvider: { self.channel },
            chooseDestination: { await chooser.choose() },
            cancelDestination: {},
            commitApplication: { _, destination, _ in destination }
        )
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        store.beginDownload(tag: tag(6))
        await waitUntil { await chooser.count() == 1 }
        await chooser.finish(0, destination: nil)
        await waitUntil { store.downloadState == .idle }
        let initialCount = await worker.count()
        XCTAssertEqual(initialCount, 0)
        store.beginDownload(tag: tag(6))
        await waitUntil { await chooser.count() == 2 }
        store.cancelDownload()
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        await waitUntil { await chooser.count() == 3 }
        await chooser.finish(2, destination: URL(fileURLWithPath: "/tmp/selected-destination"))
        await waitUntil { await worker.count() == 1 }
        await chooser.finish(1, destination: URL(fileURLWithPath: "/tmp/stale-destination"))
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 1 }
        let finalCount = await worker.count()
        XCTAssertEqual(finalCount, 1)
        store.cancelDownload()
        await worker.finish(0)
        await store.shutdown()
    }

    func testShutdownWaitsForCancelledOwnedWorkerBeforeReturning() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        let store = makeStore(fetcher, downloader: worker)
        try await load(store, fetcher: fetcher, data: envelope([6, 5]))
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        var shutdownFinished = false
        let shutdown = Task { await store.shutdown()
            shutdownFinished = true
        }
        await waitUntil { store.downloadState == .idle }
        XCTAssertFalse(shutdownFinished)
        await worker.finish(0)
        await shutdown.value
        XCTAssertTrue(shutdownFinished)
        XCTAssertEqual(store.downloadState, .idle)
    }

    func testMissingArtifact404And410DisableRowsUntilExplicitVerifiedRefresh() async throws {
        for status in [404, 410] {
            let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
            let store = makeStore(fetcher, downloader: worker)
            let data = try envelope([6, 5, 2])
            await load(store, fetcher: fetcher, data: data)
            let initialRows = store.rows.map(\.entry)
            store.beginDownload(tag: tag(6))
            await waitUntil { await worker.count() == 1 }
            await worker.fail(0, httpStatus: status)
            await waitUntil { store.downloadState == .failed(tag: self.tag(6), .network) }
            await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
            XCTAssertEqual(store.rows.map(\.entry), initialRows)
            XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
            XCTAssertEqual(store.rows.count(where: { $0.availability.canDownload }), 1)
            XCTAssertFalse(store.offersDownloadRetry)
            store.requestDownload(tag: tag(6))
            store.beginDownload(tag: tag(6))
            let attempts = await worker.count()
            XCTAssertEqual(attempts, 1)
            // Even a successful automatic TTL reload cannot clear the observation.
            now.addTimeInterval(601)
            store.loadIfNeeded()
            await waitUntil { await fetcher.count() == 2 }
            await fetcher.succeed(1, data)
            await waitUntil { store.catalogState != .loading }
            XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
            // Failed explicit refreshes preserve both rows and missing state.
            store.refresh()
            await waitUntil { await fetcher.count() == 3 }
            await fetcher.fail(2, TipHistoryLoadError.network)
            await waitUntil { store.catalogState == .failed(.network) }
            XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
            // Explicit, signed revalidation permits one new user-directed attempt;
            // it makes no claim that the server has restored the archive.
            await load(store, fetcher: fetcher, data: data, request: 3)
            XCTAssertTrue(store.rows.first?.availability.canDownload == true)
            store.beginDownload(tag: tag(6))
            await waitUntil { await worker.count() == 2 }
            store.cancelDownload()
            await worker.finish(1)
            await store.shutdown()
        }
    }

    func testMissingOlderArtifactRequiresExplicitRefreshAndSignedPageRevalidation() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        let store = makeStore(fetcher, downloader: worker)
        let older = try envelope([3, 2])
        let head = try envelope([6, 5, 3], older: (tag(3), older))
        await load(store, fetcher: fetcher, data: head)
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.succeed(1, older)
        await waitUntil { store.pageCount == 2 }
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        await waitUntil { await worker.count() == 1 }
        await worker.fail(0, httpStatus: 410)
        await waitUntil { store.rows.last?.availability == .unavailable(.missingAsset) }
        await load(store, fetcher: fetcher, data: head, request: 2)
        XCTAssertFalse(store.rows.contains { $0.id == tag(2) })
        store.loadOlderPage()
        await waitUntil { await fetcher.count() == 4 }
        await fetcher.succeed(3, older)
        await waitUntil { store.pageCount == 2 }
        XCTAssertTrue(store.rows.last?.availability.canDownload == true)
        await store.shutdown()
    }

    func testRefreshStartedBeforeMissingArtifactResponseCannotClearIt() async throws {
        let fetcher = TipHistoryControlledFetcher(), worker = TipHistoryControlledDownloader()
        let store = makeStore(fetcher, downloader: worker)
        let data = try envelope([6, 5, 2])
        await load(store, fetcher: fetcher, data: data)
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        store.refresh()
        await waitUntil { await fetcher.count() == 2 }
        await worker.fail(0, httpStatus: 404)
        await waitUntil { store.downloadState == .failed(tag: self.tag(6), .network) }
        await fetcher.succeed(1, data)
        await waitUntil { store.catalogState != .loading }
        XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
        await store.shutdown()
    }

    func testCatalogRetryAfterIsExplicitAndNeverAutomaticallyRetries() async {
        let fetcher = TipHistoryControlledFetcher(), store = makeStore(fetcher)
        store.refresh()
        await waitUntil { await fetcher.count() == 1 }
        await fetcher.fail(0, TipHistoryCatalogFetchFailure(reason: .httpStatus(429), retryAfter: now.addingTimeInterval(120)))
        await waitUntil { store.catalogState == .failed(.httpStatus(429)) }
        await assertCount(fetcher, 1)
        store.refresh()
        await assertCount(fetcher, 1)
        now.addTimeInterval(121)
        // Passing Retry-After alone never initiates another request.
        await assertCount(fetcher, 1)
        store.refresh()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.network)
        await store.shutdown()
    }

    func testCatalogRedirectPolicyRejectsUnrelatedAssetsCredentialsAndQueries() throws {
        let repo = TipHistoryTestFixture.repository
        XCTAssertTrue(TipHistoryCatalogFetcher.trustsCatalog(repo.headURL, repository: repo))
        XCTAssertTrue(try TipHistoryCatalogFetcher.trustsCatalog(XCTUnwrap(repo.historyPageURL(tag: tag(3))), repository: repo))
        for url in [repo.headURL.absoluteString + "?token=x", repo.headURL.absoluteString + "#x", "https://github.com/other/repository/releases/download/\(tag(3))/tip-history.json", "https://user@github.com/\(repo.path)/releases/download/\(tag(3))/tip-history.json"] {
            XCTAssertFalse(try TipHistoryCatalogFetcher.trustsCatalog(XCTUnwrap(URL(string: url)), repository: repo))
        }
    }
}

private actor TipHistoryControlledReleases: TipHistoryReleaseDiscovering {
    private var pending: [Int: CheckedContinuation<TipHistoryReleasePage, Error>] = [:]
    private var pages: [Int] = []
    private var invalidations = 0

    func invalidateCache() async {
        invalidations += 1
    }

    func invalidationCount() -> Int {
        invalidations
    }

    func fetchPage(repository: TipHistoryRepository, page: Int) async throws -> TipHistoryReleasePage {
        let id = pages.count
        pages.append(page)
        // Intentionally finish after cancellation so generation fences, rather
        // than cooperative behavior of this fake, protect every publication.
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    func count() -> Int {
        pages.count
    }

    func requestedPages() -> [Int] {
        pages
    }

    func succeed(_ id: Int, _ page: TipHistoryReleasePage) {
        pending.removeValue(forKey: id)?.resume(returning: page)
    }

    func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
}

extension TipHistoryStoreTests {
    private func fallbackStore(_ fetcher: TipHistoryControlledFetcher, _ releases: TipHistoryControlledReleases, worker: any TipHistoryArtifactDownloading = TipHistoryControlledDownloader(), commit: @escaping @MainActor (URL, URL, TipHistoryEntry) throws -> URL = { _, destination, _ in destination.appendingPathComponent("saved") }) -> TipHistoryStore {
        TipHistoryStore(
            repository: TipHistoryTestFixture.repository,
            fetcher: fetcher,
            releaseProvider: releases,
            downloader: worker,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            contextProvider: { self.context },
            channelProvider: { self.channel },
            latestNoticeProvider: { self.notice },
            clock: { self.now },
            chooseDestination: { URL(fileURLWithPath: "/tmp/tip-release-fallback-test") },
            cancelDestination: {},
            commitApplication: commit
        )
    }

    private func githubEntry(_ number: Int, build: String? = nil, title: String? = nil, notes: [TipHistoryNote]? = nil, date: Date? = nil, download: TipHistoryDownload? = nil, successor: Bool = false) throws -> TipHistoryEntry {
        var raw = TipHistoryTestFixture.entry(number, successor: successor)
        if let build { raw["buildNumber"] = build }
        let entry = try XCTUnwrap(TipHistoryTestFixture.page([raw]).entries.first)
        return TipHistoryEntry(
            tag: entry.tag,
            releaseCommit: entry.releaseCommit,
            shortSHA: entry.shortSHA,
            commitDate: date ?? entry.commitDate,
            buildNumber: entry.buildNumber,
            build: entry.build,
            marketingVersion: entry.marketingVersion,
            hasHistoryUI: false,
            origin: .githubRelease,
            role: entry.role,
            signingIdentity: entry.signingIdentity,
            bundleIdentifier: entry.bundleIdentifier,
            teamIdentifier: entry.teamIdentifier,
            migrationPhase: entry.migrationPhase,
            installationType: entry.installationType,
            minimumSystemVersion: entry.minimumSystemVersion,
            minimumSystemVersionString: entry.minimumSystemVersionString,
            commitRange: nil,
            architectures: entry.architectures,
            title: title ?? "Release \(entry.buildNumber) improves workspace recovery",
            titleSource: .commit,
            notes: notes ?? [TipHistoryNote(text: "Preserve workspace selections after reload", source: .commit)],
            omittedNoteCount: 0,
            downgradeBarrier: false,
            downgradeBarrierReasons: [],
            download: download ?? entry.download,
            metadataProblem: entry.metadataProblem,
            historyCatalogSha256: nil
        )
    }

    private func enterFallback(
        _ store: TipHistoryStore,
        _ fetcher: TipHistoryControlledFetcher,
        _ releases: TipHistoryControlledReleases,
        response: TipHistoryReleasePage,
        request: Int = 0,
        releaseRequest: Int = 0
    ) async {
        store.refresh()
        await waitUntil { await fetcher.count() == request + 1 }
        await fetcher.fail(request, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == releaseRequest + 1 }
        await releases.succeed(releaseRequest, response)
        await waitUntil { store.catalogState != .loading }
    }

    func testInitialCatalog404ImmediatelyShowsExistingReleaseBuildsAndCommitNotes() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        let initialRequests = await releases.count()
        XCTAssertEqual(initialRequests, 0)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(136, build: "39.21.36"), githubEntry(133, build: "39.21.33")], nextPage: 2, omittedCount: 1))
        XCTAssertEqual(store.historySource, .githubReleases)
        XCTAssertEqual(store.rows.map(\.entry.buildNumber), ["39.21.36", "39.21.33"])
        XCTAssertTrue(store.rows.allSatisfy { $0.entry.origin == .githubRelease && !$0.entry.notes.isEmpty })
        XCTAssertEqual(store.releaseOmittedCount, 1)
        XCTAssertEqual(store.olderPageState, .available)
        XCTAssertNil(store.historyStartBuild)
        await store.shutdown()
    }

    func testOnlyCatalogNotPublishedYetCanStartFallback() async {
        for error: TipHistoryLoadError in [.network, .timeout, .invalidSignature, .unsupportedFormat, .integrityMismatch, .malformed, .httpStatus(403), .httpStatus(429)] {
            let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
            let store = fallbackStore(fetcher, releases)
            store.refresh()
            await waitUntil { await fetcher.count() == 1 }
            await fetcher.fail(0, error)
            await waitUntil { store.catalogState == .failed(error) }
            let count = await releases.count()
            XCTAssertEqual(count, 0)
            XCTAssertNil(store.historySource)
            await store.shutdown()
        }
    }

    func testAuthenticatedSignedCatalogNeverFallsBackOn404() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        let rows = store.rows
        store.refresh()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.notPublishedYet)
        await waitUntil { store.catalogState == .failed(.notPublishedYet) }
        XCTAssertEqual(store.historySource, .signedCatalog)
        XCTAssertEqual(store.rows, rows)
        let count = await releases.count()
        XCTAssertEqual(count, 0)
        await store.shutdown()
    }

    func testChannelSwitchCannotResetSignedCatalogAuthorityIntoFallback() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        channel = .stable
        store.channelDidChange(.stable)
        channel = .tip
        store.channelDidChange(.tip)
        store.loadIfNeeded()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.notPublishedYet)
        await waitUntil { store.catalogState == .failed(.notPublishedYet) }
        let count = await releases.count()
        XCTAssertEqual(count, 0)
        await store.shutdown()
    }

    func testUnsignedFallbackNeverCreatesASignedHeadMonotonicityPin() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(136)], nextPage: nil, omittedCount: 0))
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(133)], nextPage: nil, omittedCount: 0), request: 1, releaseRequest: 1)
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "133")
        XCTAssertEqual(store.debugPublishedSnapshot()["signed_catalog_authenticated"] as? Bool, false)
        await store.shutdown()
    }

    func testFirstSignedCatalogReplacesUnsignedRowsWithoutComparingTheirHeadPin() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(136)], nextPage: nil, omittedCount: 0))
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]), request: 1)
        XCTAssertEqual(store.historySource, .signedCatalog)
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "6")
        XCTAssertTrue(store.rows.allSatisfy { $0.entry.origin != .githubRelease })
        await store.shutdown()
    }

    func testReleasePagesMergeUniqueNumericBuildsAndStopAtTenPages() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        let first = try githubEntry(30), overlap = try githubEntry(29)
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [first, overlap], nextPage: 2, omittedCount: 2))
        store.loadOlderPage()
        await waitUntil { await releases.count() == 2 }
        try await releases.succeed(1, TipHistoryReleasePage(entries: [overlap, githubEntry(280, build: "29.0.0"), githubEntry(27)], nextPage: 3, omittedCount: 1))
        await waitUntil { store.pageCount == 2 }
        XCTAssertEqual(store.rows.map(\.entry.buildNumber), ["30", "29", "27"])
        for page in 3 ... 10 {
            store.loadOlderPage()
            await waitUntil { await releases.count() == page }
            try await releases.succeed(page - 1, TipHistoryReleasePage(entries: [githubEntry(27 - page)], nextPage: page + 1, omittedCount: 0))
            await waitUntil { store.pageCount == page }
        }
        XCTAssertEqual(store.olderPageState, .pageLimitReached)
        XCTAssertEqual(store.releaseOmittedCount, 3)
        XCTAssertNil(store.historyStartBuild)
        store.loadOlderPage()
        let requested = await releases.requestedPages()
        XCTAssertEqual(requested, Array(1 ... 10))
        let invalidations = await releases.invalidationCount()
        XCTAssertEqual(invalidations, 1, "Older pages must not invalidate their shared release index")
        await store.shutdown()
    }

    func testReleasePageOverlapConflictAndCursorCycleKeepPreviousRows() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6), githubEntry(5)], nextPage: 2, omittedCount: 0))
        let original = store.rows
        store.loadOlderPage()
        await waitUntil { await releases.count() == 2 }
        try await releases.succeed(1, TipHistoryReleasePage(entries: [githubEntry(5, title: "Inconsistent overlap"), githubEntry(2)], nextPage: nil, omittedCount: 0))
        await waitUntil { store.olderPageState == .failed(.integrityMismatch) }
        XCTAssertEqual(store.rows, original)
        store.loadOlderPage()
        await waitUntil { await releases.count() == 3 }
        try await releases.succeed(2, TipHistoryReleasePage(entries: [githubEntry(2)], nextPage: 2, omittedCount: 0))
        await waitUntil { store.olderPageState == .failed(.malformed) }
        XCTAssertEqual(store.rows, original)
        await store.shutdown()
    }

    func testReleaseOlderPageAfterRefreshCannotMutateNewHead() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: 2, omittedCount: 0))
        store.loadOlderPage()
        await waitUntil { await releases.count() == 2 }
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(7)], nextPage: 2, omittedCount: 0), request: 1, releaseRequest: 2)
        try await releases.succeed(1, TipHistoryReleasePage(entries: [githubEntry(2)], nextPage: nil, omittedCount: 0))
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
        XCTAssertEqual(store.rows.map(\.entry.buildNumber), ["7"])
        XCTAssertEqual(store.pageCount, 1)
        await store.shutdown()
    }

    func testLeavingTipDiscardsPendingReleaseHead() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        store.refresh()
        await waitUntil { await fetcher.count() == 1 }
        await fetcher.fail(0, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 1 }
        channel = .stable
        store.channelDidChange(.stable)
        try await releases.succeed(0, TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        await store.shutdown()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.historySource)
        XCTAssertEqual(store.catalogState, .idle)
    }

    func testCancelAndRestartReleaseHeadDiscardsOldCompletion() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        store.refresh()
        await waitUntil { await fetcher.count() == 1 }
        await fetcher.fail(0, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 1 }
        store.cancelLoad()
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(7)], nextPage: nil, omittedCount: 0), request: 1, releaseRequest: 1)
        try await releases.succeed(0, TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        await waitUntil { (store.debugPublishedSnapshot()["owned_task_count"] as? Int) == 0 }
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "7")
        await store.shutdown()
    }

    func testReleaseCacheAndRefreshFailureKeepRowsAndSelection() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        store.selectedTag = tag(6)
        store.loadIfNeeded()
        await assertCount(fetcher, 1)
        store.refresh()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 2 }
        await releases.fail(1, TipHistoryLoadError.timeout)
        await waitUntil { store.catalogState == .failed(.timeout) }
        XCTAssertEqual(store.rows.first?.entry.buildNumber, "6")
        XCTAssertEqual(store.selectedTag, tag(6))
        now.addTimeInterval(601)
        store.loadIfNeeded()
        await waitUntil { await fetcher.count() == 3 }
        await fetcher.fail(2, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 3 }
        try await releases.succeed(2, TipHistoryReleasePage(entries: [githubEntry(7)], nextPage: nil, omittedCount: 0))
        await waitUntil { store.catalogState != .loading }
        XCTAssertNil(store.selectedTag)
        let invalidations = await releases.invalidationCount()
        XCTAssertEqual(invalidations, 3, "Explicit refresh and expired TTL must each request fresh page-one metadata")
        await store.shutdown()
    }

    func testShutdownWaitsForCancelledOwnedReleaseProvider() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        store.refresh()
        await waitUntil { await fetcher.count() == 1 }
        await fetcher.fail(0, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 1 }
        var finished = false
        let shutdown = Task { await store.shutdown()
            finished = true
        }
        await waitUntil { store.catalogState == .idle }
        XCTAssertFalse(finished)
        try await releases.succeed(0, TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        await shutdown.value
        XCTAssertTrue(finished)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testFallbackOlderAlwaysRequiresBothBackupAndUnknownCoverageConsent() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases(), worker = TipHistoryControlledDownloader()
        let store = fallbackStore(fetcher, releases, worker: worker)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6), githubEntry(5), githubEntry(2)], nextPage: nil, omittedCount: 0))
        guard case let .available(.older, cautions) = store.rows.last?.availability else { return XCTFail("Older release was not admitted") }
        XCTAssertTrue(cautions.contains(.barrierUnknownInstalledOutsideHistory))
        store.beginDownload(tag: tag(2))
        store.beginDownload(tag: tag(2), acknowledgedBackup: true)
        store.beginDownload(tag: tag(2), acknowledgedUnknownCoverage: true)
        XCTAssertEqual(store.downloadState, .idle)
        let before = await worker.count()
        XCTAssertEqual(before, 0)
        store.beginDownload(tag: tag(2), acknowledgedBackup: true, acknowledgedUnknownCoverage: true)
        await waitUntil { await worker.count() == 1 }
        store.cancelDownload()
        await worker.finish(0)
        await store.shutdown()
    }

    func testNonOfficialFallbackSaveIsInspectionOnlyEvenAfterChannelChange() async throws {
        context = TipHistoryInstallationContext(
            installedBuild: context.installedBuild,
            installedBuildString: "5",
            runningIdentity: .nonOfficial,
            osVersion: context.osVersion,
            architecture: context.architecture,
            migrationBlockedMessage: nil,
            sparkleConfigurationValid: true
        )
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases(), worker = TipHistoryControlledDownloader()
        let store = fallbackStore(fetcher, releases, worker: worker)
        let entry = try githubEntry(6)
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [entry], nextPage: nil, omittedCount: 0))
        guard case let .available(_, cautions) = store.rows.first?.availability else { return XCTFail("Inspection acquisition was blocked") }
        XCTAssertTrue(cautions.contains(.downloadOnlyNonOfficial))
        let notice = AvailableUpdateNotice(channel: .tip, version: entry.marketingVersion, buildNumber: "6", shortCommitSHA: nil, date: nil, releaseNotes: nil, downloadURL: entry.download?.url)
        XCTAssertFalse(store.canCheckLatest(entry, notice: notice, canInstall: true))
        store.requestDownload(tag: tag(6))
        XCTAssertEqual(store.confirmationEntry?.tag, tag(6))
        store.confirmationEntry = nil
        store.beginDownload(tag: tag(6), acknowledgedUnknownCoverage: true)
        await waitUntil { await worker.count() == 1 }
        await worker.finish(0)
        await waitUntil { if case .ready = store.downloadState { return true }
            return false
        }
        XCTAssertTrue(store.acquiredForInspectionOnly)
        channel = .stable
        store.channelDidChange(.stable)
        XCTAssertTrue(store.acquiredForInspectionOnly)
        await store.shutdown()
    }

    func testNonOfficialExceptionDoesNotEnableSignedCatalogAcquisition() async throws {
        context = TipHistoryInstallationContext(
            installedBuild: context.installedBuild,
            installedBuildString: "5",
            runningIdentity: .nonOfficial,
            osVersion: context.osVersion,
            architecture: context.architecture,
            migrationBlockedMessage: nil,
            sparkleConfigurationValid: true
        )
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await load(store, fetcher: fetcher, data: envelope([6, 5, 2]))
        XCTAssertTrue(store.rows.allSatisfy { !$0.availability.canDownload })
        store.beginDownload(tag: tag(6))
        XCTAssertEqual(store.downloadState, .idle)
        await store.shutdown()
    }

    func testFallbackContextChangeCancelsBeforeExclusiveCommit() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases(), worker = TipHistoryControlledDownloader()
        var commits = 0
        let store = fallbackStore(fetcher, releases, worker: worker) { _, destination, _ in commits += 1
            return destination
        }
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        context = TipHistoryInstallationContext(
            installedBuild: context.installedBuild,
            installedBuildString: "5",
            runningIdentity: .legacy,
            osVersion: context.osVersion,
            architecture: context.architecture,
            migrationBlockedMessage: nil,
            sparkleConfigurationValid: false
        )
        store.contextDidChange()
        await worker.finish(0)
        await store.shutdown()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(store.downloadState, .idle)
    }

    func testFallbackMissingArtifactNeedsExplicitMetadataRevalidation() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases(), worker = TipHistoryControlledDownloader()
        let store = fallbackStore(fetcher, releases, worker: worker)
        let page = try TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0)
        await enterFallback(store, fetcher, releases, response: page)
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        await worker.fail(0, httpStatus: 404)
        await waitUntil { store.rows.first?.availability == .unavailable(.missingAsset) }
        now.addTimeInterval(601)
        store.loadIfNeeded()
        await waitUntil { await fetcher.count() == 2 }
        await fetcher.fail(1, TipHistoryLoadError.notPublishedYet)
        await waitUntil { await releases.count() == 2 }
        await releases.succeed(1, page)
        await waitUntil { store.catalogState != .loading }
        XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
        await enterFallback(store, fetcher, releases, response: page, request: 2, releaseRequest: 2)
        XCTAssertTrue(store.rows.first?.availability.canDownload == true)
        await store.shutdown()
    }

    func testMissingReleaseArtifactRevalidationIgnoresRecoveredDisplayTextButNotArtifactChanges() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases(), worker = TipHistoryControlledDownloader()
        let store = fallbackStore(fetcher, releases, worker: worker)
        let original = try githubEntry(6, title: "Commit lookup unavailable", notes: [])
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [original], nextPage: nil, omittedCount: 0))
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 1 }
        await worker.fail(0, httpStatus: 404)
        await waitUntil { store.rows.first?.availability == .unavailable(.missingAsset) }
        let recovered = try githubEntry(6, title: "Recovered commit subject", notes: [TipHistoryNote(text: "Recovered commit details", source: .commit)], date: Date(timeIntervalSince1970: 42))
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [recovered], nextPage: nil, omittedCount: 0), request: 1, releaseRequest: 1)
        XCTAssertTrue(store.rows.first?.availability.canDownload == true)
        XCTAssertEqual(store.rows.first?.entry.title, "Recovered commit subject")
        store.beginDownload(tag: tag(6))
        await waitUntil { await worker.count() == 2 }
        await worker.fail(1, httpStatus: 410)
        await waitUntil { store.rows.first?.availability == .unavailable(.missingAsset) }
        let priorDownload = try XCTUnwrap(original.download)
        let changedDownload = TipHistoryDownload(
            name: priorDownload.name,
            url: priorDownload.url,
            size: priorDownload.size + 1,
            expandedSize: priorDownload.expandedSize,
            sha256: priorDownload.sha256,
            edSignature: priorDownload.edSignature
        )
        let differentArtifact = try githubEntry(6, download: changedDownload)
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [differentArtifact], nextPage: nil, omittedCount: 0), request: 2, releaseRequest: 2)
        XCTAssertEqual(store.rows.first?.availability, .unavailable(.missingAsset))
        await store.shutdown()
    }

    func testEmptyOmittedReleasePageRequiresExplicitOlderTapWithoutEagerWalking() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [], nextPage: 2, omittedCount: 30))
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.releaseOmittedCount, 30)
        XCTAssertEqual(store.olderPageState, .available)
        let before = await releases.count()
        XCTAssertEqual(before, 1)
        store.loadOlderPage()
        await waitUntil { await releases.count() == 2 }
        try await releases.succeed(1, TipHistoryReleasePage(entries: [githubEntry(6)], nextPage: nil, omittedCount: 0))
        await waitUntil { store.rows.count == 1 }
        await store.shutdown()
    }

    func testReleaseTerminalPageNeverClaimsCompleteSignedPersistenceCoverage() async throws {
        let fetcher = TipHistoryControlledFetcher(), releases = TipHistoryControlledReleases()
        let store = fallbackStore(fetcher, releases)
        try await enterFallback(store, fetcher, releases, response: TipHistoryReleasePage(entries: [githubEntry(6), githubEntry(5), githubEntry(2)], nextPage: nil, omittedCount: 0))
        XCTAssertEqual(store.olderPageState, .exhausted)
        XCTAssertNil(store.historyStartBuild)
        guard case let .available(.older, cautions) = store.rows.last?.availability else { return XCTFail("Missing older release") }
        XCTAssertTrue(cautions.contains(.barrierUnknownInstalledOutsideHistory))
        XCTAssertEqual(store.debugPublishedSnapshot()["signed_catalog_authenticated"] as? Bool, false)
        await store.shutdown()
    }
}
