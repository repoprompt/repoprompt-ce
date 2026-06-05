import Darwin
@testable import RepoPrompt
import RepoPromptCore
import XCTest

final class MCPAppProxyAcceptedTransportLeaseTests: XCTestCase {
    private final class TransportRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: (any MCPAppProxyAcceptedTransport)?

        func record(_ transport: any MCPAppProxyAcceptedTransport) {
            lock.lock()
            self.transport = transport
            lock.unlock()
        }

        var hasTransport: Bool {
            lock.lock()
            defer { lock.unlock() }
            return transport != nil
        }
    }

    func testLeaseTransitionsFromListenerOwnershipThroughTransferAndOneTimeClaim() throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let lease = MacOSBootstrapAcceptedTransportLease(fileDescriptor: descriptors[0])
        XCTAssertEqual(lease.state, .listenerOwned)
        XCTAssertTrue(lease.reserveForAdmission())
        XCTAssertEqual(lease.state, .admissionReserved)

        let published = TransportRecorder()
        XCTAssertTrue(lease.transfer { transport in
            published.record(transport)
            return true
        })
        XCTAssertEqual(lease.state, .transferred)
        XCTAssertTrue(published.hasTransport)
        XCTAssertEqual(lease.claimConnectedFileDescriptor(), descriptors[0])
        XCTAssertNil(lease.claimConnectedFileDescriptor())

        Self.closeIfOpen(descriptors[0])
    }

    func testRollbackClosesReservedTransportExactlyOnce() throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let lease = MacOSBootstrapAcceptedTransportLease(fileDescriptor: descriptors[0])
        XCTAssertTrue(lease.reserveForAdmission())
        lease.rollback()
        lease.rollback()

        XCTAssertEqual(lease.state, .closed)
        XCTAssertTrue(Self.isClosed(descriptors[0]))
        XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
    }

    func testFailedPublicationClosesTransferredTransport() throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let lease = MacOSBootstrapAcceptedTransportLease(fileDescriptor: descriptors[0])
        XCTAssertTrue(lease.reserveForAdmission())
        XCTAssertFalse(lease.transfer { _ in false })

        XCTAssertEqual(lease.state, .closed)
        XCTAssertTrue(Self.isClosed(descriptors[0]))
        XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
    }

    func testReentrantCloseDuringPublicationDoesNotDeadlockAndRollsBack() throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let lease = MacOSBootstrapAcceptedTransportLease(fileDescriptor: descriptors[0])
        XCTAssertTrue(lease.reserveForAdmission())
        XCTAssertFalse(lease.transfer { transport in
            transport.close()
            return true
        })

        XCTAssertEqual(lease.state, .closed)
        XCTAssertTrue(Self.isClosed(descriptors[0]))
        XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))
    }

    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptors
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0, fcntl(fd, F_GETFD) >= 0 else { return }
        Darwin.close(fd)
    }

    private static func isClosed(_ fd: Int32) -> Bool {
        errno = 0
        return fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    private static func peerObservedEOF(on fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        guard Darwin.poll(&descriptor, 1, 2000) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) == 0
    }
}
