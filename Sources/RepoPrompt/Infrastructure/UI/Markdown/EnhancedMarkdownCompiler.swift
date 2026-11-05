//
//  EnhancedMarkdownCompiler.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-28.
//
//  MARKDOWNOSAUR ATTRIBUTION
//  Portions adapted from Markdownosaur by Christian Selig:
//  https://github.com/christianselig/Markdownosaur
//  Licensed under Apache-2.0 and substantially modified for RepoPrompt.
//

import AppKit
import Foundation
import Markdown
import SwiftUI

// MARK: - Enhanced Markdown Compiler

struct EnhancedMarkdownCompiler: Markdown.MarkupVisitor {
    typealias Result = NSAttributedString

    var forceTextColor: Color?
    var fontSize: CGFloat = 16.0
    var useMonospaced: Bool = false
    var bareURLLinkificationPolicy: BareURLLinkificationPolicy = .disabled
    var suppressBareLinksTouchingEndBoundary = false

    private static let maxTextTableRowsForInlineLayout = 300
    private static let maxTextTableCharactersForInlineLayout = 50000

    // Internal state for list depth
    private var currentListDepth: Int = 0
    private var currentListTracker: OrderedListMarkerGenerator? // For ordered lists

    mutating func attributedString(from markup: Markdown.Markup) -> NSAttributedString {
        let result = visit(markup).mutableCopy() as! NSMutableAttributedString
        if suppressBareLinksTouchingEndBoundary {
            removeBareLinksTouchingEndBoundary(from: result)
        }
        guard useMonospaced else {
            return result
        }

        let baseFont = NSFont.monospacedSystemFont(ofSize: max(fontSize, 10), weight: .regular)
        return makeMonospaced(result, baseFont: baseFont)
    }

    mutating func visit(_ markup: any Markdown.Markup) -> NSAttributedString {
        markup.accept(&self)
    }

    mutating func visitDocument(_ document: Markdown.Document) -> NSAttributedString {
        defaultVisit(document)
    }

    mutating func defaultVisit(_ markup: any Markdown.Markup) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    private func removeBareLinksTouchingEndBoundary(from result: NSMutableAttributedString) {
        guard result.length > 0 else { return }

        var range = NSRange(location: 0, length: 0)
        guard result.attribute(.repoPromptBareURLLink, at: result.length - 1, effectiveRange: &range) != nil else {
            return
        }

        let normalTextColor = NSColor(forceTextColor ?? Color.primary)
        result.removeAttribute(.link, range: range)
        result.removeAttribute(.underlineStyle, range: range)
        result.removeAttribute(.repoPromptBareURLLink, range: range)
        result.addAttribute(.foregroundColor, value: normalTextColor, range: range)
    }

    private func attributes(
        font: NSFont? = nil,
        paragraphStyle: NSParagraphStyle? = nil,
        additional: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = additional
        let baseFont = useMonospaced ?
            NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) :
            NSFont.systemFont(ofSize: fontSize, weight: .regular).rounded()
        attrs[.font] = font ?? baseFont

        let resolvedForceTextColor = forceTextColor ?? Color.primary
        attrs[.foregroundColor] = NSColor(resolvedForceTextColor)

