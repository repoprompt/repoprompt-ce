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
