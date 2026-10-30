#if canImport(FoundationNetworking)
    import Foundation
    import FoundationNetworking
    @testable import RepoPromptFoundation
    import XCTest

    final class LinuxHTTPByteStreamTests: XCTestCase {
        func testStreamingPreservesByteOrderAndResponseHeaders() async throws {
            let request = request("ordered")
            let response = try await client().bytes(for: request)
            XCTAssertEqual(response.http.statusCode, 200)
            XCTAssertEqual(response.http.value(forHTTPHeaderField: "X-Fixture"), "stream")
            var result = Data()
            for try await byte in response.bytes {
                result.append(byte)
            }
            XCTAssertEqual(result, LinuxHTTPFixtureProtocol.orderedChunks.reduce(into: Data()) { $0.append($1) })
        }

        func testCancellationBeforeHeadersStopsTheUnderlyingRequest() async throws {
            let request = request("waiting")
            let requestURL = try XCTUnwrap(request.url)
            let observed = LinuxHTTPFixtureProtocol.observe(requestURL)
            defer { LinuxHTTPFixtureProtocol.removeObservation(requestURL) }
            let client = client()
            let task = Task { try await client.bytes(for: request) }
            await fulfillment(of: [observed.started], timeout: 5)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("A cancelled request must not return a streaming response")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            await fulfillment(of: [observed.stopped], timeout: 5)
        }

        func testUnconsumedResponseFailsExplicitlyAtTheBufferLimit() async throws {
            let request = request("overflow")
            let requestURL = try XCTUnwrap(request.url)
            let observed = LinuxHTTPFixtureProtocol.observe(requestURL)
            defer { LinuxHTTPFixtureProtocol.removeObservation(requestURL) }
            let response = try await client().bytes(for: request)
            await fulfillment(of: [observed.stopped], timeout: 5)
            guard observed.didStop else { throw URLError(.timedOut) }
            var count = 0
            do {
                for try await _ in response.bytes {
                    count += 1
                }
                XCTFail("A truncated response must fail rather than return successful partial data")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
            }
            XCTAssertEqual(count, LinuxHTTPByteStream.maximumBufferedBytes)
        }

        func testDroppingUnconsumedResponseStopsTheUnderlyingRequest() async throws {
            let request = request("headers-only")
            let requestURL = try XCTUnwrap(request.url)
            let observed = LinuxHTTPFixtureProtocol.observe(requestURL)
            defer { LinuxHTTPFixtureProtocol.removeObservation(requestURL) }
            _ = try await client().bytes(for: request)
            await fulfillment(of: [observed.stopped], timeout: 5)
        }

        private func request(_ scenario: String) -> URLRequest {
            URLRequest(url: URL(string: "https://repoprompt-http-fixture.invalid/\(scenario)/\(UUID().uuidString)")!)
        }

        private func client() -> DefaultHTTPClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LinuxHTTPFixtureProtocol.self]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            return DefaultHTTPClient(configuration: configuration)
        }
    }

    private final class LinuxHTTPFixtureObservation: @unchecked Sendable {
        let started = XCTestExpectation(description: "HTTP request started")
        let stopped = XCTestExpectation(description: "HTTP request cancelled")
        private let lock = NSLock()
        private var stoppedValue = false

        var didStop: Bool {
            lock.withLock { stoppedValue }
        }

        func stop() {
            let first = lock.withLock {
                defer { stoppedValue = true }
                return !stoppedValue
            }
            if first { stopped.fulfill() }
        }
    }

    private final class LinuxHTTPFixtureProtocol: URLProtocol {
        static let orderedChunks = [Data("first:猫".utf8), Data([0, 255, 10]), Data("last".utf8)]
        private static let lock = NSLock()
        private static var observations: [URL: LinuxHTTPFixtureObservation] = [:]

        static func observe(_ url: URL) -> LinuxHTTPFixtureObservation {
            lock.withLock {
                let observation = LinuxHTTPFixtureObservation()
                observations[url] = observation
                return observation
            }
        }

        static func removeObservation(_ url: URL) {
            _ = lock.withLock { observations.removeValue(forKey: url) }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "repoprompt-http-fixture.invalid"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.lock.withLock { Self.observations[url] }?.started.fulfill()
            if url.path.hasPrefix("/waiting/") { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["X-Fixture": "stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if url.path.hasPrefix("/headers-only/") { return }
            if url.path.hasPrefix("/overflow/") {
                client?.urlProtocol(self, didLoad: Data(repeating: 65, count: LinuxHTTPByteStream.maximumBufferedBytes + 1))
            } else {
                for chunk in Self.orderedChunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {
            guard let url = request.url else { return }
            Self.lock.withLock { Self.observations[url] }?.stop()
        }
    }
#endif
