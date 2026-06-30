import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerConversationCleanupTests: XCTestCase {
    func testArchiveByConversationIDSendsThreadArchiveRequest() async {
        let recorder = CleanupRequestRecorder(result: [:])
        let controller = makeController(recorder: recorder)

        let outcome = await controller.cleanupConversation(
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "thread-123"
            ),
            action: .archive
        )

        XCTAssertEqual(outcome, .succeeded(message: "Archived Codex conversation."))
        XCTAssertEqual(recorder.requests().map(\.method), ["thread/archive"])
        XCTAssertEqual(recorder.requests().first?.params["threadId"] as? String, "thread-123")
    }

    func testArchiveByRolloutPathResolvesSummaryThenArchivesThread() async {
        let recorder = CleanupRequestRecorder(resultsByMethod: [
            "getConversationSummary": ["summary": ["conversationId": "thread-from-rollout"]],
            "thread/archive": [:]
        ])
        let controller = makeController(recorder: recorder)

        let outcome = await controller.cleanupConversation(
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                rolloutPath: "/tmp/codex-rollout.jsonl"
            ),
            action: .archive
        )

        XCTAssertEqual(outcome, .succeeded(message: "Archived Codex conversation."))
        let requests = recorder.requests()
        XCTAssertEqual(requests.map(\.method), ["getConversationSummary", "thread/archive"])
        XCTAssertEqual(requests.first?.params["rolloutPath"] as? String, "/tmp/codex-rollout.jsonl")
        XCTAssertEqual(requests.last?.params["threadId"] as? String, "thread-from-rollout")
    }

    func testDeleteIsUnsupportedAndDoesNotSendRequest() async {
        let recorder = CleanupRequestRecorder(result: [:])
        let controller = makeController(recorder: recorder)

        let outcome = await controller.cleanupConversation(
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "thread-123"
            ),
            action: .delete
        )

        XCTAssertEqual(
            outcome,
            .unsupported(message: "Codex app-server does not expose a delete conversation API; archive is supported.")
        )
        XCTAssertTrue(recorder.requests().isEmpty)
    }

    func testArchiveRequestFailureMapsToFailedOutcome() async {
        let recorder = CleanupRequestRecorder(error: CleanupTestError.rejected)
        let controller = makeController(recorder: recorder)

        let outcome = await controller.cleanupConversation(
            ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "thread-123"
            ),
            action: .archive
        )

        XCTAssertEqual(outcome.status, "failed")
        XCTAssertEqual(outcome.message, "cleanup rejected")
    }

    private func makeController(recorder: CleanupRequestRecorder) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            requestExecutor: { method, params, timeout in
                try recorder.handle(method: method, params: params, timeout: timeout)
            }
        )
    }
}

private enum CleanupTestError: Error, LocalizedError {
    case rejected

    var errorDescription: String? {
        "cleanup rejected"
    }
}

private final class CleanupRequestRecorder: @unchecked Sendable {
    struct Request {
        let method: String
        let params: [String: Any]
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private let result: [String: Any]
    private let resultsByMethod: [String: [String: Any]]?
    private let error: Error?

    init(result: [String: Any] = [:], error: Error? = nil) {
        self.result = result
        resultsByMethod = nil
        self.error = error
    }

    init(resultsByMethod: [String: [String: Any]]) {
        result = [:]
        self.resultsByMethod = resultsByMethod
        error = nil
    }

    func handle(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) throws -> [String: Any] {
        lock.lock()
        recordedRequests.append(Request(method: method, params: params ?? [:], timeout: timeout))
        let result = resultsByMethod?[method] ?? result
        let error = error
        lock.unlock()
        if let error {
            throw error
        }
        return result
    }

    func requests() -> [Request] {
        lock.lock()
        let requests = recordedRequests
        lock.unlock()
        return requests
    }
}
