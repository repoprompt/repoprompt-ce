#if canImport(FoundationNetworking)
    import Foundation
    import FoundationNetworking

    final class LinuxHTTPByteStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        static let maximumBufferedBytes = 256 * 1024
        private let lock = NSLock()
        private let bytes: HTTPBytes
        private let byteContinuation: HTTPBytes.Continuation
        private var responseContinuation: CheckedContinuation<(bytes: HTTPBytes, http: HTTPURLResponse), Error>?
        private var task: URLSessionDataTask?
        private var cancelled = false

        override init() {
            let stream = HTTPBytes.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedBytes))
            bytes = stream.stream
            byteContinuation = stream.continuation
            super.init()
            byteContinuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
            }
        }

        static func open(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (bytes: HTTPBytes, http: HTTPURLResponse) {
            let owner = LinuxHTTPByteStream()
            return try await withTaskCancellationHandler {
                try await owner.start(request: request, configuration: configuration)
            } onCancel: {
                owner.cancel()
            }
        }

        private func start(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (bytes: HTTPBytes, http: HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDataTask? = lock.withLock {
                    guard !cancelled else { return nil }
                    responseContinuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request)
                    self.task = task
                    return task
                }
                if let task {
                    task.resume()
                } else {
                    continuation.resume(throwing: CancellationError())
                    byteContinuation.finish(throwing: CancellationError())
                }
            }
        }

        private func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let continuation = lock.withLock {
                defer { responseContinuation = nil }
                return responseContinuation
            }
            guard let http = response as? HTTPURLResponse else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                byteContinuation.finish(throwing: URLError(.badServerResponse))
                completionHandler(.cancel)
                session.invalidateAndCancel()
                return
            }
            continuation?.resume(returning: (bytes, http))
            completionHandler(.allow)
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
            for byte in data {
                switch byteContinuation.yield(byte) {
                case .enqueued:
                    continue
                case .dropped:
                    byteContinuation.finish(throwing: URLError(.dataLengthExceedsMaximum))
                    cancel()
                    return
                case .terminated:
                    cancel()
                    return
                @unknown default:
                    byteContinuation.finish(throwing: URLError(.unknown))
                    cancel()
                    return
                }
            }
        }

        func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = lock.withLock {
                defer {
                    responseContinuation = nil
                    task = nil
                }
                return responseContinuation
            }
            continuation?.resume(throwing: error ?? URLError(.badServerResponse))
            if let error {
                byteContinuation.finish(throwing: error)
            } else {
                byteContinuation.finish()
            }
            session.finishTasksAndInvalidate()
        }
    }
#endif
