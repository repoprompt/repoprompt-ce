import AppKit
import Markdown
@testable import RepoPrompt
import XCTest

final class EnhancedMarkdownBareURLTests: XCTestCase {
    func testBareProseURLLinksOnlyWhenPolicyEnabled() {
        let disabled = compile("Visit https://example.com", policy: .disabled)
        XCTAssertTrue(linkedSubstrings(in: disabled).isEmpty)

        let enabled = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        XCTAssertEqual(linkedSubstrings(in: enabled), ["https://example.com"])
    }

    func testExplicitMarkdownLinkStillWorksWhenBareURLPolicyDisabled() throws {
        let attributed = compile("Visit [the docs](https://example.com/docs)", policy: .disabled)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        let rawRange = try XCTUnwrap(linkRanges(in: attributed).first)
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: rawRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
    }

    func testInlineCodeURLDoesNotBecomeBareLink() {
        let attributed = compile("Inline `https://code.example` then https://prose.example", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testFencedCodeBlockURLDoesNotBecomeBareLink() {
        let markdown = """
        ```
        curl https://code.example
        ```

        Prose https://prose.example
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewLikeMarkdownProtectsInlineAndFencedCodeURLs() {
        let markdown = """
        Inline `https://inline-code.example` stays code.

        ```bash
        curl https://fenced-code.example
        ```

        Prose https://prose.example.
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly, suppressBareLinksTouchingEndBoundary: true)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewBoundarySuppressionRemovesBareURLAtDocumentEnd() {
        let completeBeforeBoundary = compile(
            "Prose https://example.com.",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertEqual(linkedSubstrings(in: completeBeforeBoundary), ["https://example.com"])

        let touchingBoundary = compile(
            "Prose https://example.com",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertTrue(linkedSubstrings(in: touchingBoundary).isEmpty)

        assertSuppressedBareURLIsNotVisuallyMarked(touchingBoundary, urlText: "https://example.com")
    }

    func testExplicitMarkdownLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "Visit [the docs](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testExplicitMarkdownLinkWithURLLabelSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "[https://example.com](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testImageGeneratedLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "![Diagram](https://example.com/image.png)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["Diagram (example.com)"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testSymbolGeneratedLinkDoesNotReceiveBareURLMarker() throws {
        let attributed = compile(
            "``https://example.com/symbol``",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true,
            options: .parseSymbolLinks
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com/symbol"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    @MainActor
    func testMarkdownWebLinkClickFallsThroughToAppKitDefaultOpening() throws {
        let attributed = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)
        let coordinator = MarkdownTextViewCoordinator()

        XCTAssertFalse(try coordinator.textView(textView, clickedOnLink: XCTUnwrap(URL(string: "https://example.com")), at: linkRange.location))
    }

    func testRenderSignatureConfigurationIncludesBareURLPolicy() {
        let disabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .disabled
        )
        let enabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )

        XCTAssertNotEqual(disabled, enabled)
        XCTAssertFalse(disabled.hasSameRenderingConfiguration(as: enabled))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: disabled, requested: enabled))
    }

    func testRenderSignatureConfigurationIncludesBoundarySuppression() {
        let ordinary = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )
        let preview = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )

        XCTAssertNotEqual(ordinary, preview)
        XCTAssertFalse(ordinary.hasSameRenderingConfiguration(as: preview))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: ordinary, requested: preview))
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

    private func compile(
        _ markdown: String,
        policy: BareURLLinkificationPolicy,
        suppressBareLinksTouchingEndBoundary: Bool = false,
        options: ParseOptions = []
    ) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = 13
        compiler.bareURLLinkificationPolicy = policy
        compiler.suppressBareLinksTouchingEndBoundary = suppressBareLinksTouchingEndBoundary
        return compiler.attributedString(from: Document(parsing: markdown, options: options))
    }
}
