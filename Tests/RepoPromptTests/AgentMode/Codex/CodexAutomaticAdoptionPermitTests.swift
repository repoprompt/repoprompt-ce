import Darwin
@testable import RepoPromptApp
import XCTest

final class CodexAutomaticAdoptionPermitTests: XCTestCase {
    func testPermitIsBoundToExactDestinationTokenAndIdentity() throws {
        let grant = CodexAccountAdoptionGrant(adoptionID: UUID(), selectionID: UUID(), revision: 2, expiresAt: Date().addingTimeInterval(60), accountID: "fixture-b", email: "b@example.invalid", plan: "pro", accessToken: "synthetic-b")
        let permit = try CodexAutomaticAdoptionPermit(
            id: UUID(),
            controlEpoch: 1,
            manualGeneration: 0,
            beginStartedAt: DispatchTime.now().uptimeNanoseconds,
            ttlMilliseconds: 5000,
            destination: .init(grant: grant)
        )
        XCTAssertTrue(permit.authorizesLogin(["type": "chatgptAuthTokens", "chatgptAccountId": "fixture-b", "accessToken": "synthetic-b"]))
        XCTAssertFalse(permit.authorizesLogin(["type": "chatgptAuthTokens", "chatgptAccountId": "fixture-a", "accessToken": "synthetic-b"]))
        XCTAssertFalse(permit.authorizesLogin(["type": "chatgptAuthTokens", "chatgptAccountId": "fixture-b", "accessToken": "synthetic-other"]))
        XCTAssertEqual(Mirror(reflecting: permit).children.count, 0)
    }

    func testDelayedBeginCannotArmAfterPauseOrManualGenerationChange() throws {
        let epoch = CodexAutomaticAdoptionEpoch()
        XCTAssertTrue(epoch.update(epoch: 2, enabled: true, cancelled: []))
        XCTAssertTrue(epoch.update(epoch: 3, enabled: false, cancelled: []))
        XCTAssertFalse(epoch.update(epoch: 2, enabled: true, cancelled: []))
        let delayed = try epoch.arm(id: UUID(), epoch: 2, manualGeneration: 0, beginStartedAt: DispatchTime.now().uptimeNanoseconds, ttlMilliseconds: 5000)
        XCTAssertThrowsError(try delayed.publishChunk(offset: 0, count: 1, isFinal: true) {})
        XCTAssertEqual(delayed.snapshot.publication, .none)
        epoch.finish(delayed)
        XCTAssertTrue(epoch.update(epoch: 4, enabled: true, cancelled: []))
        epoch.manualChanged(generation: 1)
        let staleManual = try epoch.arm(id: UUID(), epoch: 4, manualGeneration: 0, beginStartedAt: DispatchTime.now().uptimeNanoseconds, ttlMilliseconds: 5000)
        XCTAssertThrowsError(try staleManual.publishChunk(offset: 0, count: 1, isFinal: true) {})
    }

    func testCancellationForUntrackedPermitOnlyFencesItsLaterExactResponse() throws {
        let epoch = CodexAutomaticAdoptionEpoch()
        let id = UUID()
        epoch.update(epoch: 2, enabled: true, cancelled: [id])
        let delayed = try epoch.arm(id: id, epoch: 2, manualGeneration: 0, beginStartedAt: DispatchTime.now().uptimeNanoseconds, ttlMilliseconds: 5000)
        XCTAssertTrue(delayed.snapshot.fenced)
        XCTAssertThrowsError(try delayed.publishChunk(offset: 0, count: 1, isFinal: true) {})
        epoch.finish(delayed)
        XCTAssertThrowsError(try epoch.arm(id: id, epoch: 2, manualGeneration: 0, beginStartedAt: DispatchTime.now().uptimeNanoseconds, ttlMilliseconds: 5000))
    }

