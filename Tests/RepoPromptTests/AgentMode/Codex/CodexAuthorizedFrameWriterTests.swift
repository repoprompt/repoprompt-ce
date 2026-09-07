import Darwin
@testable import RepoPromptApp
import XCTest

final class CodexAuthorizedFrameWriterTests: XCTestCase {
    func testRevocationAfterPrefixNeverPublishesNewlineAndRestoresFlags() throws {
        let pipe = try configuredPipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        let authority = CodexAccountAdoptionAuthorization()
        let frame = Data(repeating: 0x61, count: 16384) + Data([0x0A])
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.writeAuthorizedFrame(
            frame, descriptor: descriptor, authorization: authority,
            didPublishChunk: { _ in authority.invalidate() }
        )) { XCTAssertEqual(($0 as? FDWriteError)?.errnoValue, ECANCELED) }
        XCTAssertEqual(fcntl(descriptor, F_GETFL), flags)
        try pipe.fileHandleForWriting.close()
        let prefix = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertGreaterThan(prefix.count, 0)
        XCTAssertLessThan(prefix.count, frame.count)
        XCTAssertFalse(prefix.contains(0x0A))
    }

    func testStalledReaderHasMonotonicBoundedDeadline() throws {
        let pipe = try configuredPipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        try fill(pipe)
        let flags = fcntl(descriptor, F_GETFL)
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.writeAuthorizedFrame(
            Data([0x0A]), descriptor: descriptor, authorization: .init(), timeout: 0.05
        )) { XCTAssertEqual(($0 as? FDWriteError)?.errnoValue, ETIMEDOUT) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(elapsed, 0.05)
        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(fcntl(descriptor, F_GETFL), flags)
    }

    func testStalledReaderDoesNotHoldRevocationLock() throws {
        let pipe = try configuredPipe()
        try fill(pipe)
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let authority = CodexAccountAdoptionAuthorization()
        let attempted = DispatchSemaphore(value: 0)
        let completed = expectation(description: "stalled writer observes revocation")
        DispatchQueue.global().async {
            do {
                try CodexManagedHTTPPolicy.writeAuthorizedFrame(
                    Data([0x0A]), descriptor: descriptor, authorization: authority, timeout: 1,
                    writeChunk: { fd, chunk in
                        attempted.signal()
                        try CodexManagedHTTPPolicy.writeAtomicChunk(chunk, descriptor: fd)
                    }
                )
                XCTFail("Stalled writer ignored revocation")
            } catch { XCTAssertEqual(error as? CodexAccountAdoptionReason, .revoked) }
            completed.fulfill()
        }
        XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
        let start = DispatchTime.now().uptimeNanoseconds
        authority.invalidate()
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.25)
        wait(for: [completed], timeout: 2)
    }

    func testInterruptedWriteRetriesAndBrokenPipeRefusesSafely() throws {
        let pipe = try configuredPipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let frame = Data("synthetic\n".utf8)
        var interrupted = false
        try CodexManagedHTTPPolicy.writeAuthorizedFrame(frame, descriptor: descriptor, authorization: .init(), writeChunk: { fd, chunk in
            if !interrupted {
                interrupted = true
                throw FDWriteError.system(errno: EINTR)
            }
            try CodexManagedHTTPPolicy.writeAtomicChunk(chunk, descriptor: fd)
        })
        XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: frame.count), frame)
        XCTAssertTrue(FDWriteSupport.configureNoSigPipe(fd: descriptor))
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.writeAuthorizedFrame(
            frame, descriptor: descriptor, authorization: .init()
        )) { XCTAssertEqual(($0 as? FDWriteError)?.errnoValue, EPIPE) }
    }

    private func configuredPipe() throws -> Pipe {
        let pipe = Pipe()
        // Match ProcessLauncher native stdin setup before taking an exact
        // descriptor-flags baseline; SIGPIPE protection is not a writer change.
        XCTAssertTrue(FDWriteSupport.configureNoSigPipe(fd: pipe.fileHandleForWriting.fileDescriptor))
        // Darwin adds sticky FWASWRITTEN on the first write; F_SETFL cannot
        // restore it. Native stdin has already carried initialize before any
        // managed frame, so prime/drain likewise before exact flag snapshots.
        try CodexManagedHTTPPolicy.writeAtomicChunk(Data([0]), descriptor: pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: 1), Data([0]))
        return pipe
    }

    private func fill(_ pipe: Pipe) throws {
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let bytes = [UInt8](repeating: 0x61, count: 512)
        try CodexManagedHTTPPolicy.withNonblockingPipeWrite(descriptor: descriptor) {
            while true {
                let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written < 0 {
                    XCTAssertEqual(errno, EAGAIN)
                    return
                }
                XCTAssertEqual(written, bytes.count)
            }
        }
    }
}
