import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

protocol ProviderCredentialHTTPTransport: Sendable {
    func statusCode(for request: URLRequest, timeout: Duration) async throws -> Int
}

private final class ProviderCredentialRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct URLSessionProviderCredentialHTTPTransport: ProviderCredentialHTTPTransport {
    private enum TransportError: Error {
        case invalidResponse
        case timedOut
    }

    func statusCode(for request: URLRequest, timeout: Duration) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(
            configuration: configuration,
            delegate: ProviderCredentialRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                let (_, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw TransportError.invalidResponse
                }
                return response.statusCode
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TransportError.invalidResponse
            }
            return result
        }
    }
}
