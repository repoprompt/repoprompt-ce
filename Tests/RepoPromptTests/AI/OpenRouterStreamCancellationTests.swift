import Foundation
@testable import RepoPrompt
import SwiftOpenAI
import XCTest

final class OpenRouterStreamCancellationTests: XCTestCase {
    func testDownstreamCancellationCancelsOnlyItsUpstreamBridge() async throws {
        let provider = OpenRouterProvider(apiKey: "test-credential")
        let firstUpstreamTerminated = expectation(description: "first upstream terminated")
        let secondUpstreamTerminated = expectation(description: "second upstream terminated")
        let secondTermination = LockedFlag()
        let firstChunkReceived = expectation(description: "first downstream received a chunk")
        let secondChunkReceived = expectation(description: "second downstream remained active")

        var firstContinuation: AsyncThrowingStream<ChatCompletionChunkObject, Error>.Continuation!
        let firstUpstream = AsyncThrowingStream<ChatCompletionChunkObject, Error> { continuation in
            firstContinuation = continuation
            continuation.onTermination = { _ in firstUpstreamTerminated.fulfill() }
        }
        var secondContinuation: AsyncThrowingStream<ChatCompletionChunkObject, Error>.Continuation!
        let secondUpstream = AsyncThrowingStream<ChatCompletionChunkObject, Error> { continuation in
            secondContinuation = continuation
            continuation.onTermination = { _ in
                secondTermination.set()
                secondUpstreamTerminated.fulfill()
            }
        }

        let firstTask = Task {
            for try await result in provider.bridgeStream(firstUpstream) where result.text == "first" {
                firstChunkReceived.fulfill()
            }
        }
        let secondTask = Task {
            for try await result in provider.bridgeStream(secondUpstream) where result.text == "second" {
                secondChunkReceived.fulfill()
            }
        }

        try firstContinuation.yield(chunk(content: "first"))
        await fulfillment(of: [firstChunkReceived], timeout: 1)

        firstTask.cancel()
        await fulfillment(of: [firstUpstreamTerminated], timeout: 1)
        XCTAssertFalse(secondTermination.value)

        try secondContinuation.yield(chunk(content: "second"))
        await fulfillment(of: [secondChunkReceived], timeout: 1)
        secondContinuation.finish()
        await fulfillment(of: [secondUpstreamTerminated], timeout: 1)

        _ = await firstTask.result
        _ = await secondTask.result
    }

    private func chunk(content: String) throws -> ChatCompletionChunkObject {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "chunk",
            "object": "chat.completion.chunk",
            "choices": [
                [
                    "index": 0,
                    "delta": ["content": content]
                ]
            ]
        ])
        return try JSONDecoder().decode(ChatCompletionChunkObject.self, from: data)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}
