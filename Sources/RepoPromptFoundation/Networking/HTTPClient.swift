import Foundation

package struct HTTPResponse {
    package let data: Data
    package let http: HTTPURLResponse
}

package protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse)
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

    package func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (bytes: bytes, http: http)
    }

    private static func makeConfiguration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return config
    }
}