        if let paragraphStyle {
            attrs[.paragraphStyle] = paragraphStyle
        }
        return attrs
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        BareURLLinkifier.attributedString(
            text: text.plainText,
            attributes: attributes(),
            policy: bareURLLinkificationPolicy
        )
    }

    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in paragraph.children {
            result.append(visit(child))
        }
        if paragraph.hasSuccessorConsideringBlockElements {
            // Inside list items use a single LF, elsewhere keep two.
            let isInListItem = paragraph.parent is Markdown.ListItem
            let lf = isInListItem ? "\n" : "\n\n"
            result.append(NSAttributedString(
                string: lf,
                attributes: attributes(font: NSFont.systemFont(ofSize: fontSize).rounded())
            ))
        }
        return result
    }

    mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in emphasis.children {
            result.append(visit(child))
        }
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length), options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            result.addAttribute(.font, value: italicFont, range: range)
        }
        return result
    }

    mutating func visitStrong(_ strong: Markdown.Strong) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in strong.children {
            result.append(visit(child))
        }
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length), options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            result.addAttribute(.font, value: boldFont, range: range)
        }
        return result
    }

    mutating func visitInlineCode(_ inlineCode: Markdown.InlineCode) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        // An attributed-string embedding keeps inline code left-to-right without
        // inserting bidi controls or changing UTF-16 offsets. Embedding is not
        // isolate semantics, and RTL runs inside the code remain subject to the
        // Unicode bidi algorithm rather than being forcibly reordered.
        let writingDirection = NSNumber(
            value: NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue
        )
        return NSAttributedString(string: inlineCode.code, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .writingDirection: [writingDirection]
        ])
    }

    // MARK: - Code Block ----------------------------------------------------

    mutating func visitCodeBlock(_ codeBlock: Markdown.CodeBlock) -> NSAttributedString {
        // ⓵  Raw source (trim trailing line-feed that the parser keeps)
        let code = codeBlock.code.hasSuffix("\n")
            ? String(codeBlock.code.dropLast())
            : codeBlock.code

        // ⓶  Base attributes & paragraph style
        let font = NSFont.monospacedSystemFont(
            ofSize: fontSize - 1,
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.lineSpacing = 2
        // Horizontal insets so text isn't glued to the rounded border
        let horizontalInset: CGFloat = 8
        paragraphStyle.headIndent = horizontalInset
        paragraphStyle.firstLineHeadIndent = horizontalInset
        paragraphStyle.tailIndent = -horizontalInset

        // ⓷  Build body string without background color (will be drawn separately)
        let body = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        // Tag the whole code block for UI to draw background and attach copy button
        body.addAttribute(
            .codeBlockSource,
            value: code,
            range: NSRange(location: 0, length: body.length)
        )

        // Apply enhanced syntax highlighting
        CodeHighlighter.applyHighlighting(to: body, code: code)

        // ⓹  Padding strategy:
        //   • Background expansion in CodeBlockTextView provides the visual inset.
        //   • The tagged code range stays limited to real source text so drawing
        //     does not include an extra empty line fragment inside the rounded rect.
        //   • Untagged trailing spacers reserve room for the expanded bottom
        //     edge without becoming part of the code block background.
        //   • Top-level block successors use body-size spacing so text between
        //     two code blocks sits evenly between them; terminal/list padding
        //     remains compact.
        let compactSpacerFont = NSFont.systemFont(ofSize: max(fontSize * 0.5, 6)).rounded()
        let compactSpacerStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        compactSpacerStyle.lineSpacing = 0
        compactSpacerStyle.paragraphSpacing = 0
        let compactSpacerAttributes: [NSAttributedString.Key: Any] = [
            .font: compactSpacerFont,
            .paragraphStyle: compactSpacerStyle
        ]
        let blockSpacingAttributes = attributes(font: NSFont.systemFont(ofSize: fontSize).rounded())
        let leadingSpacer = NSAttributedString(
            string: "\n",
            attributes: compactSpacerAttributes
        )
        let hasBlockSuccessor = codeBlock.hasSuccessorConsideringBlockElements
        let usesCompactTrailingSpacer = !hasBlockSuccessor || codeBlock.parent is Markdown.ListItem
        let trailingSpacerText = hasBlockSuccessor ? "\n\n" : "\n"
        let trailingSpacer = NSAttributedString(
            string: trailingSpacerText,
            attributes: usesCompactTrailingSpacer ? compactSpacerAttributes : blockSpacingAttributes
        )

        // ⓺  Final result
        let result = NSMutableAttributedString()
        if shouldInsertLeadingCodeBlockSpacer(before: codeBlock) {
            result.append(leadingSpacer)
        }
        result.append(body)
        result.append(trailingSpacer)

        return result
    }

    private func shouldInsertLeadingCodeBlockSpacer(before codeBlock: Markdown.CodeBlock) -> Bool {
        guard codeBlock.hasPredecessor else { return false }
        // Paragraphs inside list items intentionally emit a single line break between
        // child blocks. Reserve one compact spacer line so the drawn code block
        // background can expand upward without covering the previous list line.
        return codeBlock.parent is Markdown.ListItem
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in link.children {
            result.append(visit(child))
        }
        guard let destination = link.destination, result.length > 0 else {
            return result
        }

        let fullRange = NSRange(location: 0, length: result.length)
        result.removeAttribute(.repoPromptBareURLLink, range: fullRange)
        result.addAttribute(.markdownRawLink, value: destination, range: fullRange)
        if let url = URL(string: destination),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme)
        {
            result.addRepoPromptLink(url, range: fullRange)
        } else {
            result.addRepoPromptLink(destination, range: fullRange)
        }
        return result
    }

    mutating func visitBlockQuote(_ blockQuote: Markdown.BlockQuote) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let originalFontSize = fontSize
        // self.fontSize *= 0.9 // Optionally slightly smaller font for quotes

        let originalForceTextColor = forceTextColor
        // self.forceTextColor = (self.forceTextColor ?? Color.primary).opacity(0.8) // Dim text slightly

        let quoteDepth = blockQuote.quoteDepth
        let indentSize: CGFloat = 20.0 // Indent per quote level

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = CGFloat(quoteDepth + 1) * indentSize
        paragraphStyle.firstLineHeadIndent = CGFloat(quoteDepth + 1) * indentSize // Indent first line too

        // Add a visual marker for the blockquote (e.g., a vertical line)
        // This is complex with NSAttributedString directly. A simpler way is indent and color.
        // For more advanced drawing, one would need to subclass NSTextView or use TextKit drawing.

        for child in blockQuote.children {
            let childString = visit(child).mutableCopy() as! NSMutableAttributedString

            if child is Markdown.ListItemContainer || child is Markdown.Table {
                // Lists and tables carry their own direction, indentation, tab stops and table
                // blocks; indent them by the quote instead of replacing their styles.
                composeQuoteIndentation(into: childString, quoteStyle: paragraphStyle)
            } else {
                // Apply paragraph style to the entire child string
                childString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: childString.length))
            }

            // Adjust text color for quote, but preserve link colors.
            // Use a dynamic system color so quoted text stays readable in both
            // light and dark appearances (NSColor.gray is a fixed mid-gray and
            // becomes hard to read on dark backgrounds).
            childString.applyForegroundColor(.secondaryLabelColor, preservingLinkRanges: true)
            result.append(childString)
        }

        // self.fontSize = originalFontSize
        forceTextColor = originalForceTextColor

        if blockQuote.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(string: "\n\n", attributes: attributes(font: NSFont.systemFont(ofSize: fontSize).rounded())))
        }
        return result
    }

    /// Adds the quote's indent to every paragraph style in `content` while keeping direction,
    /// alignment and tab-stop layout; table cells (`textBlocks`) are left untouched and unstyled
    /// runs take the plain quote style.
    private func composeQuoteIndentation(
        into content: NSMutableAttributedString,
        quoteStyle: NSParagraphStyle
    ) {
        let indent = quoteStyle.headIndent
        let fullRange = NSRange(location: 0, length: content.length)
        var updates: [(NSRange, NSParagraphStyle)] = []
        content.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard let existing = value as? NSParagraphStyle else {
                updates.append((range, quoteStyle))
                return
            }
            guard existing.textBlocks.isEmpty else { return }
            let composed = existing.mutableCopy() as! NSMutableParagraphStyle
            composed.headIndent += indent
            composed.firstLineHeadIndent += indent
            composed.tabStops = existing.tabStops.map { tab in
                NSTextTab(textAlignment: tab.alignment, location: tab.location + indent, options: tab.options)
            }
            updates.append((range, composed))
        }
        for (range, style) in updates {
            content.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    mutating func visitCustomBlock(_ customBlock: Markdown.CustomBlock) -> NSAttributedString {
        defaultVisit(customBlock)
    }

    mutating func visitHeading(_ heading: Markdown.Heading) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in heading.children {
            result.append(visit(child))
        }

        let headingFontSize: CGFloat = switch heading.level {
        case 1: fontSize * 1.8
        case 2: fontSize * 1.5
        case 3: fontSize * 1.3
        case 4: fontSize * 1.15
        case 5: fontSize * 1.05
        default: fontSize
        }

        let headingFont = NSFont.systemFont(ofSize: headingFontSize, weight: .bold).rounded()
        result.addAttribute(.font, value: headingFont, range: NSRange(location: 0, length: result.length))

        if heading.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(string: "\n\n", attributes: attributes(font: NSFont.systemFont(ofSize: fontSize).rounded())))
        }
        return result
    }

    mutating func visitThematicBreak(_ thematicBreak: Markdown.ThematicBreak) -> NSAttributedString {
        // A simple way to represent thematic break, could be enhanced with drawing
        let hrString = "\n───────\n"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        return NSAttributedString(string: hrString, attributes: attributes(paragraphStyle: paragraphStyle))
    }

    mutating func visitHTMLBlock(_ html: Markdown.HTMLBlock) -> NSAttributedString {
        // HTML rendering is not supported, display as plain text or skip
        NSAttributedString(string: html.rawHTML, attributes: attributes(font: NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)))
    }

    // MARK: - List Items ----------------------------------------------------

    // MARK: - List Item ------------------------------------------------------

    mutating func visitListItem(_ listItem: Markdown.ListItem) -> NSAttributedString {
        renderListItemChildren(listItem).body
    }

    /// Renders each child of `listItem` exactly once and records the UTF-16 ranges of the prose
    /// paragraphs the item owns directly (not those of nested lists, code blocks, tables or quotes).
    private mutating func renderListItemChildren(
        _ listItem: Markdown.ListItem
    ) -> (body: NSMutableAttributedString, ownedParagraphRanges: [NSRange]) {
        let result = NSMutableAttributedString()
        var ownedParagraphRanges: [NSRange] = []

        for child in listItem.children {
            let start = result.length
            result.append(visit(child))
            if child is Markdown.Paragraph {
                ownedParagraphRanges.append(NSRange(location: start, length: result.length - start))
            }
        }

        // Trailing newline (single) when there are more items following
        if listItem.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(
                string: "\n",
                attributes: attributes(font: NSFont.systemFont(ofSize: fontSize).rounded())
            ))
        }
        return (result, ownedParagraphRanges)
    }

    /// One list item: `marker` (already carrying `markerStyle`) followed by the rendered children.
    ///
    /// The item's first line (marker plus the first TextKit paragraph of a leading prose
    /// paragraph) uses `markerStyle`; every later TextKit paragraph of the prose paragraphs the
    /// item owns (hard-break lines, loose-list paragraphs) uses `continuationStyle`, so they keep
    /// the list's direction and start at the content indent. Nested lists, code blocks, tables and
    /// other blocks keep their own paragraph styles; when the item does not start with a prose
    /// paragraph only the marker itself is styled, so a leading block's style and `textBlocks`
    /// are never overwritten.
    private mutating func renderListItem(
        _ listItem: Markdown.ListItem,
        marker: NSAttributedString,
        markerStyle: NSParagraphStyle,
        continuationStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let (body, ownedParagraphRanges) = renderListItemChildren(listItem)
        body.insert(marker, at: 0)
        let markerLength = marker.length
        let string = body.string as NSString

        for paragraphRange in ownedParagraphRanges {
            let range = NSRange(location: paragraphRange.location + markerLength, length: paragraphRange.length)
            guard range.length > 0 else { continue }
            var continuationStart = range.location
            if paragraphRange.location == 0 {
                // Leading prose paragraph: its first TextKit paragraph shares the marker's line.
                let firstLine = string.paragraphRange(for: NSRange(location: range.location, length: 0))
                continuationStart = min(NSMaxRange(firstLine), NSMaxRange(range))
                body.addAttribute(
                    .paragraphStyle,
                    value: markerStyle,
                    range: NSRange(location: range.location, length: continuationStart - range.location)
                )
            }
            if continuationStart < NSMaxRange(range) {
                body.addAttribute(
                    .paragraphStyle,
                    value: continuationStyle,
                    range: NSRange(location: continuationStart, length: NSMaxRange(range) - continuationStart)
                )
            }
        }
        return body
    }

    /// Marker-line and continuation styles for one list level. Continuation paragraphs start at the
    /// content tab stop (`headIndent`) instead of the marker column.
    private func listItemParagraphStyles(
        direction: NSWritingDirection?,
        markerColumnEnd: CGFloat,
        contentStart: CGFloat
    ) -> (marker: NSParagraphStyle, continuation: NSParagraphStyle) {
        let markerStyle = NSMutableParagraphStyle()
        MarkdownStructureDirection.apply(direction, to: markerStyle)
        markerStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: markerColumnEnd),
            NSTextTab(textAlignment: .left, location: contentStart)
        ]
        markerStyle.headIndent = contentStart
        let continuationStyle = markerStyle.mutableCopy() as! NSMutableParagraphStyle
        continuationStyle.firstLineHeadIndent = contentStart
        return (markerStyle, continuationStyle)
    }

    private func listParagraphStyle(depth: Int) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        let baseIndent: CGFloat = 20.0
        let indentPerLevel: CGFloat = 20.0

        let totalIndent = baseIndent + (CGFloat(depth) * indentPerLevel)

        // Create tab stops: one for the marker, one for the content after the marker.
        // Marker alignment (right) means text before this tab stop is right-aligned.
        // Content alignment (left) means text after this tab stop is left-aligned.
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: totalIndent - 5), // Marker ends here
            NSTextTab(textAlignment: .left, location: totalIndent) // Content starts here
        ]
        paragraphStyle.headIndent = totalIndent // Indent subsequent lines of the list item
        // Add a little breathing room between consecutive list items
        paragraphStyle.paragraphSpacing = 2
        return paragraphStyle
    }

    // MARK: - Ordered List ---------------------------------------------------

    mutating func visitOrderedList(_ orderedList: Markdown.OrderedList) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: fontSize, weight: .regular).rounded()
        let numeralFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)

        // Highest index width (monospaced so width of any digit is same)
        let highestNumber = orderedList.childCount
        let numeralColumnWidth = ceil(
            NSAttributedString(
                string: "\(highestNumber).",
                attributes: [.font: numeralFont]
            ).size().width
        )
        // One direction per list keeps markers and continuation indents on the same side for
        // every item, even when an item starts with a code span or a word in the other script.
        let listDirection = MarkdownStructureDirection.baseWritingDirection(for: orderedList)

        let baseLeftMargin: CGFloat = 15.0
        let leftMarginOffset = baseLeftMargin + (20.0 * CGFloat(orderedList.listDepth))
        let spacingFromIndex: CGFloat = 8.0
        let firstTabLocation = leftMarginOffset + numeralColumnWidth
        let styles = listItemParagraphStyles(
            direction: listDirection,
            markerColumnEnd: firstTabLocation,
            contentStart: firstTabLocation + spacingFromIndex
        )

        for (idx, child) in orderedList.children.enumerated() {
            guard let listItem = child as? Markdown.ListItem else { continue }

            var numberAttributes: [NSAttributedString.Key: Any] = [:]
            numberAttributes[.paragraphStyle] = styles.marker
            numberAttributes[.font] = numeralFont
            numberAttributes[.listDepth] = orderedList.listDepth
            // Use the same text colour we apply everywhere else so markers react to dark/light mode
            let resolvedColour = forceTextColor ?? Color.primary
            numberAttributes[.foregroundColor] = NSColor(resolvedColour)

            // Prefix with the number using numeral font
            let numberString = NSAttributedString(
                string: "\t\(idx + Int(orderedList.startIndex)).\t",
                attributes: numberAttributes
            )
            result.append(renderListItem(
                listItem,
                marker: numberString,
                markerStyle: styles.marker,
                continuationStyle: styles.continuation
            ))
        }

        // Trailing spacing rules (single NL if nested, double otherwise)
        if orderedList.hasSuccessorConsideringBlockElements {
            let gap = orderedList.isContainedInList ? "\n" : "\n\n"
            result.append(NSAttributedString(
                string: gap,
                attributes: attributes(font: bodyFont)
            ))
        }
        return result
    }

    // MARK: - Unordered List -------------------------------------------------

    mutating func visitUnorderedList(_ unorderedList: Markdown.UnorderedList) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular).rounded()
        // See `visitOrderedList`: one direction per list.
        let listDirection = MarkdownStructureDirection.baseWritingDirection(for: unorderedList)

        let baseLeftMargin: CGFloat = 15.0
        let leftMarginOffset = baseLeftMargin + (20.0 * CGFloat(unorderedList.listDepth))
        let spacingFromIndex: CGFloat = 8.0
        // Width of the bullet glyph so text after aligns nicely
        let bulletWidth = ceil(
            NSAttributedString(string: "•", attributes: [.font: font]).size().width
        )
        let firstTabLocation = leftMarginOffset + bulletWidth
        let styles = listItemParagraphStyles(
            direction: listDirection,
            markerColumnEnd: firstTabLocation,
            contentStart: firstTabLocation + spacingFromIndex
        )

        // Iterate over each list item so we can prepend bullet + tab stops
        for case let listItem as Markdown.ListItem in unorderedList.children {
            var bulletAttributes: [NSAttributedString.Key: Any] = [:]
            bulletAttributes[.paragraphStyle] = styles.marker
            bulletAttributes[.font] = font
            bulletAttributes[.listDepth] = unorderedList.listDepth
            // Use dynamic colour so the bullet adapts to the current appearance
            let resolvedColour = forceTextColor ?? Color.primary
            bulletAttributes[.foregroundColor] = NSColor(resolvedColour)

            result.append(renderListItem(
                listItem,
                marker: NSAttributedString(string: "\t•\t", attributes: bulletAttributes),
                markerStyle: styles.marker,
                continuationStyle: styles.continuation
            ))
        }

        // After the list, insert two new-lines unless this list is itself inside another one
        if unorderedList.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(
                string: "\n\n",
                attributes: attributes(font: font)
            ))
        }
        return result
    }

    mutating func visitBlockDirective(_ blockDirective: Markdown.BlockDirective) -> NSAttributedString {
        defaultVisit(blockDirective)
    }

    mutating func visitCustomInline(_ customInline: Markdown.CustomInline) -> NSAttributedString {
        NSAttributedString(string: customInline.plainText, attributes: attributes())
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        // Basic image handling: display alt text with a link if available
        var text = image.plainText
        if let source = image.source, let url = URL(string: source) {
            text += " (\(url.host ?? source))"
            let result = NSMutableAttributedString(string: text, attributes: attributes())
            result.addRepoPromptLink(url, range: NSRange(location: 0, length: result.length))
            return result
        }
        return NSAttributedString(string: text, attributes: attributes())
    }

    mutating func visitInlineHTML(_ inlineHTML: Markdown.InlineHTML) -> NSAttributedString {
        NSAttributedString(string: inlineHTML.rawHTML, attributes: attributes(font: NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)))
    }

    mutating func visitLineBreak(_ lineBreak: Markdown.LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: attributes())
    }

    mutating func visitSoftBreak(_ softBreak: Markdown.SoftBreak) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: attributes())
    }

    mutating func visitStrikethrough(_ strikethrough: Markdown.Strikethrough) -> NSAttributedString {
        let result = defaultVisit(strikethrough).mutableCopy() as! NSMutableAttributedString
        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: result.length))
        // Optionally, change color for strikethrough text
        // result.addAttribute(.foregroundColor, value: NSColor.gray, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Tables

    mutating func visitTable(_ table: Markdown.Table) -> NSAttributedString {
        var rows: [[NSAttributedString]] = []
        var headerRowCount = 0

        if table.head.childCount > 0 {
            let firstHeadChild = table.head.children.first(where: { _ in true })
            if firstHeadChild is Markdown.Table.Cell {
                let headerCells = attributedCells(in: table.head)
                if !headerCells.isEmpty {
                    rows.append(headerCells)
                    headerRowCount = 1
                }
            } else {
                for case let headRow as Markdown.Table.Row in table.head.children {
                    rows.append(attributedCells(in: headRow))
                    headerRowCount += 1
                }
            }
        }

        for case let bodyRow as Markdown.Table.Row in table.body.children {
            rows.append(attributedCells(in: bodyRow))
        }

        guard !rows.isEmpty else { return NSAttributedString() }
        removeCanonicalSeparatorRows(from: &rows, headerRowCount: &headerRowCount)
        // One direction per table: every NSTextTable cell paragraph shares it, so alignment does
        // not depend on whether a given cell holds Hebrew, Arabic or English. The plain fallback
        // uses it for row alignment and keeps the same left-to-right column order.
        let tableDirection = MarkdownStructureDirection.baseWritingDirection(for: table)
        if shouldUsePlainTableFallback(rows) {
            return renderPlainTable(rows, table: table, direction: tableDirection)
        }
        return renderTextTable(rows, headerRowCount: headerRowCount, table: table, direction: tableDirection)
    }

    private func shouldUsePlainTableFallback(_ rows: [[NSAttributedString]]) -> Bool {
        guard rows.count <= Self.maxTextTableRowsForInlineLayout else { return true }
        let characterCount = rows.reduce(0) { partial, row in
            partial + row.reduce(0) { $0 + $1.string.count }
        }
        return characterCount > Self.maxTextTableCharactersForInlineLayout
    }

    private func renderPlainTable(
        _ rows: [[NSAttributedString]],
        table sourceTable: Markdown.Table,
        direction: NSWritingDirection?
    ) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: max(fontSize - 1, 10), weight: .regular).rounded()
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor(forceTextColor ?? Color.primary)
        ]
        // Column order must not depend on which script a row's cells hold, and must match the
        // NSTextTable path, which TextKit lays out in string order (column 0 on the left) for every
        // direction. A single paragraph direction cannot do that: neutral " | " separators between
        // two same-direction cells take that direction and the row reorders. So, display-only:
        // - every row is a left-to-right paragraph (right-aligned for a right-to-left table), and
        // - every non-empty cell is wrapped in a left-to-right embedding, prepended to any direction
        //   it already carries (inline code), while separators stay outside every cell embedding.
        // Embeddings are not isolates: bidi controls already inside a cell (an unmatched isolate
        // initiator in particular) can still reorder its row. A table without any strong character
        // (nil direction) gets no explicit direction at all.
        let rowParagraphStyle = NSMutableParagraphStyle()
        if direction != nil {
            rowParagraphStyle.baseWritingDirection = .leftToRight
            if direction == .rightToLeft {
                rowParagraphStyle.alignment = .right
            }
        }
        let cellEmbedding = NSNumber(
            value: NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue
        )
        let result = NSMutableAttributedString()
        if sourceTable.hasPredecessor {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
            let rowStart = result.length
            for (columnIndex, cell) in row.enumerated() {
                if columnIndex > 0 {
                    result.append(NSAttributedString(string: "  |  ", attributes: bodyAttributes))
                }
                if direction != nil, cell.length > 0 {
                    result.append(Self.prependingWritingDirection(cellEmbedding, to: cell))
                } else {
                    result.append(cell)
                }
            }
            result.addAttribute(
                .paragraphStyle,
                value: rowParagraphStyle,
                range: NSRange(location: rowStart, length: result.length - rowStart)
            )
        }
        if sourceTable.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }
        return result
    }

    /// `attributed` with `embedding` added as the outermost `.writingDirection` level over its
    /// whole range; existing (inner) levels such as inline code's embedding are kept after it.
    private static func prependingWritingDirection(
        _ embedding: NSNumber,
        to attributed: NSAttributedString
    ) -> NSAttributedString {
        let result = attributed.mutableCopy() as! NSMutableAttributedString
        let fullRange = NSRange(location: 0, length: result.length)
        var updates: [(NSRange, [NSNumber])] = []
        result.enumerateAttribute(.writingDirection, in: fullRange) { value, range, _ in
            updates.append((range, [embedding] + ((value as? [NSNumber]) ?? [])))
        }
        for (range, levels) in updates {
            result.addAttribute(.writingDirection, value: levels, range: range)
        }
        return result
    }

    private func removeCanonicalSeparatorRows(
        from rows: inout [[NSAttributedString]],
        headerRowCount: inout Int
    ) {
        func isSeparatorCell(_ str: String) -> Bool {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return trimmed.first(where: { $0 != "-" && $0 != ":" }) == nil
        }

        func isSeparatorRow(_ row: [NSAttributedString]) -> Bool {
            row.allSatisfy { isSeparatorCell($0.string) }
        }

        guard headerRowCount > 0 else { return }
        if headerRowCount < rows.count, isSeparatorRow(rows[headerRowCount]) {
            rows.remove(at: headerRowCount)
        } else if headerRowCount - 1 < rows.count,
                  isSeparatorRow(rows[headerRowCount - 1])
        {
            rows.remove(at: headerRowCount - 1)
            headerRowCount = max(0, headerRowCount - 1)
        }
        headerRowCount = min(headerRowCount, rows.count)
    }

    private func renderTextTable(
        _ rows: [[NSAttributedString]],
        headerRowCount: Int,
        table sourceTable: Markdown.Table,
        direction: NSWritingDirection?
    ) -> NSAttributedString {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return NSAttributedString() }

        let result = NSMutableAttributedString()
        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.setValue(100, type: .percentageValueType, for: .width)

        let bodyFont = NSFont.systemFont(ofSize: max(fontSize - 1, 10), weight: .regular).rounded()
        let textColor = NSColor(forceTextColor ?? Color.primary)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor
        ]

        if sourceTable.hasPredecessor {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }

        for (rowIndex, row) in rows.enumerated() {
            let isHeaderRow = rowIndex < headerRowCount
            for columnIndex in 0 ..< columnCount {
                let block = tableBlock(
                    table: textTable,
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnCount: columnCount,
                    isHeader: isHeaderRow
                )
                let paragraphStyle = tableParagraphStyle(
                    block: block,
                    alignment: tableTextAlignment(for: sourceTable, columnIndex: columnIndex),
                    direction: direction
                )
                let cell = columnIndex < row.count
                    ? row[columnIndex]
                    : NSAttributedString()
                result.append(
                    tableCellAttributedString(
                        cell,
                        isHeader: isHeaderRow,
                        paragraphStyle: paragraphStyle,
                        baseAttributes: bodyAttributes
                    )
                )
            }
        }

        if sourceTable.hasSuccessorConsideringBlockElements {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }
        return result
    }

    private func tableBlock(
        table: NSTextTable,
        rowIndex: Int,
        columnIndex: Int,
        columnCount: Int,
        isHeader: Bool
    ) -> NSTextTableBlock {
        let block = NSTextTableBlock(
            table: table,
            startingRow: rowIndex,
            rowSpan: 1,
            startingColumn: columnIndex,
            columnSpan: 1
        )
        let borderColor = NSColor.separatorColor.withAlphaComponent(0.45)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setBorderColor(borderColor, for: edge)
            block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: edge)
        }
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setValue(100 / CGFloat(max(columnCount, 1)), type: .percentageValueType, for: .width)
        if isHeader {
            block.backgroundColor = NSColor.controlColor.withAlphaComponent(0.18)
        }
        return block
    }

    private func tableParagraphStyle(
        block: NSTextTableBlock,
        alignment: NSTextAlignment,
        direction: NSWritingDirection?
    ) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.textBlocks = [block]
        paragraphStyle.alignment = alignment
        MarkdownStructureDirection.apply(direction, to: paragraphStyle)
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return paragraphStyle
    }

    private func tableTextAlignment(for table: Markdown.Table, columnIndex: Int) -> NSTextAlignment {
        let alignment = columnIndex < table.columnAlignments.count
            ? table.columnAlignments[columnIndex]
            : nil
        // An unspecified column follows the table's direction (leading edge); LTR tables are
        // unchanged because `.natural` resolves to left there.
        switch alignment {
        case nil:
            return .natural
        case .left:
            return .left
        case .right:
            return .right
        case .center:
            return .center
        }
    }

    private func tableCellAttributedString(
        _ original: NSAttributedString,
        isHeader: Bool,
        paragraphStyle: NSParagraphStyle,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let cell: NSMutableAttributedString = if original.length > 0 {
            original.mutableCopy() as! NSMutableAttributedString
        } else {
            NSMutableAttributedString(string: "\u{00a0}", attributes: baseAttributes)
        }

        if isHeader {
            applyHeaderWeight(to: cell)
        }

        let fullRange = NSRange(location: 0, length: cell.length)
        cell.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        var newlineAttributes = baseAttributes
        newlineAttributes[.paragraphStyle] = paragraphStyle
        cell.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
        return cell
    }

    private func applyHeaderWeight(to cell: NSMutableAttributedString) {
        guard cell.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: cell.length)
        var updates: [(NSFont, NSRange)] = []
        cell.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: max(fontSize - 1, 10), weight: .regular).rounded()
            let headerFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            updates.append((headerFont, range))
        }
        for (font, range) in updates {
            cell.addAttribute(.font, value: font, range: range)
        }
    }

    mutating func visitTableRow(_ tableRow: Markdown.Table.Row) -> NSAttributedString {
        // This is not called directly by visitTable in the current structure.
        // visitTable processes rows and cells internally.
        NSAttributedString()
    }

    mutating func visitTableCell(_ tableCell: Markdown.Table.Cell) -> NSAttributedString {
        // Build cell content independently so inline markdown remains rich inside
        // the NSTextTable-backed table renderer.
        let originalUseMonospaced = useMonospaced
        useMonospaced = false
        let firstPass = trimmedTableCell(defaultVisit(tableCell))
        useMonospaced = originalUseMonospaced

        if hasRichTableCellAttributes(firstPass) {
            return firstPass
        }

        let cellFont = NSFont.systemFont(ofSize: fontSize, weight: .regular).rounded()
        return NSAttributedString(
            string: firstPass.string,
            attributes: attributes(font: cellFont)
        )
    }

    private func trimmedTableCell(_ attributed: NSAttributedString) -> NSAttributedString {
        let text = attributed.string as NSString
        var start = 0
        var end = text.length
        while start < end,
              let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(text.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
            end -= 1
        }
        guard start > 0 || end < text.length else { return attributed }
        guard end > start else { return NSAttributedString() }
        return attributed.attributedSubstring(from: NSRange(location: start, length: end - start))
    }

    private func hasRichTableCellAttributes(_ attributed: NSAttributedString) -> Bool {
        var isRich = false
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange) { attributes, _, stop in
            if attributes.keys.contains(where: { key in
                key != .font && key != .foregroundColor && key != .paragraphStyle
            }) {
                isRich = true
                stop.pointee = true
                return
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || traits.contains(.italic) || font.fontName.lowercased().contains("mono") {
                    isRich = true
                    stop.pointee = true
                }
            }
        }
        return isRich
    }

    mutating func visitTableHead(_ tableHead: Markdown.Table.Head) -> NSAttributedString {
        // Not called directly by visitTable.
        defaultVisit(tableHead)
    }

    mutating func visitTableBody(_ tableBody: Markdown.Table.Body) -> NSAttributedString {
        // Not called directly by visitTable.
        defaultVisit(tableBody)
    }

    // MARK: - Doxygen and other specific types (default behavior)

    mutating func visitSymbolLink(_ symbolLink: Markdown.SymbolLink) -> NSAttributedString {
        // Similar to a link, but might need specific styling if distinguished
        let text = symbolLink.destination ?? "SymbolLink"
        let result = NSMutableAttributedString(string: text, attributes: attributes())
        if let dest = symbolLink.destination, let url = URL(string: dest) { // Assuming destination can be a URL
            result.addRepoPromptLink(url, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    mutating func visitInlineAttributes(_ attributesNode: Markdown.InlineAttributes) -> NSAttributedString {
        // These are attributes applied to other inline elements, not directly rendered.
        // The parent element should handle them.
        defaultVisit(attributesNode)
    }

    /// For Doxygen and other specific types, we'll use defaultVisit or provide basic plain text.
    mutating func visitDoxygenDiscussion(_ doxygenDiscussion: Markdown.DoxygenDiscussion) -> NSAttributedString {
        defaultVisit(doxygenDiscussion)
    }

    mutating func visitDoxygenNote(_ doxygenNote: Markdown.DoxygenNote) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "Note: ", attributes: attributes(font: NSFont.systemFont(ofSize: fontSize, weight: .bold).rounded()))
        result.append(defaultVisit(doxygenNote))
        return result
    }

    mutating func visitDoxygenParameter(_ doxygenParam: Markdown.DoxygenParameter) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\(doxygenParam.name): ", attributes: attributes(font: NSFont.systemFont(ofSize: fontSize, weight: .semibold).rounded()))
        result.append(defaultVisit(doxygenParam))
        return result
    }

    mutating func visitDoxygenReturns(_ doxygenReturns: Markdown.DoxygenReturns) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "Returns: ", attributes: attributes(font: NSFont.systemFont(ofSize: fontSize, weight: .bold).rounded()))
        result.append(defaultVisit(doxygenReturns))
        return result
    }

    // MARK: - Table Helper (NEW) - attributedCells

    private mutating func attributedCells(in row: Markdown.Table.Row) -> [NSAttributedString] {
        row.children
            .compactMap { $0 as? Markdown.Table.Cell }
            .map { visitTableCell($0) }
    }

    // MARK: - Table Helper (NEW) - attributedCells for header  🆕

    private mutating func attributedCells(in head: Markdown.Table.Head) -> [NSAttributedString] {
        head.children
            .compactMap { $0 as? Markdown.Table.Cell }
            .map { visitTableCell($0) }
    }
}

