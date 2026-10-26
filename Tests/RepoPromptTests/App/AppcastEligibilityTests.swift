import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
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

// MARK: - TipHistoryCatalogTests

enum TipHistoryTestFixture {
    static let repository = TipHistoryRepository(feedURL: URL(string: "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/latest/download/appcast.xml"))!

    static func entry(_ number: Int, successor: Bool = false) -> [String: Any] {
        let sha = String(format: "%012llx", UInt64(number))
        let identity: OfficialApplicationIdentity = successor ? .successor : .legacy
        return [
            "tag": "tip-" + sha, "releaseCommit": sha + String(repeating: "0", count: 28), "shortSHA": sha,
            "commitDate": "2026-10-22T00:00:00Z", "buildNumber": String(number), "marketingVersion": "1.6.0",
            "hasHistoryUI": true, "origin": "catalog", "role": successor ? "successor" : "preparer",
            "signingIdentity": identity.rawValue, "bundleIdentifier": identity.bundleIdentifier,
            "teamIdentifier": identity.teamIdentifier, "migrationPhase": successor ? "disabled" : "legacy-preparer",
            "installationType": "application", "minimumSystemVersion": "14.0", "architectures": ["arm64", "x86_64"],
            "title": "Readable build \(number)", "titleSource": "reviewed", "notes": [["text": "A reviewed change", "source": "reviewed"]],
            "omittedCount": 0, "commitRange": ["fromCommit": NSNull(), "count": 1],
            "downgradeBarrier": false, "downgradeBarrierReasons": [String](), "historyCatalogSha256": NSNull(),
            "download": ["name": "RepoPrompt.zip", "url": "https://github.com/\(repository.path)/releases/download/tip-\(sha)/RepoPrompt.zip", "size": 123, "expandedSize": 456, "sha256": String(repeating: "a", count: 64), "edSignature": Data(repeating: 0, count: 64).base64EncodedString()]
        ]
    }

    static func envelope(_ entries: [[String: Any]], key: Curve25519.Signing.PrivateKey, changes: [String: Any] = [:]) throws -> Data {
        var page: [String: Any] = ["schemaVersion": 1, "channel": "tip", "updateRepository": repository.path, "generatedForTag": entries[0]["tag"]!, "windowSize": 30, "entries": entries, "olderPage": NSNull(), "archiveTail": NSNull()]
        page.merge(changes) { _, new in new }
        let payload = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
        return try envelope(payload: payload, key: key)
    }

