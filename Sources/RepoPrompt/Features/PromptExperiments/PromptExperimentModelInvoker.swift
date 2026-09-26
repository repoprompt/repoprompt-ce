#if DEBUG
    import Foundation

    /// Provider retry policy for one logical model call (reflection, target execution, or judge).
    ///
    /// Only classified transient failures retry. Every invocation, including each retry,
    /// is its own model-call ledger entry; retries never consume an evaluation admission.
    struct PromptExperimentProviderRetryPolicy: Equatable {
        /// Additional invocations after the first (sealed `max_provider_retries`, 0...3).
        var maxRetries: Int
        var baseDelaySeconds: Double = 2
        var maxDelaySeconds: Double = 30
        /// Deadline for the whole logical call: all attempts plus backoff.
        var overallTimeoutSeconds: Double = 900

        /// Exponential backoff with ±50% jitter; `retry` is 1-based, `jitter` in [0, 1).
        func delaySeconds(beforeRetry retry: Int, jitter: Double) -> Double {
            let exponential = baseDelaySeconds * pow(2, Double(max(0, retry - 1)))
            return min(maxDelaySeconds, exponential) * (0.5 + min(max(jitter, 0), 1))
        }
    }

    /// Invokes a prompt-only model with retries and durable per-invocation evidence.
    @MainActor
    final class PromptExperimentModelInvoker {
        typealias RetryObserver = @MainActor (_ retry: Int, _ code: PromptExperimentProviderFailureCode, _ delaySeconds: Double) async -> Void

        private let completer: PromptExperimentModelCompleting
        private let policy: PromptExperimentProviderRetryPolicy
        private let checkpoint: PromptExperimentCheckpointSink
        private let callbackRootBase: URL
        private let backoffSleep: @Sendable (Double) async throws -> Void
        private let jitter: @Sendable () -> Double
        private let uptime: @Sendable () -> TimeInterval

        init(
            completer: PromptExperimentModelCompleting,
            policy: PromptExperimentProviderRetryPolicy,
            checkpoint: @escaping PromptExperimentCheckpointSink,
            callbackRootBase: URL,
            backoffSleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
            jitter: @escaping @Sendable () -> Double = { Double.random(in: 0 ..< 1) },
            uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.completer = completer
            self.policy = policy
            self.checkpoint = checkpoint
            self.callbackRootBase = callbackRootBase
            self.backoffSleep = backoffSleep
            self.jitter = jitter
            self.uptime = uptime
        }

        func invoke(
            target: PromptExperimentResolvedTarget,
            role: String,
            systemPrompt: String,
            userPrompt: String,
            onRetry: RetryObserver? = nil
        ) async throws -> PromptExperimentConnectedModelCompletion {
            let deadline = uptime() + policy.overallTimeoutSeconds
            var retries = 0
            while true {
                try Task.checkCancellation()
                let remaining = deadline - uptime()
                guard remaining > 0 else { throw PromptExperimentProviderFailure(code: .timedOut) }
                let invocationID = UUID()
                try await checkpoint(.modelCall(.init(
                    id: invocationID, target: target, role: role, state: .started,
                    promptTokens: nil, completionTokens: nil
                )))
                do {
                    let completion = try await completeWithDeadline(
                        target: target,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        remainingSeconds: remaining
                    )
                    try await checkpoint(.modelCall(.init(
                        id: invocationID, target: target, role: role, state: .completed,
                        promptTokens: completion.promptTokens, completionTokens: completion.completionTokens
                    )))
                    return completion
                } catch is CancellationError {
                    // Settlement writes are accepted after cancellation; never retry.
                    try? await checkpoint(.modelCall(.init(
                        id: invocationID, target: target, role: role, state: .failed,
                        promptTokens: nil, completionTokens: nil
                    )))
                    throw CancellationError()
                } catch {
                    let failure = (error as? PromptExperimentProviderFailure)
                        ?? PromptExperimentConnectedModelRunner.classifyProviderFailure(error)
                    try await checkpoint(.modelCall(.init(
                        id: invocationID, target: target, role: role, state: .failed,
                        promptTokens: nil, completionTokens: nil
                    )))
                    guard failure.code.isRetryable, retries < policy.maxRetries else { throw failure }
                    retries += 1
                    let delay = policy.delaySeconds(beforeRetry: retries, jitter: jitter())
                    guard uptime() + delay < deadline else { throw PromptExperimentProviderFailure(code: .timedOut) }
                    await onRetry?(retries, failure.code, delay)
                    try await backoffSleep(delay)
                }
            }
        }

        private func completeWithDeadline(
            target: PromptExperimentResolvedTarget,
            systemPrompt: String,
            userPrompt: String,
            remainingSeconds: Double
        ) async throws -> PromptExperimentConnectedModelCompletion {
            let completer = completer
            let callbackRoot = callbackRootBase.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            return try await withThrowingTaskGroup(of: PromptExperimentConnectedModelCompletion.self) { group in
                group.addTask { @MainActor in
                    try await completer.complete(
                        target: target,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        callbackRoot: callbackRoot
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(remainingSeconds))
                    throw PromptExperimentProviderFailure(code: .timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        }
    }
#endif
