import Foundation

protocol OpenAIDecisionsHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, HTTPURLResponse)
}

enum OpenAIDecisionsRoutingClientError: Error, Equatable {
    case cancelled
    case timeout
    case transport
    case responseTooLarge
    case invalidResponse
    case invalidRequest
    case authentication
    case policyUnavailable
    case rateLimited
    case overloaded
}

struct OpenAIDecisionsRoutingClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    static let requestDeadline: Duration = .seconds(5)
    static let maximumResponseBytes = 64 * 1024

    private let transport: any OpenAIDecisionsHTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        transport: any OpenAIDecisionsHTTPTransport = OpenAIDecisionsURLSessionTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.sleep = sleep
    }

    func decide(
        _ wireRequest: OpenAIDecisionsWireRequest,
        apiKey: String,
        timeout: Duration = Self.requestDeadline
    ) async throws -> OpenAIDecisionsWireResponse {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.001, timeout.secondsValue)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(wireRequest) }
        catch { throw OpenAIDecisionsRoutingClientError.invalidRequest }

        let result: (Data, HTTPURLResponse)
        do {
            result = try await OpenAIDecisionsOwnedFirstResult<(Data, HTTPURLResponse)>().run([
                { try await transport.send(request, maximumBodyBytes: Self.maximumResponseBytes) },
                {
                    try await sleep(timeout)
                    throw OpenAIDecisionsRoutingClientError.timeout
                }
            ])
        } catch is CancellationError {
            throw OpenAIDecisionsRoutingClientError.cancelled
        } catch let error as OpenAIDecisionsRoutingClientError {
            throw error
        } catch {
            throw OpenAIDecisionsRoutingClientError.transport
        }

        guard result.1.url?.scheme == "https",
              result.1.url?.host == Self.endpoint.host,
              result.1.url?.path == Self.endpoint.path
        else {
            throw OpenAIDecisionsRoutingClientError.invalidResponse
        }
        guard (200 ..< 300).contains(result.1.statusCode) else {
            throw Self.mapError(status: result.1.statusCode, body: result.0)
        }
        do { return try JSONDecoder().decode(OpenAIDecisionsWireResponse.self, from: result.0) }
        catch { throw OpenAIDecisionsRoutingClientError.invalidResponse }
    }

    private static func mapError(status: Int, body: Data) -> OpenAIDecisionsRoutingClientError {
        let error = try? JSONDecoder().decode(OpenAIDecisionsWireError.self, from: body).error
        let code = error?.code
        switch status {
        case 400:
            return .invalidRequest
        case 401:
            // The shared guide lists non-credential 401 causes too. Without a verified code
            // discriminator, do not let a status-only mapping invalidate a stored key.
            return .policyUnavailable
        case 403:
            return .policyUnavailable
        case 429:
            switch code {
            case "slow_down" where error?.type == "rate_limit_error": return .rateLimited
            case "credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded": return .policyUnavailable
            default: return .transport
            }
        case 500:
            return .overloaded
        case 503 where error?.type == "service_unavailable_error" && code == "server_is_overloaded":
            return .overloaded
        default:
            return .transport
        }
    }
}

/// URLSession delegate receives decoded body chunks and stops at cap + 1. Redirects are refused.
final class OpenAIDecisionsURLSessionTransport: OpenAIDecisionsHTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let operation = OpenAIDecisionsURLSessionOperation(
            request: request,
            maximumBodyBytes: maximumBodyBytes,
            configuration: configuration
        )
        return try await operation.run()
    }
}

private final class OpenAIDecisionsURLSessionOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let maximumBodyBytes: Int
    private let configuration: URLSessionConfiguration
    private var body = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var settled = false

    init(request: URLRequest, maximumBodyBytes: Int, configuration: URLSessionConfiguration) {
        self.request = request
        self.maximumBodyBytes = maximumBodyBytes
        self.configuration = configuration
    }

    func run() async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                // Cancellation can settle before this continuation is installed.
                guard !settled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.lock()
                let alreadySettled = settled
                if !alreadySettled {
                    self.session = session
                    self.task = task
                }
                lock.unlock()
                if alreadySettled {
                    task.cancel()
                    session.invalidateAndCancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancelTask: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(OpenAIDecisionsRoutingClientError.invalidResponse), cancelTask: true)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= maximumBodyBytes else {
            finish(.failure(OpenAIDecisionsRoutingClientError.responseTooLarge), cancelTask: true)
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(OpenAIDecisionsRoutingClientError.invalidResponse), cancelTask: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error), cancelTask: false)
        } else if let response {
            finish(.success((body, response)), cancelTask: false)
        } else {
            finish(.failure(OpenAIDecisionsRoutingClientError.invalidResponse), cancelTask: false)
        }
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>, cancelTask: Bool) {
        lock.lock()
        guard !settled else { lock.unlock()
            return
        }
        settled = true
        let continuation = continuation
        self.continuation = nil
        let task = task
        let session = session
        self.task = nil
        self.session = nil
        lock.unlock()
        if cancelTask { task?.cancel() }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

/// Logical first-result settlement is independent of a cancellation-ignoring injected transport.
private final class OpenAIDecisionsOwnedFirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func run(_ operations: [@Sendable () async throws -> Value]) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let tasks = operations.map { operation in
                    Task {
                        do { try await self.settle(.success(operation())) }
                        catch { self.settle(.failure(error)) }
                    }
                }
                lock.lock()
                if result != nil { lock.unlock()
                    tasks.forEach { $0.cancel() }
                } else { self.tasks = tasks
                    lock.unlock()
                }
            }
        } onCancel: {
            self.settle(.failure(CancellationError()))
        }
    }

    private func settle(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock()
            return
        }
        self.result = result
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
        let value = components
        return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
