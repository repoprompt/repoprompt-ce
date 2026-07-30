import RepoPromptRegexCore
import XCTest

final class PCRE2JITTests: XCTestCase {
    func testJITEnvironmentValueMapping() {
        for value in ["0", "false", "OFF", " no ", "disable", "disabled"] {
            XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode(from: value), .disabled)
        }
        for value in ["require", " REQUIRED "] {
            XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode(from: value), .required)
        }

        XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode(from: nil), .auto)
        XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode(from: ""), .auto)
        XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode(from: "unknown"), .auto)
    }

    func testJITDisabledAutoAndRequiredOutcomes() throws {
        let disabled = try PCRE2Regex(#"^value$"#, jit: .disabled)
        XCTAssertEqual(disabled.jitStatus, .disabled)

        let automatic = try PCRE2Regex(#"^value$"#, jit: .auto)
        switch automatic.jitStatus {
        case .compiled, .unavailable, .fallback:
            break
        case .disabled:
            XCTFail("Automatic JIT resolution must attempt construction")
        }

        do {
            let required = try PCRE2Regex(#"^value$"#, jit: .required)
            guard case .compiled = required.jitStatus else {
                return XCTFail("Required JIT succeeded without compiled code")
            }
        } catch let error as PCRE2Error {
            guard case .jitRequiredButUnavailable = error else {
                return XCTFail("Unexpected required-JIT failure: \(error)")
            }
            XCTAssertFalse(PCRE2BuildConfiguration.isJITSupported)
        }
    }
}
