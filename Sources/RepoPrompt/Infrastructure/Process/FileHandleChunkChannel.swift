import Foundation

// SEARCH-HELPER: FileHandleChunkChannel, AsyncStream, chunk ordering, readabilityHandler, backpressure
/// Provides an ordered, single-consumer async stream of `Data` chunks from a `FileHandle`.
///
/// The `readabilityHandler` on `FileHandle` fires on an arbitrary dispatch queue. Wrapping
/// each callback in a standalone `Task` can reorder chunks because actor task scheduling is
/// not guaranteed FIFO. This channel instead feeds chunks into an `AsyncStream.Continuation`
/// protected by `os_unfair_lock`, preserving the order in which the OS delivers data.
///
/// A single consumer task iterates `stream` to process chunks in the exact order they arrived.
///
/// Related:
/// - Producer:  ClaudeNativeProcessSessionController.startStdoutReader / startStderrReader
/// - Consumer:  ClaudeNativeProcessSessionController.handleStdoutChunk / handleStderrChunk
/// - Tests:     RepoPromptTests/Process/ProcessCoreTests.swift
final class FileHandleChunkChannel: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var lock = os_unfair_lock()

    init(bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy = .unbounded) {
        var captured: AsyncStream<Data>.Continuation?
        stream = AsyncStream<Data>(bufferingPolicy: bufferingPolicy) { continuation in
            captured = continuation
        }
        guard let captured else {
            fatalError("FileHandleChunkChannel: failed to capture AsyncStream continuation")
        }
        continuation = captured
    }

    /// Enqueue a data chunk. Safe to call from any thread (including `readabilityHandler` dispatch queues).
    func yield(_ data: Data) {
        os_unfair_lock_lock(&lock)
        _ = continuation.yield(data)
        os_unfair_lock_unlock(&lock)
    }

    /// Signal that no more chunks will be produced (e.g. EOF or shutdown).
    func finish() {
        os_unfair_lock_lock(&lock)
        continuation.finish()
        os_unfair_lock_unlock(&lock)
    }
}
