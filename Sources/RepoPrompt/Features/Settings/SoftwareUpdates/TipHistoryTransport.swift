import Foundation
import os

enum TipHistoryDownloadError: String, Error, Equatable {
    case network, sizeMismatch, digestMismatch, invalidSparkleSignature, extractionFailed
    case unexpectedArchiveLayout, bundleMismatch, codeSignatureInvalid, insufficientDiskSpace
    case accessDenied, archiveLimitExceeded, assessmentFailed, timeout, fileSystem, untrustedRedirect

    var permitsRetry: Bool {
        self == .network || self == .timeout
    }

    var message: String {
        switch self {
        case .network: "The download failed. Check your connection and try again."
        case .timeout: "The download or verification timed out."
        case .insufficientDiskSpace: "There is not enough free space in the selected destination."
        case .accessDenied: "Choose a writable download folder outside Applications and existing app bundles."
        case .assessmentFailed: "macOS could not confirm this app’s Gatekeeper assessment. No verified app was saved."
        case .fileSystem: "The verified download could not be saved."
        default: "This download failed verification and was deleted."
        }
    }
}

struct TipHistoryTransferFailure: Error {
    let reason: TipHistoryDownloadError
    var httpStatus: Int?
    var retryAfter: Date?

    init(_ reason: TipHistoryDownloadError, httpStatus: Int? = nil, retryAfter: Date? = nil) {
        self.reason = reason
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
    }
}

/// File-backed, credential-free transport for this feature only. The delegate
/// queue is serial; cancellation does not resume the caller until completion has
/// drained an in-flight file-copy callback, so cleanup cannot race a late write.
final class TipHistoryTransfer: NSObject, URLSessionDownloadDelegate {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var finished = false
        var fileReady = false
        var failure: TipHistoryTransferFailure?
        var lastProgress = Date.distantPast
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let destination: URL
    private let maximumBytes: Int64
    private let expectedBytes: Int64?
    private let allowsRedirect: @Sendable (URL) -> Bool
    private let progress: @Sendable (Int64) -> Void

    init(destination: URL, maximumBytes: Int64, expectedBytes: Int64?, allowsRedirect: @escaping @Sendable (URL) -> Bool, progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.expectedBytes = expectedBytes
        self.allowsRedirect = allowsRedirect
        self.progress = progress
    }

    func receive(_ url: URL, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) async throws {
        guard Self.isHTTPSWithoutCredentials(url), allowsRedirect(url) else { throw TipHistoryTransferFailure(.untrustedRedirect) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = resourceTimeout
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.httpShouldSetCookies = false
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
                request.httpShouldHandleCookies = false
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.downloadTask(with: request)
                let cancelled = state.withLock { value in
                    guard !value.cancelled else { return true }
                    value.continuation = continuation
                    value.session = session
                    value.task = task
                    return false
                }
                if cancelled {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.state.withLock { value in
                value.cancelled = true
                return value.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isHTTPSWithoutCredentials(url), allowsRedirect(url) else {
            state.withLock { $0.failure = TipHistoryTransferFailure(.untrustedRedirect) }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || (expectedBytes.map { totalBytesWritten > $0 } ?? false) {
            state.withLock { $0.failure = TipHistoryTransferFailure(.sizeMismatch) }
            downloadTask.cancel()
            return
        }
        let publish = state.withLock { value in
            guard !value.cancelled, value.failure == nil, Date().timeIntervalSince(value.lastProgress) >= 0.25 else { return false }
            value.lastProgress = Date()
            return true
        }
        if publish { progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !state.withLock({ $0.cancelled || $0.failure != nil }) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            state.withLock { $0.failure = TipHistoryTransferFailure(.network) }
            return
        }
        guard response.statusCode == 200 else {
            let failure = TipHistoryTransferFailure(.network, httpStatus: response.statusCode, retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
            state.withLock { $0.failure = failure }
            return
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let count = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard count >= 0, count <= maximumBytes, expectedBytes.map({ count == $0 }) ?? true else {
                throw TipHistoryTransferFailure(.sizeMismatch)
            }
            // The target is a new private staging path, never a final user item.
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw TipHistoryTransferFailure(.fileSystem) }
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock { $0.fileReady = true }
        } catch let failure as TipHistoryTransferFailure {
            state.withLock { $0.failure = failure }
        } catch {
            state.withLock { $0.failure = TipHistoryTransferFailure(.fileSystem) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = state.withLock { value -> (CheckedContinuation<Void, Error>?, Error?) in
            guard !value.finished else { return (nil, nil) }
            value.finished = true
            let continuation = value.continuation
            value.continuation = nil
            value.task = nil
            value.session = nil
            if value.cancelled { return (continuation, CancellationError()) }
            if let failure = value.failure { return (continuation, failure) }
            if let error {
                return (continuation, TipHistoryTransferFailure((error as? URLError)?.code == .timedOut ? .timeout : .network))
            }
            return (continuation, value.fileReady ? nil : TipHistoryTransferFailure(.network))
        }
        session.finishTasksAndInvalidate()
        if let failure = pending.1 { pending.0?.resume(throwing: failure) }
        else { pending.0?.resume() }
    }

    static func isHTTPSWithoutCredentials(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
    }

    static func allowsReleaseCDN(_ url: URL) -> Bool {
        isHTTPSWithoutCredentials(url) && url.host == "release-assets.githubusercontent.com" && url.fragment == nil
    }

    private static func retryAfter(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let interval = TimeInterval(value), interval.isFinite, interval >= 0 { return Date().addingTimeInterval(interval) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
