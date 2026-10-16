import Foundation

protocol JevHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct JevURLSessionTransport: JevHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JevRoutingClientError.invalidResponse }
        return (data, response)
    }
}

struct JevModelList: Decodable, Equatable {
    struct Model: Decodable, Equatable { let name: String }
    let models: [Model]
}

struct JevRoutingWireRequest: Encodable, Equatable {
    struct Question: Encodable, Equatable {
        let type: String
        let instructions: String
        let criteria: [String: String]
    }

    let model: String
    let state: String
    let questions: [String: Question]
}

struct JevRoutingWireResponse: Decodable, Equatable {
    struct Answer: Decodable, Equatable {
        let type: String
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct Usage: Decodable, Equatable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let model: String
    let answers: [String: Answer]
    let usage: Usage
}

enum JevRoutingClientError: Error, Equatable {
    case invalidResponse
    case authentication
    case invalidRequest
    case rateLimited
    case overloaded
    case timeout
    case service(statusCode: Int)
    case decoding
}

protocol JevRoutingClientProtocol: Sendable {
    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList
    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) async throws -> JevRoutingWireResponse
}

struct JevRoutingClient: JevRoutingClientProtocol {
    static let baseURL = URL(string: "https://api.typesafe.ai")!
    static let outerDeadline: Duration = .seconds(5)

    private let transport: any JevHTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        transport: any JevHTTPTransport = JevURLSessionTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.sleep = sleep
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func listModels(apiKey: String, timeout: Duration = Self.outerDeadline) async throws -> JevModelList {
        let request = try makeRequest(path: "/v1/models", method: "GET", apiKey: apiKey, body: nil, timeout: timeout)
        return try await perform(request, timeout: timeout, as: JevModelList.self)
    }

    func judge(
        request wireRequest: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration = Self.outerDeadline
    ) async throws -> JevRoutingWireResponse {
        let body = try encoder.encode(wireRequest)
        let request = try makeRequest(path: "/v1/systemone", method: "POST", apiKey: apiKey, body: body, timeout: timeout)
        return try await perform(request, timeout: timeout, as: JevRoutingWireResponse.self)
    }

    private func makeRequest(
        path: String,
        method: String,
        apiKey: String,
        body: Data?,
        timeout: Duration
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw JevRoutingClientError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = max(0.001, timeout.secondsValue)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func perform<T: Decodable>(
        _ request: URLRequest,
        timeout: Duration,
        as type: T.Type
    ) async throws -> T {
        let result = try await JevOwnedFirstResult<JevTransportResult>().run([
            {
                let (data, response) = try await transport.data(for: request)
                return JevTransportResult(data: data, response: response)
            },
            {
                try await sleep(timeout)
                throw JevRoutingClientError.timeout
            }
        ])
        switch result.response.statusCode {
        case 200 ..< 300:
            do { return try decoder.decode(type, from: result.data) }
            catch { throw JevRoutingClientError.decoding }
        case 401, 403: throw JevRoutingClientError.authentication
        case 422: throw JevRoutingClientError.invalidRequest
        case 429: throw JevRoutingClientError.rateLimited
        case 529: throw JevRoutingClientError.overloaded
        default: throw JevRoutingClientError.service(statusCode: result.response.statusCode)
        }
    }
}

private struct JevTransportResult {
    let data: Data
    let response: HTTPURLResponse
}

/// Settles the awaiting caller on the first result without structurally waiting for a
/// cancellation-ignoring loser. Losers remain owned, receive cancellation, and cannot publish late.
final class JevOwnedFirstResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settledResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func run(
        _ operations: [@Sendable () async throws -> Value]
    ) async throws -> Value {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let started = operations.map { operation in
                    Task { [weak self] in
                        do { try await self?.settle(.success(operation())) }
                        catch { self?.settle(.failure(error)) }
                    }
                }
                install(started)
            }
        }, onCancel: {
            self.settle(.failure(CancellationError()))
        })
    }

    private func install(_ newContinuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let settledResult {
            lock.unlock()
            newContinuation.resume(with: settledResult)
            return false
        }
        continuation = newContinuation
        lock.unlock()
        return true
    }

    private func install(_ newTasks: [Task<Void, Never>]) {
        lock.lock()
        if settledResult != nil {
            lock.unlock()
            newTasks.forEach { $0.cancel() }
            return
        }
        tasks = newTasks
        lock.unlock()
    }

    private func settle(_ result: Result<Value, Error>) {
        lock.lock()
        guard settledResult == nil else {
            lock.unlock()
            return
        }
        settledResult = result
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

private extension Duration {
    var secondsValue: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
