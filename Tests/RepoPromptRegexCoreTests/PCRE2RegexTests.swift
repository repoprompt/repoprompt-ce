import RepoPromptRegexCore
import XCTest

final class PCRE2RegexTests: XCTestCase {
    func testCompileMatchCapturesAndUTF8ByteRanges() throws {
        let regex = try PCRE2Regex(#"^(é)(.)$"#, jit: .disabled)
        let match = try XCTUnwrap(regex.firstMatch(in: "é🙂"))

        XCTAssertEqual(match.byteRange, 0..<6)
        XCTAssertEqual(match.captureByteRanges, [0..<6, 0..<2, 2..<6])
        XCTAssertFalse(try regex.firstMatch(in: "é") != nil)
    }

    func testEnumerationAdvancesPastZeroLengthUnicodeMatches() throws {
        let regex = try PCRE2Regex(#"(?=.)"#, jit: .disabled)
        var ranges: [Range<Int>] = []

        try regex.enumerateMatches(in: "éa") { match in
            ranges.append(match.byteRange)
            return true
        }

        XCTAssertEqual(ranges, [0..<0, 2..<2])
    }

    func testMatchLimitIsReported() throws {
        let regex = try PCRE2Regex(#"^(a+)+$"#, jit: .disabled)
        let subject = String(repeating: "a", count: 64) + "!"

        XCTAssertThrowsError(
            try regex.firstMatch(
                in: subject,
                matchLimits: PCRE2MatchLimits(matchLimit: 1)
            )
        ) { error in
            guard case let PCRE2Error.matchLimitExceeded(kind, _, _) = error else {
                return XCTFail("Expected match-limit failure, got \(error)")
            }
            XCTAssertEqual(kind, .match)
        }
    }

    func testMatchSessionSupportsSequentialReuse() throws {
        let regex = try PCRE2Regex(#"^item-(\d+)$"#, jit: .disabled)

        try regex.withMatchSession { session in
            XCTAssertTrue(try session.containsMatch(in: "item-1"))
            XCTAssertFalse(try session.containsMatch(in: "other"))
            XCTAssertEqual(
                try session.firstMatch(in: "item-22")?.captureByteRanges[1],
                5..<7
            )
        }
    }

    func testLiteralEscapingHandlesEmbeddedQuoteTerminator() throws {
        let literal = #"left\Eright"#
        let regex = try PCRE2Regex(
            PCRE2Literal.escapedPattern(for: literal),
            jit: .disabled
        )

        XCTAssertTrue(try regex.firstMatch(in: literal) != nil)
        XCTAssertNil(try regex.firstMatch(in: #"left-right"#))
    }
}
