@testable import RepoPromptApp
import XCTest

/// Passive appcast selection must tolerate sibling identity-transition items
/// (preparer ZIP, transition PKG, successor ZIP) before the Stable feed ever
/// carries more than one item. These tests pin the eligibility contract:
/// filter first, then pick the greatest eligible build.
final class AppcastEligibilityTests: XCTestCase {
    /// Preparer ZIP: build 120, no update constraint.
    /// Transition PKG: build 150, requires build 120, package install.
    /// Successor ZIP: build 200, requires build 150.
    private let siblingLadderXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
            <item>
                <title>Version 1.2.0</title>
                <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
                <sparkle:version>120</sparkle:version>
                <sparkle:minimumSystemVersion>13.5</sparkle:minimumSystemVersion>
                <enclosure url="https://example.com/RepoPrompt-1.2.0.zip" />
            </item>
            <item>
                <title>Version 1.5.0</title>
                <sparkle:shortVersionString>1.5.0</sparkle:shortVersionString>
                <sparkle:version>150</sparkle:version>
                <sparkle:minimumSystemVersion>13.5</sparkle:minimumSystemVersion>
                <sparkle:minimumUpdateVersion>120</sparkle:minimumUpdateVersion>
                <sparkle:minimumAutoupdateVersion>120</sparkle:minimumAutoupdateVersion>
                <enclosure url="https://example.com/RepoPromptTransition-1.5.0.pkg" sparkle:installationType="package" />
            </item>
            <item>
                <title>Version 2.0.0</title>
                <sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
                <sparkle:version>200</sparkle:version>
                <sparkle:minimumSystemVersion>13.5</sparkle:minimumSystemVersion>
                <sparkle:minimumUpdateVersion>150</sparkle:minimumUpdateVersion>
                <sparkle:minimumAutoupdateVersion>150</sparkle:minimumAutoupdateVersion>
                <enclosure url="https://example.com/RepoPrompt-2.0.0.zip" />
            </item>
        </channel>
    </rss>
    """

    private func context(build: String, osMajor: Int = 15) -> AppcastEligibilityContext {
        AppcastEligibilityContext(
            currentBuildNumber: build,
            osVersion: SparkleBuildVersion(major: osMajor, minor: 0, patch: 0)
        )
    }

    func testLegacySingleItemFeedSelectsExactlyAsBefore() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>28</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-1.0.27.zip" />
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8), context: context(build: "27")))

        XCTAssertEqual(version.buildNumber, "28")
        XCTAssertNil(version.minimumUpdateVersion)
        XCTAssertNil(version.minimumAutoupdateVersion)
        XCTAssertNil(version.installationType)
    }

    func testSiblingLadderFiltersBeforeSelectingGreatestBuild() throws {
        let items = AppcastParser().parseItems(data: Data(siblingLadderXML.utf8))
        XCTAssertEqual(items.count, 3)
        XCTAssertNil(items[0].minimumUpdateVersion)
        XCTAssertNil(items[0].minimumAutoupdateVersion)
        XCTAssertEqual(items[1].minimumUpdateVersion, "120")
        XCTAssertEqual(items[1].minimumAutoupdateVersion, "120")
        XCTAssertEqual(items[2].minimumUpdateVersion, "150")
        XCTAssertEqual(items[2].minimumAutoupdateVersion, "150")

        // Unprepared legacy client sees only the preparer, not the higher builds.
        let oldClient = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "100")))
        XCTAssertEqual(oldClient.buildNumber, "120")

        // Prepared legacy client (running the preparer) is offered the transition PKG.
        let preparedClient = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "120")))
        XCTAssertEqual(preparedClient.buildNumber, "150")
        XCTAssertEqual(preparedClient.installationType, "package")

        // A client that crossed the transition is offered the successor ZIP.
        let transitionedClient = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "150")))
        XCTAssertEqual(transitionedClient.buildNumber, "200")
    }

    func testMinimumSystemVersionExcludesItemsOnOlderOS() {
        let items = AppcastParser().parseItems(data: Data(siblingLadderXML.utf8))

        // All ladder items require macOS 13.5; a 12.x client gets no update at all.
        XCTAssertNil(AppcastParser.select(from: items, context: context(build: "200", osMajor: 12)))
    }

    func testMinimumUpdateVersionBoundaryIsInclusive() {
        let item = AppcastVersion(
            version: "2.0.0",
            buildNumber: "200",
            title: nil,
            date: nil,
            description: nil,
            releaseNotesURL: nil,
            downloadURL: "https://example.com/update.zip",
            minimumSystemVersion: nil,
            minimumUpdateVersion: "150",
            minimumAutoupdateVersion: nil,
            installationType: nil
        )

        XCTAssertTrue(AppcastItemEligibility.isEligible(item, context: context(build: "150")))
        XCTAssertTrue(AppcastItemEligibility.isEligible(item, context: context(build: "150.7.95")))
        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "149")))
        // A malformed local build cannot prove eligibility for a constrained item.
        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "unknown")))
    }

    func testMinimumAutoupdateVersionAloneFailsClosed() {
        let item = AppcastVersion(
            version: "2.0.0",
            buildNumber: "200",
            title: nil,
            date: nil,
            description: nil,
            releaseNotesURL: nil,
            downloadURL: "https://example.com/update.zip",
            minimumSystemVersion: nil,
            minimumUpdateVersion: nil,
            minimumAutoupdateVersion: "150",
            installationType: nil
        )

        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "150")))
        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "999")))
    }

    func testDivergentMinimumUpdateAndAutoupdateVersionsFailClosed() {
        let item = AppcastVersion(
            version: "2.0.0",
            buildNumber: "200",
            title: nil,
            date: nil,
            description: nil,
            releaseNotesURL: nil,
            downloadURL: "https://example.com/update.zip",
            minimumSystemVersion: nil,
            minimumUpdateVersion: "150",
            minimumAutoupdateVersion: "149",
            installationType: nil
        )

        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "150")))
        XCTAssertFalse(AppcastItemEligibility.isEligible(item, context: context(build: "999")))
    }

    func testSupportedInstallationTypesAreApplicationAndPackageOnly() {
        func item(installationType: String?) -> AppcastVersion {
            AppcastVersion(
                version: "1.0.0",
                buildNumber: "100",
                title: nil,
                date: nil,
                description: nil,
                releaseNotesURL: nil,
                downloadURL: "https://example.com/update.zip",
                minimumSystemVersion: nil,
                minimumUpdateVersion: nil,
                minimumAutoupdateVersion: nil,
                installationType: installationType
            )
        }

        XCTAssertTrue(AppcastItemEligibility.isEligible(item(installationType: nil), context: context(build: "1")))
        XCTAssertTrue(AppcastItemEligibility.isEligible(item(installationType: "application"), context: context(build: "1")))
        XCTAssertTrue(AppcastItemEligibility.isEligible(item(installationType: "package"), context: context(build: "1")))
        XCTAssertFalse(AppcastItemEligibility.isEligible(item(installationType: "interactive-package"), context: context(build: "1")))
        XCTAssertFalse(AppcastItemEligibility.isEligible(item(installationType: "Package"), context: context(build: "1")))
    }

    func testMalformedConstraintsAndUnknownInstallationTypeFailClosedPerItem() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>3.0.0</sparkle:shortVersionString>
                    <sparkle:version>300</sparkle:version>
                    <sparkle:minimumUpdateVersion>not-a-build</sparkle:minimumUpdateVersion>
                    <sparkle:minimumAutoupdateVersion>not-a-build</sparkle:minimumAutoupdateVersion>
                    <enclosure url="https://example.com/RepoPrompt-3.0.0.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
                    <sparkle:version>250</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-2.5.0.bin" sparkle:installationType="script" />
                </item>
                <item>
                    <sparkle:shortVersionString>2.4.0</sparkle:shortVersionString>
                    <sparkle:version>240</sparkle:version>
                    <sparkle:minimumSystemVersion>not-an-os</sparkle:minimumSystemVersion>
                    <enclosure url="https://example.com/RepoPrompt-2.4.0.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>2.3.0</sparkle:shortVersionString>
                    <sparkle:version>230</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-2.3.0.zip" />
                </item>
            </channel>
        </rss>
        """