    static func envelope(payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: TipHistoryCatalogDecoder.domain + payload)
        return try JSONSerialization.data(withJSONObject: ["format": "repoprompt-tip-history", "schemaVersion": 1, "payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()])
    }

    static func page(_ entries: [[String: Any]]) throws -> TipHistoryPage {
        let key = Curve25519.Signing.PrivateKey()
        return try TipHistoryCatalogDecoder.decodePage(envelopeData: envelope(entries, key: key), expectedTag: nil, expectedSHA256: nil, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: repository)
    }
}

final class TipHistoryCatalogTests: XCTestCase {
    func testValidSignedPageAndUnknownAdditiveFields() throws {
        let key = Curve25519.Signing.PrivateKey()
        let raw = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3), TipHistoryTestFixture.entry(2)], key: key, changes: ["futureAdditiveField": "ignored"])
        let page = try TipHistoryCatalogDecoder.decodePage(envelopeData: raw, expectedTag: "tip-000000000003", expectedSHA256: TipHistorySignatureVerifier.sha256(raw), publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: TipHistoryTestFixture.repository)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertNil(page.entries[0].metadataProblem)
        XCTAssertEqual(page.entries[0].title, "Readable build 3")
    }

    func testRawEnvelopeDuplicateKeysAreRejectedIncludingEscapedAndNestedKeys() throws {
        let key = Curve25519.Signing.PrivateKey()
        let valid = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key)
        let remainder = String(decoding: valid.dropFirst(), as: UTF8.self)
        let additions = [
            #""schemaVersion":2,"#,
            #""schema\u0056ersion":2,"#,
            #""future":{"downgradeBarrier":true,"downgradeBarrier":false},"#,
            #""future":[{"a\"b":1,"a\u0022b":2}],"#
        ]
        for addition in additions {
            let raw = Data(("{" + addition + remainder).utf8)
            XCTAssertThrowsError(try decode(raw, key: key)) {
                XCTAssertEqual($0 as? TipHistoryLoadError, .malformed, addition)
            }
        }
    }

    func testAuthenticatedPayloadRejectsConflictingRecursiveSafetyKeys() throws {
        let key = Curve25519.Signing.PrivateKey()
        let valid = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let encodedPayload = try XCTUnwrap(envelope["payload"] as? String)
        let payload = try XCTUnwrap(Data(base64Encoded: encodedPayload))
        let text = String(decoding: payload, as: UTF8.self)
        let replacements = [
            (#""downgradeBarrier":false"#, #""downgradeBarrier":true,"downgradeBarrier":false"#),
            (#""downgradeBarrier":false"#, #""downgradeBarrier":true,"downgrade\u0042arrier":false"#),
            (#""expandedSize":456"#, #""expandedSize":1,"expanded\u0053ize":456"#)
        ]
        for (original, replacement) in replacements {
            XCTAssertTrue(text.contains(original))
            let conflicting = Data(text.replacingOccurrences(of: original, with: replacement).utf8)
            // Re-sign the conflicting raw bytes: this must be a structural
            // rejection of authenticated metadata, not a signature failure.
            let raw = try TipHistoryTestFixture.envelope(payload: conflicting, key: key)
            XCTAssertThrowsError(try decode(raw, key: key)) {
                XCTAssertEqual($0 as? TipHistoryLoadError, .malformed, replacement)
            }
        }
        let nestedUnknown = Data((#"{"future":[{"n":1,"\u006e":2}],"# + String(text.dropFirst())).utf8)
        let raw = try TipHistoryTestFixture.envelope(payload: nestedUnknown, key: key)
        XCTAssertThrowsError(try decode(raw, key: key)) { XCTAssertEqual($0 as? TipHistoryLoadError, .malformed) }
    }

    func testUniqueKeysAndEscapedStringContentsRemainValid() throws {
        let key = Curve25519.Signing.PrivateKey()
        let future: [String: Any] = [
            "first": "Escaped quote \" and slash \\ and punctuation {[]},:",
            "second": ["first": "Different object"]
        ]
        let raw = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key, changes: ["future": future])
        let page = try decode(raw, key: key)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertNil(page.entries[0].metadataProblem)
    }

    func testExcessiveJSONNestingIsRejectedInEnvelopeAndAuthenticatedPayload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let valid = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key)
        let nesting = String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        let rawEnvelope = Data((#"{"future":"# + nesting + "," + String(decoding: valid.dropFirst(), as: UTF8.self)).utf8)
        XCTAssertThrowsError(try decode(rawEnvelope, key: key)) { XCTAssertEqual($0 as? TipHistoryLoadError, .malformed) }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let encodedPayload = try XCTUnwrap(envelope["payload"] as? String)
        let payload = try XCTUnwrap(Data(base64Encoded: encodedPayload))
        let nestedPayload = Data((#"{"future":"# + nesting + "," + String(decoding: payload.dropFirst(), as: UTF8.self)).utf8)
        let raw = try TipHistoryTestFixture.envelope(payload: nestedPayload, key: key)
        XCTAssertThrowsError(try decode(raw, key: key)) { XCTAssertEqual($0 as? TipHistoryLoadError, .malformed) }
    }

    private func decode(_ raw: Data, key: Curve25519.Signing.PrivateKey) throws -> TipHistoryPage {
        try TipHistoryCatalogDecoder.decodePage(envelopeData: raw, expectedTag: nil, expectedSHA256: nil, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: TipHistoryTestFixture.repository)
    }

    func testPaginationCannotJumpPastAnUnboundTail() throws {
        let key = Curve25519.Signing.PrivateKey()
        let digest = String(repeating: "a", count: 64)
        let repository = TipHistoryTestFixture.repository
        func decode(_ entries: [[String: Any]], older: [String: String], anchor: [String: String]? = nil) throws -> TipHistoryPage {
            var changes: [String: Any] = ["olderPage": older, "archiveTail": NSNull()]
            if let anchor { changes["archiveTail"] = anchor }
            let bytes = try TipHistoryTestFixture.envelope(entries, key: key, changes: changes)
            return try TipHistoryCatalogDecoder.decodePage(envelopeData: bytes, expectedTag: nil, expectedSHA256: nil, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: repository)
        }
        var tail = TipHistoryTestFixture.entry(3)
        tail["historyCatalogSha256"] = digest
        let direct = ["tag": "tip-000000000003", "sha256": digest]
        XCTAssertNoThrow(try decode([TipHistoryTestFixture.entry(6), tail], older: direct))
        XCTAssertThrowsError(try decode([TipHistoryTestFixture.entry(6), tail], older: ["tag": "tip-000000000001", "sha256": digest]))
        var seed = TipHistoryTestFixture.entry(2)
        seed["origin"] = "seed"
        XCTAssertNoThrow(try decode([TipHistoryTestFixture.entry(6), tail, seed], older: direct, anchor: direct))
        XCTAssertThrowsError(try decode([TipHistoryTestFixture.entry(6), tail, seed], older: direct))
        XCTAssertThrowsError(try decode([TipHistoryTestFixture.entry(6), seed], older: direct, anchor: direct))
    }

    func testTrustFailuresRejectWholePage() throws {
        let key = Curve25519.Signing.PrivateKey()
        let raw = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key)
        let wrong = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try TipHistoryCatalogDecoder.decodePage(envelopeData: raw, expectedTag: nil, expectedSHA256: nil, publicKeyBase64: wrong, repository: TipHistoryTestFixture.repository)) { XCTAssertEqual($0 as? TipHistoryLoadError, .invalidSignature) }
        XCTAssertThrowsError(try TipHistoryCatalogDecoder.decodePage(envelopeData: raw, expectedTag: nil, expectedSHA256: String(repeating: "0", count: 64), publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: TipHistoryTestFixture.repository)) { XCTAssertEqual($0 as? TipHistoryLoadError, .integrityMismatch) }
        XCTAssertThrowsError(try TipHistoryCatalogDecoder.decodePage(envelopeData: Data(repeating: 0, count: 1_048_577), expectedTag: nil, expectedSHA256: nil, publicKeyBase64: wrong, repository: TipHistoryTestFixture.repository))
    }

    func testUnknownRolesAndMalformedDownloadsStayVisibleButDisabled() throws {
        for change: [String: Any] in [["role": "future"], ["teamIdentifier": "OTHER"], ["architectures": ["future-cpu"]], ["minimumSystemVersion": "unknown"], ["download": ["url": "https://evil.invalid/a.zip"]], ["downgradeBarrier": "false"], ["downgradeBarrier": false, "downgradeBarrierReasons": ["Irreversible change"]], ["marketingVersion": ""]] {
            var entry = TipHistoryTestFixture.entry(3)
            entry.merge(change) { _, new in new }
            let page = try TipHistoryTestFixture.page([entry])
            XCTAssertEqual(page.entries.count, 1)
            XCTAssertNotNil(page.entries[0].metadataProblem, "\(change)")
        }
    }

    func testOrderingDuplicateTagsRepositoryAndSchemaArePageFatal() throws {
        XCTAssertThrowsError(try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(2), TipHistoryTestFixture.entry(3)]))
        XCTAssertThrowsError(try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(3), TipHistoryTestFixture.entry(3)]))
        var bad = TipHistoryTestFixture.entry(3)
        bad["buildNumber"] = "not-orderable"
        XCTAssertThrowsError(try TipHistoryTestFixture.page([bad]))
        let key = Curve25519.Signing.PrivateKey()
        for changes: [String: Any] in [["schemaVersion": 2], ["updateRepository": "other/repository"], ["channel": "stable"]] {
            let raw = try TipHistoryTestFixture.envelope([TipHistoryTestFixture.entry(3)], key: key, changes: changes)
            XCTAssertThrowsError(try TipHistoryCatalogDecoder.decodePage(envelopeData: raw, expectedTag: nil, expectedSHA256: nil, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), repository: TipHistoryTestFixture.repository))
        }
    }

    func testExactInitialURLTrustAndTextSanitization() throws {
        XCTAssertFalse(TipHistoryRepository.validTag("tip-000000000003\n"))
        XCTAssertFalse(TipHistoryRepository.matches("123\n", #"^[0-9]+$"#))
        let repo = TipHistoryTestFixture.repository
        let prefix = "https://github.com/\(repo.path)/releases/download/tip-000000000003/"
        XCTAssertTrue(repo.trustsDownload(URL(string: prefix + "RepoPrompt.zip")!, tag: "tip-000000000003", name: "RepoPrompt.zip"))
        for url in [prefix + "RepoPrompt.zip?token=x", prefix + "RepoPrompt.zip#fragment", prefix + "%2FRepoPrompt.zip", prefix.replacingOccurrences(of: "github.com", with: "github.com.evil.invalid") + "RepoPrompt.zip"] {
            XCTAssertFalse(try repo.trustsDownload(XCTUnwrap(URL(string: url)), tag: "tip-000000000003", name: "RepoPrompt.zip"))
        }
        XCTAssertNil(repo.historyPageURL(tag: "../escape"))
        XCTAssertEqual(TipHistoryCatalogDecoder.sanitize("e\u{202e}\u{301}  title", limit: 200), "é title")
        XCTAssertEqual(TipHistoryCatalogDecoder.sanitize("👩‍👩‍👧‍👦suffix", limit: 1), "👩‍👩‍👧‍👦")
    }
}

// MARK: - TipHistoryCompatibilityTests

final class TipHistoryCompatibilityTests: XCTestCase {
    private func context(_ build: String = "5", identity: TipHistoryRunningIdentity = .legacy, os: String = "15", architecture: String = "arm64", blocked: String? = nil, valid: Bool = true) -> TipHistoryInstallationContext {
        TipHistoryInstallationContext(installedBuild: SparkleBuildVersion(build), installedBuildString: build, runningIdentity: identity, osVersion: SparkleBuildVersion(os)!, architecture: architecture, migrationBlockedMessage: blocked, sparkleConfigurationValid: valid)
    }

    func testInstalledRequiresOfficialMatchingIdentityAndVerifiedConfiguration() throws {
        let entry = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(5)]).entries[0]
        XCTAssertEqual(TipHistoryCompatibility.evaluate(entry, in: [entry], context: context("5.0.0")), .installed)
        XCTAssertEqual(TipHistoryCompatibility.evaluate(entry, in: [entry], context: context(identity: .successor)), .unavailable(.crossesIdentityBackward))
        XCTAssertEqual(TipHistoryCompatibility.evaluate(entry, in: [entry], context: context(identity: .nonOfficial)), .unavailable(.nonOfficialRunningBuild))
        XCTAssertEqual(TipHistoryCompatibility.evaluate(entry, in: [entry], context: context(valid: false)), .unavailable(.updatesDisabled))
    }

    func testDowngradeEnforcesEveryKnownBarrierEvenWhenInstalledBuildIsAbsent() throws {
        var barrier = TipHistoryTestFixture.entry(4)
        barrier["downgradeBarrier"] = true
        barrier["downgradeBarrierReasons"] = ["Changed database format"]
        let page = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(6), barrier, TipHistoryTestFixture.entry(2)])
        XCTAssertEqual(TipHistoryCompatibility.evaluate(page.entries[2], in: page.entries, context: context()), .unavailable(.downgradeBarrier(atBuild: "4", reasons: ["Changed database format"])))
        // Rolling back TO the build introducing a format is not crossing it.
        XCTAssertEqual(TipHistoryCompatibility.evaluate(page.entries[1], in: page.entries, context: context("4")), .installed)
    }

    func testUnknownCoverageAndStaleHeadCannotClaimSafety() throws {
        let page = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(6), TipHistoryTestFixture.entry(2)])
        XCTAssertEqual(TipHistoryCompatibility.evaluate(page.entries[1], in: page.entries, context: context()), .available(direction: .older, cautions: [.dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory]))
        XCTAssertEqual(TipHistoryCompatibility.evaluate(page.entries[1], in: page.entries, context: context("10")), .unavailable(.historyBehindInstalled))
        XCTAssertEqual(TipHistoryCompatibility.evaluate(page.entries[1], in: page.entries, context: context("unknown")), .unavailable(.unorderableInstalledBuild))
    }

    func testIdentityOSArchitectureAndMigrationCautions() throws {
        let page = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(6), TipHistoryTestFixture.entry(5), TipHistoryTestFixture.entry(2)])
        let target = page.entries[2]
        XCTAssertEqual(TipHistoryCompatibility.evaluate(target, in: page.entries, context: context(architecture: "future")), .unavailable(.unsupportedArchitecture))
        if case .unavailable(.unsupportedOS) = TipHistoryCompatibility.evaluate(target, in: page.entries, context: context(os: "13")) {} else { XCTFail("OS gate not enforced") }
        XCTAssertEqual(TipHistoryCompatibility.evaluate(target, in: page.entries, context: context(blocked: "paused")), .available(direction: .older, cautions: [.dataCompatibilityNotGuaranteed, .credentialMigrationPaused]))
        let successor = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(6, successor: true)]).entries[0]
        XCTAssertEqual(TipHistoryCompatibility.evaluate(successor, in: [successor], context: context()), .unavailable(.crossesIdentityForward))
        XCTAssertEqual(TipHistoryCompatibility.evaluate(successor, in: [successor], context: context(identity: .successor)), .available(direction: .newer, cautions: []))
    }

    func testTransitionPackageAndInvalidCoveredMetadataRemainBlocked() throws {
        var transition = TipHistoryTestFixture.entry(6, successor: true)
        transition["role"] = "transition"
        transition["installationType"] = "package"
        transition["download"] = NSNull()
        let package = try TipHistoryTestFixture.page([transition]).entries[0]
        XCTAssertNil(package.metadataProblem)
        XCTAssertEqual(TipHistoryCompatibility.evaluate(package, in: [package], context: context()), .unavailable(.transitionInstaller))
        var malformed = TipHistoryTestFixture.entry(4)
        malformed["downgradeBarrier"] = "false"
        let page = try TipHistoryTestFixture.page([TipHistoryTestFixture.entry(5), malformed, TipHistoryTestFixture.entry(2)])
        XCTAssertFalse(TipHistoryCompatibility.evaluate(page.entries[2], in: page.entries, context: context()).canDownload)
    }
}

