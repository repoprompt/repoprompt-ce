import RepoPromptApp
import XCTest

final class CodexPermissionValueCompatibilityTests: XCTestCase {
    func testRequestEncodingKeepsBothSupportedWireStyles() {
        XCTAssertEqual(CodexApprovalPolicy.allCases.map { $0.appServerRequestValue(style: .configStyle) }, ["on-request", "untrusted", "never"])
        XCTAssertEqual(CodexApprovalPolicy.allCases.map { $0.appServerRequestValue(style: .camelCase) }, ["onRequest", "unlessTrusted", "never"])
        XCTAssertEqual(CodexSandboxMode.allCases.map { $0.appServerRequestValue(style: .configStyle) }, ["read-only", "workspace-write", "danger-full-access"])
        XCTAssertEqual(CodexSandboxMode.allCases.map { $0.appServerRequestValue(style: .camelCase) }, ["readOnly", "workspaceWrite", "dangerFullAccess"])
        XCTAssertEqual(CodexApprovalReviewer.allCases.map(\.appServerRequestValue), ["user", "auto_review"])
    }

    func testLegacyPermissionSpellingsKeepPersistedMeaningAndRejectUnknownValues() {
        for value in ["onRequest", "on-request", "onFailure", "on-failure"] {
            XCTAssertEqual(CodexApprovalPolicy(storedValue: value)?.persistedValue, "on-request", value)
        }
        for value in ["unlessTrusted", "unless-trusted", "untrusted"] {
            XCTAssertEqual(CodexApprovalPolicy(storedValue: value)?.persistedValue, "unless-trusted", value)
        }
        for value in ["autoReview", "auto-review", "auto_review", "guardian_subagent", "guardianSubagent", " AUTO-REVIEW "] {
            XCTAssertEqual(CodexApprovalReviewer(storedValue: value)?.persistedValue, "auto-review", value)
        }
        let sandboxRows = [
            ("readOnly", "read-only"), ("read-only", "read-only"),
            ("workspaceWrite", "workspace-write"), ("workspace-write", "workspace-write"),
            ("dangerFullAccess", "danger-full-access"), ("danger-full-access", "danger-full-access")
        ]
        for (legacy, persisted) in sandboxRows {
            XCTAssertEqual(CodexSandboxMode(storedValue: legacy)?.persistedValue, persisted, legacy)
        }
        XCTAssertNil(CodexApprovalPolicy(storedValue: "future-policy"))
        XCTAssertNil(CodexSandboxMode(storedValue: "future-sandbox"))
        XCTAssertNil(CodexApprovalReviewer(storedValue: "future-reviewer"))
        XCTAssertEqual(CodexApprovalPolicy.allCases.map(\.displayName), ["On Request", "Unless Trusted", "Never"])
        XCTAssertEqual(CodexSandboxMode.allCases.map(\.displayName), ["Read Only", "Workspace Write", "Danger Full Access"])
        XCTAssertEqual(CodexApprovalReviewer.allCases.map(\.displayName), ["User", "Auto Review"])
    }
}