    func testAutomaticPrefixFenceKeepsBaseValidAndPreventsFinalNewline() throws {
        let pipe = Pipe()
        let base = CodexAccountAdoptionAuthorization()
        let permit = try makePermit()
        let frame = Data(repeating: 0x61, count: 8192) + Data([0x0A])
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.writeAuthorizedFrame(
            frame,
            descriptor: pipe.fileHandleForWriting.fileDescriptor,
            authorization: base,
            automaticPermit: permit,
            didPublishChunk: { _ in permit.fence() }
        )) {
            XCTAssertEqual(($0 as? FDWriteError)?.errnoValue, ECANCELED)
        }
        XCTAssertNoThrow(try base.withAuthorization {})
        XCTAssertEqual(permit.snapshot.publication, .prefix)
        try pipe.fileHandleForWriting.close()
        let prefix = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertFalse(prefix.contains(0x0A))
        XCTAssertEqual(prefix.count, permit.snapshot.bytesWritten)
    }

    func testPauseBeforePublicationDoesNotRevokeBaseConsent() throws {
        let permit = try makePermit()
        let base = CodexAccountAdoptionAuthorization()
        permit.fence()
        var wrote = false
        XCTAssertThrowsError(try base.withAuthorization {
            try permit.publishChunk(offset: 0, count: 1, isFinal: true) { wrote = true }
        })
        XCTAssertFalse(wrote)
        XCTAssertNoThrow(try base.withAuthorization {})
        XCTAssertEqual(permit.snapshot.publication, .none)
    }

    func testBeginLatencyConsumesPermitAndRejectsPublication() throws {
        let permit = try CodexAutomaticAdoptionPermit(id: UUID(), controlEpoch: 2, manualGeneration: 0, beginStartedAt: 0, ttlMilliseconds: 1)
        XCTAssertThrowsError(try permit.publishChunk(offset: 0, count: 1, isFinal: true) { XCTFail("Expired permit published") })
    }

    func testPrefixAndCompleteProgressAreAtomicAndPermitIsOneShot() throws {
        let permit = try makePermit()
        try permit.publishChunk(offset: 0, count: 3, isFinal: false) {}
        XCTAssertEqual(permit.snapshot.publication, .prefix)
        XCTAssertEqual(permit.snapshot.bytesWritten, 3)
        try permit.publishChunk(offset: 3, count: 1, isFinal: true) {}
        XCTAssertEqual(permit.fence(), .init(publication: .complete, bytesWritten: 4, fenced: true))
        XCTAssertThrowsError(try permit.publishChunk(offset: 0, count: 1, isFinal: true) {})
    }

    func testFailedAtomicSyscallDoesNotAdvanceReceipt() throws {
        let permit = try makePermit()
        XCTAssertThrowsError(try permit.publishChunk(offset: 0, count: 3, isFinal: false) { throw FDWriteError.system(errno: EAGAIN) })
        XCTAssertEqual(permit.snapshot.bytesWritten, 0)
        try permit.publishChunk(offset: 0, count: 3, isFinal: false) {}
        XCTAssertThrowsError(try permit.publishChunk(offset: 0, count: 1, isFinal: true) {})
    }

    func testFenceCannotObserveZeroBytesWhileFinalSyscallIsInFlight() throws {
        let permit = try makePermit()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "publication completed")
        DispatchQueue.global().async {
            do {
                try permit.publishChunk(offset: 0, count: 1, isFinal: true) {
                    entered.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 1), .success)
                }
            } catch { XCTFail("Unexpected refusal") }
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let fenced = expectation(description: "fence observed completion")
        DispatchQueue.global().async {
            let receipt = permit.fence()
            XCTAssertEqual(receipt.publication, .complete)
            fenced.fulfill()
        }
        release.signal()
        wait(for: [finished, fenced], timeout: 2)
    }

    private func makePermit() throws -> CodexAutomaticAdoptionPermit {
        try .init(id: UUID(), controlEpoch: 2, manualGeneration: 0, beginStartedAt: DispatchTime.now().uptimeNanoseconds, ttlMilliseconds: 5000)
    }
}
