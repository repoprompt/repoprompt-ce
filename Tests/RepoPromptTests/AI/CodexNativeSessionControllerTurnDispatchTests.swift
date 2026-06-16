import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class CodexNativeSessionControllerTurnDispatchTests: XCTestCase {
    func testTurnStartReturnsProvisionalReceiptWithoutInstallingActiveIdentity() async throws {
        let recorder = TurnRequestRecorder(result: [
            "turn": ["id": "submission-1"]
        ])
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(threadID: "thread-1")

        let receipt = try await controller.startUserTurn(
            text: "hello",
            images: [],
            model: "gpt-test",
            reasoningEffort: "high",
            serviceTier: "fast"
        )

        XCTAssertEqual(receipt.provisionalSubmissionID, "submission-1")
        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "turn/start")
        XCTAssertEqual(request.params["threadId"] as? String, "thread-1")
        XCTAssertEqual(request.params["model"] as? String, "gpt-test")
        XCTAssertEqual(request.params["effort"] as? String, "high")
        XCTAssertEqual(request.params["serviceTier"] as? String, "fast")
        XCTAssertNotNil(request.params["approvalPolicy"])
        XCTAssertNotNil(request.params["approvalsReviewer"])
        XCTAssertNotNil(request.params["sandboxPolicy"])
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
        XCTAssertNil(controller.test_routingCurrentTurnID)
    }

    func testTurnSteerUsesExactExpectedIDAndOmitsStartOnlySettings() async throws {
        let recorder = TurnRequestRecorder(result: [
            "turnId": "turn-1"
        ])
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )

        let receipt = try await controller.steerUserTurn(
            text: "adjust course",
            images: [],
            expectedTurnID: "turn-1"
        )

        XCTAssertEqual(receipt.acceptedTurnID, "turn-1")
        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "turn/steer")
        XCTAssertEqual(Set(request.params.keys), Set(["threadId", "input", "expectedTurnId"]))
        XCTAssertEqual(request.params["threadId"] as? String, "thread-1")
        XCTAssertEqual(request.params["expectedTurnId"] as? String, "turn-1")
        XCTAssertNil(request.params["model"])
        XCTAssertNil(request.params["effort"])
        XCTAssertNil(request.params["serviceTier"])
        XCTAssertNil(request.params["cwd"])
        XCTAssertNil(request.params["approvalPolicy"])
        XCTAssertNil(request.params["approvalsReviewer"])
        XCTAssertNil(request.params["sandboxPolicy"])
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn-1")
    }

    func testTurnSteerAcceptedMismatchReturnsAcceptedReceiptWithoutResend() async throws {
        let recorder = TurnRequestRecorder(result: [
            "turnId": "turn-2"
        ])
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )

        let receipt = try await controller.steerUserTurn(
            text: "adjust course",
            images: [],
            expectedTurnID: "turn-1"
        )

        XCTAssertEqual(receipt.acceptedTurnID, "turn-2")
        XCTAssertEqual(recorder.requests().count, 1)
    }

    func testStructuredSteerErrorsMapWithoutLosingJSONRPCPayload() async throws {
        let cases: [(failure: CodexAppServerClient.RequestFailure, assertion: (Error) -> Void)] = [
            (
                CodexAppServerClient.RequestFailure(
                    method: "turn/steer",
                    code: -32602,
                    message: "future no-active wording",
                    data: .object(["type": .string("noActiveTurn")])
                ),
                { error in
                    guard case let CodexTurnSteerError.noActiveTurn(failure) = error else {
                        return XCTFail("Expected no-active error, got \(error)")
                    }
                    XCTAssertEqual(failure.code, -32602)
                    XCTAssertEqual(failure.data, .object(["type": .string("noActiveTurn")]))
                }
            ),
            (
                CodexAppServerClient.RequestFailure(
                    method: "turn/steer",
                    code: -32602,
                    message: "future mismatch wording",
                    data: .object(["actualTurnId": .string("turn-2")])
                ),
                { error in
                    guard case let CodexTurnSteerError.expectedTurnMismatch(expected, actual, failure) = error else {
                        return XCTFail("Expected mismatch error, got \(error)")
                    }
                    XCTAssertEqual(expected, "turn-1")
                    XCTAssertEqual(actual, "turn-2")
                    XCTAssertEqual(failure.code, -32602)
                }
            ),
            (
                CodexAppServerClient.RequestFailure(
                    method: "turn/steer",
                    code: -32602,
                    message: "cannot steer a review turn",
                    data: .object([
                        "codexErrorInfo": .object([
                            "activeTurnNotSteerable": .object([
                                "turnKind": .string("review")
                            ])
                        ])
                    ])
                ),
                { error in
                    guard case let CodexTurnSteerError.activeTurnNotSteerable(turnKind, failure) = error else {
                        return XCTFail("Expected non-steerable error, got \(error)")
                    }
                    XCTAssertEqual(turnKind, "review")
                    XCTAssertEqual(failure.code, -32602)
                }
            )
        ]

        for testCase in cases {
            let recorder = TurnRequestRecorder(error: CodexAppServerClient.ClientError.requestFailed(testCase.failure))
            let controller = makeController(recorder: recorder)
            controller.test_installThreadState(
                threadID: "thread-1",
                authoritativeTurnID: "turn-1",
                routingTurnID: "turn-1"
            )
            do {
                _ = try await controller.steerUserTurn(
                    text: "hello",
                    images: [],
                    expectedTurnID: "turn-1"
                )
                XCTFail("Expected steer error")
            } catch {
                testCase.assertion(error)
            }
            XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn-1")
        }
    }

    func testStrictMessageFallbackMapsCurrentMismatchShapeWithoutPromotingActualID() async throws {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "expected active turn id `turn-1` but found `turn-2`",
            data: nil
        )
        let recorder = TurnRequestRecorder(error: CodexAppServerClient.ClientError.requestFailed(failure))
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )

        do {
            _ = try await controller.steerUserTurn(
                text: "hello",
                images: [],
                expectedTurnID: "turn-1"
            )
            XCTFail("Expected mismatch error")
        } catch let CodexTurnSteerError.expectedTurnMismatch(expected, actual, retainedFailure) {
            XCTAssertEqual(expected, "turn-1")
            XCTAssertEqual(actual, "turn-2")
            XCTAssertEqual(retainedFailure, failure)
        }

        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn-1")
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-1")
    }

    func testInterruptRequiresSameAuthoritativeLifecycleIdentity() async throws {
        let recorder = TurnRequestRecorder(result: [:])
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-2"
        )

        do {
            _ = try await controller.interruptUserTurn(expectedTurnID: "turn-2")
            XCTFail("Expected reconciliation failure")
        } catch let error as CodexTurnInterruptError {
            XCTAssertEqual(
                error,
                .reconciliationFailed(
                    expectedTurnID: "turn-2",
                    authoritativeTurnID: "turn-1"
                )
            )
        }
        XCTAssertTrue(recorder.requests().isEmpty)

        let receipt = try await controller.interruptUserTurn(expectedTurnID: "turn-1")
        XCTAssertEqual(receipt.interruptedTurnID, "turn-1")
        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "turn/interrupt")
        XCTAssertEqual(request.params["turnId"] as? String, "turn-1")
    }

    func testCancellationReconciliationInterruptsUniqueSnapshotTurnWithoutPromotingIt() async throws {
        let recorder = TurnRequestRecorder(resultsByMethod: [
            "thread/read": [
                "thread": [
                    "id": "thread-1",
                    "status": ["type": "active"],
                    "turns": [
                        ["id": "turn-snapshot", "status": "inProgress"]
                    ]
                ]
            ],
            "turn/interrupt": [:]
        ])
        let controller = makeController(recorder: recorder)
        controller.test_installThreadState(threadID: "thread-1")

        let receipt = try await controller.reconcileAndInterruptCurrentTurn()

        XCTAssertEqual(receipt.interruptedTurnID, "turn-snapshot")
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
        XCTAssertEqual(recorder.requests().map(\.method), ["thread/read", "turn/interrupt"])
        XCTAssertEqual(recorder.requests().last?.params["turnId"] as? String, "turn-snapshot")
    }

    func testJSONRPCFailureParserPreservesMethodCodeMessageAndData() {
        let failure = CodexAppServerClient.requestFailure(
            method: "turn/steer",
            errorObject: [
                "code": -32602,
                "message": "cannot steer",
                "data": [
                    "actualTurnId": "turn-2",
                    "retryable": false
                ]
            ]
        )

        XCTAssertEqual(
            failure,
            CodexAppServerClient.RequestFailure(
                method: "turn/steer",
                code: -32602,
                message: "cannot steer",
                data: .object([
                    "actualTurnId": .string("turn-2"),
                    "retryable": .bool(false)
                ])
            )
        )
    }

    private func makeController(recorder: TurnRequestRecorder) -> CodexNativeSessionController {
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

private final class TurnRequestRecorder: @unchecked Sendable {
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

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