// MARK: - Markdown Structure Extensions

extension Markdown.Markup {
    var hasPredecessor: Bool {
        indexInParent >= 1
    }

    var hasSuccessor: Bool {
        guard let parent else { return false }
        return indexInParent < parent.childCount - 1
    }

    /// More robust successor check, especially for block elements needing double newlines.
    var hasSuccessorConsideringBlockElements: Bool {
        guard let parent else { return false }
        if indexInParent < parent.childCount - 1 {
            // Check if the current element is a block element that typically has space after it
            // This is a heuristic; specific Markdown elements might have their own rules.
            return true
        }
        return false
    }
}

extension Markdown.OrderedList {
    /// True if this list is nested within another list.
    var isContainedInList: Bool {
        (parent as? Markdown.ListItemContainer) != nil
    }
}

extension Markdown.ListItemContainer {
    var listDepth: Int {
        var depth = 0
        var current: Markdown.Markup? = parent
        while let c = current {
            if c is Markdown.ListItemContainer {
                depth += 1
            }
            current = c.parent
        }
        return depth
    }
}

extension Markdown.BlockQuote {
    var quoteDepth: Int {
        var depth = 0
        var current: Markdown.Markup? = parent
        while let c = current {
            if c is Markdown.BlockQuote {
                depth += 1
            }
            current = c.parent
        }
        return depth
    }
}

