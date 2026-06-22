@testable import RepoPromptCore
import XCTest

final class StringRuntimeUtilitiesParityTests: XCTestCase {
    func testDistanceSimilarityAndLongestSubsequencePreserveUTF8Semantics() {
        XCTAssertEqual(StringRuntimeUtilities.levenshteinDistance("kitten", "sitting"), 3)
        XCTAssertEqual(
            StringRuntimeUtilities.levenshteinDistance(
                "kitten",
                "sitting",
                maxAllowedDistance: 2
            ),
            3
        )
        XCTAssertEqual(StringRuntimeUtilities.levenshteinDistance("café", "cafe"), 1)
        XCTAssertEqual(StringRuntimeUtilities.similarityScore("identical", "identical"), 1)
        XCTAssertEqual(
            StringRuntimeUtilities.longestCommonSubsequence("A😀BC", "😀BD"),
            "😀B"
        )
    }

    func testDiceAndBulkBestMatchPreserveOrderingAndThresholds() throws {
        XCTAssertEqual(
            StringRuntimeUtilities.diceCoefficient("night", "nacht"),
            0.25,
            accuracy: 0.000_001
        )

        let match = try XCTUnwrap(
            StringRuntimeUtilities.bulkDiceBestMatch(
                pattern: "night",
                candidates: ["nacht", "night", "nighttime"],
                threshold: 0.2
            )
        )
        XCTAssertEqual(match.index, 1)
        XCTAssertEqual(match.score, 1, accuracy: 0.000_001)
        XCTAssertNil(
            StringRuntimeUtilities.bulkDiceBestMatch(
                pattern: "night",
                candidates: ["day", "sun"],
                threshold: 0.9
            )
        )
    }

    func testLineSplittingPreservesDetectedAndPerLineEndings() {
        let split = StringRuntimeUtilities.splitPreservingLineEndings("one\r\ntwo\r\n")
        XCTAssertEqual(split.0, ["one", "two"])
        XCTAssertEqual(split.1, "\r\n")

        let mixed = StringLineUtilities.splitPreservingAllLineEndings("α\r\nβ\rγ\n")
        XCTAssertEqual(mixed.map(\.line), ["α", "β", "γ"])
        XCTAssertEqual(mixed.map(\.ending), ["\r\n", "\r", "\n"])
        XCTAssertTrue(StringLineUtilities.splitPreservingAllLineEndings("").isEmpty)
    }

    func testIndentationEncodingDecodingAndCommonTrimRemainByteCompatible() {
        XCTAssertEqual(
            StringRuntimeUtilities.encodeIndentationAsSpaces("\t  value  "),
            "<s6>value"
        )
        XCTAssertEqual(
            StringRuntimeUtilities.decodeIndentation("<s6>value"),
            "      value"
        )
        XCTAssertEqual(
            StringRuntimeUtilities.decodeIndentation("<x6>value"),
            "<x6>value"
        )
        XCTAssertEqual(
            StringRuntimeUtilities.trimCommonLeadingWhitespacePreservingLineEndings(
                "    one\r\n      two"
            ),
            "one\r\n  two"
        )
    }

    func testEscapingHTMLAndWhitespaceNormalizationPreserveLegacyResults() {
        let source = "quote: \" slash: \\ tab:\t line:\n"
        let escaped = StringRuntimeUtilities.escape(source)
        XCTAssertEqual(escaped, "quote: \\\" slash: \\\\ tab:\\t line:\\n")
        XCTAssertEqual(StringRuntimeUtilities.unescape(escaped), source)
        XCTAssertEqual(
            StringRuntimeUtilities.decodeHTMLEntities("&lt;a&gt;&amp;&quot;&#39;&nbsp;"),
            "<a>&\"' "
        )
        XCTAssertEqual(
            StringRuntimeUtilities.condenseWhitespace(" \talpha\u{00A0}\n beta "),
            " alpha beta "
        )
    }

    func testFuzzySpaceCanonicalKeyAndHashPreserveLegacyResults() {
        XCTAssertTrue(
            StringRuntimeUtilities.fuzzySpaceMatch(
                pattern: "alpha beta",
                text: "alpha\t  beta",
                caseInsensitive: false
            )
        )
        XCTAssertTrue(
            StringRuntimeUtilities.fuzzySpaceMatch(
                pattern: "Alpha beta",
                text: "alpha beta",
                caseInsensitive: true
            )
        )
        XCTAssertFalse(
            StringRuntimeUtilities.fuzzySpaceMatch(
                pattern: "Alpha beta",
                text: "alpha beta",
                caseInsensitive: false
            )
        )
        XCTAssertEqual(StringRuntimeUtilities.canonicalKey(" Public  Foo__Bar: "), "foo-bar")
        XCTAssertNil(StringRuntimeUtilities.canonicalKey(" \t\n "))
        XCTAssertEqual(StringRuntimeUtilities.fnv1a64("hello"), 0xA430_D846_80AA_BD0B)
        XCTAssertEqual(StringLineUtilities.fnv1a64(""), 0xCBF2_9CE4_8422_2325)
    }
}
