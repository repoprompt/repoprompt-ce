@testable import RepoPromptApp
import XCTest

final class TokenCalculationServiceByteEstimateTests: XCTestCase {
    func testTextAndByteCountOverloadsMatchForEmptyASCIIAndMultibyteText() {
        let samples = [
            "",
            "RepoPrompt",
            String(repeating: "a", count: 4097),
            "Grüße 👋🏽 from RepoPrompt"
        ]

        for text in samples {
            XCTAssertEqual(
                TokenCalculationService.estimateTokens(for: text),
                TokenCalculationService.estimateTokens(utf8ByteCount: text.utf8.count),
                "Mismatch for \(text.utf8.count) UTF-8 bytes"
            )
        }
    }

    func testByteCountOverloadPreservesCanonicalArithmetic() {
        let byteCounts = [0, 1, 3, 4, 5, 127, 1024, 10000, 10_000_001]

        for byteCount in byteCounts {
            XCTAssertEqual(
                TokenCalculationService.estimateTokens(utf8ByteCount: byteCount),
                Int((Double(byteCount) / 4.0) * 1.05)
            )
        }
    }
}