        let items = AppcastParser().parseItems(data: Data(xml.utf8))
        XCTAssertEqual(items.count, 4)

        // Malformed or unknown constraints hide those items, not the whole feed.
        let selected = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "999")))
        XCTAssertEqual(selected.buildNumber, "230")
    }

    func testMalformedXMLFailsEntireParse() {
        let truncated = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
                    <sparkle:version>100</sparkle:version>
                </item>
                <item>
                    <sparkle:shortVersionString>2.0.0
        """

        XCTAssertTrue(AppcastParser().parseItems(data: Data(truncated.utf8)).isEmpty)
        XCTAssertNil(AppcastParser().parse(data: Data(truncated.utf8), context: context(build: "1")))
    }

    func testItemsWithoutValidEnclosureURLAreNotPassivelyEligible() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>4.0.0</sparkle:shortVersionString>
                    <sparkle:version>400</sparkle:version>
                </item>
                <item>
                    <sparkle:shortVersionString>3.9.0</sparkle:shortVersionString>
                    <sparkle:version>390</sparkle:version>
                    <enclosure url="" />
                </item>
                <item>
                    <sparkle:shortVersionString>3.8.0</sparkle:shortVersionString>
                    <sparkle:version>380</sparkle:version>
                    <enclosure url="not a valid url" />
                </item>
                <item>
                    <sparkle:shortVersionString>3.7.0</sparkle:shortVersionString>
                    <sparkle:version>370</sparkle:version>
                    <enclosure url="relative/path.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>3.6.0</sparkle:shortVersionString>
                    <sparkle:version>360</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-3.6.0.zip" />
                </item>
            </channel>
        </rss>
        """

        let items = AppcastParser().parseItems(data: Data(xml.utf8))
        XCTAssertEqual(items.count, 5)

        // Missing, empty, malformed, and schemeless/hostless enclosures are all
        // excluded; the highest item with a downloadable enclosure wins.
        let selected = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "1")))
        XCTAssertEqual(selected.buildNumber, "360")

        // Application and package enclosures both remain supported.
        XCTAssertTrue(
            AppcastItemEligibility.hasValidEnclosureURL(
                AppcastVersion(
                    version: "1.0.0",
                    buildNumber: "100",
                    title: nil,
                    date: nil,
                    description: nil,
                    releaseNotesURL: nil,
                    downloadURL: "https://example.com/Transition.pkg",
                    minimumSystemVersion: nil,
                    minimumUpdateVersion: nil,
                    minimumAutoupdateVersion: nil,
                    installationType: "package"
                )
            )
        )
    }

    func testMalformedBuildFailsClosedAndValidBuildsBeatMarketingOnlyItems() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
                    <sparkle:version>9999x</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-9.9.9.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>99.0.0</sparkle:shortVersionString>
                    <enclosure url="https://example.com/RepoPrompt-99.0.0.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
                    <sparkle:version>100</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-1.0.0.zip" />
                </item>
            </channel>
        </rss>
        """

        let items = AppcastParser().parseItems(data: Data(xml.utf8))
        XCTAssertEqual(items.count, 3)

        // The malformed build fails closed even though it reads "highest";
        // the buildless marketing-only item never outranks a valid build.
        let selected = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "1")))
        XCTAssertEqual(selected.buildNumber, "100")
    }

    func testAllBuildlessLegacyItemsFallBackToMarketingComparison() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
                    <enclosure url="https://example.com/RepoPrompt-1.2.3.zip" />
                </item>
                <item>
                    <sparkle:shortVersionString>1.10.0</sparkle:shortVersionString>
                    <enclosure url="https://example.com/RepoPrompt-1.10.0.zip" />
                </item>
            </channel>
        </rss>
        """

        let items = AppcastParser().parseItems(data: Data(xml.utf8))
        XCTAssertEqual(items.count, 2)

        let selected = try XCTUnwrap(AppcastParser.select(from: items, context: context(build: "1")))
        XCTAssertEqual(selected.version, "1.10.0")
        XCTAssertNil(selected.buildNumber)
    }
}
