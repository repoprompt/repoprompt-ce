import AppKit
@testable import RepoPrompt
import SwiftUI
import XCTest

final class NonProseURLLinkificationBoundaryTests: XCTestCase {
    @MainActor
    func testUnifiedDiffAttributedTextDoesNotAddLinksForURLsInDiffLines() {
        let document = UnifiedDiffCardRendering.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old https://deleted.example
        +new https://added.example
        """)
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            colorScheme: .light,
            lineSpacing: 2
        ).build()

        XCTAssertTrue(linkedSubstrings(in: attributed).isEmpty)
    }

    @MainActor
    func testNSTextViewHelperDisablesAutomaticURLDetection() {
        let textView = NSTextView()
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true

        textView.disableAutomaticLinkAndDataDetection()

        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
    }

    @MainActor
    func testToolScrollableMarkdownTextViewRendersToolOutputWithoutLinks() {
        let output = "tool output https://example.com"
        let view = ToolScrollableMarkdownTextView(text: output, maxHeight: 180)

        let textView = view.textKitView.configuredTextViewForTesting()

        XCTAssertEqual(textView.string, output)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        if #available(macOS 13.0, *) {
            XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        }
        XCTAssertTrue(linkedSubstrings(in: textView.attributedString()).isEmpty)
    }
}
