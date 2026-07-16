@testable import RepoPromptApp
import XCTest

final class AppPlatformUtilityRecoveryTests: XCTestCase {
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
                    <title>Version 2.1.20</title>
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

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8)))

        XCTAssertEqual(version.version, "2.1.20")
        XCTAssertEqual(version.buildNumber, "320")
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
                </item>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>412</sparkle:version>
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8)))

        XCTAssertEqual(version.version, "1.0.27")
        XCTAssertEqual(version.buildNumber, "412")
    }

    func testTipBuildVersionSortsBetweenAdjacentStableBuilds() throws {
        let currentStable = try XCTUnwrap(SparkleBuildVersion("28"))
        let tip = try XCTUnwrap(SparkleBuildVersion("28.7.95"))
        let nextStable = try XCTUnwrap(SparkleBuildVersion("29"))

        XCTAssertGreaterThan(tip, currentStable)
        XCTAssertGreaterThan(nextStable, tip)
        XCTAssertEqual(SparkleBuildVersion("28"), SparkleBuildVersion("28.0.0"))
        XCTAssertNil(SparkleBuildVersion("28.7.95.1"))
    }

    func testAvailableUpdateNoticeKeepsDetectedChannelAndCentralizesTipCopy() {
        let notice = AvailableUpdateNotice(
            channel: .tip,
            version: "1.0.28",
            buildNumber: "29.8.52",
            date: nil,
            releaseNotes: nil
        )

        XCTAssertEqual(notice.toolbarLabel, "Tip build v1.0.28")
        XCTAssertEqual(notice.availabilityStatus, "Tip build v1.0.28 (29.8.52) is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Tip build v1.0.28…")
        XCTAssertEqual(notice.installButtonTitle, "Install Tip Build")
        XCTAssertEqual(notice.accessibilityLabel, "Tip build v1.0.28 (29.8.52) update available")
        XCTAssertEqual(notice.channel, .tip)
    }

    func testStableUpdateNoticePreservesExistingStableCopy() {
        let notice = AvailableUpdateNotice(
            channel: .stable,
            version: "v1.0.29",
            buildNumber: "30",
            date: nil,
            releaseNotes: nil
        )

        XCTAssertEqual(notice.toolbarLabel, "Update v1.0.29")
        XCTAssertEqual(notice.availabilityStatus, "Version 1.0.29 is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Update 1.0.29…")
        XCTAssertEqual(notice.installButtonTitle, "Install Update")
        XCTAssertFalse(notice.availabilityStatus.contains("Tip"))
    }

    func testSparkleDisplayVersionNormalizationRemovesTipDecoration() {
        XCTAssertEqual(
            SparkleUpdaterManager.sanitizeVersionString("  Tip build v1.0.28  "),
            "1.0.28"
        )
        XCTAssertEqual(SparkleUpdaterManager.sanitizeVersionString("v1.0.29"), "1.0.29")
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
