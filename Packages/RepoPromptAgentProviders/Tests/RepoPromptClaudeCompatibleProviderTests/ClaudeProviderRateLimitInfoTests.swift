import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeProviderRateLimitInfoTests: XCTestCase {
    func testAllowedEventPreservesUnknownUtilizationWithoutTranscriptNoise() throws {
        let data = Data(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","resetsAt":1900000000},"session_id":"not-an-account"}"#.utf8)
        let info = try XCTUnwrap(ClaudeProviderRateLimitInfo.decodeEvent(data))
        XCTAssertEqual(info.status, .allowed)
        XCTAssertEqual(info.rateLimitType, "five_hour")
        XCTAssertEqual(info.resetsAt, 1_900_000_000)
        XCTAssertNil(info.utilization)
        var translator = ClaudeSDKNDJSONTranslator()
        XCTAssertTrue(translator.parseNDJSONLine(data).isEmpty)
    }

    func testUtilizationIsOptionalFractionAndMalformedTypesFailClosed() throws {
        let info = try XCTUnwrap(ClaudeProviderRateLimitInfo.decodeEvent(Data(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.82}}"#.utf8)))
        XCTAssertEqual(info.utilization, 0.82)
        for invalid in [
            #"{"type":"assistant","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"new_status"}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","utilization":true}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":"tomorrow"}}"#
        ] {
            XCTAssertNil(ClaudeProviderRateLimitInfo.decodeEvent(Data(invalid.utf8)))
        }
    }
}
