import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking

    package typealias HTTPBytes = AsyncThrowingStream<UInt8, Error>
#else
    package typealias HTTPBytes = URLSession.AsyncBytes
#endif

package struct HTTPResponse {
    package let data: Data
    package let http: HTTPURLResponse
}

package protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
    func bytes(for request: URLRequest) async throws -> (bytes: HTTPBytes, http: HTTPURLResponse)
}

package final class DefaultHTTPClient: HTTPClient, @unchecked Sendable {
    package static let uiCriticalClient = DefaultHTTPClient(configuration: DefaultHTTPClient.makeConfiguration(requestTimeout: 15, resourceTimeout: 30))
    package static let discoveryClient = DefaultHTTPClient(configuration: DefaultHTTPClient.makeConfiguration(requestTimeout: 15, resourceTimeout: 30))
    package static let aiClient = DefaultHTTPClient(configuration: DefaultHTTPClient.makeConfiguration(requestTimeout: 120, resourceTimeout: 120))
    package static let aiStreamingClient = DefaultHTTPClient(configuration: DefaultHTTPClient.makeConfiguration(requestTimeout: 120, resourceTimeout: 7200))

    private let session: URLSession

    package init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    package func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResponse(data: data, http: http)
    }

    package func bytes(for request: URLRequest) async throws -> (bytes: HTTPBytes, http: HTTPURLResponse) {
        #if canImport(FoundationNetworking)
            return try await LinuxHTTPByteStream.open(request: request, configuration: session.configuration)
        #else
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (bytes: bytes, http: http)
        #endif
    }

    private static func makeConfiguration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        #if !canImport(FoundationNetworking)
            config.waitsForConnectivity = false
        #endif
        return config
    }
}
