import Foundation

#if DEBUG
    /// Opt-in, task-scoped instrumentation of the real presentation decoder. See
    /// docs/testing.md#workspace-projection-decode-diagnostics for the headless diagnostic entry point.
    /// No payloads, errors, paths, hashes, or user identities enter this recorder.
    enum WorkspaceProjectionDecodeDiagnostics {
        static let normalizationVersion = 1

        struct Context {
            let recorder: Recorder
            let contentOrdinal: Int
            let consumerOrdinal: Int
            let revision: UInt64
            let schemaVersion: Int
            /// Set only by a caller that owns a synchronous MainActor measurement scope.
            let onMainActor: Bool
        }

        struct Sample: Codable {
            let contentOrdinal: Int
            let consumerOrdinal: Int
            let revision: UInt64
            let schemaVersion: Int
            let normalizationVersion: Int
            let inputBytes: Int
            let succeeded: Bool
            let wallNanoseconds: UInt64
            let mainActorNanoseconds: UInt64?
            let normalizationCount: Int
            let normalizationMutationCount: Int
            let normalizationNanoseconds: UInt64
        }

        struct Snapshot {
            let samples: [Sample]
            let droppedCount: Int
        }

        /// The lock protects all mutable state, including when a scope is inherited by a task.
        final class Recorder: @unchecked Sendable {
            static let maximumSamples = 128
            private let lock = NSLock()
            private var samples: [Sample] = []
            private var droppedCount = 0

            fileprivate func append(_ sample: Sample) {
                lock.withLock {
                    guard samples.count < Self.maximumSamples else {
                        if droppedCount < Int.max { droppedCount += 1 }
                        return
                    }
                    samples.append(sample)
                }
            }

            func snapshot() -> Snapshot {
                lock.withLock { Snapshot(samples: samples, droppedCount: droppedCount) }
            }
        }

        private final class Attempt: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            private var mutations = 0
            private var nanoseconds: UInt64 = 0

            func normalized(start: UInt64, mutated: Bool) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                lock.withLock {
                    count += 1
                    mutations += mutated ? 1 : 0
                    nanoseconds += elapsed
                }
            }

            func snapshot() -> (count: Int, mutations: Int, nanoseconds: UInt64) {
                lock.withLock { (count, mutations, nanoseconds) }
            }
        }

        struct NormalizationInterval {
            fileprivate let finishBody: (Bool) -> Void

            func finish(mutated: Bool) {
                finishBody(mutated)
            }
        }

        @TaskLocal static var context: Context?
        @TaskLocal private static var attempt: Attempt?

        static func beginNormalization() -> NormalizationInterval? {
            guard let attempt else { return nil }
            let start = DispatchTime.now().uptimeNanoseconds
            return NormalizationInterval { attempt.normalized(start: start, mutated: $0) }
        }

        static func measure<T>(inputBytes: Int, operation: () throws -> T) rethrows -> T {
            guard let context else { return try operation() }
            let attempt = Attempt()
            let start = DispatchTime.now().uptimeNanoseconds
            var succeeded = false
            defer {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                let normalization = attempt.snapshot()
                context.recorder.append(Sample(
                    contentOrdinal: context.contentOrdinal,
                    consumerOrdinal: context.consumerOrdinal,
                    revision: context.revision,
                    schemaVersion: context.schemaVersion,
                    normalizationVersion: normalizationVersion,
                    inputBytes: inputBytes,
                    succeeded: succeeded,
                    wallNanoseconds: elapsed,
                    mainActorNanoseconds: context.onMainActor ? elapsed : nil,
                    normalizationCount: normalization.count,
                    normalizationMutationCount: normalization.mutations,
                    normalizationNanoseconds: normalization.nanoseconds
                ))
            }
            return try $attempt.withValue(attempt) {
                let result = try operation()
                succeeded = true
                return result
            }
        }
    }
#endif
