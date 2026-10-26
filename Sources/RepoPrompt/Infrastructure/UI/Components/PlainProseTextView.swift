import AppKit
import SwiftUI

/// AppKit-backed plain prose renderer for selectable text with optional bare URL links.
///
/// This deliberately applies explicit `.link` attributes instead of enabling AppKit's
/// automatic link/data detection, so callers control exactly where prose linkification
/// is allowed.
struct PlainProseTextView: View {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let fallbackMeasurementWidth: CGFloat?
    let bareURLLinkificationPolicy: BareURLLinkificationPolicy
    let suppressLinksTouchingEndBoundary: Bool

    @Environment(\.markdownFileLinkOpener) private var markdownFileLinkOpener

    init(
        text: String,
        font: NSFont,
        textColor: NSColor = .textColor,
        fallbackMeasurementWidth: CGFloat? = nil,
        bareURLLinkificationPolicy: BareURLLinkificationPolicy = .disabled,
        suppressLinksTouchingEndBoundary: Bool = false
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.fallbackMeasurementWidth = fallbackMeasurementWidth
        self.bareURLLinkificationPolicy = bareURLLinkificationPolicy
        self.suppressLinksTouchingEndBoundary = suppressLinksTouchingEndBoundary
    }

    private var attributedString: NSAttributedString {
        BareURLLinkifier.attributedString(
            text: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor
            ],
            policy: bareURLLinkificationPolicy,
            suppressLinksTouchingEndBoundary: suppressLinksTouchingEndBoundary
        )
    }

    var body: some View {
        AttributedTextView(
            attributedString: attributedString,
            isEditable: false,
            allowsTextSelection: true,
            linkOpener: markdownFileLinkOpener,
            fallbackMeasurementWidth: fallbackMeasurementWidth
        )
    }
}
