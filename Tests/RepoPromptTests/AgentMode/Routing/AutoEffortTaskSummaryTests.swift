@testable import RepoPromptApp
import XCTest

final class AutoEffortTaskSummaryTests: XCTestCase {
    func testMasksCommonSecretsAndIdentifiersWithoutSendingCode() {
        let text = """
        Debug the login regression for me@example.com at https://example.com/private?token=abc.
        password=hunter2 Bearer abc.def.ghi.123456789 /Users/alice/private/client.swift
        ```swift
        let customerRecord = "private customer data"
        ```
        """

        let summary = AutoEffortTaskSummary.make(from: text)
        XCTAssertNotNil(summary)
        for secret in ["me@example.com", "example.com", "hunter2", "abc.def.ghi", "alice", "customerRecord"] {
            XCTAssertFalse(summary?.contains(secret) == true, "Leaked \(secret)")
        }
        XCTAssertTrue(summary?.contains("Debug the login regression") == true)
    }

    func testMasksQuotedAndPrefixedAssignments() {
        let text = """
        Investigate login: {"password": "customer secret", "token": "abc123"}
        DB_PASSWORD=veryprivate GITHUB_TOKEN: anotherprivate
        """
        let summary = AutoEffortTaskSummary.make(from: text)
        for secret in ["customer secret", "abc123", "veryprivate", "anotherprivate"] {
            XCTAssertFalse(summary?.contains(secret) == true, "Leaked \(secret)")
        }
        XCTAssertTrue(summary?.contains("Investigate login") == true)
    }

    func testMasksCommonCredentialShapesAndQuotedPaths() {
        let stripeToken = "sk_live_" + "1234567890"
        let text = """
        Check postgres://admin:s3cret@localhost:5432/db and abcdefghij.klmnopqrst.uvwxyzabcd.
        password is hunter2 Stripe \(stripeToken) GitLab glpat-1234567890
        npm_1234567890 hf_1234567890 at "/Users/alice/project.swift" or (/root/private.txt).
        """
        let summary = AutoEffortTaskSummary.make(from: text)
        XCTAssertNotNil(summary)
        for secret in [
            "s3cret", "abcdefghij", "hunter2", stripeToken,
            "glpat-1234567890", "npm_1234567890", "hf_1234567890",
            "alice", "/root/private.txt"
        ] {
            XCTAssertFalse(summary?.contains(secret) == true, "Leaked \(secret)")
        }
        XCTAssertTrue(summary?.contains("Check") == true)
    }

    func testRejectsOversizedOrCodeOnlyInput() {
        let pemBegin = "-----BEGIN " + "PRIVATE KEY-----"
        XCTAssertNil(AutoEffortTaskSummary.make(from: String(repeating: "a", count: 4001)))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "```\nsecret\n```"))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "~~~swift\nsecret\n~~~"))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "Debug this:\n```\nsecret"))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "Debug this:\n~~~\nsecret"))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "Debug this:\n\(pemBegin)\nsecret"))
        XCTAssertNil(AutoEffortTaskSummary.make(from: "[code omitted] [code omitted]"))
    }

    func testRejectsUnmatchedSecondPEMEnvelopeAndMasksCompleteOne() {
        let x509Begin = "-----BEGIN X509 " + "PRIVATE KEY-----"
        let x509End = "-----END X509 " + "PRIVATE KEY-----"
        let pemBegin = "-----BEGIN " + "PRIVATE KEY-----"
        let complete = "\(x509Begin)\nsecret\n\(x509End)"
        XCTAssertNil(AutoEffortTaskSummary.make(from: "Review this:\n\(complete)\n\(pemBegin)\nleak"))
        let summary = AutoEffortTaskSummary.make(from: "Review this:\n\(complete)")
        XCTAssertFalse(summary?.contains("secret") == true)
        XCTAssertTrue(summary?.contains("Review this") == true)
    }

    func testPreservesOrdinaryBasicProseAndBoundsExcerpt() {
        XCTAssertEqual(AutoEffortTaskSummary.make(from: "Add basic validation"), "Add basic validation")
        let longText = "Review the architecture. " + String(repeating: "ordinary work ", count: 100)
        XCTAssertEqual(AutoEffortTaskSummary.make(from: longText)?.count, 1200)
    }

    func testDoesNotClaimToAnonymizeOrdinaryProse() {
        XCTAssertEqual(AutoEffortTaskSummary.make(from: "Review the checkout race"), "Review the checkout race")
    }
}
