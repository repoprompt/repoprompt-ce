import Foundation
import XCTest

enum TestScaleGate {
    static let environmentKey = "RPCE_RUN_SCALE_TESTS"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func requireEnabled(_ description: String) throws {
        try XCTSkipUnless(isEnabled, "\(description). Set \(environmentKey)=1.")
    }
}