/// Helper for ordered list markers
struct OrderedListMarkerGenerator {
    private var current: Int
    init(start: Int) {
        current = start
    }

    mutating func next() -> String {
        let marker = "\(current)."
        current += 1
        return marker
    }
}

// MARK: - Utilities for Table Rendering (Largely Preserved)

extension NSAttributedString.Key {
    /// Marks the range that represents one full Markdown code-block –
    /// the value stored under this key is the raw source string so a
    /// button can copy it to the pasteboard.
    static let codeBlockSource = NSAttributedString.Key("codeBlockSource")

    /// Indicates the nesting depth of a list item
    static let listDepth = NSAttributedString.Key("listDepth")
    /// Indicates the nesting depth of a block quote
    static let quoteDepth = NSAttributedString.Key("quoteDepth")
    /// Marks a range as inline code so the text view can draw a rounded background.
    static let inlineCode = NSAttributedString.Key("inlineCode")
}

private func makeMonospaced(_ src: NSAttributedString, baseFont mono: NSFont) -> NSAttributedString {
    let out = src.mutableCopy() as! NSMutableAttributedString
    let full = NSRange(location: 0, length: out.length)

    out.enumerateAttribute(.font, in: full) { value, range, _ in
        let original = (value as? NSFont) ?? mono
        let traits = original.fontDescriptor.symbolicTraits
        let weight: NSFont.Weight = traits.contains(.bold) ? .bold : .regular

        var monoSizedFont = NSFont.monospacedSystemFont(ofSize: mono.pointSize, weight: weight)

        if traits.contains(.italic) {
            monoSizedFont = NSFontManager.shared.convert(monoSizedFont, toHaveTrait: .italicFontMask)
        }
        out.addAttribute(.font, value: monoSizedFont, range: range)
        // Preserve original foreground color if different from default
        if let originalColor = src.attribute(.foregroundColor, at: range.location, effectiveRange: nil) {
            out.addAttribute(.foregroundColor, value: originalColor, range: range)
        }
    }
    return out
}

// MARK: - NSFont Extension for Rounded Design

extension NSFont {
    /// Returns a version of this font with rounded design
    func rounded() -> NSFont {
        let descriptor = fontDescriptor.withDesign(.rounded) ?? fontDescriptor
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
