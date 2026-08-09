import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class DomainInteractionAppSeamTests: XCTestCase {
    func testPresentationCoordinatorCancelsExactlyOnceAcrossConcurrentAndLateRegistration() async {
        let coordinator = MCPAskUserPresentationCoordinator()
        let requestID = UUID()
        let counter = AppSeamCounter()
        let registered = await coordinator.register(requestID: requestID) {
            await counter.increment()
        }
        XCTAssertTrue(registered)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    await coordinator.cancel(requestID: requestID)
                }
            }
        }
        let concurrentCancellationCount = await counter.value()
        let repeatedCancellation = await coordinator.cancel(requestID: requestID)
        XCTAssertEqual(concurrentCancellationCount, 1)
        XCTAssertFalse(repeatedCancellation)

        let cancelledBeforeRegistration = UUID()
        let preRegistrationCancellation = await coordinator.cancel(
            requestID: cancelledBeforeRegistration
        )
        XCTAssertFalse(preRegistrationCancellation)
        let lateCounter = AppSeamCounter()
        let acceptedLateRegistration = await coordinator.register(
            requestID: cancelledBeforeRegistration
        ) {
            await lateCounter.increment()
        }
        let lateCancellationCount = await lateCounter.value()
        XCTAssertFalse(acceptedLateRegistration)
        XCTAssertEqual(lateCancellationCount, 1)
    }

    func testElicitationBridgePreservesStructuredAskUserResponseShape() throws {
        let payload: [String: Value] = [
            "title": .string("Choose"),
            "context": .string("Need a decision"),
            "questions": .array([
                .object([
                    "id": .string("mode"),
                    "question": .string("Which mode?"),
                    "options": .array([.string("Fast"), .string("Safe")]),
                    "allows_custom": .bool(false)
                ]),
                .object([
                    "id": .string("notes"),
                    "question": .string("Any notes?"),
                    "allows_custom": .bool(true)
                ])
            ])
        ]
        let questions = try MCPAskUserElicitationBridge.questions(from: payload)
        let schema = MCPAskUserElicitationBridge.schema(from: payload, questions: questions)
        XCTAssertNil(schema.required)
        XCTAssertEqual(schema.properties["mode"]?.objectValue?["type"], .string("string"))

        let value = MCPAskUserElicitationBridge.response(
            questions: questions,
            content: ["mode": .string("Safe"), "notes": .string("Keep logs")],
            elapsedSeconds: 3,
            includeLegacyResponse: false
        )
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["timed_out"], .bool(false))
        XCTAssertEqual(object["skipped"], .bool(false))
        XCTAssertEqual(object["elapsed_seconds"], .int(3))
        let answers = try XCTUnwrap(object["answers"]?.objectValue)
        XCTAssertEqual(
            answers["mode"]?.objectValue?["selected_options"],
            .array([.string("Safe")])
        )
        XCTAssertEqual(
            answers["notes"]?.objectValue?["custom_response"],
            .string("Keep logs")
        )
    }

    func testPresentationCoordinatorBoundsTombstonesAndLateCancelDoesNotRegrowEarlyState() async {
        let coordinator = MCPAskUserPresentationCoordinator()
        for _ in 0 ..< 300 {
            _ = await coordinator.cancel(requestID: UUID())
        }
        let bounded = await coordinator.test_tombstoneCounts()
        XCTAssertEqual(bounded.early, 256)
        XCTAssertEqual(bounded.completed, 0)

        let completedID = UUID()
        let registered = await coordinator.register(requestID: completedID) {}
        XCTAssertTrue(registered)
        await coordinator.unregister(requestID: completedID)
        let beforeLateCancel = await coordinator.test_tombstoneCounts()
        let lateCancellation = await coordinator.cancel(requestID: completedID)
        let afterLateCancel = await coordinator.test_tombstoneCounts()
        XCTAssertFalse(lateCancellation)
        XCTAssertEqual(afterLateCancel.early, beforeLateCancel.early)
        XCTAssertEqual(afterLateCancel.completed, beforeLateCancel.completed)
    }

    func testElicitationBridgeUsesCanonicalValidationAndAllowsPerQuestionSkip() throws {
        let duplicateQuestions: [String: Value] = [
            "questions": .array([
                .object(["id": .string("same"), "question": .string("First?")]),
                .object(["id": .string("same"), "question": .string("Second?")])
            ])
        ]
        XCTAssertThrowsError(
            try MCPAskUserElicitationBridge.questions(from: duplicateQuestions)
        )

        let valid: [String: Value] = [
            "questions": .array([
                .object(["id": .string("optional"), "question": .string("Answer?")])
            ])
        ]
        let questions = try MCPAskUserElicitationBridge.questions(from: valid)
        XCTAssertNil(MCPAskUserElicitationBridge.schema(from: valid, questions: questions).required)
    }

    func testChildLaunchEnvironmentUsesOnlyCurrentCarrierAndStripsStaleAuthority() {
        let carrier = DomainChildLaunchCarrier(
            runID: UUID(),
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [
                DomainChildLaunchCarrier.endpointEnvironmentKey: "private://endpoint",
                DomainChildLaunchCarrier.launchTokenEnvironmentKey: "one-shot-token"
            ]
        )
        let inherited = [
            "PATH": "/bin",
            DomainChildLaunchCarrier.launchTokenEnvironmentKey: "stale-token",
            DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey: "stale-envelope"
        ]
        let carried = DomainChildLaunchContext.$current.withValue(carrier) {
            DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: inherited)
        }
        XCTAssertEqual(carried["PATH"], "/bin")
        XCTAssertEqual(carried[DomainChildLaunchCarrier.endpointEnvironmentKey], "private://endpoint")
        XCTAssertEqual(carried[DomainChildLaunchCarrier.launchTokenEnvironmentKey], "one-shot-token")
        XCTAssertNil(carried[DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey])

        let stripped = DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: inherited)
        XCTAssertEqual(stripped, ["PATH": "/bin"])
    }

    func testCodexPreparedRuntimeMergesOnlyTheCarrierPresentAtFinalLaunchBoundary() {
        let baseEnvironment = [
            "PATH": "/bin",
            DomainChildLaunchCarrier.launchTokenEnvironmentKey: "cached-stale-token"
        ]
        let carrier = DomainChildLaunchCarrier(
            runID: UUID(),
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [
                DomainChildLaunchCarrier.endpointEnvironmentKey: "private://final",
                DomainChildLaunchCarrier.launchTokenEnvironmentKey: "final-token"
            ]
        )
        let carried = DomainChildLaunchContext.$current.withValue(carrier) {
            CodexAppServerClient.testProcessEnvironmentForCurrentLaunch(
                baseEnvironment: baseEnvironment
            )
        }
        XCTAssertEqual(carried["PATH"], "/bin")
        XCTAssertEqual(
            carried[DomainChildLaunchCarrier.endpointEnvironmentKey],
            "private://final"
        )
        XCTAssertEqual(
            carried[DomainChildLaunchCarrier.launchTokenEnvironmentKey],
            "final-token"
        )

        let uncarried = CodexAppServerClient.testProcessEnvironmentForCurrentLaunch(
            baseEnvironment: baseEnvironment
        )
        XCTAssertEqual(uncarried, ["PATH": "/bin"])
    }
}

private actor AppSeamCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
