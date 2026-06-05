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

    private func compile(
        _ markdown: String,
        policy: BareURLLinkificationPolicy,
        suppressBareLinksTouchingEndBoundary: Bool = false
    ) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = 13
        compiler.bareURLLinkificationPolicy = policy
        compiler.suppressBareLinksTouchingEndBoundary = suppressBareLinksTouchingEndBoundary
        return compiler.attributedString(from: Document(parsing: markdown))
    }
}
