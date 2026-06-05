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
    }

    func testBareURLDoesNotReceiveMarkdownRawLinkAttribute() throws {
        let attributed = linkified("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertNil(attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil))
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