extension AppcastEligibilityTests {
    func testPublicTipDiscoveryBindsMetadataWithoutClaimingCatalogTrust() async throws {
        let fixture = try TipPublicReleaseFixture()
        let transport = TipPublicReleaseTransport(responses: fixture.responses())
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        let page = try await discovery.fetchPage(repository: fixture.repository, page: 1)
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.omittedCount, 0)
        XCTAssertNil(page.nextPage)
        XCTAssertEqual(entry.origin, .githubRelease)
        XCTAssertNil(entry.historyCatalogSha256)
        XCTAssertFalse(entry.hasHistoryUI)
        XCTAssertEqual(entry.buildNumber, "39.21.36")
        XCTAssertEqual(entry.marketingVersion, "1.6.0")
        XCTAssertEqual(entry.teamIdentifier, "648A27MST5")
        XCTAssertEqual(entry.title, "Keep connection approval across reconnects")
        XCTAssertEqual(entry.titleSource, .commit)
        XCTAssertEqual(entry.notes.last?.text, "Preserve FIFO approval order.")
        XCTAssertTrue(entry.notes.allSatisfy { $0.source == .commit })
        XCTAssertEqual(entry.download?.sha256, fixture.zipHash)
        XCTAssertEqual(entry.download?.size, 412_514_799)
        XCTAssertNil(entry.metadataProblem)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains(fixture.commitURL))
        XCTAssertFalse(requests.contains { $0.contains("/releases/assets/") || $0.hasSuffix(".zip") })
    }

    func testPublicTipDiscoverySingleLineCommitHasSourceDerivedNote() async throws {
        let fixture = try TipPublicReleaseFixture()
        let transport = TipPublicReleaseTransport(responses: fixture.responses(message: "Fix reconnect approval"))
        let page = try await TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
            .fetchPage(repository: fixture.repository, page: 1)
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.title, "Fix reconnect approval")
        XCTAssertEqual(entry.notes, [TipHistoryNote(text: "Source change: Fix reconnect approval", source: .commit)])
    }

    func testPublicTipDiscoverySkipsMissingAndInconsistentAssetsButSortsNumericBuilds() async throws {
        let low = try TipPublicReleaseFixture(sha: String(repeating: "a", count: 40), build: "39.9.99")
        let high = try TipPublicReleaseFixture(sha: String(repeating: "b", count: 40), build: "39.21.36")
        var missing = low.release
        missing["tag_name"] = "tip-cccccccccccc"
        missing["assets"] = []
        var draft = high.release
        draft["draft"] = true
        var responses = low.responses()
        responses.merge(high.responses()) { _, new in new }
        responses[low.listURL] = try TipPublicReleaseFixture.json([low.release, missing, high.release, draft, ["draft": false]])
        let transport = TipPublicReleaseTransport(responses: responses)
        let page = try await TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
            .fetchPage(repository: low.repository, page: 1)
        XCTAssertEqual(page.entries.map(\.buildNumber), ["39.21.36", "39.9.99"])
        XCTAssertEqual(page.omittedCount, 3)
    }

    func testPublicTipDiscoveryRejectsBrokenHashSizeIdentityRoleAndNamespaceBindings() async throws {
        for mutation in ["hash", "size", "identity", "role", "sha", "namespace", "checksums"] {
            let fixture = try TipPublicReleaseFixture(mutation: mutation)
            let transport = TipPublicReleaseTransport(responses: fixture.responses())
            let page = try await TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
                .fetchPage(repository: fixture.repository, page: 1)
            XCTAssertTrue(page.entries.isEmpty, mutation)
            XCTAssertEqual(page.omittedCount, 1, mutation)
            let requests = await transport.requests
            XCTAssertFalse(requests.contains { $0.contains("evil.example") }, mutation)
        }
    }

    func testPublicTipDiscoveryHasExplicitSourceFailureAndBoundedPages() async throws {
        let fixture = try TipPublicReleaseFixture()
        var responses = fixture.responses()
        responses.removeValue(forKey: fixture.commitURL)
        responses[fixture.listURL] = try TipPublicReleaseFixture.json(Array(repeating: fixture.release, count: 30))
        let transport = TipPublicReleaseTransport(responses: responses)
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        let page = try await discovery.fetchPage(repository: fixture.repository, page: 1)
        XCTAssertNil(page.nextPage)
        XCTAssertEqual(page.omittedCount, 29)
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.title, "Commit ab84d47e6271 — source unavailable")
        XCTAssertTrue(entry.notes[0].text.contains("unavailable"))
        XCTAssertFalse(entry.notes[0].source == .reviewed)
        XCTAssertNil(entry.commitDate)
        for pageNumber in [0, 11] {
            do {
                _ = try await discovery.fetchPage(repository: fixture.repository, page: pageNumber)
                XCTFail("Out-of-bound release page accepted")
            } catch {
                XCTAssertEqual(error as? TipHistoryLoadError, .malformed)
            }
        }
        do {
            let other = try XCTUnwrap(TipHistoryRepository(feedURL: URL(string: "https://github.com/other/releases/releases/latest/download/appcast.xml")))
            _ = try await discovery.fetchPage(repository: other, page: 1)
            XCTFail("Foreign update repository accepted")
        } catch {
            XCTAssertEqual(error as? TipHistoryLoadError, .malformed)
        }
    }

    func testPublicTipDiscoveryFindsNewestBuildBeyondServerFirstPageAndCachesSuccessfulPages() async throws {
        let newest = try TipPublicReleaseFixture()
        var records: [[String: Any]] = []
        var responses = newest.responses()
        for number in 1 ... 104 {
            let older = try TipPublicReleaseFixture(sha: String(format: "%012x", number) + String(repeating: "0", count: 28), build: "38.0.\(number)")
            records.append(older.release)
            responses.merge(older.responses()) { _, new in new }
        }
        // Mimic the observed SHA-ordered API: newest publication/build is not
        // even in server page one, much less in the first thirty records.
        let invalid = try TipPublicReleaseFixture(sha: String(repeating: "f", count: 40), build: "99.0.0", mutation: "hash")
        records.append(invalid.release)
        responses.merge(invalid.responses()) { _, new in new }
        records.append(newest.release)
        XCTAssertEqual(Set(records.compactMap { $0["tag_name"] as? String }).count, records.count, "Generated full SHAs must also have unique twelve-character release tags")
        responses[newest.listURL] = try TipPublicReleaseFixture.json(Array(records.prefix(100)))
        let secondIndexURL = newest.listURL.replacingOccurrences(of: "&page=1", with: "&page=2")
        responses[secondIndexURL] = try TipPublicReleaseFixture.json(Array(records.dropFirst(100)))
        let transport = TipPublicReleaseTransport(responses: responses)
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        let first = try await discovery.fetchPage(repository: newest.repository, page: 1)
        XCTAssertEqual(first.entries.first?.buildNumber, "39.21.36")
        XCTAssertEqual(first.entries.count, 30)
        XCTAssertEqual(first.omittedCount, 1)
        XCTAssertEqual(first.nextPage, 2)
        var requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0.contains("/commits/") }), 30)
        let second = try await discovery.fetchPage(repository: newest.repository, page: 2)
        XCTAssertEqual(second.entries.count, 30)
        XCTAssertTrue(Set(first.entries.map(\.tag)).isDisjoint(with: second.entries.map(\.tag)))
        _ = try await discovery.fetchPage(repository: newest.repository, page: 1)
        requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0.contains("/releases?") }), 2)
        XCTAssertEqual(requests.count(where: { $0.contains("/commits/") }), 60)
        await discovery.invalidateCache()
        let refreshed = try await discovery.fetchPage(repository: newest.repository, page: 1)
        XCTAssertEqual(refreshed.entries, first.entries)
        requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0.contains("/releases?") }), 4)
        XCTAssertEqual(requests.count(where: { $0.contains("/commits/") }), 60, "Successful immutable commit text survives explicit refresh")
    }

    func testCancelledDelayedInvalidationCannotClearNewerDiscoveryWork() async throws {
        let fixture = try TipPublicReleaseFixture()
        let listURL = try XCTUnwrap(URL(string: fixture.listURL))
        let transport = TipPublicReleaseTransport(responses: fixture.responses(), pauseFirstList: true)
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        let delayed = Task {
            _ = try await transport.fetch(listURL, maximumBytes: 4_194_304)
            await discovery.invalidateCache()
        }
        await transport.waitUntilListPaused()
        delayed.cancel()
        let fresh = try await discovery.fetchPage(repository: fixture.repository, page: 1)
        await transport.resumePausedList(with: Data("[]".utf8))
        try await delayed.value
        let cached = try await discovery.fetchPage(repository: fixture.repository, page: 1)
        XCTAssertEqual(cached.entries, fresh.entries)
        let requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0.contains("/releases?") }), 2, "Cancelled invalidation must preserve the newer page cache")
    }

    func testPublicTipDiscoveryPropagatesRetryAfterWithoutAdvancingPastRateLimitedMetadata() async throws {
        let fixture = try TipPublicReleaseFixture()
        let rolloutURL = try XCTUnwrap(fixture.assets.keys.first { $0.hasSuffix("/identity-rollout.json") })
        let retryAfter = Date(timeIntervalSince1970: 2_000_000_000)
        let transport = TipPublicReleaseTransport(responses: fixture.responses(), failures: [rolloutURL: TipHistoryCatalogFetchFailure(reason: .httpStatus(429), retryAfter: retryAfter)])
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        do {
            _ = try await discovery.fetchPage(repository: fixture.repository, page: 1)
            XCTFail("Rate-limited metadata was cached as an omission")
        } catch let failure as TipHistoryCatalogFetchFailure {
            XCTAssertEqual(failure.reason, .httpStatus(429))
            XCTAssertEqual(failure.retryAfter, retryAfter)
        }
        let retry = try await discovery.fetchPage(repository: fixture.repository, page: 1)
        XCTAssertEqual(retry.entries.count, 1)
        XCTAssertEqual(retry.omittedCount, 0)
        let requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0 == rolloutURL }), 2)
        XCTAssertEqual(requests.count(where: { $0.contains("/releases?") }), 1)
    }

    func testPublicTipDiscoveryInvalidationFencesAnInFlightIndexResponse() async throws {
        let fixture = try TipPublicReleaseFixture()
        let repository = fixture.repository
        let transport = TipPublicReleaseTransport(responses: fixture.responses(), pauseFirstList: true)
        let discovery = TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
        let stale = Task { try await discovery.fetchPage(repository: repository, page: 1) }
        await transport.waitUntilListPaused()
        await discovery.invalidateCache()
        let fresh = try await discovery.fetchPage(repository: repository, page: 1)
        XCTAssertEqual(fresh.entries.count, 1)
        // Deliberately deliver an empty old response even after cancellation.
        await transport.resumePausedList(with: Data("[]".utf8))
        do {
            _ = try await stale.value
            XCTFail("Invalidated request returned a stale page")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cached = try await discovery.fetchPage(repository: repository, page: 1)
        XCTAssertEqual(cached.entries, fresh.entries)
        let requests = await transport.requests
        XCTAssertEqual(requests.count(where: { $0.contains("/releases?") }), 2)
    }

    func testPublicTipDiscoveryPropagatesCancellationAndBoundsInjectedResponses() async throws {
        let fixture = try TipPublicReleaseFixture()
        let cancelled = TipHistoryReleaseDiscovery(fetch: { _, _ in throw CancellationError() })
        do {
            _ = try await cancelled.fetchPage(repository: fixture.repository, page: 1)
            XCTFail("Cancellation swallowed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let oversized = TipHistoryReleaseDiscovery(fetch: { _, bound in Data(repeating: 32, count: bound + 1) })
        do {
            _ = try await oversized.fetchPage(repository: fixture.repository, page: 1)
            XCTFail("Oversized metadata accepted")
        } catch {
            XCTAssertEqual(error as? TipHistoryLoadError, .malformed)
        }
    }
}

extension TipHistoryCatalogTests {
    func testSignedCatalogCannotClaimPublicReleaseFallbackOrigin() throws {
        var raw = TipHistoryTestFixture.entry(3)
        raw["origin"] = "githubRelease"
        let page = try TipHistoryTestFixture.page([raw])
        XCTAssertEqual(page.entries.first?.metadataProblem, .provenance)
    }
}

extension TipHistoryCompatibilityTests {
    func testPublicFallbackRetainsUnknownCoverageAndNonOfficialSaveOnlyCautions() async throws {
        let installed = try TipPublicReleaseFixture()
        let older = try TipPublicReleaseFixture(sha: String(repeating: "a", count: 40), build: "39.21.35")
        var responses = installed.responses()
        responses.merge(older.responses()) { _, new in new }
        responses[installed.listURL] = try TipPublicReleaseFixture.json([installed.release, older.release])
        let transport = TipPublicReleaseTransport(responses: responses)
        let page = try await TipHistoryReleaseDiscovery(fetch: { try await transport.fetch($0, maximumBytes: $1) })
            .fetchPage(repository: installed.repository, page: 1)
        XCTAssertEqual(page.entries.count, 2)
        let target = try XCTUnwrap(page.entries.last)
        // Having the installed build in the fallback list is NOT coverage of
        // intervening persistence changes or an absence of reviewed barriers.
        XCTAssertEqual(
            TipHistoryCompatibility.evaluate(target, in: page.entries, context: context("39.21.36")),
            .available(direction: .older, cautions: [.dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory])
        )
        let saveOnly = TipHistoryCompatibility.evaluate(target, in: page.entries, context: context("39.21.36", identity: .nonOfficial))
        XCTAssertEqual(saveOnly, .available(direction: .older, cautions: [.downloadOnlyNonOfficial, .dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory]))
        XCTAssertTrue(saveOnly.canDownload)
        XCTAssertEqual(saveOnly.badge, "Download only")
        XCTAssertEqual(
            TipHistoryCompatibility.evaluate(target, in: page.entries, context: context("999", identity: .nonOfficial)),
            .available(direction: .older, cautions: [.downloadOnlyNonOfficial, .dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory])
        )
        XCTAssertEqual(TipHistoryCompatibility.evaluate(target, in: page.entries, context: context("999")), .unavailable(.historyBehindInstalled))
        let sameBuild = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(
            TipHistoryCompatibility.evaluate(sameBuild, in: page.entries, context: context("39.21.36", identity: .nonOfficial)),
            .available(direction: .newer, cautions: [.downloadOnlyNonOfficial, .dataCompatibilityNotGuaranteed, .barrierUnknownInstalledOutsideHistory])
        )
    }
}

/// The schema and identity values match the existing published build 39.21.36.
/// No binary is fetched/executed; a syntactically valid enclosure signature is
/// deliberately not treated as verified by discovery.
private struct TipPublicReleaseFixture {
    let repository: TipHistoryRepository
    let release: [String: Any]
    let assets: [String: Data]
    let commitURL: String
    let listURL = "https://api.github.com/repos/repoprompt/repoprompt-ce-tip-updates/releases?per_page=100&page=1"
    let zipHash = "7677766fb706f0b5e5fb841c55b3b23cf7373382f00643541954a5e49ae8cf70"

    init(sha: String = "ab84d47e6271d107cdfc1208116150a7ae86d259", build: String = "39.21.36", mutation: String? = nil) throws {
        repository = try XCTUnwrap(TipHistoryRepository(feedURL: URL(string: "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/latest/download/appcast.xml")))
        let tag = "tip-\(sha.prefix(12))"
        let base = "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/download/\(tag)/"
        let zip = "RepoPrompt-\(tag)-\(build).zip"
        let manifestName = "RepoPrompt-\(tag)-\(build)-artifact-manifest.json"
        let manifest = try Self.json([
            "schema_version": 1,
            "bundle": ["identifier": "com.pvncher.repoprompt.ce", "build_number": build, "marketing_version": "1.6.0", "signing_mode": "developer-id", "architectures": ["arm64", "x86_64"]],
            "bundle_signing": ["identifier": "com.pvncher.repoprompt.ce", "team_identifier": "648A27MST5"]
        ])
        let manifestHash = TipHistorySignatureVerifier.sha256(manifest)
        let item: [String: Any] = [
            "role": mutation == "role" ? "successor" : "preparer", "tag": tag,
            "buildNumber": build, "marketingVersion": "1.6.0", "installationType": "application", "minimumSystemVersion": "14.0",
            "enclosureName": zip, "enclosureSha256": zipHash, "enclosureSize": 412_514_799,
            "edSignature": Data(repeating: 7, count: 64).base64EncodedString(), "url": base + zip
        ]
        let rollout = try Self.json([
            "schemaVersion": 1, "channel": "tip", "updateRepository": repository.path, "sourceTag": tag,
            "releaseCommit": mutation == "sha" ? String(repeating: "f", count: 40) : sha,
            "buildNumber": build, "marketingVersion": "1.6.0", "currentRole": "preparer", "signingIdentity": "legacy",
            "bundleIdentifier": "com.pvncher.repoprompt.ce", "teamIdentifier": mutation == "identity" ? "UNTRUSTED" : "648A27MST5",
            "migrationPhase": "legacy-preparer", "appcastItems": [item],
            "appArtifactManifest": ["name": manifestName, "sha256": mutation == "hash" ? String(repeating: "0", count: 64) : manifestHash]
        ])
        let sums = Data("\(mutation == "checksums" ? String(repeating: "0", count: 64) : zipHash)  \(zip)\n\(manifestHash)  \(manifestName)\n\(TipHistorySignatureVerifier.sha256(rollout))  identity-rollout.json\n".utf8)
        assets = [base + "identity-rollout.json": rollout, base + manifestName: manifest, base + "SHA256SUMS": sums]
        var inventory: [[String: Any]] = assets.map { url, bytes in
            ["name": URL(string: url)!.lastPathComponent, "size": bytes.count, "state": "uploaded", "browser_download_url": url]
        }
        inventory.append(["name": zip, "size": mutation == "size" ? 1 : 412_514_799, "state": "uploaded", "browser_download_url": mutation == "namespace" ? "https://evil.example/\(zip)" : base + zip])
        release = ["tag_name": tag, "draft": false, "published_at": "2026-10-21T17:34:29Z", "assets": inventory]
        commitURL = "https://api.github.com/repos/repoprompt/repoprompt-ce/commits/\(sha)?per_page=1"
    }

    func responses(message: String = "Merge pull request #1435 from opaque/branch\n\nKeep connection approval across reconnects\n\nPreserve FIFO approval order.\u{202E}") -> [String: Data] {
        var responses = assets
        responses[listURL] = try! Self.json([release])
        responses[commitURL] = try! Self.json([
            "sha": URL(string: commitURL)!.lastPathComponent,
            "commit": ["message": message, "committer": ["date": "2026-10-21T15:00:00Z"]]
        ])
        return responses
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

private actor TipPublicReleaseTransport {
    let responses: [String: Data]
    private(set) var requests: [String] = []
    private var pauseFirstList: Bool
    private var failures: [String: TipHistoryCatalogFetchFailure]
    private var pausedList: CheckedContinuation<Data, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    init(responses: [String: Data], pauseFirstList: Bool = false, failures: [String: TipHistoryCatalogFetchFailure] = [:]) {
        self.responses = responses
        self.pauseFirstList = pauseFirstList
        self.failures = failures
    }

    func waitUntilListPaused() async {
        if pausedList != nil {
            return
        }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resumePausedList(with data: Data) {
        pausedList?.resume(returning: data)
        pausedList = nil
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        requests.append(url.absoluteString)
        if let failure = failures.removeValue(forKey: url.absoluteString) {
            throw failure
        }
        if pauseFirstList, url.absoluteString.contains("/releases?") {
            pauseFirstList = false
            return await withCheckedContinuation {
                pausedList = $0
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
        guard let data = responses[url.absoluteString] else { throw TipHistoryLoadError.network }
        guard data.count <= maximumBytes else { throw TipHistoryLoadError.malformed }
        return data
    }
}
