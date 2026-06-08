import AppKit
@testable import RepoPrompt
import XCTest

final class BareURLLinkifierTests: XCTestCase {
    func testDisabledPolicyLeavesBareURLUnlinked() {
        let attributed = linkified("Visit https://example.com", policy: .disabled)

        XCTAssertTrue(linkedSubstrings(in: attributed).isEmpty)
    }

    func testHTTPAndHTTPSURLsBecomeLinks() throws {
        let attributed = linkified("Visit http://example.com and https://example.org/path", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), [
            "http://example.com",
            "https://example.org/path"
        ])
        let firstURL = try XCTUnwrap(linkValues(in: attributed).first as? URL)
        XCTAssertEqual(firstURL.absoluteString, "http://example.com")
    }

    func testBareURLReceivesPositiveMarkerAndVisualLinkStyling() throws {
        let attributed = linkified("Visit https://example.com then stop", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(
            attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil) as? Bool,
            true
        )
        XCTAssertEqual(attributed.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let foregroundColor = try XCTUnwrap(attributed.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? NSColor)
        XCTAssertTrue(foregroundColor.isEqual(NSColor.linkColor))
    }

    func testTrailingSentencePunctuationAndWrappingParensAreExcludedFromLinkRange() {
        let attributed = linkified("See https://example.com. Also (https://example.org/docs).", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), [
            "https://example.com",
            "https://example.org/docs"
        ])
    }

    func testBalancedParenthesesInsideURLArePreserved() {
        let attributed = linkified("See https://example.com/a_(b)", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com/a_(b)"])
    }

    func testRejectedBareURLShapesStayPlainText() {
        let attributed = linkified(
            "mailto:me@example.com me@example.com ftp://example.com file:///tmp/a www.example.com /tmp/http://local",
            policy: .httpHTTPSOnly
        )

        XCTAssertTrue(linkedSubstrings(in: attributed).isEmpty)
    }

    func testCallerCanSuppressURLThatTouchesDisplayedBoundary() {
        let completeBeforeBoundary = linkified(
            "See https://example.com.",
            policy: .httpHTTPSOnly,
            suppressLinksTouchingEndBoundary: true
        )
        XCTAssertEqual(linkedSubstrings(in: completeBeforeBoundary), ["https://example.com"])

        let touchingBoundary = linkified(
            "See https://example.com",
            policy: .httpHTTPSOnly,
            suppressLinksTouchingEndBoundary: true
        )
        XCTAssertTrue(linkedSubstrings(in: touchingBoundary).isEmpty)

        assertSuppressedBareURLIsNotVisuallyMarked(touchingBoundary, urlText: "https://example.com")
    }

    func testBareURLDoesNotReceiveMarkdownRawLinkAttribute() throws {
        let attributed = linkified("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertNil(attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil))
    }

    func testHTTPHTTPSURLSignalPreflightIsCheapAndCaseInsensitive() {
        XCTAssertTrue(BareURLLinkifier.containsHTTPHTTPSURLSignal(in: "Visit http://example.com"))
        XCTAssertTrue(BareURLLinkifier.containsHTTPHTTPSURLSignal(in: "Visit HTTPS://EXAMPLE.COM"))
        XCTAssertFalse(BareURLLinkifier.containsHTTPHTTPSURLSignal(in: "Visit www.example.com"))
        XCTAssertFalse(BareURLLinkifier.containsHTTPHTTPSURLSignal(in: "Email mailto:me@example.com"))
        XCTAssertFalse(BareURLLinkifier.containsHTTPHTTPSURLSignal(in: "No URL here"))
    }

    @MainActor
    func testPlainProseWebLinkClickFallsThroughToAppKitDefaultOpening() throws {
        let attributed = linkified("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)
        let coordinator = MarkdownTextViewCoordinator()

        XCTAssertFalse(try coordinator.textView(textView, clickedOnLink: XCTUnwrap(URL(string: "https://example.com")), at: linkRange.location))
    }

    private func assertSuppressedBareURLIsNotVisuallyMarked(
        _ attributed: NSAttributedString,
        urlText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (attributed.string as NSString).range(of: urlText)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(attributed.attribute(.link, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.underlineStyle, at: range.location, effectiveRange: nil), file: file, line: line)
        let foregroundColor = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertFalse(foregroundColor?.isEqual(NSColor.linkColor) ?? false, file: file, line: line)
    }

    private func linkified(
        _ text: String,
        policy: BareURLLinkificationPolicy,
        suppressLinksTouchingEndBoundary: Bool = false
    ) -> NSAttributedString {
        BareURLLinkifier.attributedString(
            text: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)],
            policy: policy,
            suppressLinksTouchingEndBoundary: suppressLinksTouchingEndBoundary
        )
    }
}

func linkedSubstrings(in attributed: NSAttributedString) -> [String] {
    linkRanges(in: attributed).map { (attributed.string as NSString).substring(with: $0) }
}

func linkValues(in attributed: NSAttributedString) -> [Any] {
    var values: [Any] = []
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let value {
            values.append(value)
        }
    }
    return values
}

func linkRanges(in attributed: NSAttributedString) -> [NSRange] {
    var ranges: [NSRange] = []
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
        if value != nil {
            ranges.append(range)
        }
    }
    return ranges
}
