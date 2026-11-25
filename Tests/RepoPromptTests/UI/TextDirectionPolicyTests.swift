import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class TextDirectionPolicyTests: XCTestCase {
    func testRolesMapToSharedBaseAndFrameworkDirections() {
        let scenarios: [(
            role: TextDirectionRole,
            base: TextDirectionPolicy.BaseDirection,
            appKit: NSWritingDirection?,
            swiftUI: LayoutDirection?
        )] = [
            (.naturalProse, .natural, nil, nil),
            (.dedicatedLeftToRight, .leftToRight, .leftToRight, .leftToRight),
            (.markdownCodeBlock, .leftToRight, .leftToRight, .leftToRight)
        ]

        XCTAssertEqual(TextDirectionRole.allCases, scenarios.map(\.role))

        for scenario in scenarios {
            XCTAssertEqual(TextDirectionPolicy.baseDirection(for: scenario.role), scenario.base)
            XCTAssertEqual(TextDirectionPolicy.appKitBaseWritingDirection(for: scenario.role), scenario.appKit)
            XCTAssertEqual(TextDirectionPolicy.swiftUILayoutDirection(for: scenario.role), scenario.swiftUI)
        }
    }

    func testAppKitAdaptersPreserveLogicalStringsAndNaturalOverrides() {
        let logicalString = "עברית / Sources/App/main.swift / العربية / 👩‍💻 / e\u{301}"
        let logicalScalars = logicalString.unicodeScalars.map(\.value)

        for role in TextDirectionRole.allCases {
            let expectedDirection: NSWritingDirection = role == .naturalProse ? .rightToLeft : .leftToRight

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.baseWritingDirection = .rightToLeft
            TextDirectionPolicy.apply(role, to: paragraphStyle)
            XCTAssertEqual(paragraphStyle.baseWritingDirection, expectedDirection)

            let textView = NSTextView(frame: .zero)
            textView.string = logicalString
            textView.baseWritingDirection = .rightToLeft
            TextDirectionPolicy.apply(role, to: textView)

            XCTAssertEqual(textView.baseWritingDirection, expectedDirection)
            XCTAssertEqual(textView.string, logicalString)
            XCTAssertEqual(textView.string.unicodeScalars.map(\.value), logicalScalars)
        }
    }
}

@MainActor
final class CodeBlockDirectionTests: XCTestCase {
    private let code = "שלום = 42\nlet x = 7\nprint(x)"

    func testPlainPreviewAnchorsMixedDirectionLinesAtLeftInRTL() throws {
        try assertLeftAnchored(CodeBlock(content: code), lineCount: 3)
    }

    func testCollapsiblePreviewAnchorsCollapsedAndExpandedLinesAtLeftInRTL() throws {
        for expanded in [false, true] {
            let preview = CollapsibleCodeBlock(content: code, previewLineCount: 2, expansion: .constant(expanded))
            try assertLeftAnchored(preview, lineCount: expanded ? 3 : 2)
        }
    }

    private func assertLeftAnchored(_ preview: some View, lineCount: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        // The preview background reads AppKit's appearance during rendering.
        _ = NSApplication.shared
        let leftToRight = try codeLineBounds(preview, direction: .leftToRight)
        let rightToLeft = try codeLineBounds(preview, direction: .rightToLeft)

        XCTAssertEqual(leftToRight.count, lineCount, file: file, line: line)
        XCTAssertEqual(rightToLeft.count, lineCount, file: file, line: line)
        let firstLTRLine = try XCTUnwrap(leftToRight.first, file: file, line: line)
        let firstRTLLine = try XCTUnwrap(rightToLeft.first, file: file, line: line)
        XCTAssertGreaterThanOrEqual(firstRTLLine.minY - firstLTRLine.minY, 24, "RTL copy button needs space above the code", file: file, line: line)
        for (reference, actual) in zip(leftToRight, rightToLeft) {
            XCTAssertLessThan(actual.minX, 24, "Code should start near the physical left edge", file: file, line: line)
            XCTAssertEqual(actual.minX, reference.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(actual.width, reference.width, accuracy: 1, file: file, line: line)
        }
    }

    private func codeLineBounds(_ preview: some View, direction: LayoutDirection) throws -> [CGRect] {
        let renderer = ImageRenderer(
            content: preview
                .foregroundColor(.red)
                .frame(width: 300)
                .environment(\.layoutDirection, direction)
        )
        renderer.scale = 1
        let bitmap = try NSBitmapImageRep(cgImage: XCTUnwrap(renderer.cgImage))

        // Mask the copy button's padded 32-point corner because it can inherit the ink color.
        // The first code line extends past that corner even if the RTL clearance regresses.
        let copyButtonSize = 32
        let copyButtonX = direction == .rightToLeft ? 0 : bitmap.pixelsWide - copyButtonSize
        let copyButtonColumns = copyButtonX ..< (copyButtonX + copyButtonSize)

        // Group consecutive rows of code ink so each line is checked independently.
        var lines: [CGRect] = []
        var currentLine = CGRect.null
        for y in 0 ..< bitmap.pixelsHigh {
            var row = CGRect.null
            for x in 0 ..< bitmap.pixelsWide {
                guard y >= copyButtonSize || !copyButtonColumns.contains(x),
                      let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.redComponent > 0.6, pixel.greenComponent < 0.4
                else { continue }
                row = row.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
            if row.isNull, !currentLine.isNull {
                lines.append(currentLine)
                currentLine = .null
            } else {
                currentLine = currentLine.union(row)
            }
        }
        if !currentLine.isNull {
            lines.append(currentLine)
        }
        return lines
    }
}
