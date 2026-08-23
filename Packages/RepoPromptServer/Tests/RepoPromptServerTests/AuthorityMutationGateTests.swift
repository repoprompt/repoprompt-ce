import RepoPromptRuntimeModel
@testable import RepoPromptServerHost
import XCTest

@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class AuthorityMutationGateTests: XCTestCase {
    func testDrainInvalidatesRetainedCapability() async throws {
        let gate = AuthorityMutationGate()
        let capability = await gate.capability()
        let admittedValue = try await capability.perform { 42 }
        XCTAssertEqual(admittedValue, 42)
        await gate.beginDraining()
        do {
            _ = try await capability.perform { 7 }
            XCTFail("stale capability unexpectedly mutated")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        }
        let snapshot = await gate.snapshot()
        XCTAssertFalse(snapshot.acceptingMutations)
        XCTAssertEqual(snapshot.inFlightMutations, 0)
    }

    func testDrainTimeoutRemainsStickyAfterAdmittedMutationCompletes() async throws {
        let gate = AuthorityMutationGate()
        let capability = await gate.capability()
        let mutation = Task {
            try await capability.perform {
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        while await gate.snapshot().inFlightMutations == 0 {
            await Task.yield()
        }
        let timedOut = await gate.drain(timeout: .milliseconds(10))
        XCTAssertTrue(timedOut.drainTimedOut)
        try await mutation.value
        let repeated = await gate.drain(timeout: .milliseconds(10))
        XCTAssertTrue(repeated.drainTimedOut)
        XCTAssertEqual(repeated.inFlightMutations, 0)
    }

    func testClosingInvalidatesReadAndMutationGenerations() async {
        let gate = AuthorityMutationGate()
        let read = await gate.readCapability()
        let subscription = await gate.readCapability(subscription: true)
        let before = await gate.snapshot()
        await gate.beginDraining()
        let drainedRead = try? await read.perform { 42 }
        XCTAssertEqual(drainedRead, 42)
        do {
            _ = try await subscription.perform { 1 }
            XCTFail("subscription unexpectedly survived drain admission closure")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .serviceDraining)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await gate.close()
        let after = await gate.snapshot()
        XCTAssertGreaterThan(after.mutationGeneration, before.mutationGeneration)
        XCTAssertGreaterThan(after.readGeneration, before.readGeneration)
        XCTAssertFalse(after.acceptingSubscriptions)
        XCTAssertFalse(after.acceptingReads)
        do {
            _ = try await read.perform { 7 }
            XCTFail("read capability unexpectedly survived close")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
